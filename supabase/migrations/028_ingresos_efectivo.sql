-- ============================================================
-- RIDESOCOPÓ - Migración: INGRESOS REALES CON COMISIONES EFECTIVO
-- Corrige get_admin_metrics para incluir las comisiones de viajes
-- en efectivo que ya fueron descontadas de la wallet del conductor.
--
-- Antes: ingresos = tarifas + penalizaciones + recargas + pagos
--         − reembolsos − compensaciones − pagos_plataforma
-- Faltaba: comisiones de viajes en EFECTIVO (ya cobradas de wallets)
--
-- Después: + comisiones_efectivo al cálculo
-- ============================================================

-- ============================================================
-- REESCRIBIR GET_ADMIN_METRICS
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

  -- Dinero REAL que entra/sale
  v_tarifas_digitales NUMERIC := 0;
  v_penalizaciones NUMERIC := 0;
  v_reembolsos_clientes NUMERIC := 0;
  v_compensaciones_conductores NUMERIC := 0;
  
  -- 🔴 NUEVO: comisiones de viajes en efectivo (ya descontadas de wallets)
  v_comisiones_efectivo NUMERIC := 0;
  
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
  -- 🔴 comisiones SOLO de completados
  -- ============================================================
  SELECT
    COALESCE(SUM(r.commission_usd) FILTER (WHERE r.status = 'completada'), 0),
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
  -- TARIFAS DE VIAJES DIGITALES que ENTRARON a la plataforma
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
  -- 🔴 NUEVO: COMISIONES DE VIAJES EN EFECTIVO
  -- Estas comisiones YA fueron descontadas de la wallet del conductor
  -- por settle_ride_earnings → el dinero YA está en la plataforma
  -- ============================================================
  SELECT COALESCE(SUM(de.commission_usd), 0)
  INTO v_comisiones_efectivo
  FROM driver_earnings de
  JOIN rides r ON r.id = de.ride_id
  WHERE LOWER(r.payment_method) = 'efectivo'
    AND r.status = 'completada'
    AND r.created_at >= p_fecha_inicio
    AND r.created_at <= p_fecha_fin
    AND (p_conductor_id IS NULL OR r.driver_id = p_conductor_id)
    AND (p_cliente_id IS NULL OR r.client_id = p_cliente_id)
    AND (p_metodo IS NULL OR LOWER(r.payment_method) = LOWER(p_metodo));

  -- ============================================================
  -- SUMAR PENALIZACIONES / REEMBOLSOS / COMPENSACIONES
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
  -- 🔴 AHORA INCLUYE comisiones de efectivo
  -- ============================================================
  v_ingresos_reales :=
    v_tarifas_digitales        -- dinero que entró por viajes digitales
    + v_comisiones_efectivo    -- comisiones de efectivo YA descontadas de wallets 🔴
    + v_penalizaciones         -- dinero retenido al culpable
    + v_recargas               -- clientes que recargaron billetera
    + v_pagos_conductores      -- comisiones que SÍ pagaron los conductores
    - v_reembolsos_clientes    -- devoluciones al cliente
    - v_compensaciones_conductores -- compensaciones pagadas por incidentes
    - v_pagos_plataforma;      -- retiros pagados a conductores

  -- ============================================================
  -- DESGLOSE POR MÉTODO DE PAGO
  -- 🔴 comisiones SOLO de completados
  -- ============================================================
  SELECT COALESCE(jsonb_agg(t), '[]'::jsonb)
  INTO v_por_metodo
  FROM (
    SELECT
      LOWER(r.payment_method) AS metodo,
      COUNT(*) AS viajes,
      COUNT(*) FILTER (WHERE r.status = 'completada') AS completados,
      COALESCE(SUM(r.final_fare_usd), 0) AS tarifa_total,
      COALESCE(SUM(r.commission_usd) FILTER (WHERE r.status = 'completada'), 0) AS comision_total
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
  -- 🔴 comisiones SOLO de completados
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
      COALESCE(SUM(r.commission_usd) FILTER (WHERE r.status = 'completada'), 0) AS comisiones
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
      'comisiones_efectivo', v_comisiones_efectivo,
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
-- VERIFICACIÓN
-- ============================================================
SELECT 'Migración: ingresos reales con comisiones efectivo completada' AS estado;