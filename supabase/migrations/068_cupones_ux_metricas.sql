-- ============================================================
-- BUNRIDER - Migración 068: UX DE CUPONES + MÉTRICAS
-- ------------------------------------------------------------
-- 1. apply_coupon ahora devuelve reason/message (en español)
--    para que el cliente sepa POR QUÉ no aplica un cupón.
-- 2. calculate_fare propaga coupon_reason/coupon_message
--    (mantiene firma y claves previas).
-- 3. validate_coupon: validación en vivo desde la app.
-- 4. get_coupon_stats_detailed: métricas para admin (global) y
--    encargado (solo su ciudad).
-- 5. get_my_ride_coupon: el cliente ve el código usado en su viaje.
-- Compatibilidad: apply_coupon/calculate_fare conservan sus claves
-- anteriores y get_coupon_stats queda intacta.
-- ============================================================

-- ============================================================
-- 1. APPLY_COUPON: valida y explica (NO consume)
-- ============================================================
CREATE OR REPLACE FUNCTION public.apply_coupon(
  p_code TEXT,
  p_total NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_code TEXT;
  v_coupon RECORD;
  v_used INTEGER := 0;
  v_prior INTEGER := 0;
  v_discount NUMERIC := 0.00;
  v_min NUMERIC;
BEGIN
  IF p_code IS NULL OR TRIM(p_code) = '' THEN
    RETURN jsonb_build_object('valid', FALSE, 'discount', 0,
      'reason', 'empty', 'message', 'Ingresa un código de cupón');
  END IF;

  IF p_total IS NULL OR p_total <= 0 THEN
    RETURN jsonb_build_object('valid', FALSE, 'discount', 0,
      'reason', 'no_total', 'message', 'No se pudo calcular el monto del viaje');
  END IF;

  -- Requiere usuario autenticado (para límites por usuario)
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('valid', FALSE, 'discount', 0,
      'reason', 'no_auth', 'message', 'Inicia sesión para usar cupones');
  END IF;

  v_code := UPPER(BTRIM(p_code));

  SELECT * INTO v_coupon FROM coupons WHERE code = v_code;

  IF v_coupon.id IS NULL THEN
    RETURN jsonb_build_object('valid', FALSE, 'discount', 0, 'code', v_code,
      'reason', 'not_found', 'message', 'El cupón no existe');
  END IF;

  IF v_coupon.is_active IS DISTINCT FROM TRUE THEN
    RETURN jsonb_build_object('valid', FALSE, 'discount', 0, 'code', v_code,
      'reason', 'inactive', 'message', 'El cupón ya no está disponible');
  END IF;

  IF v_coupon.valid_from IS NOT NULL AND v_coupon.valid_from > NOW() THEN
    RETURN jsonb_build_object('valid', FALSE, 'discount', 0, 'code', v_code,
      'reason', 'not_started', 'message', 'Este cupón aún no está vigente');
  END IF;

  IF v_coupon.valid_until IS NOT NULL AND v_coupon.valid_until < NOW() THEN
    RETURN jsonb_build_object('valid', FALSE, 'discount', 0, 'code', v_code,
      'reason', 'expired', 'message', 'El cupón ya expiró');
  END IF;

  IF v_coupon.max_uses IS NOT NULL AND v_coupon.used_count >= v_coupon.max_uses THEN
    RETURN jsonb_build_object('valid', FALSE, 'discount', 0, 'code', v_code,
      'reason', 'max_uses', 'message', 'El cupón alcanzó su límite de usos');
  END IF;

  v_min := COALESCE(v_coupon.min_fare_usd, 0);
  IF p_total < v_min THEN
    RETURN jsonb_build_object('valid', FALSE, 'discount', 0, 'code', v_code,
      'reason', 'min_fare',
      'message', 'Tu viaje no alcanza el mínimo para este cupón (mín. $' || to_char(v_min, 'FM9999990.00') || ')');
  END IF;

  -- Límite por usuario
  SELECT COUNT(*) INTO v_used FROM coupon_redemptions
  WHERE coupon_id = v_coupon.id AND user_id = v_user_id;
  IF v_used >= COALESCE(v_coupon.per_user_limit, 1) THEN
    RETURN jsonb_build_object('valid', FALSE, 'discount', 0, 'code', v_code,
      'reason', 'per_user_limit', 'message', 'Ya usaste este cupón');
  END IF;

  -- Solo primer viaje: sin viajes previos no cancelados
  IF v_coupon.first_ride_only THEN
    SELECT COUNT(*) INTO v_prior FROM rides
    WHERE client_id = v_user_id AND status <> 'cancelada';
    IF v_prior > 0 THEN
      RETURN jsonb_build_object('valid', FALSE, 'discount', 0, 'code', v_code,
        'reason', 'first_ride_only', 'message', 'Este cupón solo aplica en tu primer viaje');
    END IF;
  END IF;

  -- Calcular descuento (nunca más que el total)
  IF v_coupon.discount_type = 'percentage' THEN
    v_discount := ROUND((p_total * v_coupon.discount_value / 100), 2);
  ELSE
    v_discount := LEAST(v_coupon.discount_value, p_total);
  END IF;
  v_discount := LEAST(v_discount, p_total);

  IF v_discount <= 0 THEN
    RETURN jsonb_build_object('valid', FALSE, 'discount', 0, 'code', v_code,
      'reason', 'zero_discount', 'message', 'El cupón no genera descuento para este monto');
  END IF;

  RETURN jsonb_build_object(
    'valid', TRUE,
    'coupon_id', v_coupon.id,
    'code', v_code,
    'discount', v_discount,
    'reason', 'ok',
    'message', 'Cupón aplicado: ahorras $' || to_char(v_discount, 'FM9999990.00')
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.apply_coupon(text, numeric) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.apply_coupon FROM anon;

-- ============================================================
-- 2. CALCULATE_FARE: propaga el motivo del cupón
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
  SELECT z.id, z.name INTO v_zone
  FROM zones z
  WHERE z.zone_type = 'cobertura_general'
    AND z.is_active = TRUE
    AND ST_Contains(z.polygon, ST_SetSRID(ST_MakePoint(p_origin_lng, p_origin_lat), 4326))
  LIMIT 1;

  IF v_zone.id IS NULL THEN
    RAISE EXCEPTION 'Tu ubicación está fuera del área de cobertura de la app';
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
  -- Fila explícita -> columna histórica -> recargo general del barrio.
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

GRANT EXECUTE ON FUNCTION public.calculate_fare TO anon, authenticated, service_role;

-- ============================================================
-- 3. VALIDATE_COUPON: feedback en vivo para el cliente
-- ============================================================
CREATE OR REPLACE FUNCTION public.validate_coupon(
  p_code TEXT,
  p_total NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  RETURN public.apply_coupon(p_code, p_total);
END;
$$;

GRANT EXECUTE ON FUNCTION public.validate_coupon(text, numeric) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.validate_coupon FROM anon;

-- ============================================================
-- 4. GET_COUPON_STATS_DETAILED: admin (global) y encargado (su ciudad)
--    p_zone_id = NULL -> global (admin). Encargado: se fuerza su zona.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_coupon_stats_detailed(
  p_fecha_inicio TIMESTAMPTZ,
  p_fecha_fin TIMESTAMPTZ,
  p_zone_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_role TEXT;
  v_zone UUID := p_zone_id;
  v_total_discount NUMERIC := 0;
  v_viajes INTEGER := 0;
  v_redemptions INTEGER := 0;
  v_usuarios INTEGER := 0;
  v_promedio NUMERIC := 0;
  v_activos INTEGER := 0;
  v_top JSONB := '[]'::jsonb;
BEGIN
  v_role := public.get_user_role(v_uid);
  IF v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- El encargado solo ve su ciudad, sin importar lo que envíe
  IF v_role = 'encargado' THEN
    v_zone := public.caller_zone_id();
  END IF;

  SELECT COALESCE(SUM(discount_usd), 0),
         COUNT(*) FILTER (WHERE coupon_id IS NOT NULL)
  INTO v_total_discount, v_viajes
  FROM rides
  WHERE created_at >= p_fecha_inicio AND created_at <= p_fecha_fin
    AND (v_zone IS NULL OR origin_zone_id = v_zone);

  SELECT COUNT(*), COUNT(DISTINCT cr.user_id), COALESCE(AVG(cr.amount_usd), 0)
  INTO v_redemptions, v_usuarios, v_promedio
  FROM coupon_redemptions cr
  JOIN rides r ON r.id = cr.ride_id
  WHERE cr.created_at >= p_fecha_inicio AND cr.created_at <= p_fecha_fin
    AND (v_zone IS NULL OR r.origin_zone_id = v_zone);

  SELECT COALESCE(jsonb_agg(t), '[]'::jsonb) INTO v_top
  FROM (
    SELECT c.code AS code,
           COUNT(*) AS redemptions,
           COALESCE(SUM(cr.amount_usd), 0) AS discount
    FROM coupon_redemptions cr
    JOIN coupons c ON c.id = cr.coupon_id
    JOIN rides r ON r.id = cr.ride_id
    WHERE cr.created_at >= p_fecha_inicio AND cr.created_at <= p_fecha_fin
      AND (v_zone IS NULL OR r.origin_zone_id = v_zone)
    GROUP BY c.code
    ORDER BY COUNT(*) DESC, COALESCE(SUM(cr.amount_usd), 0) DESC
    LIMIT 5
  ) t;

  SELECT COUNT(*) INTO v_activos
  FROM coupons
  WHERE is_active = TRUE
    AND (valid_until IS NULL OR valid_until >= NOW())
    AND (max_uses IS NULL OR used_count < max_uses);

  RETURN jsonb_build_object(
    'total_discount_usd', COALESCE(v_total_discount, 0),
    'redemptions', COALESCE(v_redemptions, 0),
    'viajes_con_cupon', COALESCE(v_viajes, 0),
    'usuarios_unicos', COALESCE(v_usuarios, 0),
    'descuento_promedio', ROUND(COALESCE(v_promedio, 0), 2),
    'cupones_activos', COALESCE(v_activos, 0),
    'top_cupones', v_top
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_coupon_stats_detailed(timestamptz, timestamptz, uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_coupon_stats_detailed FROM anon;

-- ============================================================
-- 5. GET_MY_RIDE_COUPON: el código del cupón usado en un viaje
--    (cliente/conductor del viaje y staff de la zona)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_my_ride_coupon(p_ride_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_role TEXT;
  v_ride RECORD;
  v_code TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT id, client_id, driver_id, coupon_id, discount_usd, origin_zone_id
  INTO v_ride
  FROM rides WHERE id = p_ride_id;

  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  v_role := public.get_user_role(v_uid);

  IF NOT (
    v_uid = v_ride.client_id
    OR v_uid = v_ride.driver_id
    OR v_role = 'super_admin'
    OR (v_role = 'encargado' AND v_ride.origin_zone_id = public.caller_zone_id())
  ) THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF v_ride.coupon_id IS NULL OR COALESCE(v_ride.discount_usd, 0) <= 0 THEN
    RETURN jsonb_build_object('found', FALSE);
  END IF;

  SELECT code INTO v_code FROM coupons WHERE id = v_ride.coupon_id;

  RETURN jsonb_build_object(
    'found', TRUE,
    'code', v_code,
    'discount_usd', COALESCE(v_ride.discount_usd, 0)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_ride_coupon(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_my_ride_coupon FROM anon;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 068: UX de cupones + métricas detalladas lista' AS estado;
