-- ============================================================
-- BUNRIDER - Migración 075: LÍMITES DE SUBIDA Y LIMPIEZA DE STORAGE
-- ------------------------------------------------------------
-- 1) Límites duros por bucket. Hoy los 5 buckets están en
--    file_size_limit = NULL (ILIMITADO) y allowed_mime_types = NULL
--    (TODOS), así que cualquier usuario podía subir un archivo de
--    cientos de MB y disparar el costo. Los límites son holgados
--    frente a la compresión que hace la app (~30-250 KB) y rechazan
--    en el servidor cualquier archivo sin comprimir.
-- 2) storage_paths_to_purge(): devuelve los comprobantes del bucket
--    'payments' con más de N días (90 por defecto) que NO estén
--    referenciados por filas pendientes. Seguro por diseño: nunca
--    devuelve un archivo que la app todavía pueda necesitar.
--    Solo service_role puede ejecutarla.
-- 3) daily_maintenance(): wrapper del cron diario. Ejecuta la
--    limpieza de datos (cleanup_old_data) y luego dispara la Edge
--    Function que borra los archivos viejos con la Storage API
--    (borrar por SQL no elimina el archivo real).
-- ============================================================

-- ============================================================
-- 1. LÍMITES DUROS POR BUCKET
-- ============================================================
UPDATE storage.buckets
SET file_size_limit = 524288, -- 512 KB
    allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp']
WHERE id = 'avatars';

UPDATE storage.buckets
SET file_size_limit = 1048576, -- 1 MB
    allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp']
WHERE id IN ('vehicles', 'banners');

UPDATE storage.buckets
SET file_size_limit = 2097152, -- 2 MB
    allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp']
WHERE id = 'payments';

UPDATE storage.buckets
SET file_size_limit = 2097152, -- 2 MB (se mantiene pdf por si acaso)
    allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp', 'application/pdf']
WHERE id = 'documents';

-- ============================================================
-- 2. RUTAS DE STORAGE SEGURAS DE PURGAR
-- ============================================================
CREATE OR REPLACE FUNCTION public.storage_paths_to_purge(p_dias INTEGER DEFAULT 90)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_dias INTEGER := GREATEST(COALESCE(p_dias, 90), 30); -- nunca menos de 30 días
  v_corte TIMESTAMPTZ := NOW() - (GREATEST(COALESCE(p_dias, 90), 30) || ' days')::INTERVAL;
  v_protegidas TEXT[] := ARRAY[]::TEXT[];
  v_rutas TEXT[] := ARRAY[]::TEXT[];
BEGIN
  -- 1) Comprobantes de recargas aún pendientes de aprobación
  SELECT COALESCE(ARRAY_AGG(DISTINCT t.proof_url), ARRAY[]::TEXT[])
  INTO v_protegidas
  FROM transactions t
  WHERE t.proof_url IS NOT NULL
    AND t.status::text = 'pendiente';

  -- 2) Comprobantes de viajes que siguen esperando conductor o aprobación
  SELECT v_protegidas || COALESCE(ARRAY_AGG(DISTINCT r.proof_url), ARRAY[]::TEXT[])
  INTO v_protegidas
  FROM rides r
  WHERE r.proof_url IS NOT NULL
    AND (r.status::text = 'buscando' OR COALESCE(r.proof_status, '') = 'pendiente');

  -- 3) Fotos de incidencias abiertas o en revisión
  SELECT v_protegidas || COALESCE(ARRAY_AGG(DISTINCT p.url), ARRAY[]::TEXT[])
  INTO v_protegidas
  FROM ride_incidents i
  CROSS JOIN LATERAL jsonb_array_elements_text(COALESCE(i.photo_urls, '[]'::jsonb)) AS p(url)
  WHERE i.status::text IN ('abierto', 'en_revision');

  -- 4) Objetos del bucket payments más antiguos que el corte y sin referencia viva
  SELECT COALESCE(ARRAY_AGG(o.name), ARRAY[]::TEXT[])
  INTO v_rutas
  FROM storage.objects o
  WHERE o.bucket_id = 'payments'
    AND o.created_at < v_corte
    AND NOT (o.name = ANY (v_protegidas));

  RETURN jsonb_build_object(
    'dias', v_dias,
    'corte', v_corte,
    'candidatos', COALESCE(ARRAY_LENGTH(v_rutas, 1), 0),
    'protegidas', COALESCE(ARRAY_LENGTH(v_protegidas, 1), 0),
    'paths', to_jsonb(v_rutas)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.storage_paths_to_purge(integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.storage_paths_to_purge(integer) TO service_role;

-- ============================================================
-- 3. MANTENIMIENTO DIARIO (datos + archivos)
-- ============================================================
CREATE OR REPLACE FUNCTION public.daily_maintenance()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_datos JSONB;
  v_settings RECORD;
BEGIN
  -- 1) Limpieza de datos (notificaciones, cola push, auditoría)
  v_datos := public.cleanup_old_data();

  -- 2) Disparar la limpieza de ARCHIVOS viejos de Storage (Edge Function
  --    que usa la Storage API: el borrado por SQL no elimina el archivo).
  BEGIN
    SELECT * INTO v_settings FROM push_settings LIMIT 1;
    IF v_settings.function_secret IS NOT NULL AND v_settings.function_url IS NOT NULL THEN
      PERFORM net.http_post(
        url := replace(v_settings.function_url, 'push-notifications', 'cleanup-storage'),
        headers := jsonb_build_object(
          'Content-Type', 'application/json',
          'Authorization', 'Bearer ' || v_settings.function_secret
        ),
        body := jsonb_build_object('dias', 90)
      );
    END IF;
  EXCEPTION WHEN OTHERS THEN
    NULL; -- la limpieza de archivos jamás debe romper la limpieza de datos
  END;

  RETURN jsonb_build_object('datos', v_datos, 'storage_solicitado', TRUE);
END;
$$;

REVOKE ALL ON FUNCTION public.daily_maintenance() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.daily_maintenance() TO authenticated, service_role;

-- ============================================================
-- 4. CRON: la limpieza diaria ahora también purga archivos
-- ============================================================
DO $$
BEGIN
  BEGIN
    PERFORM cron.unschedule('ridesocopo-cleanup-daily');
  EXCEPTION WHEN OTHERS THEN
    NULL; -- el job aún no existía
  END;

  PERFORM cron.schedule(
    'ridesocopo-cleanup-daily',
    '0 3 * * *',
    'SELECT public.daily_maintenance()'
  );
END $$;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 075: límites de subida y limpieza de storage listos' AS estado;

SELECT id AS bucket,
       pg_size_pretty(file_size_limit::bigint) AS limite,
       allowed_mime_types::text AS mimes
FROM storage.buckets
ORDER BY id;

SELECT jobname, schedule, active
FROM cron.job
ORDER BY jobname;

