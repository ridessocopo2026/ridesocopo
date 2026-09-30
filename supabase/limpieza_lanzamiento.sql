-- ============================================================
-- BUNRIDER - LIMPIEZA PARA LANZAMIENTO
-- ------------------------------------------------------------
-- Ejecutada el 2026-09-30 en el proyecto de producción
-- (inxxhkwybjkcaeyahami) para dejar la app lista para uso real:
--
--   · Se borraron TODAS las transacciones, viajes, ganancias,
--     incidentes, liquidaciones y notificaciones (eran pruebas).
--   · Se dejaron TODAS las billeteras en 0.00 $.
--   · Se borraron todas las cuentas MENOS las de la lista de
--     abajo (24 perfiles + 2 cuentas de auth huérfanas).
--   · Se conservó la configuración: ciudades, barrios, categorías
--     de vehículo, métodos de pago, cupones y banners.
--
-- RESULTADO VERIFICADO TRAS EJECUTARLO:
--   perfiles 8 · cuentas auth 8 · transacciones 0 · viajes 0
--   earnings 0 · incidentes 0 · payouts 0 · notificaciones 0
--   vehículos 0 · documentos 0 · billeteras 8 con 0.00 $
--   audit_logs 204 (histórico de las cuentas conservadas)
--   ciudades 2 · barrios 41 · categorías 7 · métodos de pago 3
--
-- ⚠️ ES IRREVERSIBLE. Hacer respaldo antes (Dashboard → Database
--    → Backups) y ejecutarlo en UNA transacción (como está aquí):
--    si algo falla, se revierte todo y no queda a medias.
--
-- ORDEN IMPORTANTE (por las claves foráneas):
--   payouts.ride_id → rides       (NO ACTION) ⇒ payouts antes que rides
--   rides.incident_id → ride_incidents (NO ACTION) ⇒ rides antes que ride_incidents
--   driver_earnings / coupon_redemptions → rides (CASCADE, se van solos)
--   audit_logs.user_id → profiles (NO ACTION) ⇒ borrar la auditoría
--   de las cuentas que se van ANTES de borrarlas
--   profiles.id → auth.users (CASCADE) ⇒ borrar auth.users limpia
--   perfil, billetera, vehículos, documentos, favoritos y push
-- ============================================================

BEGIN;

-- ------------------------------------------------------------
-- 1. CUENTAS QUE SE CONSERVAN (editar aquí si hace falta)
-- ------------------------------------------------------------
CREATE TEMP TABLE keep_users ON COMMIT DROP AS
SELECT id, LOWER(email) AS email
FROM public.profiles
WHERE LOWER(email) IN (
  'leonardyjhn@gmail.com',    -- super_admin
  'ljhn741@gmail.com',
  'leonardyjoseh@gmail.com',
  'duranyaneth453@gmail.com',
  'marynieves455@gmail.com',
  'hluilly03@gmail.com',
  'hluilly170@gmail.com',
  'yonathanacosta70@gmail.com'
);

CREATE TEMP TABLE a_borrar ON COMMIT DROP AS
SELECT id FROM public.profiles WHERE id NOT IN (SELECT id FROM keep_users);

-- ------------------------------------------------------------
-- 2. DINERO Y HISTORIAL OPERATIVO
-- ------------------------------------------------------------
DELETE FROM public.transactions;          -- recargas, comisiones, débitos, ajustes
DELETE FROM public.payouts;               -- liquidaciones (apunta a rides)
DELETE FROM public.driver_earnings;       -- ganancias por viaje
DELETE FROM public.coupon_redemptions;    -- cupones usados
DELETE FROM public.rides;                 -- viajes (cascada: incidentes y ganancias)
DELETE FROM public.ride_incidents;        -- incidentes restantes

-- ------------------------------------------------------------
-- 3. NOTIFICACIONES (bandeja + cola de push)
-- ------------------------------------------------------------
DELETE FROM public.notification_outbox;
DELETE FROM public.notifications;

-- ------------------------------------------------------------
-- 4. AUDITORÍA DE LAS CUENTAS QUE SE VAN (su FK es NO ACTION)
--    La de las cuentas conservadas se mantiene como histórico.
-- ------------------------------------------------------------
DELETE FROM public.audit_logs WHERE user_id IN (SELECT id FROM a_borrar);

-- ------------------------------------------------------------
-- 5. "TODO EN 0": billeteras de las cuentas conservadas
--    (las de las cuentas borradas desaparecen con el CASCADE)
-- ------------------------------------------------------------
UPDATE public.wallets
SET balance_usd = 0, updated_at = NOW()
WHERE user_id IN (SELECT id FROM keep_users);

-- ------------------------------------------------------------
-- 6. BORRAR LAS CUENTAS (auth → CASCADE al perfil y todo lo suyo)
-- ------------------------------------------------------------
DELETE FROM auth.users
WHERE LOWER(email) NOT IN (SELECT email FROM keep_users);

-- 7. Cuentas de auth huérfanas (sin perfil)
DELETE FROM auth.users u
WHERE NOT EXISTS (SELECT 1 FROM public.profiles p WHERE p.id = u.id);

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'perfiles' AS tabla, COUNT(*)::text AS quedan FROM public.profiles
UNION ALL SELECT 'cuentas de auth', COUNT(*)::text FROM auth.users
UNION ALL SELECT 'transacciones', COUNT(*)::text FROM public.transactions
UNION ALL SELECT 'viajes', COUNT(*)::text FROM public.rides
UNION ALL SELECT 'driver_earnings', COUNT(*)::text FROM public.driver_earnings
UNION ALL SELECT 'incidentes', COUNT(*)::text FROM public.ride_incidents
UNION ALL SELECT 'payouts', COUNT(*)::text FROM public.payouts
UNION ALL SELECT 'notificaciones', COUNT(*)::text FROM public.notifications
UNION ALL SELECT 'billeteras', COUNT(*)::text FROM public.wallets
UNION ALL SELECT 'saldo total (debe ser 0.00)', COALESCE(SUM(balance_usd),0)::text FROM public.wallets;

COMMIT;
