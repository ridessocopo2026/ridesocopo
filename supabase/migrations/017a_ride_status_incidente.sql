-- ============================================================
-- RIDESOCOPÓ - Paso 1: Agregar valor 'incidente' al enum ride_status
-- Debe ejecutarse en transacción SEPARADA (Postgres no permite
-- usar un valor recién agregado a un enum en la misma transacción)
-- ============================================================
ALTER TYPE ride_status ADD VALUE IF NOT EXISTS 'incidente';

SELECT 'Estado incidente agregado al enum ride_status' AS estado;