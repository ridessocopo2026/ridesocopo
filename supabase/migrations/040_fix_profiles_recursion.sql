-- ============================================================
-- RIDERFLASSHI - Migración 040: FIX RECURSIÓN RLS EN PROFILES
-- ------------------------------------------------------------
-- Causa: la política users_update_own_profile (creada en 036)
-- usaba subconsultas DIRECTAS a profiles en su WITH CHECK:
--   AND email = (SELECT email FROM public.profiles WHERE id = auth.uid())
--   ... driver_status ... (SELECT driver_status ...)
--   ... is_online ... (SELECT is_online ...)
-- PostgreSQL detecta esa auto-referencia como:
--   "infinite recursion detected in policy for relation profiles"
-- y falla cualquier UPDATE/upsert del perfil desde el cliente
-- (upsert OAuth con Google, completar onboarding, editar perfil).
--
-- Solución: mover esas lecturas a una función SECURITY DEFINER
-- (get_own_profile_guard) que bypasea RLS → sin recursión.
-- La política sigue bloqueando cambiar role/driver_status/
-- email/is_online, exactamente igual que antes.
-- ============================================================

-- 1. HELPER SECURITY DEFINER: lee SOLO el propio perfil
--    (usa auth.uid() internamente, sin parámetros → sin IDOR)
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
    'is_online', is_online
  )
  FROM public.profiles
  WHERE id = auth.uid();
$$;

GRANT EXECUTE ON FUNCTION public.get_own_profile_guard() TO anon, authenticated, service_role;

-- 2. REEMPLAZAR LA POLÍTICA PROBLEMÁTICA (sin subconsultas directas)
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
  );

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 040: recursión RLS en profiles corregida' AS estado;

SELECT polname, polcmd, pg_get_expr(polqual, polrelid) AS using_expr,
       pg_get_expr(polwithcheck, polrelid) AS with_check_expr
FROM pg_policy
WHERE polrelid = 'public.profiles'::regclass
ORDER BY polname;
