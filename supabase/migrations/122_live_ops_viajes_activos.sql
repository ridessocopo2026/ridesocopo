-- ============================================================
-- 122 - SUPERVISION EN VIVO: SECTOR DE ORIGEN + VIAJES ACTIVOS
-- ------------------------------------------------------------
-- 1) Guarda el barrio/sector de origen en el viaje.
-- 2) Backfill de viajes existentes.
-- 3) Indice parcial para viajes activos.
-- 4) get_live_ops devuelve active_rides con pasajero/conductor,
--    telefonos, coordenadas, distancias y estado del GPS.
-- ============================================================

ALTER TABLE public.rides ADD COLUMN IF NOT EXISTS origin_barrio_id UUID REFERENCES public.barrios(id);
ALTER TABLE public.rides ADD COLUMN IF NOT EXISTS origin_barrio_name TEXT;

CREATE OR REPLACE FUNCTION public.set_ride_origin_barrio()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_barrio RECORD;
BEGIN
  IF NEW.origin_lat IS NULL OR NEW.origin_lng IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT b.id, b.name INTO v_barrio
  FROM public.barrios b
  WHERE b.is_active = TRUE
    AND b.lat IS NOT NULL
    AND b.lng IS NOT NULL
    AND (NEW.origin_zone_id IS NULL OR b.zone_id = NEW.origin_zone_id)
  ORDER BY ST_Distance(
    ST_SetSRID(ST_MakePoint(b.lng, b.lat), 4326)::geography,
    ST_SetSRID(ST_MakePoint(NEW.origin_lng, NEW.origin_lat), 4326)::geography
  )
  LIMIT 1;

  IF v_barrio.id IS NOT NULL THEN
    NEW.origin_barrio_id := v_barrio.id;
    NEW.origin_barrio_name := v_barrio.name;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_set_ride_origin_barrio ON public.rides;
CREATE TRIGGER trg_set_ride_origin_barrio
  BEFORE INSERT OR UPDATE OF origin_lat, origin_lng, origin_zone_id ON public.rides
  FOR EACH ROW EXECUTE FUNCTION public.set_ride_origin_barrio();

WITH nearest AS (
  SELECT r.id AS ride_id, b.id AS barrio_id, b.name AS barrio_name,
         ROW_NUMBER() OVER (
           PARTITION BY r.id
           ORDER BY ST_Distance(
             ST_SetSRID(ST_MakePoint(b.lng, b.lat), 4326)::geography,
             ST_SetSRID(ST_MakePoint(r.origin_lng, r.origin_lat), 4326)::geography
           )
         ) AS rn
  FROM public.rides r
  JOIN public.barrios b
    ON b.is_active = TRUE
   AND b.lat IS NOT NULL
   AND b.lng IS NOT NULL
   AND (r.origin_zone_id IS NULL OR b.zone_id = r.origin_zone_id)
  WHERE r.origin_lat IS NOT NULL AND r.origin_lng IS NOT NULL
)
UPDATE public.rides r
SET origin_barrio_id = n.barrio_id,
    origin_barrio_name = n.barrio_name
FROM nearest n
WHERE n.ride_id = r.id AND n.rn = 1;

CREATE INDEX IF NOT EXISTS idx_rides_live_ops
  ON public.rides (status, origin_zone_id, created_at DESC)
  WHERE status IN ('buscando', 'aceptada', 'en_ruta', 'incidente');

REVOKE ALL ON FUNCTION public.set_ride_origin_barrio() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.set_ride_origin_barrio() FROM anon;
REVOKE ALL ON FUNCTION public.set_ride_origin_barrio() FROM authenticated;
-- ============================================================
-- get_live_ops ampliada: active_rides + active_counts
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_live_ops(p_zone_id uuid DEFAULT NULL::uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_role public.user_role;
  v_zone uuid;
  v_counts jsonb;
  v_drivers jsonb;
  v_pending jsonb;
  v_active jsonb;
  v_active_counts jsonb;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION 'No autenticado'; END IF;
  SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;
  IF v_role NOT IN ('super_admin','encargado') THEN RAISE EXCEPTION 'No autorizado'; END IF;
  IF v_role = 'encargado' THEN v_zone := public.caller_zone_id(); ELSE v_zone := p_zone_id; END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object('category', c.category, 'available', c.available, 'busy', c.busy)), '[]'::jsonb)
    INTO v_counts FROM public.get_available_driver_counts(v_zone) c;

  SELECT COALESCE(jsonb_agg(to_jsonb(d)), '[]'::jsonb) INTO v_drivers FROM (
    SELECT p.id AS driver_id, p.full_name, p.phone, p.zone_id, COALESCE(p.is_online,false) AS is_online,
      public.driver_in_schedule_now(p.id) AS in_schedule,
      public.driver_available_now(p.id) AS available_now,
      EXISTS (SELECT 1 FROM public.rides r WHERE r.driver_id = p.id AND r.status IN ('aceptada','en_ruta','incidente')) AS busy,
      (SELECT COALESCE(jsonb_agg(DISTINCT v.category::text), '[]'::jsonb) FROM public.vehicles v WHERE v.driver_id = p.id AND v.is_approved = TRUE AND v.is_active_vehicle = TRUE) AS categories,
      (SELECT jsonb_build_object('brand', v.brand, 'model', v.model, 'plate', v.plate, 'category', v.category::text)
        FROM public.vehicles v WHERE v.driver_id = p.id AND v.is_approved = TRUE AND v.is_active_vehicle = TRUE ORDER BY v.updated_at DESC LIMIT 1) AS vehicle
    FROM public.profiles p
    WHERE p.role = 'conductor' AND p.driver_status = 'aprobado'
      AND (v_zone IS NULL OR p.zone_id IS NULL OR p.zone_id = v_zone)
    ORDER BY public.driver_available_now(p.id) DESC, p.full_name LIMIT 200
  ) d;

  SELECT COALESCE(jsonb_agg(to_jsonb(x)), '[]'::jsonb) INTO v_pending FROM (
    SELECT r.id AS ride_id, r.tracking_code, r.category::text AS category, r.final_fare_usd, r.origin_zone_id,
      r.created_at, r.payment_method,
      GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (NOW() - r.created_at)) / 60))::int AS waiting_minutes
    FROM public.rides r
    WHERE r.status = 'buscando' AND r.driver_id IS NULL
      AND (v_zone IS NULL OR r.origin_zone_id = v_zone)
    ORDER BY r.created_at LIMIT 100
  ) x;

  SELECT COALESCE(jsonb_agg(to_jsonb(a) ORDER BY a.created_at), '[]'::jsonb) INTO v_active FROM (
    SELECT r.id AS ride_id, r.tracking_code, r.status::text AS status, r.category::text AS category,
      r.payment_method, r.final_fare_usd,
      r.client_id, cl.full_name AS cliente, cl.phone AS cliente_phone,
      r.driver_id, dr.full_name AS conductor, dr.phone AS conductor_phone,
      (SELECT jsonb_build_object('brand', v.brand, 'model', v.model, 'plate', v.plate, 'category', v.category::text)
        FROM public.vehicles v WHERE v.driver_id = r.driver_id AND v.is_approved = TRUE AND v.is_active_vehicle = TRUE
        ORDER BY v.updated_at DESC LIMIT 1) AS vehiculo,
      r.origin_address, r.origin_barrio_name, r.origin_lat, r.origin_lng,
      r.destination_address, r.destination_barrio_name, r.destination_lat, r.destination_lng,
      r.driver_location_lat, r.driver_location_lng, r.driver_last_update,
      r.created_at, r.started_at, r.updated_at,
      GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (NOW() - r.created_at)) / 60))::int AS minutos_transcurridos,
      CASE WHEN r.driver_last_update IS NULL THEN NULL
           ELSE GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (NOW() - r.driver_last_update)) / 60))::int END AS minutos_sin_gps,
      (r.driver_last_update IS NOT NULL AND NOW() - r.driver_last_update > INTERVAL '2 minutes') AS gps_vencido,
      CASE WHEN r.driver_location_lat IS NOT NULL AND r.driver_location_lng IS NOT NULL
           THEN ROUND((ST_Distance(
             ST_SetSRID(ST_MakePoint(r.driver_location_lng, r.driver_location_lat), 4326)::geography,
             ST_SetSRID(ST_MakePoint(r.origin_lng, r.origin_lat), 4326)::geography
           ) / 1000)::numeric, 2)
           ELSE NULL END AS distancia_conductor_origen_km,
      ROUND((ST_Distance(
        ST_SetSRID(ST_MakePoint(r.origin_lng, r.origin_lat), 4326)::geography,
        ST_SetSRID(ST_MakePoint(r.destination_lng, r.destination_lat), 4326)::geography
      ) / 1000)::numeric, 2) AS distancia_origen_destino_km
    FROM public.rides r
    LEFT JOIN public.profiles cl ON cl.id = r.client_id
    LEFT JOIN public.profiles dr ON dr.id = r.driver_id
    WHERE r.status IN ('buscando','aceptada','en_ruta','incidente')
      AND (v_zone IS NULL OR r.origin_zone_id = v_zone)
    ORDER BY r.created_at
    LIMIT 100
  ) a;

  SELECT jsonb_build_object(
    'buscando', COUNT(*) FILTER (WHERE r.status = 'buscando'),
    'aceptada', COUNT(*) FILTER (WHERE r.status = 'aceptada'),
    'en_ruta', COUNT(*) FILTER (WHERE r.status = 'en_ruta'),
    'incidente', COUNT(*) FILTER (WHERE r.status = 'incidente'),
    'total', COUNT(*)
  ) INTO v_active_counts
  FROM public.rides r
  WHERE r.status IN ('buscando','aceptada','en_ruta','incidente')
    AND (v_zone IS NULL OR r.origin_zone_id = v_zone);

  RETURN jsonb_build_object(
    'zone_id', v_zone,
    'counts', v_counts,
    'drivers', v_drivers,
    'pending_rides', v_pending,
    'active_rides', v_active,
    'active_counts', v_active_counts
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_live_ops(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_live_ops(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.get_live_ops(uuid) TO authenticated, service_role;

SELECT 'Migracion 122 aplicada: viajes activos en operacion en vivo' AS estado;