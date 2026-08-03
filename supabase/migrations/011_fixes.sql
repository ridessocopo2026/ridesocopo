-- ============================================================
-- RIDESOCOPÓ - Migración: FIXES RLS + REENVÍO OUTBOX
-- 1. Cliente puede ver el perfil del conductor de su viaje activo
-- 2. Reenviar los push pendientes que quedaron por el bug 401
-- ============================================================

-- ============================================================
-- 1. RLS: cliente ve perfil del conductor de su viaje activo
-- ============================================================
DROP POLICY IF EXISTS "client_view_ride_driver_profile" ON public.profiles;
CREATE POLICY "client_view_ride_driver_profile" ON public.profiles
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM rides r
      WHERE r.driver_id = profiles.id
        AND r.client_id = auth.uid()
        AND r.status IN ('aceptada', 'en_ruta', 'completada')
    )
  );

-- ============================================================
-- 2. Reenviar outbox pendientes (push que quedaron con el 401)
-- ============================================================
UPDATE notification_outbox
SET sent_at = NULL, error = NULL, attempts = 0
WHERE sent_at IS NOT NULL AND error LIKE '%401%';

-- ============================================================
SELECT 'Fixes RLS + reenvío outbox aplicados' AS estado;