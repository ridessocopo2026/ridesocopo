-- ============================================================
-- BUNRIDER - Migración 071: DISPONIBILIDAD CORRECTA
-- ------------------------------------------------------------
-- BUG: get_available_driver_counts (070) contaba con
-- vehicles.is_active (LEGACY) en vez de la regla real del
-- matching: is_approved AND is_active_vehicle.
-- Eso hacía que un conductor con un vehículo PENDIENTE o con un
-- vehículo que ya NO es su activo apareciera disponible en
-- categorías donde no puede recibir viajes.
--
-- Regla canónica (la que ya usan las ofertas de viaje):
--   vehicles.is_approved = TRUE AND vehicles.is_active_vehicle = TRUE
--
-- Además se alinea la RLS (driver_has_vehicle_for_category) y se
-- blinda accept_ride con un trigger (sin reescribir la función).
-- ============================================================

-- Índice parcial: el conteo por categoría queda indexado y barato
CREATE INDEX IF NOT EXISTS idx_vehicles_driver_approved_active
  ON public.vehicles (driver_id, category)
  WHERE is_approved = TRUE AND is_active_vehicle = TRUE;

-- ============================================================
-- 1. CONTEO REAL DE DISPONIBLES (regla canónica + no ocupado)
--    "Disponible ahora" = conectado + dentro de horario +
--    vehículo aprobado y activo de esa categoría + sin viaje activo.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_available_driver_counts(p_zone_id UUID DEFAULT NULL)
RETURNS TABLE (category TEXT, available INTEGER)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT c.name::TEXT AS category, COUNT(p.id)::INTEGER AS available
  FROM public.vehicle_categories c
  LEFT JOIN public.profiles p
    ON p.role = 'conductor'
   AND p.driver_status = 'aprobado'
   AND (p_zone_id IS NULL OR p.zone_id IS NULL OR p.zone_id = p_zone_id)
   AND public.driver_available_now(p.id)
   AND EXISTS (
     SELECT 1 FROM public.vehicles v
     WHERE v.driver_id = p.id
       AND v.category = c.name
       AND v.is_approved = TRUE
       AND v.is_active_vehicle = TRUE
   )
   AND NOT EXISTS (
     SELECT 1 FROM public.rides r
     WHERE r.driver_id = p.id
       AND r.status IN ('aceptada', 'en_ruta', 'incidente')
   )
  WHERE c.is_active = TRUE
  GROUP BY c.name, c.base_fare_usd
  ORDER BY c.base_fare_usd;
$$;

GRANT EXECUTE ON FUNCTION public.get_available_driver_counts(uuid) TO anon, authenticated, service_role;

-- ============================================================
-- 2. RLS: ver viajes disponibles SOLO con vehículo aprobado y activo
--    (antes usaba is_active legacy → veías viajes que no podías tomar)
-- ============================================================
CREATE OR REPLACE FUNCTION public.driver_has_vehicle_for_category(category_param vehicle_category)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.vehicles v
    WHERE v.driver_id = auth.uid()
      AND v.category = category_param
      AND v.is_approved = TRUE
      AND v.is_active_vehicle = TRUE
  );
$$;

GRANT EXECUTE ON FUNCTION public.driver_has_vehicle_for_category(public.vehicle_category) TO anon, authenticated, service_role;

-- ============================================================
-- 3. BLINDAJE DE ACEPTACIÓN (sin reescribir accept_ride)
--    Al pasar de 'buscando' → 'aceptada'/'en_ruta' se exige que el
--    conductor tenga un vehículo APROBADO y ACTIVO de esa categoría.
--    El staff (super_admin/encargado) queda exento.
-- ============================================================
CREATE OR REPLACE FUNCTION public.enforce_accept_vehicle_approved()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF OLD.status = 'buscando'
     AND NEW.status IN ('aceptada', 'en_ruta')
     AND NEW.driver_id IS NOT NULL
     AND NEW.driver_id IS DISTINCT FROM OLD.driver_id THEN

    IF public.get_user_role(auth.uid()) NOT IN ('super_admin', 'encargado') THEN
      IF NOT EXISTS (
        SELECT 1 FROM public.vehicles v
        WHERE v.driver_id = NEW.driver_id
          AND v.category = NEW.category
          AND v.is_approved = TRUE
          AND v.is_active_vehicle = TRUE
      ) THEN
        RAISE EXCEPTION 'No tienes un vehículo aprobado y activo de esta categoría';
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_enforce_accept_vehicle_approved ON public.rides;
CREATE TRIGGER trg_enforce_accept_vehicle_approved
  BEFORE UPDATE ON public.rides
  FOR EACH ROW
  EXECUTE FUNCTION public.enforce_accept_vehicle_approved();

-- ============================================================
-- 4. DIAGNÓSTICO PARA ADMIN/ENCARGADO
--    Permite auditar que el conteo coincide con la realidad.
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_availability_overview()
RETURNS TABLE (
  driver_id UUID,
  driver_name TEXT,
  is_online BOOLEAN,
  in_schedule BOOLEAN,
  zone_id UUID,
  vehicle_category TEXT,
  vehicle_plate TEXT,
  vehicle_approved BOOLEAN,
  vehicle_active BOOLEAN,
  busy BOOLEAN,
  eligible BOOLEAN
)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_role TEXT;
  v_zone UUID;
BEGIN
  v_role := public.get_user_role(v_uid);
  IF v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF v_role = 'encargado' THEN
    v_zone := public.caller_zone_id();
  END IF;

  RETURN QUERY
  SELECT
    p.id,
    p.full_name,
    COALESCE(p.is_online, FALSE),
    public.driver_in_schedule_now(p.id),
    p.zone_id,
    v.category::TEXT,
    v.plate,
    COALESCE(v.is_approved, FALSE),
    COALESCE(v.is_active_vehicle, FALSE),
    EXISTS (
      SELECT 1 FROM public.rides r
      WHERE r.driver_id = p.id AND r.status IN ('aceptada', 'en_ruta', 'incidente')
    ),
    (
      COALESCE(p.is_online, FALSE)
      AND public.driver_in_schedule_now(p.id)
      AND COALESCE(v.is_approved, FALSE)
      AND COALESCE(v.is_active_vehicle, FALSE)
      AND NOT EXISTS (
        SELECT 1 FROM public.rides r
        WHERE r.driver_id = p.id AND r.status IN ('aceptada', 'en_ruta', 'incidente')
      )
    )
  FROM public.profiles p
  LEFT JOIN public.vehicles v
    ON v.driver_id = p.id
   AND v.is_approved = TRUE
   AND v.is_active_vehicle = TRUE
  WHERE p.role = 'conductor'
    AND p.driver_status = 'aprobado'
    AND (v_zone IS NULL OR p.zone_id IS NULL OR p.zone_id = v_zone)
  ORDER BY p.full_name;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_availability_overview() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.admin_availability_overview() FROM anon;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 071: disponibilidad correcta (regla is_approved + is_active_vehicle)' AS estado;
