-- ============================================================
-- RIDESOCOPÓ - Migración: MÉTRICAS DE ADMINISTRACIÓN
-- RPC get_admin_metrics con filtros dinámicos
-- - Resumen financiero (plataforma vs conductores)
-- - Desglose por método de pago, conductor y cliente
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
  -- ESTADO ACTUAL DE BILLETERAS DE CONDUCTORES
  -- (no filtrado por fecha: es el estado acumulado presente)
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
  -- Dinero que ya ellos recibieron del cliente, NO es de la app
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
  -- RECARGAS APROBADAS DE CLIENTES en el rango
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
      'ingresos_plataforma', v_comisiones,
      'deuda_con_conductores', v_deuda_app,
      'deuda_conductores', v_deuda_drivers,
      'efectivo_conductores', v_efectivo,
      'total_recargas', v_recargas,
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

GRANT EXECUTE ON FUNCTION public.get_admin_metrics TO anon, authenticated, service_role;

-- ============================================================
-- Verificación
-- ============================================================
SELECT 'Migración de métricas de administración completada' AS estado;