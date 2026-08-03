-- ============================================================
-- REPARACIÓN: ONBOARDING DE CONDUCTOR (RLS WITH CHECK + GRANT EXECUTE)
-- Copia y ejecuta TODO este script en Supabase SQL Editor
-- ============================================================

-- 1. REPARAR POLÍTICAS DE VEHICLES (agregar WITH CHECK)
DROP POLICY IF EXISTS "driver_manage_own_vehicles" ON public.vehicles;
CREATE POLICY "driver_manage_own_vehicles" ON public.vehicles
  FOR ALL USING (auth.uid() = driver_id) WITH CHECK (auth.uid() = driver_id);

-- 2. REPARAR POLÍTICAS DE DRIVER_DOCUMENTS (agregar WITH CHECK)
DROP POLICY IF EXISTS "driver_manage_own_documents" ON public.driver_documents;
CREATE POLICY "driver_manage_own_documents" ON public.driver_documents
  FOR ALL USING (auth.uid() = driver_id) WITH CHECK (auth.uid() = driver_id);

-- ============================================================
-- 3. OTORGAR GRANT EXECUTE A TODAS LAS FUNCIONES RPC
-- ============================================================
GRANT EXECUTE ON FUNCTION public.calculate_fare TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.request_ride TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.accept_ride TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.complete_ride TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cancel_ride TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.update_driver_location TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.review_driver TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.request_wallet_recharge TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.approve_recharge TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.toggle_driver_online TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.save_favorite_place TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_available_rides TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_driver_active_ride TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_client_active_ride TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_active_exchange_rate TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.update_exchange_rate TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.upsert_zone TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_coupon TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.create_banner TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.register_driver_onboarding TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.upsert_barrio TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_nearest_barrio TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.promote_to_super_admin TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.handle_new_user TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.handle_new_profile TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_user_role TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.driver_has_vehicle_for_category TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.client_can_view_vehicle TO anon, authenticated, service_role;

-- ============================================================
-- 4. HACER PÚBLICO EL BUCKET VEHICLES (para que las fotos del vehículo se vean)
-- ============================================================
UPDATE storage.buckets SET public = TRUE WHERE id = 'vehicles';

-- ============================================================
-- 5. PERMISOS DE ALMACENAMIENTO (completos)
-- ============================================================
GRANT ALL ON storage.objects TO authenticated;
GRANT ALL ON storage.buckets TO authenticated;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'Reparación de onboarding completada' AS estado;