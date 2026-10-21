-- ============================================================
-- 104 - COBERTURA DEL DESTINO
-- - get_active_cities devuelve el polígono (GeoJSON) para validar
--   localmente sin llamadas extra.
-- - calculate_fare exige que el DESTINO también esté dentro
--   del polígono de cobertura (además del origen).
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_active_cities()
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', z.id,
      'name', z.name,
      'center_lat', COALESCE(z.center_lat, ST_Y(ST_Centroid(z.polygon))),
      'center_lng', COALESCE(z.center_lng, ST_X(ST_Centroid(z.polygon))),
      'polygon', ST_AsGeoJSON(z.polygon)::jsonb
    )
    ORDER BY z.name
  ), '[]'::jsonb)
  FROM public.zones z
  WHERE z.zone_type = 'cobertura_general' AND z.is_active = TRUE;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_cities() TO anon, authenticated, service_role;

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
  v_coupon_result JSONB;
  v_coupon_id UUID;
  v_coupon_reason TEXT;
  v_coupon_message TEXT;
  v_zone RECORD;
BEGIN
  SELECT base_fare_usd INTO v_base_fare
  FROM vehicle_categories WHERE name = p_category;

  IF v_base_fare IS NULL THEN
    RAISE EXCEPTION 'Categoría de vehículo no válida';
  END IF;

  -- Detectar la ciudad (zona cobertura_general) que contiene el origen
  SELECT z.id, z.name, z.polygon INTO v_zone
  FROM zones z
  WHERE z.zone_type = 'cobertura_general'
    AND z.is_active = TRUE
    AND ST_Covers(z.polygon, ST_SetSRID(ST_MakePoint(p_origin_lng, p_origin_lat), 4326))
  LIMIT 1;

  IF v_zone.id IS NULL THEN
    RAISE EXCEPTION 'Tu ubicación está fuera del área de cobertura de la app';
  END IF;

  -- El DESTINO también debe estar dentro del área de cobertura
  IF NOT ST_Covers(v_zone.polygon, ST_SetSRID(ST_MakePoint(p_dest_lng, p_dest_lat), 4326)) THEN
    RAISE EXCEPTION 'El destino está fuera del área de cobertura de la app';
  END IF;

  -- Barrio de destino por cercanía DENTRO de la misma ciudad
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

  -- Recargo efectivo del barrio para ESTA categoría (vista única).
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

  v_total := v_base_fare + v_dest_surcharge;

  -- Cupón: validación completa server-side (activo, fechas, usos, límite
  -- por usuario, primer viaje, monto mínimo). NO consume aquí.
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
    'origin_surcharge', 0.00,
    'destination_surcharge', v_dest_surcharge,
    'total_fare', v_total,
    'discount', v_discount,
    'final_fare', v_final,
    'destination_barrio_id', v_dest_barrio_id,
    'destination_barrio_name', v_dest_barrio_name,
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

GRANT EXECUTE ON FUNCTION public.calculate_fare(numeric, numeric, numeric, numeric, vehicle_category, text) TO anon, authenticated, service_role;
