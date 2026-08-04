-- ============================================================
-- RIDESOCOPÓ - Migración: TRACKING DE VIAJES + MÉTRICAS FIJAS
-- ============================================================
-- 1. Columna tracking_code en rides (formato RS-XXXXXX para buscar rápido)
-- 2. Trigger que asigna tracking_code automáticamente al insertar
-- 3. Fix get_driver_metrics: comisiones SOLO de viajes completados
-- 4. Nueva RPC get_admin_rides: listado paginado con búsqueda y detalle
-- 5. Nueva RPC get_ride_by_tracking: búsqueda por tracking_code
-- ============================================================

-- ============================================================
-- 1. COLUMNA TRACKING_CODE
-- ============================================================
ALTER TABLE public.rides
  ADD COLUMN IF NOT EXISTS tracking_code TEXT UNIQUE;

-- Índice para búsqueda O(1) por tracking
CREATE INDEX IF NOT EXISTS idx_rides_tracking_code ON public.rides(tracking_code);

-- ============================================================
-- 2. TRIGGER: GENERAR TRACKING_CODE AUTOMÁTICAMENTE
--    Formato: RS-XXXXXX (6 caracteres alfanuméricos)
--    Usa una secuencia para ser único y rápido (sin consultas extra)
-- ============================================================
CREATE SEQUENCE IF NOT EXISTS public.tracking_code_seq START 1;

-- Función del trigger
CREATE OR REPLACE FUNCTION public.assign_tracking_code()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_num INTEGER;
  v_code TEXT;
BEGIN
  IF NEW.tracking_code IS NOT NULL THEN
    RETURN NEW;
  END IF;

  -- Generar número secuencial y codificar a base36 (0-9, A-Z)
  SELECT nextval('public.tracking_code_seq') INTO v_num;

  -- Convertir a string base36 de 6 caracteres
  v_code := UPPER(LPAD(SUBSTRING((
    SELECT string_agg(chr(65 + (v % 26)), '') FROM (
      SELECT v_num, (v_num / (26^x)) % 26 AS v FROM generate_series(0, 5) AS x
    ) t
  ), 1, 6), 6, '0'));

  -- Fallback: si la codificación falla, usar el número directo
  IF v_code IS NULL OR LENGTH(v_code) < 6 THEN
    v_code := UPPER(LPAD(v_num::text, 6, '0'));
  END IF;

  NEW.tracking_code := 'RS-' || v_code;
  RETURN NEW;
END;
$$;

-- Recrear trigger (si ya existe)
DROP TRIGGER IF EXISTS trg_assign_tracking_code ON public.rides;
CREATE TRIGGER trg_assign_tracking_code
  BEFORE INSERT ON public.rides
  FOR EACH ROW EXECUTE FUNCTION public.assign_tracking_code();

-- Asignar tracking_code a viajes existentes sin código
DO $$
DECLARE
  v_ride RECORD;
  v_num INTEGER;
  v_code TEXT;
BEGIN
  FOR v_ride IN SELECT id FROM rides WHERE tracking_code IS NULL ORDER BY created_at LOOP
    SELECT nextval('public.tracking_code_seq') INTO v_num;
    v_code := UPPER(LPAD(v_num::text, 6, '0'));
    UPDATE rides SET tracking_code = 'RS-' || v_code WHERE id = v_ride.id;
  END LOOP;
END;
$$;

-- ============================================================
-- 3. FIX GET_DRIVER_METRICS
--    🔴 comisiones SOLO de viajes completados
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

  IF NOT EXISTS (SELECT 1 FROM profiles WHERE id = v_driver_id AND role = 'conductor') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- RESUMEN DEL CONDUCTOR
  -- 🔴 comisiones SOLO de completados
  SELECT
    COUNT(*),
    COUNT(*) FILTER (WHERE status = 'completada'),
    COUNT(*) FILTER (WHERE status = 'cancelada'),
    COUNT(*) FILTER (WHERE status = 'incidente'),
    COALESCE(SUM(commission_usd) FILTER (WHERE status = 'completada'), 0),
    COALESCE(SUM(final_fare_usd), 0),
    COALESCE(AVG(CASE WHEN status = 'completada' THEN final_fare_usd END), 0)
  INTO v_total, v_completadas, v_canceladas, v_incidentes, v_comisiones, v_tarifa_total, v_tarifa_avg
  FROM rides
  WHERE driver_id = v_driver_id
    AND created_at >= p_fecha_inicio
    AND created_at <= p_fecha_fin
    AND (p_metodo IS NULL OR LOWER(payment_method) = LOWER(p_metodo));

  -- GANANCIAS (efectivo y app)
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

  -- DESGLOSE POR MÉTODO
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

  -- ÚLTIMOS VIAJES CON TRACKING_CODE
  SELECT COALESCE(jsonb_agg(t), '[]'::jsonb)
  INTO v_detalle_viajes
  FROM (
    SELECT
      r.id AS ride_id,
      r.tracking_code,
      r.payment_method,
      r.status,
      r.final_fare_usd,
      r.commission_usd,
      r.created_at,
      r.destination_address,
      r.cancellation_fee_usd,
      r.driver_compensation_usd,
      COALESCE(de.cash_received_usd, 0) AS cash_received,
      COALESCE(de.app_credit_usd, 0) AS app_credit
    FROM rides r
    LEFT JOIN driver_earnings de ON de.ride_id = r.id
    WHERE r.driver_id = v_driver_id
      AND r.created_at >= p_fecha_inicio
      AND r.created_at <= p_fecha_fin
      AND (p_metodo IS NULL OR LOWER(r.payment_method) = LOWER(p_metodo))
    ORDER BY r.created_at DESC
    LIMIT 50
  ) t;

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

GRANT EXECUTE ON FUNCTION public.get_driver_metrics TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_driver_metrics TO service_role;

-- ============================================================
-- 4. NUEVA RPC: GET_ADMIN_RIDES
--    Listado paginado de viajes con búsqueda por tracking/cliente/conductor
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_admin_rides(
  p_search TEXT DEFAULT NULL,          -- buscar por tracking_code, nombre o email
  p_fecha_inicio TIMESTAMPTZ DEFAULT NOW() - INTERVAL '90 days',
  p_fecha_fin TIMESTAMPTZ DEFAULT NOW(),
  p_status TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 25,
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

  -- Limitar tamaño (máx 50)
  IF p_limit > 50 THEN p_limit := 50; END IF;
  IF p_limit < 1 THEN p_limit := 25; END IF;
  IF p_offset < 0 THEN p_offset := 0; END IF;

  -- Normalizar búsqueda (vacío = NULL)
  IF p_search IS NOT NULL AND TRIM(p_search) = '' THEN
    p_search := NULL;
  END IF;

  -- Contar total
  SELECT COUNT(*) INTO v_total
  FROM rides r
  LEFT JOIN profiles cl ON cl.id = r.client_id
  LEFT JOIN profiles dr ON dr.id = r.driver_id
  WHERE r.created_at >= p_fecha_inicio
    AND r.created_at <= p_fecha_fin
    AND (p_status IS NULL OR r.status::text = p_status)
    AND (
      p_search IS NULL
      OR UPPER(r.tracking_code) LIKE UPPER('%' || p_search || '%')
      OR UPPER(cl.full_name) LIKE UPPER('%' || p_search || '%')
      OR UPPER(dr.full_name) LIKE UPPER('%' || p_search || '%')
      OR UPPER(cl.email) LIKE UPPER('%' || p_search || '%')
    );

  -- Obtener items paginados
  SELECT COALESCE(jsonb_agg(t ORDER BY t.fecha DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT
      r.id AS ride_id,
      r.tracking_code,
      r.status::text AS status,
      r.payment_method,
      r.final_fare_usd,
      r.commission_usd,
      r.created_at AS fecha,
      r.origin_address,
      r.destination_address,
      r.destination_barrio_name,
      r.proof_status,
      r.cancellation_fee_usd,
      r.driver_compensation_usd,
      cl.full_name AS cliente,
      dr.full_name AS conductor,
      COALESCE(de.cash_received_usd, 0) AS cash_received,
      COALESCE(de.app_credit_usd, 0) AS app_credit
    FROM rides r
    LEFT JOIN profiles cl ON cl.id = r.client_id
    LEFT JOIN profiles dr ON dr.id = r.driver_id
    LEFT JOIN driver_earnings de ON de.ride_id = r.id
    WHERE r.created_at >= p_fecha_inicio
      AND r.created_at <= p_fecha_fin
      AND (p_status IS NULL OR r.status::text = p_status)
      AND (
        p_search IS NULL
        OR UPPER(r.tracking_code) LIKE UPPER('%' || p_search || '%')
        OR UPPER(cl.full_name) LIKE UPPER('%' || p_search || '%')
        OR UPPER(dr.full_name) LIKE UPPER('%' || p_search || '%')
        OR UPPER(cl.email) LIKE UPPER('%' || p_search || '%')
      )
  ) t
  LIMIT p_limit OFFSET p_offset;

  RETURN jsonb_build_object(
    'total', v_total,
    'items', v_items
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_admin_rides TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_rides TO service_role;

-- ============================================================
-- 5. NUEVA RPC: GET_RIDE_FULL_DETAIL
--    Obtiene UN viaje con todos sus detalles (para expandir)
--    transacciones del viaje, incidente y estado financiero
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_ride_full_detail(p_ride_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_role TEXT;
  v_ride JSONB;
  v_transactions JSONB;
  v_incident JSONB;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT role::text INTO v_role FROM profiles WHERE id = v_user_id;

  SELECT jsonb_build_object(
    'ride_id', r.id,
    'tracking_code', r.tracking_code,
    'status', r.status,
    'category', r.category,
    'payment_method', r.payment_method,
    'origin_address', r.origin_address,
    'destination_address', r.destination_address,
    'destination_barrio_name', r.destination_barrio_name,
    'final_fare_usd', r.final_fare_usd,
    'commission_usd', r.commission_usd,
    'commission_rate', r.commission_rate,
    'cancellation_fee_usd', r.cancellation_fee_usd,
    'driver_compensation_usd', r.driver_compensation_usd,
    'created_at', r.created_at,
    'started_at', r.started_at,
    'completed_at', r.completed_at,
    'proof_status', r.proof_status,
    'client_id', r.client_id,
    'driver_id', r.driver_id
  ) INTO v_ride
  FROM rides r
  WHERE r.id = p_ride_id;

  IF v_ride IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  -- Verificar permiso: admin ve todo, participante ve el suyo
  IF v_role NOT IN ('super_admin', 'encargado') THEN
    IF NOT (v_ride->>'client_id')::uuid = v_user_id
       AND NOT (v_ride->>'driver_id')::uuid = v_user_id THEN
      RAISE EXCEPTION 'No autorizado';
    END IF;
  END IF;

  -- Transacciones del viaje
  SELECT COALESCE(jsonb_agg(t), '[]'::jsonb)
  INTO v_transactions
  FROM (
    SELECT
      t.id,
      t.type::text AS tipo,
      t.amount_usd AS monto,
      t.status::text AS estado,
      t.description AS descripcion,
      t.created_at AS fecha,
      pr.full_name AS usuario,
      pr.role AS rol
    FROM transactions t
    LEFT JOIN profiles pr ON pr.id = t.user_id
    WHERE t.ride_id = p_ride_id
    ORDER BY t.created_at ASC
  ) t;

  -- Incidente del viaje (si existe)
  SELECT jsonb_build_object(
    'incident_id', ri.id,
    'incident_type', ri.incident_type,
    'description', ri.description,
    'status', ri.status,
    'resolution', ri.resolution,
    'resolution_details', ri.resolution_details,
    'created_at', ri.created_at
  ) INTO v_incident
  FROM ride_incidents ri
  WHERE ri.ride_id = p_ride_id
  ORDER BY ri.created_at DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'ride', v_ride,
    'transacciones', v_transactions,
    'incidente', COALESCE(v_incident, NULL)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_ride_full_detail TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_ride_full_detail TO service_role;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Tracking de viajes + métricas fijas aplicado' AS estado;