-- ============================================================
-- RIDESOCOPÓ - Migración: VISTA GENERAL DEL DINERO EN BANCO
-- Muestra al admin:
--   1. total_banco    → dinero físico recibido (pago móvil/Zelle)
--   2. deuda_wallets  → saldo total que la app debe a usuarios
--   3. patrimonio_app → lo que realmente le pertenece a la app
--
-- patrimonio_app = total_banco - deuda_wallets
-- ============================================================

-- ============================================================
-- 1. RPC: GET_WALLET_OVERVIEW
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_wallet_overview()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_total_banco NUMERIC := 0;
  v_deuda_wallets NUMERIC := 0;
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

  -- ============================================================
  -- ENTRADAS FÍSICAS (dinero que llegó al banco del admin)
  -- ============================================================

  -- 1a. Recargas aprobadas de clientes (cargaron saldo con pago externo)
  SELECT COALESCE(SUM(t.amount_usd), 0)
  INTO v_recargas
  FROM transactions t
  JOIN profiles p ON p.id = t.user_id
  WHERE t.type = 'recarga'
    AND t.status IN ('aprobado', 'completado')
    AND p.role = 'cliente';

  -- 1b. Viajes pagados con Pago Móvil (comprobante aprobado)
  --     El dinero físico llegó al banco del admin cuando se aprobó
  SELECT COALESCE(SUM(r.final_fare_usd), 0)
  INTO v_pagos_pago_movil
  FROM rides r
  WHERE LOWER(r.payment_method) IN ('pago móvil', 'pago movil')
    AND r.proof_status = 'aprobado';

  -- 1c. Conductores que pagaron a la plataforma (payout aprobado)
  SELECT COALESCE(SUM(p.amount_usd), 0)
  INTO v_pagos_conductores_plataforma
  FROM payouts p
  WHERE p.type = 'driver_pay_platform'
    AND p.status = 'aprobado';

  -- ============================================================
  -- SALIDAS FÍSICAS (dinero que salió del banco del admin)
  -- ============================================================

  -- 1d. Pagos de plataforma → conductores (retiros/liquidaciones)
  SELECT COALESCE(SUM(p.amount_usd), 0)
  INTO v_pagos_plataforma_conductores
  FROM payouts p
  WHERE p.type = 'platform_pay_driver'
    AND p.status IN ('aprobado', 'confirmado');

  -- ============================================================
  -- CÁLCULO TOTAL EN BANCO
  -- ============================================================
  v_total_banco := v_recargas
                 + v_pagos_pago_movil
                 + v_pagos_conductores_plataforma
                 - v_pagos_plataforma_conductores;

  -- ============================================================
  -- DEUDA A WALLETS (lo que la app debe a clientes y conductores)
  -- Solo saldos positivos (si hay negativos = deuda a la app)
  -- ============================================================
  SELECT COALESCE(SUM(w.balance_usd), 0)
  INTO v_deuda_wallets
  FROM wallets w
  WHERE w.balance_usd > 0;

  -- ============================================================
  -- PATRIMONIO DE LA APP (lo que realmente le pertenece)
  -- ============================================================
  v_patrimonio_app := ROUND(v_total_banco - v_deuda_wallets, 2);

  RETURN jsonb_build_object(
    'total_banco', ROUND(v_total_banco, 2),
    'deuda_wallets', ROUND(v_deuda_wallets, 2),
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

GRANT EXECUTE ON FUNCTION public.get_wallet_overview TO anon, authenticated, service_role;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'Migración de dinero en banco completada' AS estado;