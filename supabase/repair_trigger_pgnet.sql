-- ============================================================
-- REPARACIÓN DEFINITIVA v2: FORZAR eliminación + recreación
-- El schema correcto de pg_net en Supabase es "net"
-- ============================================================

-- 1. Eliminar trigger primero
DROP TRIGGER IF EXISTS on_notification_inserted ON notifications;

-- 2. Eliminar función vieja por completo (para no dejar versiones con pg_net)
DROP FUNCTION IF EXISTS public.notify_push_after_insert();

-- 3. Crear función NUEVA con net.http_post
CREATE OR REPLACE FUNCTION public.notify_push_after_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_settings RECORD;
  v_has_subs BOOLEAN;
BEGIN
  -- Solo encolar si el usuario tiene suscripciones push (ahorra llamadas)
  SELECT EXISTS (
    SELECT 1 FROM push_subscriptions WHERE user_id = NEW.user_id
  ) INTO v_has_subs;

  IF NOT v_has_subs THEN
    RETURN NEW;
  END IF;

  -- Leer configuración
  SELECT * INTO v_settings FROM push_settings LIMIT 1;

  IF v_settings.id IS NULL OR v_settings.function_url IS NULL OR v_settings.function_secret IS NULL THEN
    RETURN NEW;
  END IF;

  -- Llamar a la Edge Function asíncronamente (schema "net" de pg_net en Supabase)
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
  -- NUNCA romper el flujo de negocio aunque pg_net falle
  RETURN NEW;
END;
$$;

-- 4. Recrear trigger
CREATE TRIGGER on_notification_inserted
  AFTER INSERT ON notifications
  FOR EACH ROW EXECUTE FUNCTION public.notify_push_after_insert();

-- ============================================================
-- VERIFICACIÓN: mostrar el código exacto de la función instalada
-- ============================================================
SELECT pg_get_functiondef(oid) AS funcion_instalada
FROM pg_proc
WHERE proname = 'notify_push_after_insert';