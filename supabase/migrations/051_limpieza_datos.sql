-- ============================================================
-- RIDESOCOPÓ - Migración 051: LIMPIEZA AUTOMÁTICA DE DATOS
-- ------------------------------------------------------------
-- PROBLEMA: notificaciones, audit_logs, cola de push y
-- comprobantes (storage) acumulan filas/archivos sin límite y
-- comen la base (500 MB en Free / 8 GB en Pro) y el storage
-- (1 GB / 100 GB).
--
-- SOLUCIÓN (2 partes):
--   1) Función cleanup_old_data() [SQL, automatizada con
--      pg_cron todos los días 3:00 AM]:
--        - notifications        > 90 días (default)
--        - notification_outbox  > 30 días (cola transitoria)
--        - audit_logs           > 180 días (default)
--      Borra en LOTE (5000 filas) para NO bloquear la base.
--   2) Comprobantes (archivos de storage): NO se pueden borrar
--      por SQL (storage.protect_delete lo bloquea incluso a
--      postgres). Se borran con la Storage API desde el botón
--      "Limpiar datos antiguos" del admin (supabase.storage),
--      que requiere la política RLS super_admin_manage_all_storage
--      creada aquí. NUNCA toca transacciones ni historial.
--
-- pg_cron está disponible incluso en plan Free.
-- ============================================================

-- Índices para acelerar la limpieza (sin afectar el uso normal)
CREATE INDEX IF NOT EXISTS idx_notifications_created_at ON public.notifications (created_at);
CREATE INDEX IF NOT EXISTS idx_audit_logs_created_at ON public.audit_logs (created_at);
CREATE INDEX IF NOT EXISTS idx_outbox_created_at ON public.notification_outbox (created_at);

-- ============================================================
-- 1. FUNCIÓN DE LIMPIEZA (tablas: notificaciones/cola/auditoría)
-- ------------------------------------------------------------
-- Autorización: super_admin (usuario) o sistema (pg_cron /
-- service_role). auth.uid() es NULL cuando la llama pg_cron o
-- service_role → permitido. Cualquier otro usuario logueado que
-- no sea super_admin → 'No autorizado'.
-- ============================================================
-- Limpieza de una versión previa con p_proof_days (obsoleta)
DROP FUNCTION IF EXISTS public.cleanup_old_data(integer, integer, integer, integer);

CREATE OR REPLACE FUNCTION public.cleanup_old_data(
  p_notif_days  INTEGER DEFAULT 90,
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
-- 2. PERMISOS DE LA FUNCIÓN
-- ============================================================
GRANT EXECUTE ON FUNCTION public.cleanup_old_data(integer, integer, integer)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.cleanup_old_data(integer, integer, integer) FROM anon;

-- ============================================================
-- 3. RLS STORAGE: super_admin gestiona TODOS los archivos
-- ------------------------------------------------------------
-- Necesaria para que el botón "Limpiar datos antiguos" borre
-- los comprobantes viejos con la Storage API (supabase.storage)
-- usando la sesión del super_admin.
-- ============================================================
DROP POLICY IF EXISTS "super_admin_manage_all_storage" ON storage.objects;
CREATE POLICY "super_admin_manage_all_storage" ON storage.objects
  FOR ALL
  USING (public.get_user_role(auth.uid()) = 'super_admin')
  WITH CHECK (public.get_user_role(auth.uid()) = 'super_admin');

-- ============================================================
-- 4. PROGRAMACIÓN AUTOMÁTICA (pg_cron)
-- ------------------------------------------------------------
-- pg_cron está disponible también en plan Free. Si por alguna
-- razón no lo estuviera, la migración no falla: solo omite la
-- programación y la limpieza se hace con el botón del admin.
-- ============================================================
DO $$
BEGIN
  BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
  EXCEPTION WHEN OTHERS THEN
    RETURN; -- pg_cron no disponible
  END;

  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      BEGIN
        PERFORM cron.unschedule('ridesocopo-cleanup-daily');
      EXCEPTION WHEN OTHERS THEN
        NULL; -- el job aún no existía
      END;
      PERFORM cron.schedule(
        'ridesocopo-cleanup-daily',
        '0 3 * * *',
        'SELECT public.cleanup_old_data()'
      );
    EXCEPTION WHEN OTHERS THEN
      NULL; -- sin permisos de cron → se omite sin romper nada
    END;
  END IF;
END
$$;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 051: limpieza de datos lista' AS estado;

SELECT p.proname, p.proargnames
FROM pg_proc p
WHERE p.proname = 'cleanup_old_data';

