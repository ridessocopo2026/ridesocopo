-- ============================================================
-- DIAGNÓSTICO: ADMIN NO VE DATOS
-- ============================================================

SELECT '1. TOTAL RIDES' AS check_name, COUNT(*) AS value FROM rides;

SELECT '2. RIDES CON TRACKING' AS check_name, COUNT(*) AS value FROM rides WHERE tracking_code IS NOT NULL;

SELECT '3. RIDES POR STATUS' AS check_name, status, COUNT(*) AS value FROM rides GROUP BY status ORDER BY status;

SELECT '4. DRIVER_EARNINGS' AS check_name, COUNT(*) AS value FROM driver_earnings;

SELECT '5. TRANSACTIONS 7d' AS check_name, COUNT(*) AS value FROM transactions WHERE created_at > NOW() - INTERVAL '7 days';

SELECT '6. ADMINS' AS check_name, id, email, role FROM profiles WHERE role IN ('super_admin', 'encargado');

SELECT '7. RPC get_admin_rides EXISTS?' AS check_name, COUNT(*) AS value FROM pg_proc WHERE proname = 'get_admin_rides';

SELECT '8. RPC get_admin_metrics EXISTS?' AS check_name, COUNT(*) AS value FROM pg_proc WHERE proname = 'get_admin_metrics';