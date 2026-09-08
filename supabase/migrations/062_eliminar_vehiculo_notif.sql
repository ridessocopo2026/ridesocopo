-- ============================================================
-- BUNRIDER - Migración 062: ELIMINAR VEHÍCULO DEL CONDUCTOR +
-- NOTIFICACIONES AL ADMIN/ENCARGADO DE ZONA
-- ------------------------------------------------------------
-- 1) delete_driver_vehicle(): el conductor puede eliminar un
--    vehículo que registró (pendiente/nuevo). Se bloquea si ya
--    fue usado en viajes (historial) o está en viajes activos.
-- 2) add_vehicle: la notificación "Nuevo vehículo por aprobar"
--    llega a super_admin y a los ENCARGADOS DE LA ZONA del
--    conductor (antes llegaba a todos los encargados).
-- 3) request_avatar_change: igual filtro por zona para la
--    notificación "Nueva foto de perfil por aprobar".
-- ============================================================

-- 1. EL CONDUCTOR ELIMINA SU VEHÍCULO
CREATE OR REPLACE FUNCTION public.delete_driver_vehicle(p_vehicle_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_row RECORD;
  v_used INTEGER;
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('delete_driver_vehicle', 20);

  SELECT * INTO v_row FROM vehicles WHERE id = p_vehicle_id;
  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'Vehículo no encontrado';
  END IF;

  IF v_row.driver_id != v_driver_id THEN
    RAISE EXCEPTION 'No puedes eliminar un vehículo que no te pertenece';
  END IF;

  -- Vehículo en un viaje activo
  IF EXISTS (
    SELECT 1 FROM rides
    WHERE vehicle_id = p_vehicle_id
      AND status IN ('buscando', 'aceptada', 'en_ruta', 'incidente')
  ) THEN
    RAISE EXCEPTION 'No puedes eliminar un vehículo que está en un viaje activo';
  END IF;

  -- Vehículo usado en viajes (historial) → la FK no permite borrarlo
  SELECT COUNT(*) INTO v_used FROM rides WHERE vehicle_id = p_vehicle_id;
  IF v_used > 0 THEN
    RAISE EXCEPTION 'Este vehículo ya fue usado en viajes y no se puede eliminar (queda en tu historial)';
  END IF;

  DELETE FROM vehicles WHERE id = p_vehicle_id;

  RETURN jsonb_build_object('success', TRUE, 'vehicle_id', p_vehicle_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_driver_vehicle(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.delete_driver_vehicle FROM anon;

-- 2. ADD_VEHICLE: notificar al admin y al encargado de la ZONA del conductor
CREATE OR REPLACE FUNCTION public.add_vehicle(
  p_category vehicle_category,
  p_brand TEXT,
  p_model TEXT,
  p_year INTEGER,
  p_color TEXT,
  p_plate TEXT,
  p_photo_url TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_vehicle_id UUID;
  v_driver_profiles RECORD;
  v_driver_zone UUID;
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  -- Verificar que el usuario es conductor aprobado
  SELECT * INTO v_driver_profiles FROM public.profiles WHERE id = v_driver_id;
  IF v_driver_profiles.role != 'conductor' THEN
    RAISE EXCEPTION 'No es conductor';
  END IF;

  v_driver_zone := v_driver_profiles.zone_id;

  -- Verificar placa única
  IF EXISTS (SELECT 1 FROM vehicles WHERE plate = UPPER(p_plate)) THEN
    RAISE EXCEPTION 'La placa ya está registrada';
  END IF;

  INSERT INTO vehicles (
    driver_id, category, brand, model, year, color, plate, photo_url,
    is_approved, is_active_vehicle
  ) VALUES (
    v_driver_id, p_category, p_brand, p_model, p_year, p_color, UPPER(p_plate), p_photo_url,
    FALSE, FALSE
  ) RETURNING id INTO v_vehicle_id;

  -- Notificar a super_admin y a los encargados DE LA ZONA del conductor
  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT id, 'Nuevo vehículo por aprobar',
         CONCAT('El conductor ', v_driver_profiles.full_name, ' registró un ', p_category, ' (', p_brand, ' ', p_model, ' ', p_color, ') placa ', UPPER(p_plate), '. Revisar.'),
         'vehicle_pending',
         jsonb_build_object('vehicle_id', v_vehicle_id, 'url', '/admin/conductores')
  FROM profiles
  WHERE role = 'super_admin'
     OR (role = 'encargado' AND (v_driver_zone IS NULL OR zone_id = v_driver_zone));

  RETURN v_vehicle_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.add_vehicle TO authenticated, anon;

-- 3. REQUEST_AVATAR_CHANGE: notificar al admin y al encargado de la ZONA
CREATE OR REPLACE FUNCTION public.request_avatar_change(p_new_url TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_profile RECORD;
  v_old_pending TEXT;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('request_avatar_change', 5);

  SELECT * INTO v_profile FROM profiles WHERE id = v_user_id;
  IF v_profile.role != 'conductor' THEN
    RAISE EXCEPTION 'Solo los conductores pueden solicitar un cambio de foto de perfil';
  END IF;

  IF p_new_url IS NULL OR LENGTH(BTRIM(p_new_url)) = 0 OR LENGTH(p_new_url) > 500 THEN
    RAISE EXCEPTION 'Adjunta la nueva foto de perfil';
  END IF;

  IF NOT (p_new_url LIKE v_user_id::text || '/%' OR p_new_url ~* '^https?://') THEN
    RAISE EXCEPTION 'Ruta de imagen invalida';
  END IF;

  SELECT COALESCE(avatar_pending_url, '') INTO v_old_pending FROM profiles WHERE id = v_user_id;

  UPDATE profiles
  SET avatar_pending_url = BTRIM(p_new_url),
      avatar_pending_at = NOW()
  WHERE id = v_user_id;

  -- Notificar a super_admin y a los encargados DE LA ZONA del conductor
  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT id,
         'Nueva foto de perfil por aprobar',
         COALESCE(v_profile.full_name, 'Un conductor') || ' subió una nueva foto de perfil.',
         'avatar_review',
         jsonb_build_object('driver_id', v_user_id, 'url', '/admin/conductores')
  FROM profiles
  WHERE role = 'super_admin'
     OR (role = 'encargado' AND (v_profile.zone_id IS NULL OR zone_id = v_profile.zone_id));

  RETURN jsonb_build_object(
    'success', TRUE,
    'previous_pending', NULLIF(v_old_pending, '')
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_avatar_change(text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.request_avatar_change FROM anon;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 062: eliminar vehículo + notificaciones por zona lista' AS estado;

SELECT p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')' AS sig
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('delete_driver_vehicle', 'add_vehicle', 'request_avatar_change')
ORDER BY p.proname;
