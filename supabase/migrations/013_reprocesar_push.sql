-- ============================================================
-- RIDESOCOPÓ - Migración: REPROCESAR PUSH PENDIENTES + TRIGGER
-- 1. Función para reenviar TODOS los push pendientes
-- 2. Trigger mejorado: SIEMPRE encola (nunca pierde notificaciones)
-- ============================================================

-- ============================================================
-- 1. FUNCIÓN: REPROCESAR NOTIFICACIONES PENDIENTES
-- Reenvía todas las notificaciones con sent_at NULL a la
-- Edge Function (ahora arreglada con --no-verify-jwt).
-- ============================================================
CREATE OR REPLACE FUNCTION public.reprocess_pending_notifications()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER := 0;
  v_item RECORD;
  v_settings RECORD;
BEGIN
  -- Leer configuración del push (URL + secreto)
  SELECT * INTO v_settings FROM push_settings LIMIT 1;

  IF v_settings.id IS NULL OR v_settings.function_url IS NULL OR v_settings.function_secret IS NULL THEN
    RETURN 0;
  END IF;

  -- Reenviar los pendientes
  FOR v_item IN
    SELECT * FROM notification_outbox
    WHERE sent_at IS NULL
    LIMIT 300
  LOOP
    -- Enviar a la Edge Function
    PERFORM net.http_post(
      url := v_settings.function_url,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || v_settings.function_secret
      ),
      body := jsonb_build_object('notification_id', v_item.notification_id)
    );
    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.reprocess_pending_notifications TO anon, authenticated, service_role;

-- ============================================================
-- 2. TRIGGER MEJORADO: SIEMPRE ENCOLAR
-- Ya NO se verifica si el usuario tiene suscripción ANTES de
-- encolar. La Edge Function maneja "sin suscripciones" marcando
-- sent_at. Así NINGUNA notificación se pierde y si el conductor
-- activa push después, el reproceso la alcanza.
-- ============================================================
CREATE OR REPLACE FUNCTION public.notify_push_after_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_settings RECORD;
  v_pg_net_available BOOLEAN;
BEGIN
  -- Leer configuración
  SELECT * INTO v_settings FROM push_settings LIMIT 1;

  IF v_settings.id IS NULL OR v_settings.function_url IS NULL OR v_settings.function_secret IS NULL THEN
    RETURN NEW;
  END IF;

  -- Verificar que pg_net esté disponible
  SELECT EXISTS (
    SELECT 1 FROM pg_extension WHERE extname = 'pg_net'
  ) INTO v_pg_net_available;

  IF NOT v_pg_net_available THEN
    RETURN NEW;
  END IF;

  -- Llamar a la Edge Function asíncronamente (SIEMPRE encola)
  PERFORM net.http_post(
    url := v_settings.function_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_settings.function_secret
    ),
    body := jsonb_build_object('notification_id', NEW.id)
  );

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  -- NUNCA romper el flujo de negocio
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_notification_inserted ON notifications;
CREATE TRIGGER on_notification_inserted
  AFTER INSERT ON notifications
  FOR EACH ROW EXECUTE FUNCTION public.notify_push_after_insert();

-- ============================================================
-- 3. AGREGAR notificaciones SIN outbox a la cola (las que el
--    trigger viejo perdió porque no había suscripción)
-- ============================================================
INSERT INTO notification_outbox (notification_id, user_id)
SELECT n.id, n.user_id
FROM notifications n
LEFT JOIN notification_outbox o ON o.notification_id = n.id
WHERE o.id IS NULL
ON CONFLICT (notification_id) DO NOTHING;

-- ============================================================
SELECT 'Migración de reprocesamiento completada' AS estado;