-- ============================================================
-- RIDESOCOPÓ - LIMPIEZA FINAL DE PERMISOS RESIDUALES
-- Revoca permisos de anon en tablas secundarias que
-- quedaron expuestas tras la verificación del hardening.
-- ============================================================

-- Revocar todos los privilegios de anon en tablas secundarias
REVOKE ALL ON public.cancellation_policies FROM anon;
REVOKE ALL ON public.notification_outbox FROM anon;
REVOKE ALL ON public.push_settings FROM anon;
REVOKE ALL ON public.push_subscriptions FROM anon;
REVOKE ALL ON public.ride_incidents FROM anon;

-- Las tablas del sistema PostGIS no deben ser modificables por anon
REVOKE ALL ON public.geography_columns FROM anon;
REVOKE ALL ON public.geometry_columns FROM anon;
REVOKE ALL ON public.spatial_ref_sys FROM anon;

-- Revocar permisos de UPDATE/DELETE en authenticated también (solo lectura)
REVOKE ALL ON public.cancellation_policies FROM authenticated;
GRANT SELECT ON public.cancellation_policies TO authenticated;

REVOKE ALL ON public.notification_outbox FROM authenticated;
GRANT SELECT ON public.notification_outbox TO authenticated;

REVOKE ALL ON public.push_settings FROM authenticated;
GRANT SELECT ON public.push_settings TO authenticated;

REVOKE ALL ON public.push_subscriptions FROM authenticated;
GRANT SELECT ON public.push_subscriptions TO authenticated;

REVOKE ALL ON public.ride_incidents FROM authenticated;
GRANT SELECT ON public.ride_incidents TO authenticated;

-- Verificación final completa
SELECT '✅ Permisos residuales eliminados' AS estado;

SELECT table_schema, table_name, grantee, privilege_type
FROM information_schema.role_table_grants
WHERE grantee IN ('anon', 'authenticated')
  AND table_schema = 'public'
  AND privilege_type IN ('INSERT', 'UPDATE', 'DELETE')
ORDER BY grantee, table_name;