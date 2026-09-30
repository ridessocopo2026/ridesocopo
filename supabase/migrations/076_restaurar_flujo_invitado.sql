-- ============================================================
-- BUNRIDER - Migración 076: RESTAURAR EL FLUJO PÚBLICO (INVITADO)
-- ------------------------------------------------------------
-- PROBLEMA:
--   La ruta /cliente está pensada para verse SIN iniciar sesión
--   (el login solo se pide al solicitar el viaje). Sin embargo, la
--   migración 074_endurecer_permisos_rpc.sql revocó EXECUTE a anon
--   sobre TODAS las RPC del flujo público, incluidas:
--     - get_active_cities  → sin ella el invitado NO recibe ciudades
--     - find_city          → sin ella el GPS no detecta la ciudad
--   Ambas ya habían sido concedidas a anon en 046_multi_ciudades.sql
--   (y re-confirmadas en 053) precisamente como "Flujo público
--   (ClientHome sin login)".
--
--   Efecto visible para el usuario (el bug reportado):
--     1) cities = []  →  selectedCityId vacío
--     2) loadBarrios() nunca se ejecuta (depende de la ciudad)
--     3) "Ingresar destino" abre el panel con la lista VACÍA y solo
--        un botón "Confirmar destino" deshabilitado → parece que la
--        app no cargó / tiene un bug.
--
-- SOLUCIÓN:
--   Devolver EXECUTE a anon SOLO para las dos funciones de lectura
--   pública que el invitado necesita. Ambas son SECURITY DEFINER y
--   devuelven únicamente información que la app ya muestra en el
--   mapa público:
--     - get_active_cities(): id, nombre y centro de las ciudades
--       (zonas cobertura_general) ACTIVAS.
--     - find_city(lat, lng): si un punto cae dentro de una ciudad
--       activa, más su id/nombre/centro.
--
--   NO se re-otorgan (siguen cerradas a anon, a propósito):
--     - calculate_fare ........ expone la tabla de tarifas (motivo de 074)
--     - get_active_payment_methods / get_active_exchange_rate
--     - get_nearest_barrio / get_available_driver_counts
--   El cliente usa find_city para cobertura y deja tarifa y pedido
--   detrás del inicio de sesión.
-- ============================================================

GRANT EXECUTE ON FUNCTION public.get_active_cities() TO anon;
GRANT EXECUTE ON FUNCTION public.find_city(numeric, numeric) TO anon;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT
  p.proname AS funcion,
  has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_puede
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('get_active_cities', 'find_city', 'calculate_fare')
ORDER BY p.proname;

-- Debe devolver:
--   calculate_fare    | false
--   find_city         | true
--   get_active_cities | true

SELECT '✅ Migración 076: flujo público (invitado) restaurado' AS estado;
