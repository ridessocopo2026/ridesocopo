-- ============================================================
-- 126 - INCIDENTES: INVOLUCRADOS + CONTACTOS EN UNA SOLA LLAMADA
-- ------------------------------------------------------------
-- Problema que resuelve:
--   La pantalla de Incidentes hacia 3 requests (RPC de incidentes,
--   rides.select('*') de hasta 100 filas y profiles.in(...)). Si la
--   RLS de rides/profiles bloqueaba alguna fila (encargado de otra
--   zona, cliente sin zona), el administrador se quedaba SIN ver
--   quien estaba involucrado ni su telefono, justo cuando mas lo
--   necesita para resolver el caso.
--
-- Solucion:
--   RPC unica get_admin_incidents(status, limit, offset) que hace el
--   JOIN incidente + viaje + cliente + conductor + quien reporto y
--   devuelve todo con paginacion. SECURITY DEFINER + validacion de
--   rol: no depende de la RLS del cliente y no expone nada a anon.
--
-- Costo:
--   · 1 request por pantalla (antes 3).
--   · Paginado en el servidor (20 por defecto, max 50) en lugar de
--     traer hasta 100 viajes con todas sus columnas.
--   · No crea tablas ni indices nuevos: usa idx_ride_incidents_status,
--     idx_ride_incidents_created e idx_rides_origin_zone_id.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_admin_incidents(
  p_status TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 20,
  p_offset INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_role TEXT;
  v_zone UUID;
  v_total INTEGER := 0;
  v_items JSONB;
BEGIN
  v_role := public.get_user_role(v_admin_id)::text;

  IF v_role IS NULL OR v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- El super_admin ve todas las ciudades; el encargado solo la suya.
  v_zone := public.caller_zone_id();
  IF v_role = 'super_admin' THEN
    v_zone := NULL;
  END IF;

  IF p_limit IS NULL OR p_limit < 1 THEN p_limit := 20; END IF;
  IF p_limit > 50 THEN p_limit := 50; END IF;
  IF p_offset IS NULL OR p_offset < 0 THEN p_offset := 0; END IF;

  IF p_status IS NOT NULL AND BTRIM(p_status) = '' THEN
    p_status := NULL;
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM ride_incidents i
  INNER JOIN rides r ON r.id = i.ride_id
  WHERE (p_status IS NULL OR i.status = p_status)
    AND (v_zone IS NULL OR r.origin_zone_id = v_zone);

  SELECT COALESCE(jsonb_agg(t ORDER BY t.created_at DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT
      -- Incidente
      i.id,
      i.ride_id,
      i.reported_by,
      i.incident_type,
      i.description,
      i.photo_urls,
      i.status,
      i.resolution,
      i.resolution_details,
      i.suggested_compensation_usd,
      i.resolved_by,
      i.resolved_at,
      i.created_at,
      i.updated_at,
      -- Viaje (solo lo que la pantalla necesita)
      r.tracking_code,
      r.status::text AS ride_status,
      r.payment_method,
      r.final_fare_usd,
      r.commission_usd,
      r.cancellation_fee_usd,
      r.driver_compensation_usd,
      r.cancelled_by,
      r.origin_address,
      r.destination_address,
      r.client_id,
      r.driver_id,
      -- Involucrados
      cl.full_name AS client_name,
      cl.phone     AS client_phone,
      dr.full_name AS driver_name,
      dr.phone     AS driver_phone,
      rp.full_name AS reporter_name,
      rp.phone     AS reporter_phone,
      rp.role::text AS reporter_role
    FROM ride_incidents i
    INNER JOIN rides r ON r.id = i.ride_id
    LEFT JOIN profiles cl ON cl.id = r.client_id
    LEFT JOIN profiles dr ON dr.id = r.driver_id
    LEFT JOIN profiles rp ON rp.id = i.reported_by
    WHERE (p_status IS NULL OR i.status = p_status)
      AND (v_zone IS NULL OR r.origin_zone_id = v_zone)
    ORDER BY i.created_at DESC
    LIMIT p_limit OFFSET p_offset
  ) t;

  RETURN jsonb_build_object(
    'total', v_total,
    'limit', p_limit,
    'offset', p_offset,
    'items', v_items
  );
END;
$$;

-- Permisos: se revoca PUBLIC (PostgreSQL concede EXECUTE a PUBLIC por defecto)
REVOKE ALL ON FUNCTION public.get_admin_incidents(text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_admin_incidents(text, integer, integer)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_admin_incidents(text, integer, integer) FROM anon;

-- ============================================================
-- VERIFICACION
-- ============================================================
SELECT 'Migracion 126 aplicada: get_admin_incidents con contactos' AS estado;

SELECT p.proname || ' :: ' || pg_get_function_arguments(p.oid) AS funcion
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname = 'get_admin_incidents';
