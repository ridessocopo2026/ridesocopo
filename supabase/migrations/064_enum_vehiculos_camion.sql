-- ============================================================
-- BUNRIDER - Migración 064: ETIQUETAS DEL ENUM vehicle_category
-- ------------------------------------------------------------
-- Supabase ejecuta CADA archivo de migración en una sola
-- transacción y NO permite usar en el mismo script un valor de
-- enum recién agregado (SQLSTATE 55P04 "unsafe use of new value").
-- Por eso estas etiquetas van en un archivo DDL puro (sin usarse)
-- y la migración 065 ya puede insertarlas y usarlas.
-- Idempotente: ADD VALUE IF NOT EXISTS.
-- ============================================================

ALTER TYPE public.vehicle_category ADD VALUE IF NOT EXISTS 'moto_basica';
ALTER TYPE public.vehicle_category ADD VALUE IF NOT EXISTS 'moto_lujo';
ALTER TYPE public.vehicle_category ADD VALUE IF NOT EXISTS 'trimoto';
ALTER TYPE public.vehicle_category ADD VALUE IF NOT EXISTS 'moto_carga';
ALTER TYPE public.vehicle_category ADD VALUE IF NOT EXISTS 'camion_mudanza';

SELECT '✅ Migración 064: etiquetas del enum listas' AS estado;
