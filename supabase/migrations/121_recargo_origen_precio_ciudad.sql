-- ============================================================
-- 121 - RECARGO DE ORIGEN + PRECIO BASE POR CIUDAD
-- ------------------------------------------------------------
-- 1) calculate_fare aplica el recargo del barrio/sector de
--    ORIGEN ademas del de DESTINO.
-- 2) El precio base usa COALESCE(city_fares, vehicle_categories).
-- 3) Devuelve origin_barrio_id/name y origin_surcharge.
--
-- Regla: total = base + recargo_origen + recargo_destino - cupon
-- ============================================================

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
  v_origin_surcharge NUMERIC := 0.00;
  v_origin_barrio_id UUID;
  v_origin_barrio_name TEXT;
  v_dest_surcharge NUMERIC := 0.00;
  v_dest_barrio_id UUID;
  v_dest_barrio_name TEXT;
  v_total NUMERIC;
  v_discount NUMERIC := 0.00;
  v_final NUMERIC;
  v_coupon_result JSONB;
  v_coupon_id UUID;
  v_coupon_reason TEXT;
  v_coupon_message TEXT;
  v_zone RECORD;
BEGIN
  -- 1. Ciudad de cobertura que contiene el ORIGEN
  SELECT z.id, z.name, z.polygon INTO v_zone
  FROM zones z
  WHERE z.zone_type = 'cobertura_general'
    AND z.is_active = TRUE
    AND ST_Covers(z.polygon, ST_SetSRID(ST_MakePoint(p_origin_lng, p_origin_lat), 4326))
  LIMIT 1;

  IF v_zone.id IS NULL THEN
    RAISE EXCEPTION 'Tu ubicacion esta fuera del area de cobertura de la app';
  END IF;

  -- 2. El DESTINO tambien debe estar dentro de la cobertura
  IF NOT ST_Covers(v_zone.polygon, ST_SetSRID(ST_MakePoint(p_dest_lng, p_dest_lat), 4326)) THEN
    RAISE EXCEPTION 'El destino esta fuera del area de cobertura de la app';
  END IF;

  -- 3. Precio base: override por ciudad o global
  SELECT COALESCE(cf.base_fare_usd, c.base_fare_usd)
  INTO v_base_fare
  FROM vehicle_categories c
  LEFT JOIN city_fares cf
    ON cf.zone_id = v_zone.id
   AND cf.category = c.name
   AND cf.is_active = TRUE
  WHERE c.name = p_category;

  IF v_base_fare IS NULL THEN
    RAISE EXCEPTION 'Categoria de vehiculo no valida';
  END IF;

  -- 4. Barrio/sector de ORIGEN (el mas cercano dentro de la ciudad)
  SELECT b.id, b.name
  INTO v_origin_barrio_id, v_origin_barrio_name
  FROM barrios b
  WHERE b.is_active = TRUE
    AND b.zone_id = v_zone.id
    AND b.lat IS NOT NULL
    AND b.lng IS NOT NULL
  ORDER BY ST_Distance(
    ST_SetSRID(ST_MakePoint(b.lng, b.lat), 4326)::geography,
    ST_SetSRID(ST_MakePoint(p_origin_lng, p_origin_lat), 4326)::geography
  )
  LIMIT 1;

  IF v_origin_barrio_id IS NOT NULL THEN
    SELECT v.surcharge_usd INTO v_origin_surcharge
    FROM public.v_barrio_surcharges v
    WHERE v.barrio_id = v_origin_barrio_id
      AND v.category = p_category;
    v_origin_surcharge := COALESCE(v_origin_surcharge, 0.00);
  ELSE
    v_origin_surcharge := 0.00;
    v_origin_barrio_name := 'No especificado';
  END IF;

  -- 5. Barrio/sector de DESTINO (el mas cercano dentro de la ciudad)
  SELECT b.id, b.name
  INTO v_dest_barrio_id, v_dest_barrio_name
  FROM barrios b
  WHERE b.is_active = TRUE
    AND b.zone_id = v_zone.id
    AND b.lat IS NOT NULL
    AND b.lng IS NOT NULL
  ORDER BY ST_Distance(
    ST_SetSRID(ST_MakePoint(b.lng, b.lat), 4326)::geography,
    ST_SetSRID(ST_MakePoint(p_dest_lng, p_dest_lat), 4326)::geography
  )
  LIMIT 1;

  IF v_dest_barrio_id IS NOT NULL THEN
    SELECT v.surcharge_usd INTO v_dest_surcharge
    FROM public.v_barrio_surcharges v
    WHERE v.barrio_id = v_dest_barrio_id
      AND v.category = p_category;
    v_dest_surcharge := COALESCE(v_dest_surcharge, 0.00);
  ELSE
    v_dest_surcharge := 0.00;
    v_dest_barrio_name := 'No especificado';
  END IF;

  v_total := v_base_fare + v_origin_surcharge + v_dest_surcharge;

  -- 6. Cupon: validacion completa server-side. NO consume aqui.
  IF p_coupon_code IS NOT NULL AND TRIM(p_coupon_code) <> '' THEN
    v_coupon_result := public.apply_coupon(p_coupon_code, v_total);
    v_coupon_reason := v_coupon_result->>'reason';
    v_coupon_message := v_coupon_result->>'message';
    IF COALESCE((v_coupon_result->>'valid')::boolean, FALSE) THEN
      v_discount := COALESCE((v_coupon_result->>'discount')::NUMERIC, 0.00);
      v_coupon_id := (v_coupon_result->>'coupon_id')::UUID;
    END IF;
  END IF;

  v_final := GREATEST(v_total - v_discount, 0.00);

  RETURN jsonb_build_object(
    'base_fare', v_base_fare,
    'origin_surcharge', v_origin_surcharge,
    'origin_barrio_id', v_origin_barrio_id,
    'origin_barrio_name', v_origin_barrio_name,
    'destination_surcharge', v_dest_surcharge,
    'destination_barrio_id', v_dest_barrio_id,
    'destination_barrio_name', v_dest_barrio_name,
    'total_fare', v_total,
    'discount', v_discount,
    'final_fare', v_final,
    'in_coverage', TRUE,
    'origin_zone_id', v_zone.id,
    'origin_zone_name', v_zone.name,
    'destination_zone_id', v_zone.id,
    'destination_zone_name', v_zone.name,
    'coupon_id', v_coupon_id,
    'coupon_code', CASE WHEN v_coupon_id IS NOT NULL THEN UPPER(BTRIM(p_coupon_code)) ELSE NULL END,
    'coupon_reason', v_coupon_reason,
    'coupon_message', v_coupon_message
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.calculate_fare(NUMERIC, NUMERIC, NUMERIC, NUMERIC, public.vehicle_category, TEXT) TO anon, authenticated, service_role;