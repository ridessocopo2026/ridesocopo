-- ============================================================
-- BUNRIDER - Migracion 059: CAMBIO DE FOTO DE PERFIL CON
-- APROBACION DEL ADMIN
-- ------------------------------------------------------------
-- 1) profiles.avatar_pending_url / avatar_pending_at: la nueva
--    foto del conductor queda "en revision".
-- 2) RLS: el conductor YA NO puede cambiar avatar_url directo
--    (mostraria la foto sin moderacion); solo deja foto pendiente.
-- 3) request_avatar_change(): conductor deja su foto en revision.
-- 4) review_avatar(): admin/encargado aprueba (mueve pending a
--    avatar_url) o rechaza; notifica al conductor y audita.
-- ============================================================

-- 1. COLUMNAS DE FOTO PENDIENTE
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS avatar_pending_url TEXT,
  ADD COLUMN IF NOT EXISTS avatar_pending_at TIMESTAMPTZ;

-- 2. GET_OWN_PROFILE_GUARD incluye avatar_url para que la
--    politica de auto-update pueda bloquear el cambio directo.
CREATE OR REPLACE FUNCTION public.get_own_profile_guard()
RETURNS JSONB
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'role', role::text,
    'email', email,
    'driver_status', driver_status::text,
    'is_online', is_online,
    'avatar_url', COALESCE(avatar_url, '')
  )
  FROM public.profiles
  WHERE id = auth.uid();
$$;

GRANT EXECUTE ON FUNCTION public.get_own_profile_guard() TO anon, authenticated, service_role;

-- 3. POLITICA: el usuario solo actualiza su perfil si NO cambia
--    role/email/driver_status/is_online/avatar_url (la foto nueva
--    va por avatar_pending_url y la aprueba el admin)
DROP POLICY IF EXISTS "users_update_own_profile" ON public.profiles;

CREATE POLICY "users_update_own_profile" ON public.profiles
  FOR UPDATE
  USING (auth.uid() = id)
  WITH CHECK (
    auth.uid() = id
    AND role = (public.get_own_profile_guard()->>'role')::public.user_role
    AND email = (public.get_own_profile_guard()->>'email')
    AND COALESCE(driver_status, 'pendiente') =
        COALESCE((public.get_own_profile_guard()->>'driver_status')::public.driver_status, 'pendiente')
    AND is_online = ((public.get_own_profile_guard()->>'is_online')::boolean)
    AND COALESCE(avatar_url, '') = (public.get_own_profile_guard()->>'avatar_url')
  );
-- ============================================================
-- 4. RPC: EL CONDUCTOR SOLICITA CAMBIO DE FOTO
-- ============================================================
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

  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT id,
         'Nueva foto de perfil por aprobar',
         COALESCE(v_profile.full_name, 'Un conductor') || ' subio una nueva foto de perfil.',
         'avatar_review',
         jsonb_build_object('driver_id', v_user_id, 'url', '/admin/conductores')
  FROM profiles
  WHERE role IN ('super_admin', 'encargado');

  RETURN jsonb_build_object(
    'success', TRUE,
    'previous_pending', NULLIF(v_old_pending, '')
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_avatar_change(text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.request_avatar_change FROM anon;

-- ============================================================
-- 5. RPC: EL ADMIN APRUEBA / RECHAZA EL CAMBIO DE FOTO
-- ============================================================
CREATE OR REPLACE FUNCTION public.review_avatar(p_driver_id UUID, p_approve BOOLEAN)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
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

  PERFORM public.guard_rate_limit('review_avatar', 30);

  SELECT * INTO v_reviewer FROM profiles WHERE id = v_reviewer_id;
  IF v_reviewer.role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado para revisar fotos de perfil';
  END IF;

  IF v_reviewer.role = 'encargado' THEN
    SELECT zone_id INTO v_driver_zone FROM profiles WHERE id = p_driver_id;
    IF public.caller_zone_id() IS NULL
       OR COALESCE(v_driver_zone, '00000000-0000-0000-0000-000000000000') != public.caller_zone_id() THEN
      RAISE EXCEPTION 'No autorizado para revisar conductores de otra ciudad';
    END IF;
  END IF;

  SELECT avatar_pending_url, full_name INTO v_pending, v_driver_name
  FROM profiles WHERE id = p_driver_id;

  IF v_pending IS NULL OR v_pending = '' THEN
    RAISE EXCEPTION 'Este conductor no tiene un cambio de foto pendiente';
  END IF;

  IF p_approve THEN
    UPDATE profiles
    SET avatar_url = avatar_pending_url,
        avatar_pending_url = NULL,
        avatar_pending_at = NULL
    WHERE id = p_driver_id;

    PERFORM public.notify_user(
      p_driver_id,
      'Foto de perfil aprobada',
      'Tu nueva foto ya esta visible en la app.',
      'avatar_review',
      jsonb_build_object('approved', TRUE, 'url', '/conductor/perfil')
    );
  ELSE
    UPDATE profiles
    SET avatar_pending_url = NULL,
        avatar_pending_at = NULL
    WHERE id = p_driver_id;

    PERFORM public.notify_user(
      p_driver_id,
      'Foto de perfil rechazada',
      'Tu cambio de foto no fue aprobado. Sigue mostrando tu foto actual.',
      'avatar_review',
      jsonb_build_object('approved', FALSE, 'url', '/conductor/perfil')
    );
  END IF;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_reviewer_id, 'REVIEW_AVATAR', 'profile', p_driver_id,
          jsonb_build_object('approved', p_approve, 'driver', COALESCE(v_driver_name, p_driver_id::text)));

  RETURN jsonb_build_object('success', TRUE, 'driver_id', p_driver_id, 'approved', p_approve);
END;
$$;

GRANT EXECUTE ON FUNCTION public.review_avatar(uuid, boolean) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.review_avatar FROM anon;

-- ============================================================
-- VERIFICACION
-- ============================================================
SELECT 'OK 059 avatar con aprobacion lista' AS estado;

SELECT column_name FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'profiles'
  AND column_name IN ('avatar_url', 'avatar_pending_url', 'avatar_pending_at')
ORDER BY column_name;

SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('request_avatar_change', 'review_avatar')
ORDER BY p.proname;