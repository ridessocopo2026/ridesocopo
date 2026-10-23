-- ============================================================
-- 107 - VEHICULO COMPARTIDO: PERMISOS DE TRIGGERS Y RLS
-- ============================================================

REVOKE ALL ON FUNCTION public.validate_shared_vehicle() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sync_driver_active_vehicle_plate() FROM PUBLIC, anon, authenticated;

DROP POLICY IF EXISTS "driver_view_own_vehicles" ON public.vehicles;
CREATE POLICY "driver_view_own_vehicles" ON public.vehicles
  FOR SELECT USING ((select auth.uid()) = driver_id);

NOTIFY pgrst, 'reload schema';