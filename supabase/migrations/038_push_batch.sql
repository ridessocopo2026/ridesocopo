-- ============================================================
-- RIDESOCOPÓ - Migración 038: PUSH EN LOTE (ahorro Edge Functions)
-- ------------------------------------------------------------
-- PROBLEMA: el trigger per-row llamaba a la Edge Function 1 vez
-- por notificación → un ride_available a 25 conductores = 25
-- invocaciones (límite Pro: 2M/mes → ~4.000 viajes/día).
--
-- SOLUCIÓN: agrupar por statement.
--   1) Trigger per-row: ENCOLA el id en una tabla TEMPORAL de
--      la sesión (y en notification_outbox para reproceso manual).
--   2) Trigger AFTER STATEMENT: lee el lote, lo limpia y hace
--      UNA llamada pg_net con la lista de notification_ids
--      (en chunks de 50 para no exceder el tiempo de ejecución).
--   3) La Edge Function procesa la lista en UNA invocación.
--
-- Resultado: ride_available (25 push) = 1 invocación en vez de 25.
-- ============================================================

-- ============================================================
-- 1. FUNCIÓN PER-ROW: ENCOLAR EN TABLA TEMPORAL + OUTBOX
-- ============================================================
CREATE OR REPLACE FUNCTION public.notify_push_queue_row()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  -- Solo encolar si el usuario tiene suscripciones push (ahorra Edge Functions)
  IF NOT EXISTS (SELECT 1 FROM push_subscriptions WHERE user_id = NEW.user_id) THEN
    RETURN NEW;
  END IF;

  -- Encolar en notification_outbox (fallback de reproceso manual)
  INSERT INTO notification_outbox (notification_id, user_id)
  VALUES (NEW.id, NEW.user_id)
  ON CONFLICT (notification_id) DO NOTHING;

  -- Encolar en la tabla temporal del lote (misma sesión/statement)
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.ridesocopo_pending_push (
    notification_id UUID PRIMARY KEY
  ) ON COMMIT PRESERVE ROWS;

  INSERT INTO pg_temp.ridesocopo_pending_push (notification_id)
  VALUES (NEW.id)
  ON CONFLICT DO NOTHING;

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  -- NUNCA romper el flujo de negocio
  RETURN NEW;
END;
$$;

-- ============================================================
-- 2. FUNCIÓN AFTER STATEMENT: UNA LLAMADA PG_NET POR LOTE
-- ============================================================
CREATE OR REPLACE FUNCTION public.notify_push_batch_statement()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_settings RECORD;
  v_pg_net_available BOOLEAN;
  v_pending UUID[];
  v_idx INTEGER;
  v_chunk_size CONSTANT INTEGER := 50;
BEGIN
  -- Asegurar la tabla temporal y vaciarla SIEMPRE (evita duplicados)
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.ridesocopo_pending_push (
    notification_id UUID PRIMARY KEY
  ) ON COMMIT PRESERVE ROWS;

  -- Leer configuración del push
  SELECT * INTO v_settings FROM push_settings LIMIT 1;
  IF v_settings.id IS NULL OR v_settings.function_url IS NULL OR v_settings.function_secret IS NULL THEN
    TRUNCATE pg_temp.ridesocopo_pending_push;
    RETURN NULL;
  END IF;

  SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net')
  INTO v_pg_net_available;
  IF NOT v_pg_net_available THEN
    TRUNCATE pg_temp.ridesocopo_pending_push;
    RETURN NULL;
  END IF;

  -- Tomar el lote del statement actual
  SELECT ARRAY(
    SELECT notification_id FROM pg_temp.ridesocopo_pending_push ORDER BY notification_id
  ) INTO v_pending;

  TRUNCATE pg_temp.ridesocopo_pending_push;

  IF array_length(v_pending, 1) IS NULL THEN
    RETURN NULL;
  END IF;

  -- 💰 UNA llamada por chunk de 50 (en vez de una por notificación)
  v_idx := 1;
  WHILE v_idx <= array_length(v_pending, 1) LOOP
    PERFORM net.http_post(
      url := v_settings.function_url,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || v_settings.function_secret
      ),
      body := jsonb_build_object(
        'notification_ids', to_jsonb(
          v_pending[v_idx : LEAST(v_idx + v_chunk_size - 1, array_length(v_pending, 1))]
        )
      )
    );
    v_idx := v_idx + v_chunk_size;
  END LOOP;

  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  -- NUNCA romper el flujo de negocio (pg_net/limpieza fallan silenciosamente)
  BEGIN
    TRUNCATE pg_temp.ridesocopo_pending_push;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  RETURN NULL;
END;
$$;

-- ============================================================
-- 3. REEMPLAZAR EL TRIGGER VIEJO (per-row → nuevo par de triggers)
-- ============================================================
DROP TRIGGER IF EXISTS on_notification_inserted ON notifications;
DROP TRIGGER IF EXISTS notify_push_queue_row ON notifications;
DROP TRIGGER IF EXISTS notify_push_batch_statement ON notifications;

CREATE TRIGGER notify_push_queue_row
  AFTER INSERT ON notifications
  FOR EACH ROW EXECUTE FUNCTION public.notify_push_queue_row();

CREATE TRIGGER notify_push_batch_statement
  AFTER INSERT ON notifications
  FOR EACH STATEMENT EXECUTE FUNCTION public.notify_push_batch_statement();

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 038: push en lote aplicado' AS estado;

SELECT tgname, pg_get_triggerdef(oid) AS definicion
FROM pg_trigger
WHERE tgrelid = 'public.notifications'::regclass
  AND NOT tgisinternal
ORDER BY tgname;
