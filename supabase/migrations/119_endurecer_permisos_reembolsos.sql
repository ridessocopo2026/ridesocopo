-- ============================================================
-- 119 - ENDURECER PERMISOS DE LOS RPC DE REEMBOLSOS
-- ------------------------------------------------------------
-- Postgres otorga EXECUTE a PUBLIC por defecto; hay que quitarlo
-- explícitamente para que `anon` no pueda invocar los RPC.
-- (El chequeo interno de auth.uid() ya los bloquea, pero esto
--  evita que aparezcan como ejecutables por anon en los advisors.)
-- ============================================================

REVOKE ALL ON FUNCTION public.get_pending_refunds() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.get_pending_refunds() FROM anon;
GRANT EXECUTE ON FUNCTION public.get_pending_refunds() TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.admin_process_refund(UUID, BOOLEAN, TEXT) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.admin_process_refund(UUID, BOOLEAN, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.admin_process_refund(UUID, BOOLEAN, TEXT) TO authenticated, service_role;

SELECT 'Migración 119 aplicada: permisos de reembolsos endurecidos' AS estado;
