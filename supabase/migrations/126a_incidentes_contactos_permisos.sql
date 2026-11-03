-- ============================================================
-- 126a - PERMISOS DE get_admin_incidents
-- ------------------------------------------------------------
-- PostgreSQL concede EXECUTE a PUBLIC por defecto en cada funcion
-- nueva, por lo que `REVOKE ... FROM anon` no basta: hay que revocar
-- PUBLIC y luego conceder solo a los roles que la necesitan.
--
-- La funcion ya valida el rol internamente (super_admin / encargado),
-- pero sin este revoke quedaba expuesta a anon en la API REST.
-- ============================================================
REVOKE ALL ON FUNCTION public.get_admin_incidents(text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_admin_incidents(text, integer, integer)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_admin_incidents(text, integer, integer) FROM anon;

-- ============================================================
-- VERIFICACION
-- ============================================================
SELECT 'anon puede ejecutar get_admin_incidents: ' ||
       has_function_privilege('anon', 'public.get_admin_incidents(text,integer,integer)', 'execute')::text
       AS verificacion;
