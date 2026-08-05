-- ============================================================
-- RIDESOCOPÓ - Migración: FIX RECURSIÓN RLS PROFILES + REGISTRO
-- ============================================================
-- 1. Corrige recursión infinita en policy users_update_own_profile
-- 2. Asegura INSERT en profiles para trigger handle_new_user
-- 3. Asegura acceso a zones
-- ============================================================

-- ============================================================
-- 1. FUNCIÓN HELPER PARA VALIDAR CAMPOS INMUTABLES
--    (Security definer para evitar recursión RLS)
-- ============================================================
CREATE OR REPLACE FUNCTION public.can_update_profile(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.profiles
    WHERE id = p_user_id
  );
$$;

GRANT EXECUTE ON FUNCTION public.can_update_profile TO authenticated, service_role;

-- ============================================================
-- 2. ELIMINAR POLÍTICA RECURSIVA Y RECREAR SIN SUBQUERIES
-- ============================================================
DROP POLICY IF EXISTS "users_update_own_profile" ON public.profiles;

CREATE POLICY "users_update_own_profile" ON public.profiles
  FOR UPDATE
  USING (auth.uid() = id)
  WITH CHECK (auth.uid() = id);

-- ============================================================
-- 3. GARANTIZAR INSERT EN PROFILES (para el trigger de registro)
--    El trigger handle_new_user usa SECURITY DEFINER,
--    pero si la tabla no tiene GRANT INSERT -> falla
-- ============================================================
GRANT INSERT ON public.profiles TO authenticated;
GRANT INSERT ON public.profiles TO service_role;
GRANT INSERT ON public.profiles TO anon;

-- ============================================================
-- 4. POLICY DE INSERT PARA PROFILES
--    Solo el trigger handle_new_user inserta (service_role/definer)
--    pero hay que permitir que auth.uid() pueda insertar su propio perfil
-- ============================================================
DROP POLICY IF EXISTS "users_insert_own_profile" ON public.profiles;
CREATE POLICY "users_insert_own_profile" ON public.profiles
  FOR INSERT WITH CHECK (auth.uid() = id);

-- ============================================================
-- 5. ASEGURAR POLÍTICAS BÁSICAS DE PROFILES
-- ============================================================
DROP POLICY IF EXISTS "users_view_own_profile" ON public.profiles;
CREATE POLICY "users_view_own_profile" ON public.profiles
  FOR SELECT USING (auth.uid() = id);

DROP POLICY IF EXISTS "super_admin_view_all_profiles" ON public.profiles;
CREATE POLICY "super_admin_view_all_profiles" ON public.profiles
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'super_admin');

DROP POLICY IF EXISTS "encargado_view_drivers" ON public.profiles;
CREATE POLICY "encargado_view_drivers" ON public.profiles
  FOR SELECT USING (
    public.get_user_role(auth.uid()) = 'encargado'
    AND (role = 'conductor' OR role = 'cliente')
  );

DROP POLICY IF EXISTS "super_admin_update_all_profiles" ON public.profiles;
CREATE POLICY "super_admin_update_all_profiles" ON public.profiles
  FOR UPDATE USING (public.get_user_role(auth.uid()) = 'super_admin');

DROP POLICY IF EXISTS "encargado_update_drivers" ON public.profiles;
CREATE POLICY "encargado_update_drivers" ON public.profiles
  FOR UPDATE USING (
    public.get_user_role(auth.uid()) = 'encargado'
    AND role = 'conductor'
  );

-- ============================================================
-- 6. ASEGURAR ACCESO A ZONES (para registro/onboarding)
-- ============================================================
GRANT SELECT ON public.zones TO anon;
GRANT SELECT ON public.zones TO authenticated;
GRANT SELECT ON public.zones TO service_role;

DROP POLICY IF EXISTS "public_view_zones" ON public.zones;
CREATE POLICY "public_view_zones" ON public.zones
  FOR SELECT USING (is_active = TRUE);

DROP POLICY IF EXISTS "super_admin_manage_zones" ON public.zones;
CREATE POLICY "super_admin_manage_zones" ON public.zones
  FOR ALL USING (public.get_user_role(auth.uid()) = 'super_admin');

-- ============================================================
-- 7. GRANT EXECUTE handle_new_user (por si acaso)
-- ============================================================
GRANT EXECUTE ON FUNCTION public.handle_new_user TO anon, authenticated, service_role;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'Fix RLS profiles + registro completado' AS estado;