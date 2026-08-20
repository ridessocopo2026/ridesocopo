-- ============================================================
-- RIDERFLASSHI - Migración 043: FIX ONBOARDING DE ROL
-- ------------------------------------------------------------
-- CAUSA
--   Onboarding.tsx actualizaba el role directamente:
--     supabase.from('profiles').update({ role: 'conductor' })
--   Pero la política RLS users_update_own_profile (036/040)
--   PROHÍBE cambiar role / driver_status / email / is_online
--   (anti auto-promoción de rol) → el UPDATE falla con:
--     "new row violates row-level security policy for table profiles"
--
-- SOLUCIÓN
--   Mover la transición de rol a una función SECURITY DEFINER
--   (mismo patrón que register_driver_onboarding) que:
--     - Solo actúa sobre el perfil del propio usuario (auth.uid()).
--     - SOLO permite 'cliente' | 'conductor' → nunca
--       encargado / super_admin (sin escalada de privilegios).
--     - Para conductor fija driver_status='pendiente'
--       (nunca se puede auto-aprobar).
-- ============================================================

CREATE OR REPLACE FUNCTION public.complete_onboarding(
  p_role public.user_role,
  p_zone_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_profile RECORD;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  -- Roles permitidos en onboarding: nunca encargado/super_admin
  IF p_role NOT IN ('cliente', 'conductor') THEN
    RAISE EXCEPTION 'Rol no permitido';
  END IF;

  SELECT * INTO v_profile FROM public.profiles WHERE id = v_user_id;
  IF v_profile.id IS NULL THEN
    RAISE EXCEPTION 'Perfil no encontrado';
  END IF;

  -- Si ya es conductor con estado definido (aprobado/rechazado/suspendido)
  -- no permitir volver a cambiarlo desde onboarding
  IF v_profile.role = 'conductor'
     AND v_profile.driver_status IS NOT NULL
     AND v_profile.driver_status != 'pendiente' THEN
    RAISE EXCEPTION 'Tu cuenta ya tiene un estado como conductor. Contacta al administrador.';
  END IF;

  -- Actualizar SOLO el propio perfil (SECURITY DEFINER bypasa RLS)
  UPDATE public.profiles
  SET role = p_role,
      zone_id = p_zone_id,
      driver_status = CASE WHEN p_role = 'conductor' THEN 'pendiente' ELSE driver_status END,
      onboarding_completed = TRUE,
      updated_at = NOW()
  WHERE id = v_user_id;

  RETURN jsonb_build_object('success', TRUE, 'role', p_role::text);
END;
$$;

-- Permisos: solo usuarios autenticados pueden llamarla
REVOKE ALL ON FUNCTION public.complete_onboarding FROM anon;
GRANT EXECUTE ON FUNCTION public.complete_onboarding TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_onboarding TO service_role;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'OK: migración 043 aplicada' AS estado;
