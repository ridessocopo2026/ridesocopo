-- ============================================================
-- BUNRIDER - Migración 063: NOTIFICACIONES EFICIENTES
-- ------------------------------------------------------------
-- Problema: las ofertas de viaje (ride_available) se guardan por
-- conductor y NUNCA se borran aunque el viaje ya se aceptó,
-- canceló o terminó → pilas enormes de notificaciones sin leer
-- de viajes que ya no existen.
--
-- Solución (3 partes):
--   1) Ofertas EFÍMERAS: trigger que borra los ride_available de
--      un viaje en cuanto este sale de 'buscando'
--      (aceptada / cancelada / incidente).
--   2) Retención corta: cleanup_old_data() reduce el default a 30
--      días y además poda ofertas con más de 24 h de vida
--      (mantiene firma y JSON de retorno → AdminConfig intacto).
--   3) Auto-gestión del usuario: el dueño puede eliminar una
--      notificación, borrar las leídas o vaciar todo, mediante
--      RPCs SECURITY DEFINER acotadas a auth.uid() (la tabla no
--      tiene política DELETE para clientes).
-- ============================================================

-- ============================================================
-- 1. OFERTAS DE VIAJE EFÍMERAS (trigger sobre rides)
-- ============================================================
-- Índice para localizar rápido las ofertas de un viaje.
CREATE INDEX IF NOT EXISTS idx_notifications_ride_offers
  ON public.notifications (((data ->> 'ride_id')))
  WHERE type = 'ride_available';

CREATE OR REPLACE FUNCTION public.purge_ride_offer_notifications()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_deleted INTEGER;
BEGIN
  -- El viaje salió de 'buscando' (lo aceptaron, lo cancelaron, etc.):
  -- sus ofertas ya no sirven para ningún conductor.
  IF OLD.status = 'buscando' AND NEW.status IS DISTINCT FROM 'buscando' THEN
    LOOP
      DELETE FROM public.notifications
      WHERE id IN (
        SELECT id FROM public.notifications
        WHERE type = 'ride_available'
          AND data ->> 'ride_id' = NEW.id::text
        LIMIT 5000
      );
      GET DIAGNOSTICS v_deleted = ROW_COUNT;
      EXIT WHEN v_deleted < 5000;
    END LOOP;
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_purge_ride_offer_notifications ON public.rides;
CREATE TRIGGER trg_purge_ride_offer_notifications
  AFTER UPDATE OF status ON public.rides
  FOR EACH ROW
  EXECUTE FUNCTION public.purge_ride_offer_notifications();

-- ============================================================
-- 2. RETENCIÓN CORTA (rewrite de cleanup_old_data)
-- ------------------------------------------------------------
-- Se conserva la misma firma y el mismo JSON de retorno
-- (notifications / outbox / audit_logs) para no romper el botón
-- de "Limpieza de datos" de AdminConfig ni el job de pg_cron.
-- Cambios: default de notificaciones 90 → 30 días y poda de
-- ofertas ride_available con más de 24 h.
-- ============================================================
CREATE OR REPLACE FUNCTION public.cleanup_old_data(
  p_notif_days  INTEGER DEFAULT 30,
  p_outbox_days INTEGER DEFAULT 30,
  p_audit_days  INTEGER DEFAULT 180
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_notif  INTEGER := 0;
  v_outbox INTEGER := 0;
  v_audit  INTEGER := 0;
  v_del    INTEGER := 0;
BEGIN
  -- Solo super_admin (usuario logueado) o el sistema (cron/service_role)
  IF auth.uid() IS NOT NULL AND public.get_user_role(auth.uid()) != 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- Anti-abuso (2 ejecuciones por minuto como máximo)
  PERFORM public.guard_rate_limit('cleanup_old_data', 2);

  -- 0) Ofertas de viaje viejas (> 24 h): aunque el viaje siga 'buscando'
  --    ya nadie la va a aceptar desde la campana.
  LOOP
    DELETE FROM public.notifications
    WHERE id IN (
      SELECT id FROM public.notifications
      WHERE type = 'ride_available'
        AND created_at < NOW() - INTERVAL '24 hours'
      LIMIT 5000
    );
    GET DIAGNOSTICS v_del = ROW_COUNT;
    v_notif := v_notif + v_del;
    EXIT WHEN v_del < 5000;
  END LOOP;

  -- 1) Notificaciones in-app antiguas (en lotes de 5000)
  LOOP
    DELETE FROM public.notifications
    WHERE id IN (
      SELECT id FROM public.notifications
      WHERE created_at < NOW() - (p_notif_days || ' days')::INTERVAL
      LIMIT 5000
    );
    GET DIAGNOSTICS v_del = ROW_COUNT;
    v_notif := v_notif + v_del;
    EXIT WHEN v_del < 5000;
  END LOOP;

  -- 2) Cola de push antigua (cola transitoria: enviada o muerta)
  LOOP
    DELETE FROM public.notification_outbox
    WHERE notification_id IN (
      SELECT notification_id FROM public.notification_outbox
      WHERE created_at < NOW() - (p_outbox_days || ' days')::INTERVAL
      LIMIT 5000
    );
    GET DIAGNOSTICS v_del = ROW_COUNT;
    v_outbox := v_outbox + v_del;
    EXIT WHEN v_del < 5000;
  END LOOP;

  -- 3) Logs de auditoría antiguos
  LOOP
    DELETE FROM public.audit_logs
    WHERE id IN (
      SELECT id FROM public.audit_logs
      WHERE created_at < NOW() - (p_audit_days || ' days')::INTERVAL
      LIMIT 5000
    );
    GET DIAGNOSTICS v_del = ROW_COUNT;
    v_audit := v_audit + v_del;
    EXIT WHEN v_del < 5000;
  END LOOP;

  -- Registrar la ejecución (user_id NULL cuando lo llama cron/service_role)
  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (
    auth.uid(),
    'CLEANUP_OLD_DATA',
    'system',
    NULL,
    jsonb_build_object(
      'notifications', v_notif,
      'outbox', v_outbox,
      'audit_logs', v_audit
    )
  );

  RETURN jsonb_build_object(
    'notifications', v_notif,
    'outbox', v_outbox,
    'audit_logs', v_audit
  );
END;
$$;

-- ============================================================
-- 3. AUTO-GESTIÓN DEL USUARIO (RPCs SECURITY DEFINER)
-- ------------------------------------------------------------
-- notifications no tiene política DELETE → se usa SECURITY
-- DEFINER pero SIEMPRE filtrando por user_id = auth.uid().
-- ============================================================

-- 3.1 Eliminar una notificación propia
CREATE OR REPLACE FUNCTION public.delete_my_notification(p_notification_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_deleted INTEGER;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('delete_my_notification', 30);

  DELETE FROM public.notifications
  WHERE id = p_notification_id AND user_id = v_user_id;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted > 0;
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_my_notification(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.delete_my_notification FROM anon;

-- 3.2 Borrar todas las notificaciones ya leídas
CREATE OR REPLACE FUNCTION public.clear_read_notifications()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_deleted INTEGER;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('clear_read_notifications', 10);

  DELETE FROM public.notifications
  WHERE user_id = v_user_id AND is_read = TRUE;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

GRANT EXECUTE ON FUNCTION public.clear_read_notifications() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.clear_read_notifications FROM anon;

-- 3.3 Vaciar TODA la bandeja propia
CREATE OR REPLACE FUNCTION public.clear_all_notifications()
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_deleted INTEGER;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('clear_all_notifications', 5);

  DELETE FROM public.notifications
  WHERE user_id = v_user_id;

  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN v_deleted;
END;
$$;

GRANT EXECUTE ON FUNCTION public.clear_all_notifications() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.clear_all_notifications FROM anon;

-- ============================================================
-- 4. LIMPIEZA RETROACTIVA (se ejecuta UNA vez al aplicar)
-- ------------------------------------------------------------
-- Elimina de inmediato las ofertas acumuladas que ya no aplican:
--  · ofertas de viajes que ya NO están 'buscando' (los aceptaron,
--    cancelaron o terminaron hace tiempo), y
--  · ofertas con más de 24 h de vida aunque el viaje siga buscando.
DELETE FROM public.notifications n
WHERE n.type = 'ride_available'
  AND (
    n.created_at < NOW() - INTERVAL '24 hours'
    OR NOT EXISTS (
      SELECT 1 FROM public.rides r
      WHERE r.id = (n.data ->> 'ride_id')::uuid
        AND r.status = 'buscando'
    )
  );



