-- ============================================================
-- BUNRIDER - Migración 061: CATÁLOGO MOTO BÁSICA / LUJO /
-- TRIMOTO / CARGA
-- ------------------------------------------------------------
-- 1) Amplía el enum vehicle_category con: moto_basica,
--    moto_lujo, trimoto, moto_carga.
-- 2) Siembra el catálogo (idempotente) con tarifas, pasajeros,
--    descripción e icono (emoji).
-- 3) Reasigna los vehículos actuales de 'moto' a 'moto_basica'
--    y deja el tipo 'moto' INACTIVO (sin uso para clientes y
--    conductores, pero los viajes históricos conservan su etiqueta).
-- Guard: si hay viajes activos en 'moto' la migración aborta
-- (no se rompen emparejamientos).
-- ============================================================

-- 1. AMPLIAR EL ENUM (etiquetas nuevas)
ALTER TYPE public.vehicle_category ADD VALUE IF NOT EXISTS 'moto_basica';
ALTER TYPE public.vehicle_category ADD VALUE IF NOT EXISTS 'moto_lujo';
ALTER TYPE public.vehicle_category ADD VALUE IF NOT EXISTS 'trimoto';
ALTER TYPE public.vehicle_category ADD VALUE IF NOT EXISTS 'moto_carga';

-- 2. GUARD: no reasignar si hay viajes activos en 'moto'
DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.rides
    WHERE category = 'moto'
      AND status IN ('buscando', 'aceptada', 'en_ruta', 'incidente')
  ) THEN
    RAISE EXCEPTION 'Hay viajes activos en la categoría "moto". Termínalos o cancélalos antes de aplicar esta migración.';
  END IF;
END;
$$;

-- 3. SEMBRAR EL CATÁLOGO (idempotente)
INSERT INTO public.vehicle_categories
  (name, display_name, base_fare_usd, max_passengers, description, icon, is_active)
VALUES
  ('moto_basica', 'Moto Básica', 1.00, 1, 'Económica, 1 pasajero', '🛵', TRUE),
  ('moto_lujo', 'Moto de Lujo', 1.60, 1, 'Cómoda y rápida', '🏍️', TRUE),
  ('trimoto', 'Trimoto', 2.00, 3, 'Trimoto, hasta 3 pasajeros', '🛺', TRUE),
  ('moto_carga', 'Moto de Carga', 1.30, 1, 'Transporte de mercancías para negocios', '📦', TRUE)
ON CONFLICT (name) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  base_fare_usd = EXCLUDED.base_fare_usd,
  max_passengers = EXCLUDED.max_passengers,
  description = EXCLUDED.description,
  icon = EXCLUDED.icon,
  is_active = TRUE;

-- Iconos para los tipos clásicos (si aún no tienen)
UPDATE public.vehicle_categories SET icon = '🚗' WHERE name = 'carro';
UPDATE public.vehicle_categories SET icon = '🚚' WHERE name = 'camioneta';
UPDATE public.vehicle_categories SET icon = '🛵' WHERE name = 'moto';

-- 4. REASIGNAR VEHÍCULOS de 'moto' a 'moto_basica'
UPDATE public.vehicles
SET category = 'moto_basica'
WHERE category = 'moto'
  AND EXISTS (SELECT 1 FROM public.vehicle_categories WHERE name = 'moto_basica');

-- 5. DEJAR 'moto' SIN USO (inactiva)
UPDATE public.vehicle_categories
SET is_active = FALSE
WHERE name = 'moto';

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT name, display_name, base_fare_usd, max_passengers, icon, is_active
FROM public.vehicle_categories
ORDER BY is_active DESC, base_fare_usd;
