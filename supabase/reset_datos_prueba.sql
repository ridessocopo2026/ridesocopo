-- ============================================================
-- RIDESOCOPÓ - RESET TOTAL DE DATOS DE PRUEBA
-- ⚠️ ADVERTENCIA: Esto borra TODOS los datos transaccionales.
--    Los usuarios (profiles), vehículos y configuración se mantienen.
--
-- 1. wallets → balance = 0
-- 2. transactions → se borran
-- 3. driver_earnings → se borran
-- 4. payouts → se borran
-- 5. ride_incidents → se borran
-- 6. rides → se borran
-- 7. notifications → se borran
-- 8. notification_outbox → se borran
-- 9. push_subscriptions → SE MANTIENEN (para que los push sigan funcionando)
-- 10. rpc_audit → se borran
-- ============================================================

-- 1. RESET BILLETERAS A $0
UPDATE public.wallets
SET balance_usd = 0,
    is_blocked = FALSE,
    debt_limit_usd = 5.00,
    updated_at = NOW();

-- 2. BORRAR TRANSACCIONES (primero, porque dependen de wallets)
DELETE FROM public.transactions;

-- 3. BORRAR GANANCIAS DE CONDUCTORES
DELETE FROM public.driver_earnings;

-- 4. BORRAR PAGOS/LIQUIDACIONES
DELETE FROM public.payouts;

-- 5. LIMPIAR REFERENCIA DE INCIDENTES EN VIAJES (FK rides_incident_id_fkey)
UPDATE public.rides SET incident_id = NULL WHERE incident_id IS NOT NULL;

-- 6. BORRAR VIAJES (después de limpiar su FK a incidentes)
DELETE FROM public.rides;

-- 6b. BORRAR INCIDENTES (después de los viajes que los referenciaban)
DELETE FROM public.ride_incidents;

-- 7. BORRAR NOTIFICACIONES (datos de prueba)
DELETE FROM public.notifications;

-- 8. BORRAR OUTBOX DE PUSH (datos de prueba)
DELETE FROM public.notification_outbox;

-- 9. BORRAR AUDITORÍA DE PRUEBA
DELETE FROM public.rpc_audit;

-- 10. BORRAR LOGS DE AUDITORÍA (datos de prueba)
DELETE FROM public.audit_logs;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ TODO RESETEADO — listo para pruebas desde 0' AS estado;

SELECT
  (SELECT COUNT(*) FROM transactions) AS transactions,
  (SELECT COUNT(*) FROM driver_earnings) AS earnings,
  (SELECT COUNT(*) FROM payouts) AS payouts,
  (SELECT COUNT(*) FROM ride_incidents) AS incidentes,
  (SELECT COUNT(*) FROM rides) AS viajes,
  (SELECT COUNT(*) FROM notifications) AS notificaciones,
  (SELECT COALESCE(SUM(balance_usd), 0) FROM wallets) AS saldo_total;