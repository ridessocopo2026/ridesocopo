-- ============================================================
-- RIDERFLASSHI - Migración 047: CUPONES Y PROMOCIONES SEGURAS
-- ------------------------------------------------------------
-- 1. coupons: límite por usuario, solo primer viaje, monto mínimo.
-- 2. coupon_redemptions: uso por usuario (solo RPCs SECURITY DEFINER).
-- 3. La app cubre el descuento: comisión y liquidación del conductor
--    se calculan sobre total_fare_usd (NUNCA sobre final_fare_usd).
-- ============================================================

-- ============================================================
-- 1. ESQUEMA
-- ============================================================

ALTER TABLE public.coupons
  ADD COLUMN IF NOT EXISTS per_user_limit INTEGER DEFAULT 1,
  ADD COLUMN IF NOT EXISTS first_ride_only BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS min_fare_usd NUMERIC(10,2) DEFAULT 0.00;

-- Redenciones por usuario
CREATE TABLE IF NOT EXISTS public.coupon_redemptions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  coupon_id UUID NOT NULL REFERENCES public.coupons(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  ride_id UUID NOT NULL REFERENCES public.rides(id) ON DELETE CASCADE,
  amount_usd NUMERIC(10,2) NOT NULL DEFAULT 0.00,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_coupon_redemptions_coupon_user ON public.coupon_redemptions(coupon_id, user_id);
CREATE INDEX IF NOT EXISTS idx_coupon_redemptions_user ON public.coupon_redemptions(user_id);
CREATE INDEX IF NOT EXISTS idx_rides_coupon ON public.rides(coupon_id);

-- RLS: nadie inserta/edita directo; solo super_admin/encargado leen
ALTER TABLE public.coupon_redemptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "super_admin_view_redemptions" ON public.coupon_redemptions;
CREATE POLICY "super_admin_view_redemptions" ON public.coupon_redemptions
  FOR SELECT USING (public.get_user_role(auth.uid()) IN ('super_admin', 'encargado'));

-- ============================================================
-- 2. APPLY_COUPON: valida y calcula el descuento (NO consume)
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
  v_coupon RECORD;
  v_used INTEGER := 0;
  v_prior INTEGER := 0;
  v_discount NUMERIC := 0.00;
BEGIN
  IF p_code IS NULL OR TRIM(p_code) = '' OR p_total IS NULL OR p_total <= 0 THEN
    RETURN jsonb_build_object('valid', FALSE, 'discount', 0);
  END IF;

  -- Requiere usuario autenticado (para límites por usuario)
  IF v_user_id IS NULL THEN
    RETURN jsonb_build_object('valid', FALSE, 'discount', 0);
  END IF;

  SELECT * INTO v_coupon FROM coupons
  WHERE code = UPPER(p_code)
    AND is_active = TRUE
    AND (valid_from IS NULL OR valid_from <= NOW())
    AND (valid_until IS NULL OR valid_until >= NOW())
    AND (max_uses IS NULL OR used_count < max_uses)
    AND p_total >= COALESCE(min_fare_usd, 0);

  IF v_coupon.id IS NULL THEN
    RETURN jsonb_build_object('valid', FALSE, 'discount', 0);
  END IF;

  -- Límite por usuario
  SELECT COUNT(*) INTO v_used FROM coupon_redemptions
  WHERE coupon_id = v_coupon.id AND user_id = v_user_id;
  IF v_used >= COALESCE(v_coupon.per_user_limit, 1) THEN
    RETURN jsonb_build_object('valid', FALSE, 'discount', 0);
  END IF;

  -- Solo primer viaje: sin viajes previos no cancelados
  IF v_coupon.first_ride_only THEN
    SELECT COUNT(*) INTO v_prior FROM rides
    WHERE client_id = v_user_id AND status <> 'cancelada';
    IF v_prior > 0 THEN
      RETURN jsonb_build_object('valid', FALSE, 'discount', 0);
    END IF;
  END IF;

  -- Calcular descuento (nunca más que el total)
  IF v_coupon.discount_type = 'percentage' THEN
    v_discount := ROUND((p_total * v_coupon.discount_value / 100), 2);
  ELSE
    v_discount := LEAST(v_coupon.discount_value, p_total);
  END IF;
  v_discount := LEAST(v_discount, p_total);

  RETURN jsonb_build_object(
    'valid', v_discount > 0,
    'coupon_id', v_coupon.id,
    'code', v_coupon.code,
    'discount', v_discount
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.apply_coupon(text, numeric) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.apply_coupon FROM anon;

-- ============================================================
-- 3. REDEEM_COUPON: canjea atómicamente (FOR UPDATE) al crear el viaje
-- ============================================================
CREATE OR REPLACE FUNCTION public.redeem_coupon(
  p_coupon_id UUID,
  p_user_id UUID,
  p_ride_id UUID,
  p_amount NUMERIC
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_coupon RECORD;
  v_used INTEGER := 0;
  v_prior INTEGER := 0;
BEGIN
  IF p_coupon_id IS NULL THEN
    RETURN;
  END IF;

  -- Bloquear la fila del cupón: serializa canjes concurrentes
  SELECT * INTO v_coupon FROM coupons WHERE id = p_coupon_id FOR UPDATE;
  IF v_coupon.id IS NULL THEN
    RAISE EXCEPTION 'Cupón no encontrado';
  END IF;

  IF v_coupon.is_active IS DISTINCT FROM TRUE THEN
    RAISE EXCEPTION 'El cupón ya no está activo';
  END IF;
  IF v_coupon.max_uses IS NOT NULL AND v_coupon.used_count >= v_coupon.max_uses THEN
    RAISE EXCEPTION 'El cupón alcanzó su límite de usos';
  END IF;

  SELECT COUNT(*) INTO v_used FROM coupon_redemptions
  WHERE coupon_id = p_coupon_id AND user_id = p_user_id;
  IF v_used >= COALESCE(v_coupon.per_user_limit, 1) THEN
    RAISE EXCEPTION 'Ya usaste este cupón';
  END IF;

  IF v_coupon.first_ride_only THEN
    SELECT COUNT(*) INTO v_prior FROM rides
    WHERE client_id = p_user_id AND status <> 'cancelada';
    IF v_prior > 0 THEN
      RAISE EXCEPTION 'Este cupón solo aplica en tu primer viaje';
    END IF;
  END IF;

  INSERT INTO coupon_redemptions (coupon_id, user_id, ride_id, amount_usd)
  VALUES (p_coupon_id, p_user_id, p_ride_id, COALESCE(p_amount, 0));

  UPDATE coupons SET used_count = used_count + 1, updated_at = NOW()
  WHERE id = p_coupon_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.redeem_coupon(uuid, uuid, uuid, numeric) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.redeem_coupon FROM anon;

-- ============================================================
-- 4. CALCULATE_FARE: descuento vía apply_coupon + coupon_id
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
    AND b.zone_id = v_zone.id
    AND b.lat IS NOT NULL
    AND b.lng IS NOT NULL
  ORDER BY ST_Distance(
    ST_SetSRID(ST_MakePoint(b.lng, b.lat), 4326)::geography,
    ST_SetSRID(ST_MakePoint(p_dest_lng, p_dest_lat), 4326)::geography
  )
  LIMIT 1;

  IF v_dest_barrio_id IS NULL THEN
    v_dest_surcharge := 0.00;
    v_dest_barrio_name := 'No especificado';
  END IF;

  v_total := v_base_fare + v_dest_surcharge;

  -- Cupón: validación completa server-side (activo, fechas, usos, límite
  -- por usuario, primer viaje, monto mínimo). NO consume aquí.
  IF p_coupon_code IS NOT NULL THEN
    v_coupon_result := public.apply_coupon(p_coupon_code, v_total);
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
    'coupon_code', CASE WHEN v_coupon_id IS NOT NULL THEN UPPER(p_coupon_code) ELSE NULL END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.calculate_fare TO anon, authenticated, service_role;

-- ============================================================
-- 5. CREATE_COUPON: solo super_admin, con nuevas opciones
-- ============================================================
DROP FUNCTION IF EXISTS public.create_coupon(text, text, text, numeric, integer, timestamptz, timestamptz);

CREATE OR REPLACE FUNCTION public.create_coupon(
  p_code TEXT,
  p_description TEXT,
  p_discount_type TEXT,
  p_discount_value NUMERIC,
  p_max_uses INTEGER DEFAULT NULL,
  p_valid_from TIMESTAMPTZ DEFAULT NULL,
  p_valid_until TIMESTAMPTZ DEFAULT NULL,
  p_per_user_limit INTEGER DEFAULT 1,
  p_first_ride_only BOOLEAN DEFAULT FALSE,
  p_min_fare_usd NUMERIC DEFAULT 0
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_coupon_id UUID;
BEGIN
  IF public.get_user_role(v_admin_id) != 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF p_code IS NULL OR TRIM(p_code) = '' THEN
    RAISE EXCEPTION 'El código es obligatorio';
  END IF;
  IF p_discount_type NOT IN ('percentage', 'fixed') THEN
    RAISE EXCEPTION 'Tipo de descuento no válido';
  END IF;
  IF p_discount_value IS NULL OR p_discount_value <= 0 THEN
    RAISE EXCEPTION 'El valor del descuento debe ser mayor a 0';
  END IF;
  IF p_discount_type = 'percentage' AND p_discount_value > 100 THEN
    RAISE EXCEPTION 'El porcentaje no puede superar 100';
  END IF;
  IF p_per_user_limit IS NOT NULL AND p_per_user_limit < 1 THEN
    RAISE EXCEPTION 'El límite por usuario debe ser al menos 1';
  END IF;
  IF p_max_uses IS NOT NULL AND p_max_uses < 1 THEN
    RAISE EXCEPTION 'Los usos máximos deben ser al menos 1';
  END IF;

  INSERT INTO coupons (code, description, discount_type, discount_value, max_uses,
                       valid_from, valid_until, per_user_limit, first_ride_only, min_fare_usd, created_by)
  VALUES (UPPER(p_code), p_description, p_discount_type, p_discount_value, p_max_uses,
          p_valid_from, p_valid_until, COALESCE(p_per_user_limit, 1),
          COALESCE(p_first_ride_only, FALSE), COALESCE(p_min_fare_usd, 0), v_admin_id)
  RETURNING id INTO v_coupon_id;

  RETURN v_coupon_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.create_coupon TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.create_coupon FROM anon;

-- ============================================================
-- 6. GET_COUPON_STATS: costo de promos para el admin
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_coupon_stats(
  p_fecha_inicio TIMESTAMPTZ DEFAULT NOW() - INTERVAL '30 days',
  p_fecha_fin TIMESTAMPTZ DEFAULT NOW()
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_total_discount NUMERIC;
  v_redemptions INTEGER;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT COALESCE(SUM(discount_usd), 0) INTO v_total_discount
  FROM rides
  WHERE created_at >= p_fecha_inicio AND created_at <= p_fecha_fin;

  SELECT COUNT(*) INTO v_redemptions
  FROM coupon_redemptions
  WHERE created_at >= p_fecha_inicio AND created_at <= p_fecha_fin;

  RETURN jsonb_build_object(
    'total_discount_usd', COALESCE(v_total_discount, 0),
    'redemptions', COALESCE(v_redemptions, 0)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_coupon_stats(timestamptz, timestamptz) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_coupon_stats FROM anon;

-- ============================================================
-- 7. REQUEST_RIDE: guarda coupon_id + canjea el cupón
-- ============================================================
CREATE OR REPLACE FUNCTION public.request_ride(
  p_origin_lat NUMERIC,
  p_origin_lng NUMERIC,
  p_origin_address TEXT,
  p_dest_lat NUMERIC,
  p_dest_lng NUMERIC,
  p_dest_address TEXT,
  p_category vehicle_category,
  p_payment_method TEXT DEFAULT 'efectivo',
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
  v_final_fare NUMERIC;
  v_wallet RECORD;
  v_is_wallet BOOLEAN;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('request_ride', 15);

  v_fare := public.calculate_fare(
    p_origin_lat, p_origin_lng,
    p_dest_lat, p_dest_lng,
    p_category, p_coupon_code
  );

  IF NOT EXISTS (SELECT 1 FROM payment_methods WHERE name = p_payment_method AND is_active = TRUE) THEN
    RAISE EXCEPTION 'Método de pago no disponible';
  END IF;

  v_final_fare := (v_fare->>'final_fare')::NUMERIC;
  v_is_wallet := (p_payment_method = 'Billetera');

  -- Billetera: validar saldo y DEBITAR (FOR UPDATE anti TOCTOU)
  IF v_is_wallet THEN
    SELECT * INTO v_wallet
    FROM wallets
    WHERE user_id = v_user_id
    FOR UPDATE;

    IF v_wallet.id IS NULL THEN
      RAISE EXCEPTION 'Billetera no encontrada';
    END IF;

    IF v_wallet.balance_usd < v_final_fare THEN
      RAISE EXCEPTION USING MESSAGE = format('Saldo insuficiente en billetera. Necesitas $%s y tienes $%s', v_final_fare, v_wallet.balance_usd);
    END IF;

    UPDATE wallets
    SET balance_usd = balance_usd - v_final_fare,
        updated_at = NOW()
    WHERE user_id = v_user_id;

    INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description)
    VALUES (v_wallet.id, v_user_id, 'debito', v_final_fare, 'completado',
            'Pago de viaje con billetera');
  END IF;

  INSERT INTO rides (
    client_id, category,
    origin_lat, origin_lng, origin_address, origin_zone_id,
    destination_lat, destination_lng, destination_address, destination_zone_id,
    destination_barrio_id, destination_barrio_name,
    base_fare_usd, origin_surcharge_usd, destination_surcharge_usd,
    total_fare_usd, coupon_id, discount_usd, final_fare_usd,
    payment_method, status
  ) VALUES (
    v_user_id, p_category,
    p_origin_lat, p_origin_lng, p_origin_address, (v_fare->>'origin_zone_id')::UUID,
    p_dest_lat, p_dest_lng, p_dest_address, (v_fare->>'destination_zone_id')::UUID,
    (v_fare->>'destination_barrio_id')::UUID,
    v_fare->>'destination_barrio_name',
    (v_fare->>'base_fare')::NUMERIC,
    (v_fare->>'origin_surcharge')::NUMERIC,
    (v_fare->>'destination_surcharge')::NUMERIC,
    (v_fare->>'total_fare')::NUMERIC,
    (v_fare->>'coupon_id')::UUID,
    (v_fare->>'discount')::NUMERIC,
    v_final_fare,
    p_payment_method, 'buscando'
  ) RETURNING id INTO v_ride_id;

  -- Canjear el cupón de forma atómica (si falla, todo el viaje se revierte)
  IF (v_fare->>'coupon_id') IS NOT NULL THEN
    PERFORM public.redeem_coupon(
      (v_fare->>'coupon_id')::UUID,
      v_user_id,
      v_ride_id,
      (v_fare->>'discount')::NUMERIC
    );
  END IF;

  -- Notificar SOLO a conductores aprobados/online de la MISMA ciudad (o sin zona)
  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT p.id, 'Nuevo viaje disponible',
         CONCAT('Viaje de ', v_fare->>'final_fare', '$ en ', p_category, '. ¿Lo aceptas?'),
         'ride_available',
         jsonb_build_object('ride_id', v_ride_id, 'category', p_category,
                            'fare', (v_fare->>'final_fare')::NUMERIC,
                            'url', '/conductor')
  FROM profiles p
  WHERE p.role = 'conductor'
    AND p.driver_status = 'aprobado'
    AND p.is_online = TRUE
    AND (p.zone_id IS NULL OR p.zone_id = (v_fare->>'origin_zone_id')::uuid)
    AND p.id IN (
      SELECT v.driver_id FROM vehicles v
      WHERE v.is_active = TRUE AND v.category = p_category
    )
  ORDER BY p.updated_at DESC
  LIMIT 25;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_user_id, 'REQUEST_RIDE', 'ride', v_ride_id,
          jsonb_build_object('fare', v_fare, 'wallet_debited', v_is_wallet));

  RETURN v_ride_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_ride TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_ride TO service_role;
REVOKE ALL ON FUNCTION public.request_ride FROM anon;

-- ============================================================
-- 8. REQUEST_RIDE_WITH_PROOF: guarda coupon_id + canjea
-- ============================================================
CREATE OR REPLACE FUNCTION public.request_ride_with_proof(
  p_origin_lat NUMERIC,
  p_origin_lng NUMERIC,
  p_origin_address TEXT,
  p_dest_lat NUMERIC,
  p_dest_lng NUMERIC,
  p_dest_address TEXT,
  p_category vehicle_category,
  p_payment_method TEXT,
  p_proof_url TEXT,
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
  v_proof_required BOOLEAN;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('request_ride_with_proof', 15);

  SELECT proof_required INTO v_proof_required
  FROM payment_methods WHERE name = p_payment_method AND is_active = TRUE;

  IF v_proof_required IS NULL THEN
    RAISE EXCEPTION 'Método de pago no disponible';
  END IF;

  IF v_proof_required AND (p_proof_url IS NULL OR p_proof_url = '') THEN
    RAISE EXCEPTION 'Debes subir el comprobante del pago';
  END IF;

  v_fare := public.calculate_fare(
    p_origin_lat, p_origin_lng,
    p_dest_lat, p_dest_lng,
    p_category, p_coupon_code
  );

  INSERT INTO rides (
    client_id, category,
    origin_lat, origin_lng, origin_address, origin_zone_id,
    destination_lat, destination_lng, destination_address, destination_zone_id,
    destination_barrio_id, destination_barrio_name,
    base_fare_usd, origin_surcharge_usd, destination_surcharge_usd,
    total_fare_usd, coupon_id, discount_usd, final_fare_usd,
    payment_method, status, proof_url, proof_status
  ) VALUES (
    v_user_id, p_category,
    p_origin_lat, p_origin_lng, p_origin_address, (v_fare->>'origin_zone_id')::UUID,
    p_dest_lat, p_dest_lng, p_dest_address, (v_fare->>'destination_zone_id')::UUID,
    (v_fare->>'destination_barrio_id')::UUID,
    v_fare->>'destination_barrio_name',
    (v_fare->>'base_fare')::NUMERIC,
    (v_fare->>'origin_surcharge')::NUMERIC,
    (v_fare->>'destination_surcharge')::NUMERIC,
    (v_fare->>'total_fare')::NUMERIC,
    (v_fare->>'coupon_id')::UUID,
    (v_fare->>'discount')::NUMERIC,
    (v_fare->>'final_fare')::NUMERIC,
    p_payment_method, 'buscando',
    CASE WHEN v_proof_required THEN p_proof_url ELSE NULL END,
    CASE WHEN v_proof_required THEN 'pendiente' ELSE 'aprobado' END
  ) RETURNING id INTO v_ride_id;

  -- Canjear el cupón de forma atómica
  IF (v_fare->>'coupon_id') IS NOT NULL THEN
    PERFORM public.redeem_coupon(
      (v_fare->>'coupon_id')::UUID,
      v_user_id,
      v_ride_id,
      (v_fare->>'discount')::NUMERIC
    );
  END IF;

  IF v_proof_required THEN
    INSERT INTO notifications (user_id, title, body, type, data)
    SELECT id, 'Comprobante por aprobar',
           'Nuevo comprobante de pago pendiente de revisión para un viaje',
           'proof_pending',
           jsonb_build_object('ride_id', v_ride_id, 'url', '/admin/comprobantes')
    FROM profiles WHERE role IN ('super_admin', 'encargado');
  ELSE
    INSERT INTO notifications (user_id, title, body, type, data)
    SELECT p.id, 'Nuevo viaje disponible',
           CONCAT('Viaje de ', v_fare->>'final_fare', '$ en ', p_category, '. ¿Lo aceptas?'),
           'ride_available',
           jsonb_build_object('ride_id', v_ride_id, 'category', p_category,
                              'fare', (v_fare->>'final_fare')::NUMERIC,
                              'url', '/conductor')
    FROM profiles p
    WHERE p.role = 'conductor'
      AND p.driver_status = 'aprobado'
      AND p.is_online = TRUE
      AND (p.zone_id IS NULL OR p.zone_id = (v_fare->>'origin_zone_id')::uuid)
      AND p.id IN (
        SELECT v.driver_id FROM vehicles v
        WHERE v.is_active = TRUE AND v.category = p_category
      )
    ORDER BY p.updated_at DESC
    LIMIT 25;
  END IF;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_user_id, 'REQUEST_RIDE_WITH_PROOF', 'ride', v_ride_id,
          jsonb_build_object('fare', v_fare, 'proof_required', v_proof_required));

  RETURN v_ride_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_ride_with_proof TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_ride_with_proof TO service_role;
REVOKE ALL ON FUNCTION public.request_ride_with_proof FROM anon;

-- ============================================================
-- 9. ACCEPT_RIDE: comisión sobre el TOTAL (la app cubre el cupón)
-- ============================================================
CREATE OR REPLACE FUNCTION public.accept_ride(p_ride_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_ride RECORD;
  v_wallet RECORD;
  v_commission NUMERIC;
  v_vehicle RECORD;
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('accept_ride', 30);

  SELECT driver_status INTO v_ride FROM profiles WHERE id = v_driver_id;
  IF v_ride.driver_status != 'aprobado' THEN
    RAISE EXCEPTION 'Conductor no aprobado';
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id AND status = 'buscando';
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no disponible';
  END IF;

  IF v_ride.proof_status = 'pendiente' THEN
    RAISE EXCEPTION 'Este viaje aún no está disponible. Esperando aprobación del pago.';
  END IF;

  SELECT * INTO v_vehicle FROM vehicles
  WHERE driver_id = v_driver_id AND category = v_ride.category AND is_active = TRUE
  LIMIT 1;

  IF v_vehicle.id IS NULL THEN
    RAISE EXCEPTION 'No tiene un vehículo activo de la categoría requerida';
  END IF;

  -- Comisión sobre el TOTAL del viaje (sin descontar cupones)
  v_commission := ROUND(COALESCE(v_ride.total_fare_usd, v_ride.final_fare_usd, 0) * v_ride.commission_rate / 100, 2);

  UPDATE rides
  SET driver_id = v_driver_id,
      vehicle_id = v_vehicle.id,
      commission_usd = v_commission,
      status = 'aceptada',
      started_at = NOW()
  WHERE id = p_ride_id;

  PERFORM public.notify_user(
    v_ride.client_id,
    'Conductor asignado',
    'Un conductor ha aceptado tu viaje',
    'ride_accepted',
    jsonb_build_object('ride_id', p_ride_id, 'url', '/cliente/viaje/' || p_ride_id)
  );

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_driver_id, 'ACCEPT_RIDE', 'ride', p_ride_id,
          jsonb_build_object('commission', v_commission, 'final_fare', v_ride.final_fare_usd));

  RETURN jsonb_build_object(
    'success', TRUE,
    'ride_id', p_ride_id,
    'commission', v_commission
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.accept_ride TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.accept_ride FROM anon;

-- ============================================================
-- 10. SETTLE_RIDE_EARNINGS: la app cubre el cupón
--     - Efectivo: cobró final; la app acredita el descuento
--     - Billetera / Pago Móvil aprobado: acredita total - comisión
--     - Sin cupón: comportamiento idéntico (total = final)
-- ============================================================
CREATE OR REPLACE FUNCTION public.settle_ride_earnings(p_ride_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ride RECORD;
  v_wallet RECORD;
  v_commission NUMERIC := 0.00;
  v_cash NUMERIC := 0.00;
  v_app_credit NUMERIC := 0.00;
  v_full NUMERIC;
  v_discount NUMERIC;
  v_method TEXT;
BEGIN
  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF v_ride.status != 'completada' THEN
    RAISE EXCEPTION 'El viaje debe estar completado';
  END IF;

  IF v_ride.driver_id IS NULL THEN
    RETURN jsonb_build_object('success', TRUE, 'driver_earned', 0, 'note', 'Sin conductor asignado');
  END IF;

  -- Idempotente: si ya se liquidó, no tocar de nuevo
  IF EXISTS (SELECT 1 FROM driver_earnings WHERE ride_id = p_ride_id) THEN
    RETURN jsonb_build_object('success', TRUE, 'already_settled', TRUE);
  END IF;

  v_commission := COALESCE(v_ride.commission_usd, 0);
  v_method := LOWER(COALESCE(v_ride.payment_method, 'efectivo'));
  v_full := COALESCE(v_ride.total_fare_usd, v_ride.final_fare_usd, 0);
  v_discount := COALESCE(v_ride.discount_usd, 0);

  -- ============================================================
  -- LIQUIDACIÓN SEGÚN MÉTODO (la app cubre los cupones)
  -- ============================================================
  IF v_method = 'efectivo' THEN
    -- El conductor YA cobró final_fare al cliente.
    -- La app cubre el descuento → acredita discount a su billetera.
    -- La comisión (sobre el total) se descuenta (deuda).
    v_cash := v_ride.final_fare_usd;
    v_app_credit := GREATEST(v_discount, 0);

    SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.driver_id;
    IF v_wallet.id IS NOT NULL AND v_commission > 0 THEN
      UPDATE wallets
      SET balance_usd = balance_usd - v_commission,
          updated_at = NOW()
      WHERE user_id = v_ride.driver_id;

      INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
      VALUES (v_wallet.id, v_ride.driver_id, 'comision', v_commission, 'completado',
              'Comisión del viaje en efectivo (adeudada a la plataforma)', p_ride_id);
    END IF;
  ELSIF v_method = 'billetera' THEN
    -- Cliente pagó final a la app. La app le debe total - comisión.
    v_cash := 0.00;
    v_app_credit := GREATEST(v_full - v_commission, 0);
  ELSE
    -- Pago Móvil: solo acreditar si comprobante aprobado
    IF v_ride.proof_status = 'aprobado' THEN
      v_cash := 0.00;
      v_app_credit := GREATEST(v_full - v_commission, 0);
    ELSE
      v_cash := 0.00;
      v_app_credit := 0.00;
    END IF;
  END IF;

  -- Insertar historial exacto
  INSERT INTO driver_earnings (
    ride_id, driver_id, fare_usd, commission_usd,
    cash_received_usd, app_credit_usd, payment_method, status
  ) VALUES (
    p_ride_id, v_ride.driver_id, v_full, v_commission,
    v_cash, v_app_credit, v_method, 'completado'
  )
  ON CONFLICT (ride_id) DO UPDATE
  SET cash_received_usd = EXCLUDED.cash_received_usd,
      app_credit_usd = EXCLUDED.app_credit_usd,
      commission_usd = EXCLUDED.commission_usd,
      payment_method = EXCLUDED.payment_method;

  -- Acreditar en wallet SOLO lo que la app realmente le debe
  IF v_app_credit > 0 THEN
    SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.driver_id;
    IF v_wallet.id IS NOT NULL THEN
      UPDATE wallets
      SET balance_usd = balance_usd + v_app_credit,
          updated_at = NOW()
      WHERE user_id = v_ride.driver_id;

      INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
      VALUES (v_wallet.id, v_ride.driver_id, 'credito', v_app_credit, 'completado',
              CONCAT('Ganancia del viaje por ', v_method), p_ride_id);
    END IF;
  END IF;

  -- Auditoría
  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (
    COALESCE(v_ride.driver_id, auth.uid()),
    'SETTLE_RIDE_EARNINGS', 'ride', p_ride_id,
    jsonb_build_object(
      'total_fare', v_full,
      'discount', v_discount,
      'commission', v_commission,
      'cash_received', v_cash,
      'app_credit', v_app_credit,
      'payment_method', v_method
    )
  );

  RETURN jsonb_build_object(
    'success', TRUE, 'ride_id', p_ride_id,
    'cash_received_usd', v_cash, 'app_credit_usd', v_app_credit,
    'commission_usd', v_commission, 'payment_method', v_method
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.settle_ride_earnings TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.settle_ride_earnings FROM anon;

-- ============================================================
-- 11. APPROVE_RIDE_PROOF: acredita total - comisión + libera cupón
-- ============================================================
CREATE OR REPLACE FUNCTION public.approve_ride_proof(
  p_ride_id UUID,
  p_approve BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_ride RECORD;
  v_status TEXT;
  v_wallet RECORD;
  v_app_credit NUMERIC := 0.00;
  v_commission NUMERIC := 0.00;
  v_earning RECORD;
  v_fare NUMERIC;
  v_category vehicle_category;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id FOR UPDATE;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF v_ride.proof_status != 'pendiente' THEN
    RAISE EXCEPTION 'El comprobante ya fue procesado';
  END IF;

  v_status := CASE WHEN p_approve THEN 'aprobado' ELSE 'rechazado' END;
  v_fare := v_ride.final_fare_usd;
  v_category := v_ride.category;

  UPDATE rides SET proof_status = v_status WHERE id = p_ride_id;

  IF p_approve THEN
    -- Si el viaje está 'buscando' (aún sin conductor) → notificar conductores AHORA
    IF v_ride.status = 'buscando' THEN
      INSERT INTO notifications (user_id, title, body, type, data)
      SELECT p.id, 'Nuevo viaje disponible',
             CONCAT('Viaje de ', v_fare, '$ en ', v_category, '. ¿Lo aceptas?'),
             'ride_available',
             jsonb_build_object('ride_id', p_ride_id, 'category', v_category,
                                'fare', v_fare, 'url', '/conductor')
      FROM profiles p
      WHERE p.role = 'conductor'
        AND p.driver_status = 'aprobado'
        AND public.driver_has_vehicle_for_category(v_category) = TRUE;
    END IF;

    -- Si el viaje YA se completó → acreditar ganancia al conductor
    IF v_ride.status = 'completada' AND v_ride.driver_id IS NOT NULL THEN
      v_commission := COALESCE(v_ride.commission_usd, 0);
      v_app_credit := GREATEST(COALESCE(v_ride.total_fare_usd, v_ride.final_fare_usd, 0) - v_commission, 0);

      SELECT * INTO v_earning FROM driver_earnings WHERE ride_id = p_ride_id;

      IF v_earning.id IS NOT NULL THEN
        UPDATE driver_earnings
        SET cash_received_usd = 0,
            app_credit_usd = v_app_credit,
            status = 'completado'
        WHERE ride_id = p_ride_id;
      ELSE
        INSERT INTO driver_earnings (
          ride_id, driver_id, fare_usd, commission_usd,
          cash_received_usd, app_credit_usd, payment_method, status
        ) VALUES (
          p_ride_id, v_ride.driver_id, COALESCE(v_ride.total_fare_usd, v_ride.final_fare_usd, 0), v_commission,
          0, v_app_credit, v_ride.payment_method, 'completado'
        );
      END IF;

      IF v_app_credit > 0 AND NOT EXISTS (
        SELECT 1 FROM transactions t
        WHERE t.ride_id = p_ride_id AND t.type = 'credito' AND t.user_id = v_ride.driver_id
      ) THEN
        SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.driver_id;
        IF v_wallet.id IS NOT NULL THEN
          UPDATE wallets
          SET balance_usd = balance_usd + v_app_credit,
              updated_at = NOW()
          WHERE user_id = v_ride.driver_id;

          INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
          VALUES (v_wallet.id, v_ride.driver_id, 'credito', v_app_credit, 'completado',
                  'Ganancia del viaje por Pago Móvil (comprobante aprobado)', p_ride_id);
        END IF;
      END IF;
    END IF;
  END IF;

  -- Notificar cliente
  INSERT INTO notifications (user_id, title, body, type, data)
  VALUES (
    v_ride.client_id,
    CASE WHEN p_approve THEN 'Comprobante aprobado' ELSE 'Comprobante rechazado' END,
    CASE WHEN p_approve THEN 'Tu pago fue aprobado. El viaje ya está disponible para conductores.'
         ELSE 'Tu comprobante fue rechazado. Sube uno válido.' END,
    'proof_reviewed',
    jsonb_build_object('ride_id', p_ride_id, 'approved', p_approve)
  );

  -- Si el comprobante es rechazado y el viaje aún no tiene conductor → cancelar viaje
  IF NOT p_approve AND v_ride.status = 'buscando' THEN
    UPDATE rides SET status = 'cancelada',
                     cancelled_by = v_admin_id,
                     cancel_reason = 'Comprobante rechazado',
                     updated_at = NOW()
    WHERE id = p_ride_id;

    -- Liberar el cupón: la promo no se consume en un viaje que no ocurrió
    IF v_ride.coupon_id IS NOT NULL THEN
      DELETE FROM coupon_redemptions WHERE ride_id = p_ride_id;
      UPDATE coupons SET used_count = GREATEST(used_count - 1, 0), updated_at = NOW()
      WHERE id = v_ride.coupon_id;
    END IF;

    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (v_ride.client_id, 'Viaje cancelado',
            'Tu viaje fue cancelado porque el comprobante fue rechazado. Solicita de nuevo con un pago válido.',
            'ride_cancelled', jsonb_build_object('ride_id', p_ride_id));
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'proof_status', v_status);
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_ride_proof TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.approve_ride_proof FROM anon;

-- ============================================================
-- 12. CANCEL_RIDE: libera el cupón si el viaje se cancela
-- ============================================================
CREATE OR REPLACE FUNCTION public.cancel_ride(
  p_ride_id UUID,
  p_reason TEXT DEFAULT NULL,
  p_at_fault TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_ride RECORD;
  v_policy RECORD;
  v_wallet RECORD;
  v_other_user UUID;
  v_fee NUMERIC := 0.00;
  v_compensation NUMERIC := 0.00;
  v_refund NUMERIC := 0.00;
  v_refund_commission BOOLEAN := FALSE;
  v_effective_fault TEXT;
  v_is_driver BOOLEAN;
  v_method TEXT;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('cancel_ride', 20);

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id FOR UPDATE;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF v_ride.client_id != v_user_id AND v_ride.driver_id != v_user_id THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- IDEMPOTENTE
  IF v_ride.status IN ('cancelada', 'incidente') THEN
    RETURN jsonb_build_object(
      'success', TRUE, 'ride_id', p_ride_id, 'status', v_ride.status,
      'already_processed', TRUE, 'note', 'El viaje ya fue procesado. No se reembolsó de nuevo.'
    );
  END IF;

  IF v_ride.status NOT IN ('buscando', 'aceptada', 'en_ruta') THEN
    RAISE EXCEPTION 'Estado del viaje no permite cancelación';
  END IF;

  v_is_driver := (v_ride.driver_id = v_user_id);
  v_effective_fault := p_at_fault;
  IF v_effective_fault IS NULL THEN
    v_effective_fault := CASE WHEN v_is_driver THEN 'conductor' ELSE 'cliente' END;
  END IF;

  IF v_effective_fault NOT IN ('cliente', 'conductor', 'accidente') THEN
    RAISE EXCEPTION 'Culpable no válido';
  END IF;

  IF v_effective_fault = 'accidente' AND v_ride.incident_id IS NULL THEN
    RAISE EXCEPTION 'Debe reportar un incidente antes de cancelar por accidente';
  END IF;

  SELECT * INTO v_policy FROM cancellation_policies
  WHERE ride_status = v_ride.status::text AND at_fault = v_effective_fault AND is_active = TRUE;

  IF v_policy.id IS NULL THEN
    v_fee := 0.00; v_compensation := 0.00; v_refund_commission := TRUE;
  ELSE
    v_fee := ROUND((v_ride.final_fare_usd * v_policy.fee_rate / 100), 2);
    IF v_fee < v_policy.min_fee THEN v_fee := v_policy.min_fee; END IF;
    IF v_policy.max_fee IS NOT NULL AND v_fee > v_policy.max_fee THEN v_fee := v_policy.max_fee; END IF;
    v_compensation := ROUND((v_fee * v_policy.driver_compensation_rate / 100), 2);
    v_refund_commission := v_policy.refunds_commission;
  END IF;

  v_method := LOWER(COALESCE(v_ride.payment_method, 'efectivo'));

  -- Compensación al conductor
  IF v_compensation > 0 AND v_ride.driver_id IS NOT NULL THEN
    SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.driver_id;
    IF v_wallet.id IS NOT NULL THEN
      UPDATE wallets SET balance_usd = balance_usd + v_compensation, updated_at = NOW()
      WHERE user_id = v_ride.driver_id;
      INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
      VALUES (v_wallet.id, v_ride.driver_id, 'credito', v_compensation, 'completado',
              'Compensación por cancelación', p_ride_id);
    END IF;
  END IF;

  -- Reembolso de comisión al conductor
  IF v_refund_commission AND v_ride.commission_usd > 0
     AND v_ride.driver_id IS NOT NULL AND v_effective_fault != 'conductor' THEN
    SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.driver_id;
    IF v_wallet.id IS NOT NULL THEN
      UPDATE wallets SET balance_usd = balance_usd + v_ride.commission_usd, updated_at = NOW()
      WHERE user_id = v_ride.driver_id;
      INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
      VALUES (v_wallet.id, v_ride.driver_id, 'credito', v_ride.commission_usd, 'completado',
              'Comisión reembolsada por cancelación', p_ride_id);
    END IF;
  END IF;

  -- Reembolso al cliente según método
  IF v_method IN ('billetera', 'efectivo') AND v_ride.final_fare_usd > 0 THEN
    v_refund := GREATEST(v_ride.final_fare_usd - v_fee, 0);
    IF v_refund > 0 THEN
      SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.client_id;
      IF v_wallet.id IS NOT NULL THEN
        INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
        VALUES (v_wallet.id, v_ride.client_id, 'credito', v_refund, 'pendiente',
                'Reembolso pendiente por cancelación', p_ride_id);
        INSERT INTO notifications (user_id, title, body, type, data)
        SELECT id, 'Reembolso pendiente', CONCAT('Reembolsar $', v_refund), 'refund_pending',
               jsonb_build_object('ride_id', p_ride_id, 'amount', v_refund, 'url', '/admin/incidentes')
        FROM profiles WHERE role IN ('super_admin', 'encargado');
      END IF;
    END IF;
    v_ride.reimbursement_status := 'pendiente_manual';
  ELSE
    IF v_fee > 0 AND v_effective_fault = 'cliente' THEN
      SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.client_id;
      IF v_wallet.id IS NOT NULL THEN
        UPDATE wallets SET balance_usd = balance_usd - v_fee, updated_at = NOW()
        WHERE user_id = v_ride.client_id;
        INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
        VALUES (v_wallet.id, v_ride.client_id, 'debito', v_fee, 'completado',
                'Tarifa de cancelación', p_ride_id);
      END IF;
    END IF;
    v_ride.reimbursement_status := 'no_aplica';
  END IF;

  UPDATE rides
  SET status = 'cancelada', cancelled_by = v_user_id, cancel_reason = COALESCE(p_reason, 'Cancelado'),
      cancellation_fee_usd = v_fee, driver_compensation_usd = v_compensation,
      reimbursement_status = v_ride.reimbursement_status, updated_at = NOW()
  WHERE id = p_ride_id;

  -- Liberar el cupón: la promo no se consume en un viaje que no ocurrió
  IF v_ride.coupon_id IS NOT NULL THEN
    DELETE FROM coupon_redemptions WHERE ride_id = p_ride_id;
    UPDATE coupons SET used_count = GREATEST(used_count - 1, 0), updated_at = NOW()
    WHERE id = v_ride.coupon_id;
  END IF;

  IF v_ride.client_id IS NOT NULL AND v_ride.driver_id IS NOT NULL THEN
    v_other_user := CASE WHEN v_user_id = v_ride.client_id THEN v_ride.driver_id ELSE v_ride.client_id END;
    PERFORM public.notify_user(v_other_user, 'Viaje cancelado',
      CASE WHEN v_effective_fault = 'accidente' THEN 'Viaje cancelado por incidente'
           WHEN v_fee > 0 THEN CONCAT('Cancelado. Fee: $', v_fee)
           ELSE 'El viaje fue cancelado' END,
      'ride_cancelled', jsonb_build_object('ride_id', p_ride_id, 'fee', v_fee, 'compensation', v_compensation));
    IF v_fee > 0 THEN
      PERFORM public.notify_user(v_user_id, 'Viaje cancelado',
        CONCAT('Fee: $', v_fee, CASE WHEN v_compensation > 0 THEN CONCAT('. Conductor compensado: $', v_compensation) ELSE '' END),
        'ride_cancelled_confirmation', jsonb_build_object('ride_id', p_ride_id, 'fee', v_fee));
    END IF;
  END IF;

  BEGIN
    INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
    VALUES (v_user_id, 'CANCEL_RIDE', 'ride', p_ride_id,
            jsonb_build_object('at_fault', v_effective_fault, 'fee', v_fee, 'compensation', v_compensation,
                               'refunded_commission', v_refund_commission, 'reimbursement_status', v_ride.reimbursement_status));
  EXCEPTION WHEN OTHERS THEN NULL;
  END;

  RETURN jsonb_build_object('success', TRUE, 'ride_id', p_ride_id, 'status', 'cancelada',
    'at_fault', v_effective_fault, 'cancellation_fee_usd', v_fee, 'driver_compensation_usd', v_compensation,
    'refunded_commission', v_refund_commission, 'reimbursement_status', v_ride.reimbursement_status);
END;
$$;

GRANT EXECUTE ON FUNCTION public.cancel_ride TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.cancel_ride FROM anon;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'OK: migración 047 aplicada' AS estado;
