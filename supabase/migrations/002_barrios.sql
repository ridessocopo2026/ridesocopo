-- ============================================================
-- RIDESOCOPÓ - Migración: SISTEMA DE BARRIOS CON PRECIOS
-- Ejecutar DESPUÉS de repair_rls_recursion.sql
-- ============================================================

-- 1. TABLA: BARRIOS
CREATE TABLE IF NOT EXISTS barrios (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT NOT NULL UNIQUE,
  surcharge_usd NUMERIC(10,2) NOT NULL DEFAULT 0.00,
  lat NUMERIC(10,7),
  lng NUMERIC(10,7),
  description TEXT,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. PERMISOS
GRANT ALL ON public.barrios TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;

-- 3. RLS
ALTER TABLE barrios ENABLE ROW LEVEL SECURITY;

-- Todos pueden ver barrios activos
DROP POLICY IF EXISTS "public_view_barrios" ON public.barrios;
CREATE POLICY "public_view_barrios" ON public.barrios
  FOR SELECT USING (is_active = TRUE);

-- Super Admin puede gestionar barrios (con función anti-recursión)
DROP POLICY IF EXISTS "super_admin_manage_barrios" ON public.barrios;
CREATE POLICY "super_admin_manage_barrios" ON public.barrios
  FOR ALL USING (public.get_user_role(auth.uid()) = 'super_admin');

-- 4. TRIGGER updated_at
DROP TRIGGER IF EXISTS update_barrios_updated_at ON barrios;
CREATE TRIGGER update_barrios_updated_at BEFORE UPDATE ON barrios
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- 5. ACTUALIZAR FUNCIÓN CALCULATE_FARE (solo barrio de destino)
CREATE OR REPLACE FUNCTION public.calculate_fare(
  p_origin_lat NUMERIC,
  p_origin_lng NUMERIC,
  p_dest_lat NUMERIC,
  p_dest_lng NUMERIC,
  p_category vehicle_category,
  p_coupon_code TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_base_fare NUMERIC;
  v_dest_surcharge NUMERIC := 0.00;
  v_dest_barrio_id UUID;
  v_dest_barrio_name TEXT;
  v_total NUMERIC;
  v_discount NUMERIC := 0.00;
  v_final NUMERIC;
  v_coupon RECORD;
  v_in_coverage BOOLEAN;
BEGIN
  -- Obtener tarifa base
  SELECT base_fare_usd INTO v_base_fare
  FROM vehicle_categories WHERE name = p_category;

  IF v_base_fare IS NULL THEN
    RAISE EXCEPTION 'Categoría de vehículo no válida';
  END IF;

  -- VALIDAR COBERTURA: el origen debe estar dentro del polígono de Socopó
  SELECT EXISTS (
    SELECT 1 FROM zones z
    WHERE z.zone_type = 'cobertura_general'
      AND z.is_active = TRUE
      AND ST_Contains(z.polygon, ST_SetSRID(ST_MakePoint(p_origin_lng, p_origin_lat), 4326))
  ) INTO v_in_coverage;

  IF NOT v_in_coverage THEN
    RAISE EXCEPTION 'Tu ubicación está fuera del área de cobertura de Socopó';
  END IF;

  -- Buscar barrio de destino por cercanía al punto (aprox. 500m)
  SELECT b.id, b.name, b.surcharge_usd
  INTO v_dest_barrio_id, v_dest_barrio_name, v_dest_surcharge
  FROM barrios b
  WHERE b.is_active = TRUE
    AND b.lat IS NOT NULL
    AND b.lng IS NOT NULL
  ORDER BY ST_Distance(
    ST_SetSRID(ST_MakePoint(b.lng, b.lat), 4326)::geography,
    ST_SetSRID(ST_MakePoint(p_dest_lng, p_dest_lat), 4326)::geography
  )
  LIMIT 1;

  -- Si no hay barrio cercano, recargo 0
  IF v_dest_barrio_id IS NULL THEN
    v_dest_surcharge := 0.00;
    v_dest_barrio_name := 'No especificado';
  END IF;

  -- Calcular total
  v_total := v_base_fare + v_dest_surcharge;

  -- Aplicar cupón
  IF p_coupon_code IS NOT NULL THEN
    SELECT * INTO v_coupon FROM coupons
    WHERE code = UPPER(p_coupon_code)
      AND is_active = TRUE
      AND (valid_from IS NULL OR valid_from <= NOW())
      AND (valid_until IS NULL OR valid_until >= NOW())
      AND (max_uses IS NULL OR used_count < max_uses);

    IF v_coupon.id IS NOT NULL THEN
      IF v_coupon.discount_type = 'percentage' THEN
        v_discount := (v_total * v_coupon.discount_value / 100);
      ELSE
        v_discount := LEAST(v_coupon.discount_value, v_total);
      END IF;
    END IF;
  END IF;

  v_final := GREATEST(v_total - v_discount, 0.00);

  RETURN jsonb_build_object(
    'base_fare', v_base_fare,
    'origin_surcharge', 0.00,
    'destination_surcharge', v_dest_surcharge,
    'total_fare', v_total,
    'discount', v_discount,
    'final_fare', v_final,
    'destination_barrio_id', v_dest_barrio_id,
    'destination_barrio_name', v_dest_barrio_name,
    'in_coverage', v_in_coverage
  );
END;
$$;

-- 6. TABLA RIDES: agregar columna barrio destino
ALTER TABLE rides ADD COLUMN IF NOT EXISTS destination_barrio_id UUID REFERENCES barrios(id);
ALTER TABLE rides ADD COLUMN IF NOT EXISTS destination_barrio_name TEXT;

-- 7. ACTUALIZAR REQUEST_RIDE (usa nuevo calculate_fare)
CREATE OR REPLACE FUNCTION public.request_ride(
  p_origin_lat NUMERIC,
  p_origin_lng NUMERIC,
  p_origin_address TEXT,
  p_dest_lat NUMERIC,
  p_dest_lng NUMERIC,
  p_dest_address TEXT,
  p_category vehicle_category,
  p_payment_method payment_method DEFAULT 'efectivo',
  p_coupon_code TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_fare JSONB;
  v_ride_id UUID;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  -- Calcular tarifa
  v_fare := public.calculate_fare(
    p_origin_lat, p_origin_lng,
    p_dest_lat, p_dest_lng,
    p_category, p_coupon_code
  );

  -- Crear viaje
  INSERT INTO rides (
    client_id, category,
    origin_lat, origin_lng, origin_address,
    destination_lat, destination_lng, destination_address,
    destination_barrio_id, destination_barrio_name,
    base_fare_usd, origin_surcharge_usd, destination_surcharge_usd,
    total_fare_usd, discount_usd, final_fare_usd,
    payment_method, status
  ) VALUES (
    v_user_id, p_category,
    p_origin_lat, p_origin_lng, p_origin_address,
    p_dest_lat, p_dest_lng, p_dest_address,
    (v_fare->>'destination_barrio_id')::UUID,
    v_fare->>'destination_barrio_name',
    (v_fare->>'base_fare')::NUMERIC,
    (v_fare->>'origin_surcharge')::NUMERIC,
    (v_fare->>'destination_surcharge')::NUMERIC,
    (v_fare->>'total_fare')::NUMERIC,
    (v_fare->>'discount')::NUMERIC,
    (v_fare->>'final_fare')::NUMERIC,
    p_payment_method, 'buscando'
  ) RETURNING id INTO v_ride_id;

  -- Auditoría
  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_user_id, 'REQUEST_RIDE', 'ride', v_ride_id, v_fare);

  RETURN v_ride_id;
END;
$$;

-- 8. FUNCIÓN PARA CREAR/ACTUALIZAR BARRIO (Admin)
CREATE OR REPLACE FUNCTION public.upsert_barrio(
  p_name TEXT,
  p_surcharge_usd NUMERIC,
  p_lat NUMERIC DEFAULT NULL,
  p_lng NUMERIC DEFAULT NULL,
  p_description TEXT DEFAULT NULL,
  p_barrio_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_barrio_id UUID;
BEGIN
  IF public.get_user_role(v_admin_id) != 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF p_barrio_id IS NULL THEN
    INSERT INTO barrios (name, surcharge_usd, lat, lng, description)
    VALUES (p_name, p_surcharge_usd, p_lat, p_lng, p_description)
    RETURNING id INTO v_barrio_id;
  ELSE
    UPDATE barrios
    SET name = p_name,
        surcharge_usd = p_surcharge_usd,
        lat = p_lat,
        lng = p_lng,
        description = p_description,
        updated_at = NOW()
    WHERE id = p_barrio_id
    RETURNING id INTO v_barrio_id;
  END IF;

  RETURN v_barrio_id;
END;
$$;

-- 9. FUNCIÓN PARA OBTENER BARRIO CERCANO A UN PUNTO (para cliente)
CREATE OR REPLACE FUNCTION public.get_nearest_barrio(
  p_lat NUMERIC,
  p_lng NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_barrio RECORD;
BEGIN
  SELECT b.id, b.name, b.surcharge_usd
  INTO v_barrio
  FROM barrios b
  WHERE b.is_active = TRUE
    AND b.lat IS NOT NULL
    AND b.lng IS NOT NULL
  ORDER BY ST_Distance(
    ST_SetSRID(ST_MakePoint(b.lng, b.lat), 4326)::geography,
    ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography
  )
  LIMIT 1;

  IF v_barrio IS NULL THEN
    RETURN jsonb_build_object('found', FALSE);
  END IF;

  RETURN jsonb_build_object(
    'found', TRUE,
    'id', v_barrio.id,
    'name', v_barrio.name,
    'surcharge_usd', v_barrio.surcharge_usd
  );
END;
$$;

-- 10. BARRIOS INICIALES DE EJEMPLO (admin los editará)
INSERT INTO barrios (name, surcharge_usd, lat, lng, description) VALUES
  ('Centro', 0.00, 8.2345, -70.2420, 'Zona central de Socopó'),
  ('Bum Bum', 1.50, 8.2350, -70.2480, 'Barrio Bum Bum'),
  ('El Carmen', 2.00, 8.2330, -70.2380, 'Barrio El Carmen'),
  ('Las Delicias', 1.00, 8.2360, -70.2440, 'Barrio Las Delicias')
ON CONFLICT (name) DO NOTHING;

-- ============================================================
-- FIN DE MIGRACIÓN 002
-- ============================================================
SELECT 'Migración 002 completada correctamente' AS estado;