-- ============================================================
-- BUNRIDER - Migracion 091: CAMBIO DE NOMBRE CON APROBACION
-- 1) Columnas para el nombre pendiente.
-- 2) request_name_change(): el conductor solicita un nombre nuevo.
-- 3) review_name_change(): el admin/encargado aprueba o rechaza.
-- (Mismo patron que el cambio de foto de perfil.)
-- ============================================================

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS full_name_pending text,
  ADD COLUMN IF NOT EXISTS full_name_pending_at timestamp with time zone;

CREATE OR REPLACE FUNCTION public.request_name_change(p_new_name text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id UUID := auth.uid();
  v_profile RECORD;
  v_name TEXT;
  v_old_pending TEXT;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('request_name_change', 5);

  SELECT * INTO v_profile FROM profiles WHERE id = v_user_id;
  IF v_profile.id IS NULL THEN
    RAISE EXCEPTION 'Perfil no encontrado';
  END IF;
  IF v_profile.role != 'conductor' THEN
    RAISE EXCEPTION 'Solo los conductores pueden solicitar cambio de nombre';
  END IF;

  v_name := BTRIM(COALESCE(p_new_name, ''));
  IF LENGTH(v_name) < 3 OR LENGTH(v_name) > 60 THEN
    RAISE EXCEPTION 'El nombre debe tener entre 3 y 60 caracteres';
  END IF;
  IF v_name !~ '^[A-Za-zÁÉÍÓÚÜÑáéíóúüñ'' .-]+$' THEN
    RAISE EXCEPTION 'El nombre solo puede tener letras, espacios, puntos y guiones';
  END IF;
  IF v_name = v_profile.full_name THEN
    RAISE EXCEPTION 'Ese es el nombre que ya tienes';
  END IF;

  SELECT COALESCE(full_name_pending, '') INTO v_old_pending FROM profiles WHERE id = v_user_id;

  UPDATE profiles
  SET full_name_pending = v_name,
      full_name_pending_at = NOW()
  WHERE id = v_user_id;

  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT id,
         'Cambio de nombre por aprobar',
         COALESCE(v_profile.full_name, 'Un conductor') || ' solicita cambiar su nombre a: ' || v_name,
         'name_review',
         jsonb_build_object('driver_id', v_user_id, 'url', '/admin/conductores')
  FROM profiles
  WHERE role = 'super_admin'
     OR (role = 'encargado' AND (v_profile.zone_id IS NULL OR zone_id = v_profile.zone_id));

  RETURN jsonb_build_object('success', TRUE, 'previous_pending', NULLIF(v_old_pending, ''));
END;
$function$;

CREATE OR REPLACE FUNCTION public.review_name_change(p_driver_id uuid, p_approve boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_reviewer_id UUID := auth.uid();
  v_reviewer RECORD;
  v_driver_zone UUID;
  v_pending TEXT;
  v_driver_name TEXT;
BEGIN
  IF v_reviewer_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('review_name_change', 30);

  SELECT * INTO v_reviewer FROM profiles WHERE id = v_reviewer_id;
  IF v_reviewer.role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado para revisar nombres';
  END IF;

  IF v_reviewer.role = 'encargado' THEN
    SELECT zone_id INTO v_driver_zone FROM profiles WHERE id = p_driver_id;
    IF public.caller_zone_id() IS NULL
       OR COALESCE(v_driver_zone, '00000000-0000-0000-0000-000000000000') != public.caller_zone_id() THEN
      RAISE EXCEPTION 'No autorizado para revisar conductores de otra ciudad';
    END IF;
  END IF;

  SELECT full_name_pending, full_name INTO v_pending, v_driver_name
  FROM profiles WHERE id = p_driver_id;

  IF v_pending IS NULL OR v_pending = '' THEN
    RAISE EXCEPTION 'Este conductor no tiene un cambio de nombre pendiente';
  END IF;

  IF p_approve THEN
    UPDATE profiles
    SET full_name = full_name_pending,
        full_name_pending = NULL,
        full_name_pending_at = NULL
    WHERE id = p_driver_id;

    PERFORM public.notify_user(
      p_driver_id,
      'Nombre actualizado',
      'Tu nuevo nombre ya esta activo en la app.',
      'name_review',
      jsonb_build_object('approved', TRUE, 'url', '/conductor/perfil')
    );
  ELSE
    UPDATE profiles
    SET full_name_pending = NULL,
        full_name_pending_at = NULL
    WHERE id = p_driver_id;

    PERFORM public.notify_user(
      p_driver_id,
      'Cambio de nombre rechazado',
      'Tu solicitud de cambio de nombre no fue aprobada.',
      'name_review',
      jsonb_build_object('approved', FALSE, 'url', '/conductor/perfil')
    );
  END IF;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_reviewer_id, 'REVIEW_NAME_CHANGE', 'profile', p_driver_id,
          jsonb_build_object('approved', p_approve, 'pending', v_pending, 'driver', COALESCE(v_driver_name, p_driver_id::text)));

  RETURN jsonb_build_object('success', TRUE, 'driver_id', p_driver_id, 'approved', p_approve);
END;
$function$;

REVOKE ALL ON FUNCTION public.request_name_change(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_name_change(text) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.review_name_change(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.review_name_change(uuid, boolean) TO authenticated, service_role;