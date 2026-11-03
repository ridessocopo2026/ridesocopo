-- ============================================================
-- 127 - DESGLOSE DE LA DEUDA DE BILLETERAS (conductores vs clientes)
-- ------------------------------------------------------------
-- Problema:
--   El panel principal mostraba "Debe a clientes y conductores"
--   con un único total (SUM de todos los saldos positivos). Al ver
--   2,95 no se entendía de dónde salía: 1,45 era de un conductor y
--   1,50 era SALDO EN LA BILLETERA DE UN CLIENTE (reembolso
--   acreditado), no una deuda pendiente de pago.
--
-- Solución:
--   get_wallet_overview() devuelve además el desglose:
--     · deuda_conductores   (lo que la app le debe a conductores)
--     · deuda_clientes      (saldo a favor en billeteras de clientes)
--     · conteos por rol
--   `deuda_wallets` sigue siendo el TOTAL (misma semántica de antes),
--   así que patrimonio_app y cualquier consumidor no cambian.
--
-- Costo: 1 sola pasada sobre wallets (antes también era 1).
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_wallet_overview(p_zone_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_caller_zone UUID;
  v_zone UUID;
  v_total_banco NUMERIC := 0;
  v_deuda_wallets NUMERIC := 0;
  v_deuda_conductores NUMERIC := 0;
  v_deuda_clientes NUMERIC := 0;
  v_conductores_con_saldo BIGINT := 0;
  v_clientes_con_saldo BIGINT := 0;
  v_patrimonio_app NUMERIC := 0;
  v_recargas NUMERIC := 0;
  v_pagos_pago_movil NUMERIC := 0;
  v_pagos_conductores_plataforma NUMERIC := 0;
  v_pagos_plataforma_conductores NUMERIC := 0;
BEGIN
  -- Solo admin/encargado
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- El encargado solo su ciudad; el super_admin puede elegir (NULL = todas)
  v_caller_zone := public.caller_zone_id();
  v_zone := COALESCE(v_caller_zone, p_zone_id);

  -- ============================================================
  -- ENTRADAS FÍSICAS (dinero que llegó al banco del admin)
  -- ============================================================

  -- 1a. Recargas aprobadas de clientes (por ciudad del cliente)
  SELECT COALESCE(SUM(t.amount_usd), 0)
  INTO v_recargas
  FROM transactions t
  JOIN profiles p ON p.id = t.user_id
  WHERE t.type = 'recarga'
    AND t.status IN ('aprobado', 'completado')
    AND p.role = 'cliente'
    AND (v_zone IS NULL OR p.zone_id = v_zone);

  -- 1b. Viajes pagados con Pago Móvil (comprobante aprobado)
  SELECT COALESCE(SUM(r.final_fare_usd), 0)
  INTO v_pagos_pago_movil
  FROM rides r
  WHERE LOWER(r.payment_method) IN ('pago móvil', 'pago movil')
    AND r.proof_status = 'aprobado'
    AND (v_zone IS NULL OR r.origin_zone_id = v_zone);

  -- 1c. Conductores que pagaron a la plataforma (payout aprobado)
  SELECT COALESCE(SUM(po.amount_usd), 0)
  INTO v_pagos_conductores_plataforma
  FROM payouts po
  LEFT JOIN profiles p ON p.id = po.driver_id
  WHERE po.type = 'driver_pay_platform'
    AND po.status = 'aprobado'
    AND (v_zone IS NULL OR p.zone_id = v_zone);

  -- 1d. Pagos de plataforma → conductores (retiros/liquidaciones)
  SELECT COALESCE(SUM(po.amount_usd), 0)
  INTO v_pagos_plataforma_conductores
  FROM payouts po
  LEFT JOIN profiles p ON p.id = po.driver_id
  WHERE po.type = 'platform_pay_driver'
    AND po.status IN ('aprobado', 'confirmado')
    AND (v_zone IS NULL OR p.zone_id = v_zone);

  v_total_banco := v_recargas
                 + v_pagos_pago_movil
                 + v_pagos_conductores_plataforma
                 - v_pagos_plataforma_conductores;

  -- ============================================================
  -- DEUDA A WALLETS (lo que la app debe a usuarios)
  -- Una sola pasada: total + desglose por rol.
  -- Solo saldos positivos (los negativos son deuda HACIA la app).
  -- ============================================================
  SELECT
    COALESCE(SUM(w.balance_usd), 0),
    COALESCE(SUM(w.balance_usd) FILTER (WHERE p.role = 'conductor'), 0),
    COALESCE(SUM(w.balance_usd) FILTER (WHERE p.role = 'cliente'), 0),
    COUNT(*) FILTER (WHERE p.role = 'conductor'),
    COUNT(*) FILTER (WHERE p.role = 'cliente')
  INTO v_deuda_wallets,
       v_deuda_conductores,
       v_deuda_clientes,
       v_conductores_con_saldo,
       v_clientes_con_saldo
  FROM wallets w
  JOIN profiles p ON p.id = w.user_id
  WHERE w.balance_usd > 0
    AND (v_zone IS NULL OR p.zone_id = v_zone);

  -- ============================================================
  -- PATRIMONIO (lo que realmente le pertenece a la app)
  -- ============================================================
  v_patrimonio_app := ROUND(v_total_banco - v_deuda_wallets, 2);

  RETURN jsonb_build_object(
    'zona', jsonb_build_object(
      'zone_id', v_zone,
      'es_global', (v_zone IS NULL),
      'forzada_por_rol', (v_caller_zone IS NOT NULL)
    ),
    'total_banco', ROUND(v_total_banco, 2),
    'deuda_wallets', ROUND(v_deuda_wallets, 2),
    -- Desglose: qué parte es de conductores y qué parte es saldo a favor
    -- dentro de la billetera de un cliente.
    'deuda_conductores', ROUND(v_deuda_conductores, 2),
    'deuda_clientes', ROUND(v_deuda_clientes, 2),
    'conteos', jsonb_build_object(
      'conductores_con_saldo', v_conductores_con_saldo,
      'clientes_con_saldo', v_clientes_con_saldo
    ),
    'patrimonio_app', v_patrimonio_app,
    'detalle', jsonb_build_object(
      'recargas_clientes', ROUND(v_recargas, 2),
      'pagos_pago_movil_viajes', ROUND(v_pagos_pago_movil, 2),
      'pagos_conductores_plataforma', ROUND(v_pagos_conductores_plataforma, 2),
      'pagos_plataforma_conductores', ROUND(v_pagos_plataforma_conductores, 2)
    )
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_wallet_overview(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_wallet_overview(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_wallet_overview(uuid) FROM anon;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'Migración 127 aplicada: deuda de wallets desglosada' AS estado;
