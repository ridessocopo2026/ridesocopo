-- ============================================================
-- BUNRIDER - Migración 077: OPTIMIZACIÓN SEGÚN ADVISORS
-- ------------------------------------------------------------
-- Resuelve los avisos de los advisors (puntos 2 a 5):
--   2) v_barrio_surcharges era una vista SECURITY DEFINER
--   3) search_path mutable en 3 funciones helper
--   4) RLS sin políticas (barrio_surcharges, rpc_audit) y
--      spatial_ref_sys (PostGIS) sin RLS y con permiso de escritura
--      → en spatial_ref_sys solo se puede quitar la escritura (la
--        tabla es de supabase_admin; ver 4c)
--   5) 21 claves foráneas sin índice de cobertura
--
-- CRITERIO: no cambiar nada de lo que ya funciona.
--   - Los recargos por sector se siguen leyendo igual (la vista pasa a
--     security_invoker, así que necesita una política de lectura; ese
--     precio ya es público por las columnas surcharge_* de barrios).
--   - La escritura sigue restringida a super_admin/service_role vía
--     RPCs SECURITY DEFINER.
--   - Los índices solo aceleran (no alteran resultados).
--
-- Nota: el aviso de "múltiples políticas permisivas" NO se toca aquí:
-- reescribir esas políticas de RLS (profiles, rides, wallets...) sí
-- podría abrir o cerrar accesos, y el costo del aviso es informativo.
-- ============================================================

-- ============================================================
-- 2 + 4a. RECARGOS POR SECTOR SIN SECURITY DEFINER
-- ------------------------------------------------------------
-- La vista cruza barrios (RLS pública), vehicle_categories (RLS
-- pública) y barrio_surcharges (RLS activada SIN políticas → invisible
-- al pasar a security_invoker). Se añade lectura pública de recargos.
-- ============================================================
DROP POLICY IF EXISTS "public_view_barrio_surcharges" ON public.barrio_surcharges;
CREATE POLICY "public_view_barrio_surcharges" ON public.barrio_surcharges
  FOR SELECT USING (TRUE);

ALTER VIEW public.v_barrio_surcharges SET (security_invoker = ON);

-- ============================================================
-- 4b. rpc_audit: log interno de rate limit → solo super_admin
-- ------------------------------------------------------------
-- Contiene usuario + función + fecha (dato interno). guard_rate_limit()
-- es SECURITY DEFINER, así que sigue insertando/limpiando sin problema.
-- ============================================================
DROP POLICY IF EXISTS "super_admin_view_rpc_audit" ON public.rpc_audit;
-- (SELECT auth.uid()) en lugar de auth.uid(): evita reevaluar por fila
-- (recomendación del linter auth_rls_initplan)
CREATE POLICY "super_admin_view_rpc_audit" ON public.rpc_audit
  FOR SELECT USING (public.get_user_role((SELECT auth.uid())) = 'super_admin');

REVOKE ALL ON public.rpc_audit FROM anon, authenticated;
GRANT SELECT ON public.rpc_audit TO authenticated, service_role;

-- ============================================================
-- 4c. spatial_ref_sys: NO ACCIONABLE desde el proyecto
-- ------------------------------------------------------------
-- Diagnóstico verificado en vivo:
--   propietario = supabase_admin
--   acl = {supabase_admin=arwdDxtm/supabase_admin,
--          postgres=arwdDxtm/supabase_admin,
--          anon=arwdDxtm/supabase_admin,
--          authenticated=arwdDxtm/supabase_admin,
--          service_role=arwdDxtm/supabase_admin,
--          =r/supabase_admin}
--
-- El grantor de TODOS los privilegios es `supabase_admin`, así que
-- `postgres` (rol del SQL Editor y de estas migraciones) NO puede:
--   - activar RLS  → "must be owner of table spatial_ref_sys"
--   - revocar nada → un REVOKE sin privilegios revocables solo emite
--     un WARNING (por eso "parece exitoso" pero no cambia la ACL)
-- Además PUBLIC conserva SELECT (=r/supabase_admin).
--
-- Por eso NO se incluye una sentencia que no hace nada. Solo Supabase
-- (supabase_admin) puede cambiarlo. Riesgo aceptado y bajo: es la tabla
-- pública de referencia de SRIDs de PostGIS, con el CHECK
-- spatial_ref_sys_srid_check, y la aplicación nunca la escribe.
-- ============================================================

-- ============================================================
-- 3. SEARCH_PATH FIJO EN LAS FUNCIONES HELPER
-- ------------------------------------------------------------
-- Las tres son puras (no leen tablas): fijar el search_path elimina el
-- riesgo de resolución de nombres y quita el aviso del advisor.
-- ============================================================
ALTER FUNCTION public.is_valid_amount(numeric) SET search_path = public;
ALTER FUNCTION public.sanitize_text(text, integer) SET search_path = public;
ALTER FUNCTION public.update_updated_at() SET search_path = public;

-- ============================================================
-- 5. ÍNDICES DE COBERTURA PARA LAS 21 CLAVES FORÁNEAS
-- ------------------------------------------------------------
-- Solo rendimiento: evita escaneos secuenciales en los JOIN del panel
-- admin/encargado y en las políticas RLS que filtran por zona,
-- conductor o viaje. CREATE INDEX IF NOT EXISTS es idempotente.
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_audit_logs_user_id              ON public.audit_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_banners_created_by              ON public.banners(created_by);
CREATE INDEX IF NOT EXISTS idx_coupon_redemptions_ride_id      ON public.coupon_redemptions(ride_id);
CREATE INDEX IF NOT EXISTS idx_coupons_created_by              ON public.coupons(created_by);
CREATE INDEX IF NOT EXISTS idx_exchange_rates_updated_by       ON public.exchange_rates(updated_by);
CREATE INDEX IF NOT EXISTS idx_legal_pages_updated_by          ON public.legal_pages(updated_by);
CREATE INDEX IF NOT EXISTS idx_payment_method_fields_method    ON public.payment_method_fields(payment_method_id);
CREATE INDEX IF NOT EXISTS idx_payouts_created_by              ON public.payouts(created_by);
CREATE INDEX IF NOT EXISTS idx_payouts_driver_id               ON public.payouts(driver_id);
CREATE INDEX IF NOT EXISTS idx_payouts_reviewed_by             ON public.payouts(reviewed_by);
CREATE INDEX IF NOT EXISTS idx_payouts_ride_id                 ON public.payouts(ride_id);
CREATE INDEX IF NOT EXISTS idx_ride_incidents_reported_by      ON public.ride_incidents(reported_by);
CREATE INDEX IF NOT EXISTS idx_ride_incidents_resolved_by      ON public.ride_incidents(resolved_by);
CREATE INDEX IF NOT EXISTS idx_rides_cancelled_by              ON public.rides(cancelled_by);
CREATE INDEX IF NOT EXISTS idx_rides_destination_barrio_id     ON public.rides(destination_barrio_id);
CREATE INDEX IF NOT EXISTS idx_rides_destination_zone_id       ON public.rides(destination_zone_id);
CREATE INDEX IF NOT EXISTS idx_rides_incident_id               ON public.rides(incident_id);
CREATE INDEX IF NOT EXISTS idx_rides_origin_zone_id            ON public.rides(origin_zone_id);
CREATE INDEX IF NOT EXISTS idx_rides_vehicle_id                ON public.rides(vehicle_id);
CREATE INDEX IF NOT EXISTS idx_transactions_reviewed_by        ON public.transactions(reviewed_by);
CREATE INDEX IF NOT EXISTS idx_zones_created_by                ON public.zones(created_by);

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'vista security_invoker' AS comprobacion,
       COALESCE((SELECT array_to_string(c.reloptions, ',') FROM pg_class c
                  WHERE c.oid = 'public.v_barrio_surcharges'::regclass), '(sin opciones)') AS valor
UNION ALL
SELECT 'politicas barrio_surcharges',
       (SELECT COUNT(*)::text FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
         WHERE c.relname = 'barrio_surcharges')
UNION ALL
SELECT 'politicas rpc_audit',
       (SELECT COUNT(*)::text FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
         WHERE c.relname = 'rpc_audit')
UNION ALL
SELECT 'spatial_ref_sys: propietario (no accionable desde el proyecto)',
       (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'public.spatial_ref_sys'::regclass)
UNION ALL
SELECT 'tablas public con RLS y sin politicas (esperado 0)',
       (SELECT COUNT(*)::text FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE n.nspname = 'public' AND c.relkind = 'r' AND c.relrowsecurity
           AND NOT EXISTS (SELECT 1 FROM pg_policy p WHERE p.polrelid = c.oid))
UNION ALL
SELECT 'funciones SECURITY DEFINER sin search_path (esperado 0)',
       (SELECT COUNT(*)::text FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
         WHERE n.nspname = 'public' AND p.prokind = 'f' AND p.prosecdef AND p.proconfig IS NULL
           AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e'))
UNION ALL
SELECT 'indices idx_nuevos (esperado 21)',
       (SELECT COUNT(*)::text FROM pg_indexes
         WHERE schemaname = 'public'
           AND indexname IN (
             'idx_audit_logs_user_id','idx_banners_created_by','idx_coupon_redemptions_ride_id',
             'idx_coupons_created_by','idx_exchange_rates_updated_by','idx_legal_pages_updated_by',
             'idx_payment_method_fields_method','idx_payouts_created_by','idx_payouts_driver_id',
             'idx_payouts_reviewed_by','idx_payouts_ride_id','idx_ride_incidents_reported_by',
             'idx_ride_incidents_resolved_by','idx_rides_cancelled_by','idx_rides_destination_barrio_id',
             'idx_rides_destination_zone_id','idx_rides_incident_id','idx_rides_origin_zone_id',
             'idx_rides_vehicle_id','idx_transactions_reviewed_by','idx_zones_created_by'));

SELECT '✅ Migración 077: avisos de advisors resueltos (puntos 2-5)' AS estado;
