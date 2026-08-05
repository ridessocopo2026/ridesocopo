-- ============================================================
-- RIDESOCOPÓ - Migración: Precios de barrios por tipo de vehículo
-- Agrega precios específicos por categoría de vehículo a cada barrio
-- Mantiene surcharge_usd como fallback para compatibilidad
-- ============================================================

-- 1. AGREGAR COLUMNAS DE PRECIO POR VEHÍCULO
ALTER TABLE public.barrios
  ADD COLUMN IF NOT EXISTS surcharge_moto_usd NUMERIC(10,2) DEFAULT 0.00,
  ADD COLUMN IF NOT EXISTS surcharge_carro_usd NUMERIC(10,2) DEFAULT 0.00,
  ADD COLUMN IF NOT EXISTS surcharge_camioneta_usd NUMERIC(10,2) DEFAULT 0.00;

-- 2. MIGRAR DATOS EXISTENTES (copiar surcharge_usd a las nuevas columnas)
UPDATE public.barrios
SET surcharge_moto_usd = COALESCE(surcharge_usd, 0.00),
    surcharge_carro_usd = COALESCE(surcharge_usd, 0.00),
    surcharge_camioneta_usd = COALESCE(surcharge_usd, 0.00)
WHERE surcharge_moto_usd = 0.00
  AND surcharge_carro_usd = 0.00
  AND surcharge_camioneta_usd = 0.00
  AND surcharge_usd > 0.00;

-- 3. ACTUALIZAR FUNCIÓN CALCULATE_FARE para usar precio según categoría
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
  SELECT b.id, b.name,
    CASE
      WHEN p_category = 'moto' THEN COALESCE(b.surcharge_moto_usd, b.surcharge_usd, 0.00)
      WHEN p_category = 'carro' THEN COALESCE(b.surcharge_carro_usd, b.surcharge_usd, 0.00)
      WHEN p_category = 'camioneta' THEN COALESCE(b.surcharge_camioneta_usd, b.surcharge_usd, 0.00)
      ELSE COALESCE(b.surcharge_usd, 0.00)
    END
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

-- 4. ACTUALIZAR FUNCIÓN UPSERT_BARRIO para aceptar precios por vehículo
CREATE OR REPLACE FUNCTION public.upsert_barrio(
  p_name TEXT,
  p_surcharge_usd NUMERIC,
  p_lat NUMERIC DEFAULT NULL,
  p_lng NUMERIC DEFAULT NULL,
  p_description TEXT DEFAULT NULL,
  p_barrio_id UUID DEFAULT NULL,
  p_surcharge_moto_usd NUMERIC DEFAULT NULL,
  p_surcharge_carro_usd NUMERIC DEFAULT NULL,
  p_surcharge_camioneta_usd NUMERIC DEFAULT NULL
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

  -- Si no se proporcionan precios específicos, usar el precio general
  IF p_surcharge_moto_usd IS NULL THEN p_surcharge_moto_usd := p_surcharge_usd; END IF;
  IF p_surcharge_carro_usd IS NULL THEN p_surcharge_carro_usd := p_surcharge_usd; END IF;
  IF p_surcharge_camioneta_usd IS NULL THEN p_surcharge_camioneta_usd := p_surcharge_usd; END IF;

  IF p_barrio_id IS NULL THEN
    INSERT INTO barrios (name, surcharge_usd, surcharge_moto_usd, surcharge_carro_usd, surcharge_camioneta_usd, lat, lng, description)
    VALUES (p_name, p_surcharge_usd, p_surcharge_moto_usd, p_surcharge_carro_usd, p_surcharge_camioneta_usd, p_lat, p_lng, p_description)
    RETURNING id INTO v_barrio_id;
  ELSE
    UPDATE barrios
    SET name = p_name,
        surcharge_usd = p_surcharge_usd,
        surcharge_moto_usd = p_surcharge_moto_usd,
        surcharge_carro_usd = p_surcharge_carro_usd,
        surcharge_camioneta_usd = p_surcharge_camioneta_usd,
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

-- 5. ACTUALIZAR FUNCIÓN GET_NEAREST_BARRIO para devolver precios por vehículo
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
  SELECT b.id, b.name, b.surcharge_usd,
         b.surcharge_moto_usd, b.surcharge_carro_usd, b.surcharge_camioneta_usd
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
    'surcharge_usd', v_barrio.surcharge_usd,
    'surcharge_moto_usd', COALESCE(v_barrio.surcharge_moto_usd, v_barrio.surcharge_usd, 0.00),
    'surcharge_carro_usd', COALESCE(v_barrio.surcharge_carro_usd, v_barrio.surcharge_usd, 0.00),
    'surcharge_camioneta_usd', COALESCE(v_barrio.surcharge_camioneta_usd, v_barrio.surcharge_usd, 0.00)
  );
END;
$$;

-- 6. VERIFICACIÓN
SELECT 'Migración 032: precios por vehículo en barrios completada' AS estado;