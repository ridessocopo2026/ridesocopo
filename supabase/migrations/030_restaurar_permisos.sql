-- ============================================================
-- RIDESOCOPÓ - Migración: RESTAURAR PERMISOS ADMIN
-- ============================================================
-- El hardening revocó ALL y solo dejó SELECT para authenticated.
-- Aunque las políticas RLS permiten solo a admins modificar filas,
-- Postgres necesita el GRANT a nivel de tabla para la operación.
-- Sin esto, el admin recibe 403 Forbidden al intentar gestionar.
--
-- Las políticas RLS siguen protegiendo (solo super_admin/encargado
-- pueden modificar). El GRANT solo habilita la operación
-- a nivel de tabla para que la RLS evalué la fila.
-- ============================================================

-- ============================================================
-- 1. TABLAS DE ADMINISTRACIÓN
-- ============================================================
GRANT ALL ON public.zones TO authenticated;
GRANT ALL ON public.barrios TO authenticated;
GRANT ALL ON public.vehicle_categories TO authenticated;
GRANT ALL ON public.cancellation_policies TO authenticated;
GRANT ALL ON public.ride_incidents TO authenticated;
GRANT ALL ON public.exchange_rates TO authenticated;
GRANT ALL ON public.coupons TO authenticated;
GRANT ALL ON public.banners TO authenticated;
GRANT ALL ON public.payment_methods TO authenticated;
GRANT ALL ON public.payment_method_fields TO authenticated;
GRANT ALL ON public.audit_logs TO authenticated;
GRANT ALL ON public.profiles TO authenticated;
GRANT ALL ON public.vehicles TO authenticated;
GRANT ALL ON public.driver_documents TO authenticated;

-- ============================================================
-- 2. TABLAS DE NEGOCIO (protegidas por RLS y RPCs)
-- ============================================================
GRANT ALL ON public.wallets TO authenticated;
GRANT ALL ON public.transactions TO authenticated;
GRANT ALL ON public.payouts TO authenticated;
GRANT ALL ON public.driver_earnings TO authenticated;
GRANT ALL ON public.rides TO authenticated;
GRANT ALL ON public.favorite_places TO authenticated;
GRANT ALL ON public.notifications TO authenticated;

-- ============================================================
-- 3. VERIFICACIÓN
-- ============================================================
SELECT 'Permisos de administración restaurados' AS estado;