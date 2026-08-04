-- ============================================================
-- RIDESOCOPÓ - Migración: MÉTRICAS REALES + DETALLE TRANSACCIONES
-- ============================================================
-- 1. Reescribe get_admin_metrics: ingresos_plataforma calculado
--    como el dinero REAL que entra/sale de la plataforma.
--    NO solo commission_usd (que es un abono pendiente).
--
--    ingresos_reales =
--      + tarifas de viajes digitales (lo que el cliente pagó)
--      + penalizaciones de incidentes (dinero retenido al culpable)
--      + recargas aprobadas (clientes que cargaron saldo)
--      + pagos de conductores a plataforma aprobados (comisiones pagadas)
--      − reembolsos a clientes por incidentes
--      − compensaciones a conductores (incidentes + retiros)
--      − pagos plataforma→conductor confirmados
--
-- 2. Nueva RPC get_admin_transactions: listado paginado de TODAS
--    las transacciones con filtros (tipo, fecha, rol, usuario).
-- ============================================================

-- ============================================================
-- 1. REESCRIBIR GET_ADMIN_METRICS
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_admin_metrics(
  p_fecha_inicio TIMESTAMPTZ DEFAULT NOW() - INTERVAL '30 days',
  p_fecha_fin TIMESTAMPTZ DEFAULT NOW(),
  p_conductor_id UUID DEFAULT NULL,
  p_cliente_id UUID DEFAULT NULL,
  p_metodo TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_comisiones NUMERIC := 0;
  v_total INTEGER := 0;
  v_completadas INTEGER := 0;
  v_canceladas INTEGER := 0;
  v_incidentes INTEGER := 0;
  v_tarifa_avg NUMERIC := 0;
  v_deuda_app NUMERIC := 0;
  v_deuda_drivers NUMERIC := 0;
  v_efectivo NUMERIC := 0;
  v_recargas NUMERIC := 0;
  v_pagos_conductores NUMERIC := 0;
  v_pagos_plataforma NUMERIC := 0;

  -- NUEVOS: dinero REAL que entra/sale
  v_tarifas_digitales NUMERIC := 0;
  v_penalizaciones NUMERIC := 0;
  v_reembolsos_clientes NUMERIC := 0;
  v_compensaciones_conductores NUMERIC := 0;
  v_ingresos_reales NUMERIC := 0;

  v_por_metodo JSONB;
  v_por_conductor JSONB;
  v_por_cliente JSONB;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- ============================================================
  -- RESUMEN DE VIAJES (con filtros)
  -- ============================================================
  SELECT
    COALESCE(SUM(r.commission_usd), 0),
    COUNT(*),
    COUNT(*) FILTER (WHERE r.status = 'completada'),
    COUNT(*) FILTER (WHERE r.status = 'cancelada'),
    COUNT(*) FILTER (WHERE r.status = 'incidente'),
    COALESCE(AVG(CASE WHEN r.status = 'completada' THEN r.final_fare_usd END), 0)
  INTO v_comisiones, v_total, v_completadas, v_canceladas, v_incidentes, v_tarifa_avg
  FROM rides r
  WHERE r.created_at >= p_fecha_inicio
    AND r.created_at <= p_fecha_fin
    AND (p_conductor_id IS NULL OR r.driver_id = p_conductor_id)
    AND (p_cliente_id IS NULL OR r.client_id = p_cliente_id)
    AND (p_metodo IS NULL OR LOWER(r.payment_method) = LOWER(p_metodo));

  -- ============================================================
  -- NUEVO: TARIFAS DE VIAJES DIGITALES que ENTRARON a la plataforma
  -- (Pago Móvil y Billetera: el cliente pagó, el dinero está en la app)
  -- ============================================================
  SELECT COALESCE(SUM(r.final_fare_usd), 0)
  INTO v_tarifas_digitales
  FROM rides r
  WHERE r.created_at >= p_fecha_inicio
    AND r.created_at <= p_fecha_fin
    AND LOWER(r.payment_method) IN ('pago móvil', 'pago movil', 'billetera')
    AND r.status IN ('completada', 'cancelada')
    AND (p_conductor_id IS NULL OR r.driver_id = p_conductor_id)
    AND (p_cliente_id IS NULL OR r.client_id = p_cliente_id)
    AND (p_metodo IS NULL OR LOWER(r.payment_method) = LOWER(p_metodo));

  -- ============================================================
  -- NUEVO: SUMAR PENALIZACIONES / REEMBOLSOS / COMPENSACIONES
  -- desde resolution_details de ride_incidents resueltos
  -- ============================================================
  SELECT
    COALESCE(SUM((ri.resolution_details->>'penalty')::numeric), 0),
    COALESCE(SUM((ri.resolution_details->>'refund_client')::numeric), 0),
    COALESCE(SUM((ri.resolution_details->>'compensate_driver')::numeric), 0)
  INTO v_penalizaciones, v_reembolsos_clientes, v_compensaciones_conductores
  FROM ride_incidents ri
  JOIN rides r ON r.id = ri.ride_id
  WHERE ri.status = 'resuelto'
    AND ri.resolved_at >= p_fecha_inicio
    AND ri.resolved_at <= p_fecha_fin
    AND (p_conductor_id IS NULL OR r.driver_id = p_conductor_id)
    AND (p_cliente_id IS NULL OR r.client_id = p_cliente_id)
    AND (p_metodo IS NULL OR LOWER(r.payment_method) = LOWER(p_metodo));

  -- ============================================================
  -- ESTADO ACTUAL DE BILLETERAS DE CONDUCTORES
  -- ============================================================
  SELECT
    COALESCE(SUM(w.balance_usd) FILTER (WHERE w.balance_usd > 0), 0),
    COALESCE(SUM(ABS(w.balance_usd)) FILTER (WHERE w.balance_usd < 0), 0)
  INTO v_deuda_app, v_deuda_drivers
  FROM wallets w
  JOIN profiles pr ON pr.id = w.user_id
  WHERE pr.role = 'conductor';

  -- ============================================================
  -- EFECTIVO COBRADO POR CONDUCTORES (con filtros)
  -- ============================================================
  SELECT COALESCE(SUM(de.cash_received_usd), 0)
  INTO v_efectivo
  FROM driver_earnings de
  JOIN rides r ON r.id = de.ride_id
  WHERE r.created_at >= p_fecha_inicio
    AND r.created_at <= p_fecha_fin
    AND (p_conductor_id IS NULL OR r.driver_id = p_conductor_id)
    AND (p_cliente_id IS NULL OR r.client_id = p_cliente_id)
    AND (p_metodo IS NULL OR LOWER(r.payment_method) = LOWER(p_metodo));

  -- ============================================================
  -- RECARGAS APROBADAS DE CLIENTES
  -- ============================================================
  SELECT COALESCE(SUM(t.amount_usd), 0)
  INTO v_recargas
  FROM transactions t
  WHERE t.type = 'recarga'
    AND t.status IN ('aprobado', 'completado')
    AND t.created_at >= p_fecha_inicio
    AND t.created_at <= p_fecha_fin;

  -- ============================================================
  -- PAGOS DE CONDUCTORES → PLATAFORMA (aprobados)
  -- ============================================================
  SELECT COALESCE(SUM(p.amount_usd), 0)
  INTO v_pagos_conductores
  FROM payouts p
  WHERE p.type = 'driver_pay_platform'
    AND p.status = 'aprobado'
    AND p.created_at >= p_fecha_inicio
    AND p.created_at <= p_fecha_fin;

  -- ============================================================
  -- PAGOS DE PLATAFORMA → CONDUCTORES (confirmados)
  -- ============================================================
  SELECT COALESCE(SUM(p.amount_usd), 0)
  INTO v_pagos_plataforma
  FROM payouts p
  WHERE p.type = 'platform_pay_driver'
    AND p.status IN ('aprobado', 'confirmado')
    AND p.created_at >= p_fecha_inicio
    AND p.created_at <= p_fecha_fin;

  -- ============================================================
  -- CÁLCULO REAL DE INGRESOS DE LA PLATAFORMA
  -- ============================================================
  v_ingresos_reales :=
    v_tarifas_digitales        -- dinero que entró por viajes digitales
    + v_penalizaciones         -- dinero retenido al culpable
    + v_recargas               -- clientes que recargaron billetera
    + v_pagos_conductores      -- comisiones que SÍ pagaron los conductores
    - v_reembolsos_clientes    -- devoluciones al cliente
    - v_compensaciones_conductores -- compensaciones pagadas por incidentes
    - v_pagos_plataforma;      -- retiros pagados a conductores

  -- ============================================================
  -- DESGLOSE POR MÉTODO DE PAGO
  -- ============================================================
  SELECT COALESCE(jsonb_agg(t), '[]'::jsonb)
  INTO v_por_metodo
  FROM (
    SELECT
      LOWER(r.payment_method) AS metodo,
      COUNT(*) AS viajes,
      COUNT(*) FILTER (WHERE r.status = 'completada') AS completados,
      COALESCE(SUM(r.final_fare_usd), 0) AS tarifa_total,
      COALESCE(SUM(r.commission_usd), 0) AS comision_total
    FROM rides r
    WHERE r.created_at >= p_fecha_inicio
      AND r.created_at <= p_fecha_fin
      AND (p_conductor_id IS NULL OR r.driver_id = p_conductor_id)
      AND (p_cliente_id IS NULL OR r.client_id = p_cliente_id)
      AND (p_metodo IS NULL OR LOWER(r.payment_method) = LOWER(p_metodo))
    GROUP BY LOWER(r.payment_method)
    ORDER BY comision_total DESC
  ) t;

  -- ============================================================
  -- RANKING POR CONDUCTOR
  -- ============================================================
  SELECT COALESCE(jsonb_agg(t), '[]'::jsonb)
  INTO v_por_conductor
  FROM (
    SELECT
      pr.full_name AS conductor,
      COUNT(*) AS viajes,
      COUNT(*) FILTER (WHERE r.status = 'completada') AS completados,
      COALESCE(SUM(de.cash_received_usd), 0) AS ganado_efectivo,
      COALESCE(SUM(de.app_credit_usd), 0) AS ganado_app,
      COALESCE(SUM(r.commission_usd), 0) AS comisiones
    FROM rides r
    LEFT JOIN profiles pr ON pr.id = r.driver_id
    LEFT JOIN driver_earnings de ON de.ride_id = r.id
    WHERE r.created_at >= p_fecha_inicio
      AND r.created_at <= p_fecha_fin
      AND (p_conductor_id IS NULL OR r.driver_id = p_conductor_id)
      AND (p_cliente_id IS NULL OR r.client_id = p_cliente_id)
      AND (p_metodo IS NULL OR LOWER(r.payment_method) = LOWER(p_metodo))
      AND r.driver_id IS NOT NULL
    GROUP BY pr.full_name
    ORDER BY completados DESC
    LIMIT 20
  ) t;

  -- ============================================================
  -- RANKING POR CLIENTE
  -- ============================================================
  SELECT COALESCE(jsonb_agg(t), '[]'::jsonb)
  INTO v_por_cliente
  FROM (
    SELECT
      pr.full_name AS cliente,
      COUNT(*) AS viajes,
      COUNT(*) FILTER (WHERE r.status = 'completada') AS completados,
      COALESCE(SUM(r.final_fare_usd), 0) AS total_gastado
    FROM rides r
    LEFT JOIN profiles pr ON pr.id = r.client_id
    WHERE r.created_at >= p_fecha_inicio
      AND r.created_at <= p_fecha_fin
      AND (p_conductor_id IS NULL OR r.driver_id = p_conductor_id)
      AND (p_cliente_id IS NULL OR r.client_id = p_cliente_id)
      AND (p_metodo IS NULL OR LOWER(r.payment_method) = LOWER(p_metodo))
    GROUP BY pr.full_name
    ORDER BY total_gastado DESC
    LIMIT 20
  ) t;

  -- ============================================================
  -- RESPUESTA COMPLETA
  -- ============================================================
  RETURN jsonb_build_object(
    'resumen', jsonb_build_object(
      'ingresos_plataforma', v_ingresos_reales,
      'comisiones_pendientes', v_comisiones,
      'deuda_con_conductores', v_deuda_app,
      'deuda_conductores', v_deuda_drivers,
      'efectivo_conductores', v_efectivo,
      'total_recargas', v_recargas,
      'tarifas_digitales', v_tarifas_digitales,
      'penalizaciones', v_penalizaciones,
      'reembolsos_clientes', v_reembolsos_clientes,
      'compensaciones_conductores', v_compensaciones_conductores,
      'pagos_conductores_plataforma', v_pagos_conductores,
      'pagos_plataforma_conductores', v_pagos_plataforma,
      'total_viajes', v_total,
      'viajes_completados', v_completadas,
      'viajes_cancelados', v_canceladas,
      'viajes_incidentes', v_incidentes,
      'tarifa_promedio', v_tarifa_avg
    ),
    'por_metodo', v_por_metodo,
    'por_conductor', v_por_conductor,
    'por_cliente', v_por_cliente
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_admin_metrics TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_metrics TO service_role;

-- ============================================================
-- 2. NUEVA RPC: GET_ADMIN_TRANSACTIONS
--    Listado paginado de TODAS las transacciones con detalle
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_admin_transactions(
  p_fecha_inicio TIMESTAMPTZ DEFAULT NOW() - INTERVAL '30 days',
  p_fecha_fin TIMESTAMPTZ DEFAULT NOW(),
  p_tipo TEXT DEFAULT NULL,
  p_rol TEXT DEFAULT NULL,          -- 'cliente' | 'conductor' | 'admin'
  p_usuario_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_total INTEGER := 0;
  v_items JSONB;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- Limitar tamaño de página (máx 100)
  IF p_limit > 100 THEN p_limit := 100; END IF;
  IF p_limit < 1 THEN p_limit := 50; END IF;
  IF p_offset < 0 THEN p_offset := 0; END IF;

  -- Contar total (para paginación)
  SELECT COUNT(*) INTO v_total
  FROM (
    SELECT t.id
    FROM transactions t
    LEFT JOIN profiles pr ON pr.id = t.user_id
    WHERE t.created_at >= p_fecha_inicio
      AND t.created_at <= p_fecha_fin
      AND (p_tipo IS NULL OR t.type = p_tipo)
      AND (p_usuario_id IS NULL OR t.user_id = p_usuario_id)
      AND (
        p_rol IS NULL
        OR (p_rol = 'cliente' AND pr.role = 'cliente')
        OR (p_rol = 'conductor' AND pr.role = 'conductor')
        OR (p_rol = 'admin' AND pr.role IN ('super_admin', 'encargado'))
      )
    UNION ALL
    SELECT po.id
    FROM payouts po
    LEFT JOIN profiles pr ON pr.id = po.driver_id
    WHERE po.created_at >= p_fecha_inicio
      AND po.created_at <= p_fecha_fin
      AND (p_tipo IS NULL OR po.type = p_tipo)
      AND (p_usuario_id IS NULL OR po.driver_id = p_usuario_id)
      AND (
        p_rol IS NULL
        OR (p_rol = 'conductor' AND pr.role = 'conductor')
        OR (p_rol = 'admin' AND pr.role IN ('super_admin', 'encargado'))
      )
  ) sub;

  -- Obtener items paginados
  SELECT COALESCE(jsonb_agg(t ORDER BY t.fecha DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    -- Transacciones de wallets (clientes y conductores)
    SELECT
      t.id::text AS id,
      'transaction' AS origen,
      t.created_at AS fecha,
      pr.full_name AS usuario,
      pr.role AS rol,
      t.user_id AS usuario_id,
      t.type AS tipo,
      t.amount_usd AS monto,
      t.status AS estado,
      t.description AS descripcion,
      t.reference AS referencia,
      t.ride_id AS viaje_id,
      NULL::text AS comprobante,
      COALESCE((SELECT balance_usd FROM wallets w WHERE w.id = t.wallet_id), 0) AS saldo_resultante
    FROM transactions t
    LEFT JOIN profiles pr ON pr.id = t.user_id
    WHERE t.created_at >= p_fecha_inicio
      AND t.created_at <= p_fecha_fin
      AND (p_tipo IS NULL OR t.type = p_tipo)
      AND (p_usuario_id IS NULL OR t.user_id = p_usuario_id)
      AND (
        p_rol IS NULL
        OR (p_rol = 'cliente' AND pr.role = 'cliente')
        OR (p_rol = 'conductor' AND pr.role = 'conductor')
        OR (p_rol = 'admin' AND pr.role IN ('super_admin', 'encargado'))
      )

    UNION ALL

    -- Payouts (liquidaciones entre plataforma y conductores)
    SELECT
      po.id::text AS id,
      'payout' AS origen,
      po.created_at AS fecha,
      pr.full_name AS usuario,
      pr.role AS rol,
      po.driver_id AS usuario_id,
      po.type AS tipo,
      po.amount_usd AS monto,
      po.status AS estado,
      po.description AS descripcion,
      NULL::text AS referencia,
      po.ride_id AS viaje_id,
      po.proof_url AS comprobante,
      0 AS saldo_resultante
    FROM payouts po
    LEFT JOIN profiles pr ON pr.id = po.driver_id
    WHERE po.created_at >= p_fecha_inicio
      AND po.created_at <= p_fecha_fin
      AND (p_tipo IS NULL OR po.type = p_tipo)
      AND (p_usuario_id IS NULL OR po.driver_id = p_usuario_id)
      AND (
        p_rol IS NULL
        OR (p_rol = 'conductor' AND pr.role = 'conductor')
        OR (p_rol = 'admin' AND pr.role IN ('super_admin', 'encargado'))
      )
  ) t
  LIMIT p_limit OFFSET p_offset;

  RETURN jsonb_build_object(
    'total', v_total,
    'items', v_items
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_admin_transactions TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_transactions TO service_role;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Métricas reales y detalle de transacciones aplicado' AS estado;