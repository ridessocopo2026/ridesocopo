-- ============================================================
-- REPARACIÓN DEFINITIVA: RECURSIÓN INFINITA EN TODAS LAS TABLAS
-- Copia y ejecuta TODO este script en Supabase SQL Editor
-- ============================================================

-- 1. FUNCIÓN PARA VERIFICAR ROL SIN ACTIVAR RLS
CREATE OR REPLACE FUNCTION public.get_user_role(user_id UUID)
RETURNS public.user_role
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT role FROM public.profiles WHERE id = user_id;
$$;

-- ============================================================
-- 2. REPARAR RIDES
-- ============================================================
DROP POLICY IF EXISTS "client_view_own_rides" ON public.rides;
DROP POLICY IF EXISTS "driver_view_assigned_rides" ON public.rides;
DROP POLICY IF EXISTS "driver_view_available_rides" ON public.rides;
DROP POLICY IF EXISTS "client_create_rides" ON public.rides;
DROP POLICY IF EXISTS "client_update_own_rides" ON public.rides;
DROP POLICY IF EXISTS "driver_update_assigned_rides" ON public.rides;
DROP POLICY IF EXISTS "super_admin_view_all_rides" ON public.rides;
DROP POLICY IF EXISTS "encargado_view_rides" ON public.rides;

CREATE POLICY "client_view_own_rides" ON public.rides
  FOR SELECT USING (auth.uid() = client_id);

CREATE POLICY "driver_view_assigned_rides" ON public.rides
  FOR SELECT USING (auth.uid() = driver_id);

CREATE POLICY "driver_view_available_rides" ON public.rides
  FOR SELECT USING (
    auth.uid() IN (SELECT driver_id FROM vehicles WHERE is_active = TRUE)
    AND status = 'buscando'
  );

CREATE POLICY "client_create_rides" ON public.rides
  FOR INSERT WITH CHECK (auth.uid() = client_id);

CREATE POLICY "client_update_own_rides" ON public.rides
  FOR UPDATE USING (auth.uid() = client_id AND status IN ('buscando', 'aceptada'));

CREATE POLICY "driver_update_assigned_rides" ON public.rides
  FOR UPDATE USING (auth.uid() = driver_id);

CREATE POLICY "super_admin_view_all_rides" ON public.rides
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'super_admin');

CREATE POLICY "encargado_view_rides" ON public.rides
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'encargado');

-- ============================================================
-- 3. REPARAR PROFILES
-- ============================================================
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
-- 4. REPARAR VEHICLES
-- ============================================================
DROP POLICY IF EXISTS "super_admin_view_all_vehicles" ON public.vehicles;
CREATE POLICY "super_admin_view_all_vehicles" ON public.vehicles
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'super_admin');

DROP POLICY IF EXISTS "encargado_view_vehicles" ON public.vehicles;
CREATE POLICY "encargado_view_vehicles" ON public.vehicles
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'encargado');

DROP POLICY IF EXISTS "client_view_vehicle_in_active_ride" ON public.vehicles;
CREATE POLICY "client_view_vehicle_in_active_ride" ON public.vehicles
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM rides r
      WHERE r.vehicle_id = vehicles.id
        AND r.client_id = auth.uid()
        AND r.status IN ('aceptada', 'en_ruta')
    )
  );

-- ============================================================
-- 5. REPARAR OTRAS TABLAS
-- ============================================================
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

DROP POLICY IF EXISTS "super_admin_manage_barrios" ON public.barrios;
CREATE POLICY "super_admin_manage_barrios" ON public.barrios
  FOR ALL USING (public.get_user_role(auth.uid()) = 'super_admin');

-- ============================================================
-- 6. STORAGE
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
-- 7. PERMISOS FINALES
-- ============================================================
GRANT ALL ON public.rides TO anon, authenticated, service_role;
GRANT ALL ON public.profiles TO anon, authenticated, service_role;
GRANT ALL ON public.vehicles TO anon, authenticated, service_role;
GRANT ALL ON public.driver_documents TO anon, authenticated, service_role;
GRANT ALL ON public.wallets TO anon, authenticated, service_role;
GRANT ALL ON public.transactions TO anon, authenticated, service_role;
GRANT ALL ON public.coupons TO anon, authenticated, service_role;
GRANT ALL ON public.banners TO anon, authenticated, service_role;
GRANT ALL ON public.exchange_rates TO anon, authenticated, service_role;
GRANT ALL ON public.audit_logs TO anon, authenticated, service_role;
GRANT ALL ON public.zones TO anon, authenticated, service_role;
GRANT ALL ON public.vehicle_categories TO anon, authenticated, service_role;
GRANT ALL ON public.barrios TO anon, authenticated, service_role;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'Reparación definitiva completada' AS estado;