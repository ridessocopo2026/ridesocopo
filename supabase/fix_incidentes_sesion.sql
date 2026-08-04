-- ============================================================
-- RIDESOCOPÓ - FIX: INCIDENTES + SESIÓN
--
-- 1. get_driver_active_ride() EXCLUYE el estado 'incidente'
--    → El conductor ya no queda atrapado en la pantalla del viaje
--    → Puede volver al panel y recibir nuevos viajes
-- 2. get_client_active_ride() MANTIENE 'incidente' (el cliente SÍ
--    debe ver el estado del incidente hasta que el admin resuelva)
-- ============================================================

-- ============================================================
-- 1. REESCRIBIR GET_DRIVER_ACTIVE_RIDE
--    El conductor NO debe tener un "viaje activo" cuando hay un
--    incidente. El viaje queda congelado esperando al admin,
--    pero el conductor debe poder seguir trabajando.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_driver_active_ride()
RETURNS SETOF rides
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
BEGIN
  RETURN QUERY
  SELECT r.* FROM rides r
  WHERE r.driver_id = v_driver_id
    AND r.status IN ('aceptada', 'en_ruta')
  ORDER BY r.created_at DESC
  LIMIT 1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_driver_active_ride TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_driver_active_ride TO service_role;

-- ============================================================
-- 2. REESCRIBIR GET_CLIENT_ACTIVE_RIDE
--    El cliente SÍ debe ver su viaje en estado 'incidente'
--    (congelado) para que sepa que está en revisión.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_client_active_ride()
RETURNS SETOF rides
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_client_id UUID := auth.uid();
BEGIN
  RETURN QUERY
  SELECT r.* FROM rides r
  WHERE r.client_id = v_client_id
    AND r.status IN ('buscando', 'aceptada', 'en_ruta', 'incidente')
  ORDER BY r.created_at DESC
  LIMIT 1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_client_active_ride TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_client_active_ride TO service_role;

-- ============================================================
-- 3. FUNCIÓN NUEVA: OBTENER INCIDENTE ACTIVO DEL CONDUCTOR
--    Para que el conductor pueda ver el estado del incidente
--    en su pantalla sin estar "atrapado" en el viaje.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_driver_active_incident()
RETURNS TABLE (
  incident_id UUID,
  ride_id UUID,
  incident_type TEXT,
  description TEXT,
  status TEXT,
  created_at TIMESTAMPTZ
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  RETURN QUERY
  SELECT ri.id, ri.ride_id, ri.incident_type, ri.description, ri.status, ri.created_at
  FROM ride_incidents ri
  INNER JOIN rides r ON r.id = ri.ride_id
  WHERE r.driver_id = v_driver_id
    AND ri.status IN ('abierto', 'en_revision')
  ORDER BY ri.created_at DESC
  LIMIT 1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_driver_active_incident TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_driver_active_incident TO service_role;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Fix de incidentes y sesión aplicado' AS estado;