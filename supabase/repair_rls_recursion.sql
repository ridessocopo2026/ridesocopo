-- ============================================================
-- REPARACIÓN: RECURSIÓN INFINITA EN POLÍTICAS RLS
-- Copia y ejecuta TODO este script en Supabase SQL Editor
-- ============================================================

-- 1. Función para verificar rol SIN activar RLS (evita recursión)
CREATE OR REPLACE FUNCTION public.get_user_role(user_id UUID)
RETURNS public.user_role
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT role FROM public.profiles WHERE id = user_id;
$$;

-- 2. Eliminar todas las políticas problemáticas de profiles
DROP POLICY IF EXISTS "super_admin_view_all_profiles" ON public.profiles;
DROP POLICY IF EXISTS "encargado_view_drivers" ON public.profiles;
DROP POLICY IF EXISTS "super_admin_update_all_profiles" ON public.profiles;
DROP POLICY IF EXISTS "encargado_update_drivers" ON public.profiles;

-- 3. Recrear las políticas usando la función (sin recursión)
CREATE POLICY "super_admin_view_all_profiles" ON public.profiles
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'super_admin');

CREATE POLICY "encargado_view_drivers" ON public.profiles
  FOR SELECT USING (
    public.get_user_role(auth.uid()) = 'encargado'
    AND (role = 'conductor' OR role = 'cliente')
  );

CREATE POLICY "super_admin_update_all_profiles" ON public.profiles
  FOR UPDATE USING (public.get_user_role(auth.uid()) = 'super_admin');

CREATE POLICY "encargado_update_drivers" ON public.profiles
  FOR UPDATE USING (
    public.get_user_role(auth.uid()) = 'encargado'
    AND role = 'conductor'
  );

-- ============================================================
-- 4. REPARACIÓN PARA OTRAS TABLAS CON EL MISMO PROBLEMA
-- ============================================================

DROP POLICY IF EXISTS "super_admin_view_all_vehicles" ON public.vehicles;
CREATE POLICY "super_admin_view_all_vehicles" ON public.vehicles
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'super_admin');

DROP POLICY IF EXISTS "encargado_view_vehicles" ON public.vehicles;
CREATE POLICY "encargado_view_vehicles" ON public.vehicles
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'encargado');

DROP POLICY IF EXISTS "super_admin_view_all_documents" ON public.driver_documents;
CREATE POLICY "super_admin_view_all_documents" ON public.driver_documents
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'super_admin');

DROP POLICY IF EXISTS "encargado_view_documents" ON public.driver_documents;
CREATE POLICY "encargado_view_documents" ON public.driver_documents
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'encargado');

DROP POLICY IF EXISTS "super_admin_view_all_wallets" ON public.wallets;
CREATE POLICY "super_admin_view_all_wallets" ON public.wallets
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'super_admin');

DROP POLICY IF EXISTS "encargado_view_wallets" ON public.wallets;
CREATE POLICY "encargado_view_wallets" ON public.wallets
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'encargado');

DROP POLICY IF EXISTS "super_admin_view_all_transactions" ON public.transactions;
CREATE POLICY "super_admin_view_all_transactions" ON public.transactions
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'super_admin');

DROP POLICY IF EXISTS "encargado_view_transactions" ON public.transactions;
CREATE POLICY "encargado_view_transactions" ON public.transactions
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'encargado');

DROP POLICY IF EXISTS "super_admin_view_all_rides" ON public.rides;
CREATE POLICY "super_admin_view_all_rides" ON public.rides
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'super_admin');

DROP POLICY IF EXISTS "encargado_view_rides" ON public.rides;
CREATE POLICY "encargado_view_rides" ON public.rides
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'encargado');

DROP POLICY IF EXISTS "super_admin_manage_coupons" ON public.coupons;
CREATE POLICY "super_admin_manage_coupons" ON public.coupons
  FOR ALL USING (public.get_user_role(auth.uid()) = 'super_admin');

DROP POLICY IF EXISTS "super_admin_manage_banners" ON public.banners;
CREATE POLICY "super_admin_manage_banners" ON public.banners
  FOR ALL USING (public.get_user_role(auth.uid()) = 'super_admin');

DROP POLICY IF EXISTS "super_admin_manage_exchange_rates" ON public.exchange_rates;
CREATE POLICY "super_admin_manage_exchange_rates" ON public.exchange_rates
  FOR ALL USING (public.get_user_role(auth.uid()) = 'super_admin');

DROP POLICY IF EXISTS "super_admin_view_audit_logs" ON public.audit_logs;
CREATE POLICY "super_admin_view_audit_logs" ON public.audit_logs
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'super_admin');

DROP POLICY IF EXISTS "super_admin_manage_zones" ON public.zones;
CREATE POLICY "super_admin_manage_zones" ON public.zones
  FOR ALL USING (public.get_user_role(auth.uid()) = 'super_admin');

DROP POLICY IF EXISTS "super_admin_manage_vehicle_categories" ON public.vehicle_categories;
CREATE POLICY "super_admin_manage_vehicle_categories" ON public.vehicle_categories
  FOR ALL USING (public.get_user_role(auth.uid()) = 'super_admin');

-- ============================================================
-- 5. REPARACIÓN POLÍTICAS DE STORAGE
-- ============================================================

DROP POLICY IF EXISTS "super_admin_view_documents" ON storage.objects;
CREATE POLICY "super_admin_view_documents" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'documents' AND
    public.get_user_role(auth.uid()) = 'super_admin'
  );

DROP POLICY IF EXISTS "encargado_view_documents" ON storage.objects;
CREATE POLICY "encargado_view_documents" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'documents' AND
    public.get_user_role(auth.uid()) = 'encargado'
  );

-- ============================================================
-- 6. VERIFICACIÓN FINAL
-- ============================================================
SELECT 'Reparación completada correctamente' AS estado;