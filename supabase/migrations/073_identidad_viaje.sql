-- ============================================================
-- BUNRIDER - Migración 073: IDENTIDAD DEL CLIENTE EN EL VIAJE
-- ------------------------------------------------------------
-- 1) get_ride_client_info(p_ride_id): el CONDUCTOR ASIGNADO ve el
--    nombre, la foto, la calificación y el nº de viajes del cliente
--    para poder ubicarlo/atenderlo mejor.
--    Solo funciona DESPUÉS de aceptar: se exige en cada llamada que
--    rides.driver_id = auth.uid() (accept_ride es quien llena ese
--    campo), así que antes de aceptar el conductor no puede ver
--    ningún dato del cliente, y si el viaje pasa a otro conductor
--    el acceso se revoca solo.
--    NO se expone el teléfono del cliente.
-- 2) set_my_avatar(p_url): el CLIENTE guarda o quita su foto de
--    perfil opcional. Los conductores NO usan esta RPC: siguen con
--    request_avatar_change (revisión del administrador).
--    Solo se aceptan imágenes subidas desde la app (ImgBB/Google) o
--    rutas del bucket público 'avatars'.
-- Costo: 1 RPC (~300 bytes) por viaje abierto + 1 UPDATE de una fila.
-- No crea tablas, índices ni políticas RLS nuevas.
-- ============================================================

-- ============================================================
-- 1. INFO DEL CLIENTE PARA EL CONDUCTOR ASIGNADO
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_ride_client_info(p_ride_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_ride RECORD;
  v_client RECORD;
  v_rating_avg NUMERIC;
  v_rating_count INTEGER;
  v_rides_count INTEGER;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('get_ride_client_info', 30);

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  -- Solo el conductor que ACEPTÓ el viaje (o super_admin/encargado)
  IF v_ride.driver_id IS DISTINCT FROM v_user_id
     AND public.get_user_role(v_user_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT p.id, p.full_name, p.avatar_url
  INTO v_client
  FROM profiles p
  WHERE p.id = v_ride.client_id;

  -- Reputación del cliente: promedio de las calificaciones que le
  -- dieron los conductores (rides.client_rating) y nº de viajes.
  SELECT ROUND(AVG(r.client_rating)::numeric, 1),
         COUNT(r.client_rating),
         COUNT(*)
  INTO v_rating_avg, v_rating_count, v_rides_count
  FROM rides r
  WHERE r.client_id = v_ride.client_id;

  RETURN jsonb_build_object(
    'client', jsonb_build_object(
      'id', v_client.id,
      'full_name', v_client.full_name,
      'avatar_url', v_client.avatar_url,
      'rating_avg', v_rating_avg,
      'rating_count', v_rating_count,
      'rides_count', v_rides_count
    ),
    'tracking_code', v_ride.tracking_code
  );
END;
$$;

-- Permisos: solo autenticados (la RPC valida que sea el conductor del viaje)
GRANT EXECUTE ON FUNCTION public.get_ride_client_info(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_ride_client_info FROM anon;

-- ============================================================
-- 2. FOTO DE PERFIL DEL CLIENTE (OPCIONAL, SIN MODERACIÓN)
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_my_avatar(p_url TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_role public.user_role;
  v_url TEXT;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('set_my_avatar', 10);

  SELECT role INTO v_role FROM profiles WHERE id = v_user_id;

  IF v_role = 'conductor' THEN
    RAISE EXCEPTION 'Los conductores deben solicitar el cambio de foto para su revisión';
  END IF;

  v_url := NULLIF(BTRIM(COALESCE(p_url, '')), '');

  -- Quitar la foto (opcional)
  IF v_url IS NULL THEN
    UPDATE profiles SET avatar_url = NULL WHERE id = v_user_id;
    RETURN jsonb_build_object('success', TRUE, 'avatar_url', NULL);
  END IF;

  IF LENGTH(v_url) > 500 THEN
    RAISE EXCEPTION 'La ruta de la imagen es demasiado larga';
  END IF;

  -- Solo imágenes subidas desde la app (ImgBB / Google) o del bucket avatars
  IF NOT (
    v_url LIKE v_user_id::text || '/%'
    OR v_url ~* '^https://(i\.ibb\.co|ibb\.co|lh3\.googleusercontent\.com|avatars\.googleusercontent\.com)/'
  ) THEN
    RAISE EXCEPTION 'Ruta de imagen inválida: usa una foto subida desde la app';
  END IF;

  UPDATE profiles SET avatar_url = v_url WHERE id = v_user_id;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_user_id, 'SET_AVATAR', 'profile', v_user_id,
          jsonb_build_object('role', v_role::text));

  RETURN jsonb_build_object('success', TRUE, 'avatar_url', v_url);
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_my_avatar(text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.set_my_avatar FROM anon;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 073: identidad del cliente en el viaje lista' AS estado;

SELECT p.proname || ' :: ' || pg_get_function_arguments(p.oid) AS funciones
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('get_ride_client_info', 'set_my_avatar')
ORDER BY p.proname;
