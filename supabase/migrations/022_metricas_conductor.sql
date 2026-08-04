-- ============================================================
-- RIDESOCOPÓ - Migración: MÉTRICAS DEL CONDUCTOR
-- RPC get_driver_metrics: el conductor ve SUS propias estadísticas
-- con filtros por fechas y método de pago
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_driver_metrics(
  p_fecha_inicio TIMESTAMPTZ DEFAULT NOW() - INTERVAL '30 days',
  p_fecha_fin TIMESTAMPTZ DEFAULT NOW(),
  p_metodo TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_total INTEGER := 0;
  v_completadas INTEGER := 0;
  v_canceladas INTEGER := 0;
  v_incidentes INTEGER := 0;
  v_comisiones NUMERIC := 0;
  v_tarifa_total NUMERIC := 0;
  v_tarifa_avg NUMERIC := 0;
  v_efectivo NUMERIC := 0;
  v_app_credit NUMERIC := 0;
  v_por_metodo JSONB;
  v_detalle_viajes JSONB;
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  -- Verificar que el usuario es conductor
  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_driver_id AND role = 'conductor') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- ============================================================
  -- RESUMEN DE VIAJES DEL CONDUCTOR
  -- ============================================================
  SELECT
    COUNT(*),
    COUNT(*) FILTER (WHERE status = 'completada'),
    COUNT(*) FILTER (WHERE status = 'cancelada'),
    COUNT(*) FILTER (WHERE status = 'incidente'),
    COALESCE(SUM(commission_usd), 0),
    COALESCE(SUM(final_fare_usd), 0),
    COALESCE(AVG(CASE WHEN status = 'completada' THEN final_fare_usd END), 0)
  INTO v_total, v_completadas, v_canceladas, v_incidentes, v_comisiones, v_tarifa_total, v_tarifa_avg
  FROM rides
  WHERE driver_id = v_driver_id
    AND created_at >= p_fecha_inicio
    AND created_at <= p_fecha_fin
    AND (p_metodo IS NULL OR LOWER(payment_method) = LOWER(p_metodo));

  -- ============================================================
  -- GANANCIAS (efectivo y app) en el rango
  -- ============================================================
  SELECT
    COALESCE(SUM(de.cash_received_usd), 0),
    COALESCE(SUM(de.app_credit_usd), 0)
  INTO v_efectivo, v_app_credit
  FROM driver_earnings de
  JOIN rides r ON r.id = de.ride_id
  WHERE de.driver_id = v_driver_id
    AND r.created_at >= p_fecha_inicio
    AND r.created_at <= p_fecha_fin
    AND (p_metodo IS NULL OR LOWER(r.payment_method) = LOWER(p_metodo));

  -- ============================================================
  -- DESGLOSE POR MÉTODO DE PAGO (solo viajes del conductor)
  -- ============================================================
  SELECT COALESCE(jsonb_agg(t), '[]'::jsonb)
  INTO v_por_metodo
  FROM (
    SELECT
      LOWER(r.payment_method) AS metodo,
      COUNT(*) AS viajes,
      COUNT(*) FILTER (WHERE r.status = 'completada') AS completados,
      COALESCE(SUM(r.final_fare_usd), 0) AS tarifa_total,
      COALESCE(SUM(de.cash_received_usd), 0) AS efectivo_recibido,
      COALESCE(SUM(de.app_credit_usd), 0) AS app_acredito
    FROM rides r
    LEFT JOIN driver_earnings de ON de.ride_id = r.id
    WHERE r.driver_id = v_driver_id
      AND r.created_at >= p_fecha_inicio
      AND r.created_at <= p_fecha_fin
      AND (p_metodo IS NULL OR LOWER(r.payment_method) = LOWER(p_metodo))
    GROUP BY LOWER(r.payment_method)
    ORDER BY tarifa_total DESC
  ) t;

  -- ============================================================
  -- ÚLTIMOS VIAJES CON DETALLE (limit 20)
  -- ============================================================
  SELECT COALESCE(jsonb_agg(t), '[]'::jsonb)
  INTO v_detalle_viajes
  FROM (
    SELECT
      r.id AS ride_id,
      r.payment_method,
      r.status,
      r.final_fare_usd,
      r.commission_usd,
      r.created_at,
      r.destination_address,
      COALESCE(de.cash_received_usd, 0) AS cash_received,
      COALESCE(de.app_credit_usd, 0) AS app_credit
    FROM rides r
    LEFT JOIN driver_earnings de ON de.ride_id = r.id
    WHERE r.driver_id = v_driver_id
      AND r.created_at >= p_fecha_inicio
      AND r.created_at <= p_fecha_fin
      AND (p_metodo IS NULL OR LOWER(r.payment_method) = LOWER(p_metodo))
    ORDER BY r.created_at DESC
    LIMIT 20
  ) t;

  -- ============================================================
  -- RESPUESTA
  -- ============================================================
  RETURN jsonb_build_object(
    'resumen', jsonb_build_object(
      'total_viajes', v_total,
      'viajes_completados', v_completadas,
      'viajes_cancelados', v_canceladas,
      'viajes_incidentes', v_incidentes,
      'comisiones_totales', v_comisiones,
      'tarifa_total', v_tarifa_total,
      'tarifa_promedio', v_tarifa_avg,
      'efectivo_recibido', v_efectivo,
      'app_acredito', v_app_credit
    ),
    'por_metodo', v_por_metodo,
    'detalle_viajes', v_detalle_viajes
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_driver_metrics TO anon, authenticated, service_role;

-- ============================================================
-- Verificación
-- ============================================================
SELECT 'Migración de métricas del conductor completada' AS estado;