-- ============================================================
-- RIDESOCOPÓ - Migración: Barrios, Urbanizaciones y Sectores de Socopó
-- Agrega columna tipo y los 43 lugares reales de Socopó
-- ============================================================

-- 1. AGREGAR COLUMNA TIPO
ALTER TABLE public.barrios
  ADD COLUMN IF NOT EXISTS tipo TEXT DEFAULT 'barrio';

-- 2. ELIMINAR BARRIOS DE EJEMPLO QUE NO EXISTEN EN LA LISTA REAL
DELETE FROM public.barrios WHERE name = 'Bum Bum';
DELETE FROM public.barrios WHERE name = 'Las Delicias';

-- 3. INSERTAR BARRIOS DE SOCOPÓ
INSERT INTO public.barrios (name, surcharge_usd, surcharge_moto_usd, surcharge_carro_usd, surcharge_camioneta_usd, tipo, description) VALUES
  ('Ana Campos', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('Antonio José de Sucre', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('Bella Vista', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('Carnavelli', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('Corozal', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('El Araguaney', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('El Despertar Llanero', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('El Marqués', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('Emilita Camejo', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('Florida', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('La Esperanza I', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('La Esperanza II', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('La Kimil', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('La Pradera', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('La Sabana', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('La Victoria', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('Las Américas', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('Las Flores', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('Libertador I', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('Libertador II', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('Llano Alto', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('Lorenzo Contreras', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('Los Eucaliptus', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('Los Naranjos', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('Menca de Leoni', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('Nueva República', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('Nuevo Paraíso', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('Obrero', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('Prado Alegre', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('Pueblo Nuevo', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('Santa Bárbara Bendita', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('Santa Rosa', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó'),
  ('Simón Bolívar', 0.00, 0.00, 0.00, 0.00, 'barrio', 'Barrio de Socopó')
ON CONFLICT (name) DO NOTHING;

-- 4. INSERTAR URBANIZACIONES
INSERT INTO public.barrios (name, surcharge_usd, surcharge_moto_usd, surcharge_carro_usd, surcharge_camioneta_usd, tipo, description) VALUES
  ('Urb. Ana María', 0.00, 0.00, 0.00, 0.00, 'urbanizacion', 'Urbanización de Socopó'),
  ('Urb. Antonio José de Sucre', 0.00, 0.00, 0.00, 0.00, 'urbanizacion', 'Urbanización de Socopó'),
  ('Urb. La Trinidad', 0.00, 0.00, 0.00, 0.00, 'urbanizacion', 'Urbanización de Socopó'),
  ('Urb. Los Educadores', 0.00, 0.00, 0.00, 0.00, 'urbanizacion', 'Urbanización de Socopó'),
  ('Urb. Nuevo Paraíso', 0.00, 0.00, 0.00, 0.00, 'urbanizacion', 'Urbanización de Socopó')
ON CONFLICT (name) DO NOTHING;

-- 5. INSERTAR SECTORES ADICIONALES
INSERT INTO public.barrios (name, surcharge_usd, surcharge_moto_usd, surcharge_carro_usd, surcharge_camioneta_usd, tipo, description) VALUES
  ('Batatuy', 0.00, 0.00, 0.00, 0.00, 'sector', 'Sector de Socopó'),
  ('Centro', 0.00, 0.00, 0.00, 0.00, 'sector', 'Zona central de Socopó')
ON CONFLICT (name) DO UPDATE
SET tipo = 'sector', description = 'Zona central de Socopó';

-- 6. VERIFICACIÓN
SELECT tipo, COUNT(*) as cantidad FROM public.barrios GROUP BY tipo ORDER BY tipo;