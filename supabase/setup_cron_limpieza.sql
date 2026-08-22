-- ============================================================
-- RIDESOCOPÓ - PROGRAMAR LIMPIEZA DIARIA CON PG_CRON (plan Pro+)
-- ------------------------------------------------------------
-- ⚠️ SOLO ejecutar cuando el proyecto esté en plan Pro o superior
--    (pg_cron no está disponible en Free).
-- Ejecutar UNA vez desde SQL Editor:
--   a) Antes:  CREATE EXTENSION IF NOT EXISTS pg_cron;  (si no existe)
--   b) Este script (idempotente: reemplaza el job si ya existe).
--
-- Qué programa: todos los días a las 3:00 AM (hora del servidor)
--   SELECT public.cleanup_old_data();
-- Retenciones: notificaciones 90d · cola push 30d · auditoría 180d.
-- NOTA: los comprobantes de storage NO se borran aquí (supabase
-- bloquea el borrado directo por SQL). Se borran con la Storage
-- API desde el botón "Limpiar datos antiguos" del admin.
-- ============================================================

DO $$
BEGIN
  BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
  EXCEPTION WHEN OTHERS THEN
    RAISE EXCEPTION 'pg_cron no está disponible en este plan (requiere Pro o superior)';
  END;

  BEGIN
    PERFORM cron.unschedule('ridesocopo-cleanup-daily');
  EXCEPTION WHEN OTHERS THEN
    NULL; -- aún no existía el job
  END;

  PERFORM cron.schedule(
    'ridesocopo-cleanup-daily',
    '0 3 * * *',
    'SELECT public.cleanup_old_data()'
  );

  RAISE NOTICE '✅ Limpieza diaria programada: todos los días 3:00 AM (ridesocopo-cleanup-daily)';
END
$$;
