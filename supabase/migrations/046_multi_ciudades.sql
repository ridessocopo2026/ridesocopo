-- ============================================================
-- RIDERFLASSHI - Migración 046: MULTI-CIUDAD (ZONAS POR CIUDAD)
-- ------------------------------------------------------------
-- Cada ciudad = una zona 'cobertura_general' con su polígono.
-- Los barrios pertenecen a una ciudad (barrios.zone_id).
-- La ciudad del pasajero se detecta por el origen (GPS).
-- ============================================================

-- ============================================================
-- 0. GARANTIZAR QUE LA TABLA BARRIOS EXISTA (autocontenido)
-- ------------------------------------------------------------
-- La tabla barrios se crea en la migración 002. Si esta base no
-- la tiene (migración parcial), se crea aquí completa con las
-- columnas de precios por vehículo, RLS, políticas y trigger.
-- ============================================================

-- Función updated_at (idempotente)
CREATE OR REPLACE FUNCTION public.update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Tabla barrios (completa)
CREATE TABLE IF NOT EXISTS public.barrios (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT NOT NULL,
  zone_id UUID REFERENCES public.zones(id),
  surcharge_usd NUMERIC(10,2) NOT NULL DEFAULT 0.00,
  surcharge_moto_usd NUMERIC(10,2) DEFAULT 0.00,
  surcharge_carro_usd NUMERIC(10,2) DEFAULT 0.00,
  surcharge_camioneta_usd NUMERIC(10,2) DEFAULT 0.00,
  lat NUMERIC(10,7),
  lng NUMERIC(10,7),
  description TEXT,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Columnas de precios por si la tabla ya existía sin ellas
ALTER TABLE public.barrios ADD COLUMN IF NOT EXISTS surcharge_moto_usd NUMERIC(10,2) DEFAULT 0.00;
ALTER TABLE public.barrios ADD COLUMN IF NOT EXISTS surcharge_carro_usd NUMERIC(10,2) DEFAULT 0.00;
ALTER TABLE public.barrios ADD COLUMN IF NOT EXISTS surcharge_camioneta_usd NUMERIC(10,2) DEFAULT 0.00;

-- RLS y políticas (idempotente)
ALTER TABLE public.barrios ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "public_view_barrios" ON public.barrios;
CREATE POLICY "public_view_barrios" ON public.barrios
  FOR SELECT USING (is_active = TRUE);

DROP POLICY IF EXISTS "super_admin_manage_barrios" ON public.barrios;
CREATE POLICY "super_admin_manage_barrios" ON public.barrios
  FOR ALL USING (public.get_user_role(auth.uid()) = 'super_admin');

-- Trigger updated_at (idempotente)
DROP TRIGGER IF EXISTS update_barrios_updated_at ON public.barrios;
CREATE TRIGGER update_barrios_updated_at BEFORE UPDATE ON public.barrios
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- Permisos básicos
GRANT ALL ON public.barrios TO anon, authenticated, service_role;

-- Columnas de barrio en rides (por si falta la migración 002)
ALTER TABLE public.rides ADD COLUMN IF NOT EXISTS destination_barrio_id UUID REFERENCES public.barrios(id);
ALTER TABLE public.rides ADD COLUMN IF NOT EXISTS destination_barrio_name TEXT;

-- ============================================================
-- 1. MODELO DE DATOS
-- ============================================================

-- 1.1 barrios.zone_id
ALTER TABLE public.barrios ADD COLUMN IF NOT EXISTS zone_id UUID REFERENCES public.zones(id);

-- Backfill: asignar barrios actuales a la ciudad existente (Socopó)
UPDATE public.barrios
SET zone_id = (
  SELECT z.id FROM public.zones z
  WHERE z.zone_type = 'cobertura_general' AND z.is_active = TRUE
  ORDER BY z.created_at LIMIT 1
)
WHERE zone_id IS NULL;

-- Unique global -> único por (ciudad, nombre)
ALTER TABLE public.barrios DROP CONSTRAINT IF EXISTS barrios_name_key;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'barrios_zone_name_key') THEN
    ALTER TABLE public.barrios ADD CONSTRAINT barrios_zone_name_key UNIQUE (zone_id, name);
  END IF;
END $$;

-- zone_id obligatorio (todo barrio pertenece a una ciudad)
DO $$
BEGIN
  IF (SELECT COUNT(*) FROM public.barrios WHERE zone_id IS NULL) = 0 THEN
    ALTER TABLE public.barrios ALTER COLUMN zone_id SET NOT NULL;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS idx_barrios_zone ON public.barrios(zone_id);

-- 1.2 zones.center (centro del mapa por ciudad)
ALTER TABLE public.zones ADD COLUMN IF NOT EXISTS center_lat NUMERIC(10,7);
ALTER TABLE public.zones ADD COLUMN IF NOT EXISTS center_lng NUMERIC(10,7);

-- ============================================================
-- 2. RPCs PÚBLICAS DE CIUDAD
-- ============================================================

-- 2.1 Lista de ciudades activas (selector del pasajero)
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
      'center_lng', COALESCE(z.center_lng, ST_X(ST_Centroid(z.polygon)))
    )
    ORDER BY z.name
  ), '[]'::jsonb)
  FROM public.zones z
  WHERE z.zone_type = 'cobertura_general' AND z.is_active = TRUE;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_cities() TO anon, authenticated, service_role;

-- 2.2 Detectar ciudad de un punto (GPS)
CREATE OR REPLACE FUNCTION public.find_city(p_lat NUMERIC, p_lng NUMERIC)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_zone RECORD;
BEGIN
  SELECT z.id, z.name,
         COALESCE(z.center_lat, ST_Y(ST_Centroid(z.polygon))) AS center_lat,
         COALESCE(z.center_lng, ST_X(ST_Centroid(z.polygon))) AS center_lng
  INTO v_zone
  FROM public.zones z
  WHERE z.zone_type = 'cobertura_general'
    AND z.is_active = TRUE
    AND ST_Contains(z.polygon, ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326))
  LIMIT 1;

  IF v_zone.id IS NULL THEN
    RETURN jsonb_build_object('found', FALSE);
  END IF;

  RETURN jsonb_build_object(
    'found', TRUE,
    'id', v_zone.id,
    'name', v_zone.name,
    'center_lat', v_zone.center_lat,
    'center_lng', v_zone.center_lng
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.find_city(numeric, numeric) TO anon, authenticated, service_role;

-- ============================================================
-- 3. CALCULATE_FARE: deriva la ciudad del origen y filtra barrios
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
  v_coupon RECORD;
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
    'in_coverage', TRUE,
    'origin_zone_id', v_zone.id,
    'origin_zone_name', v_zone.name,
    'destination_zone_id', v_zone.id,
    'destination_zone_name', v_zone.name
  );
END;
$$;

-- ============================================================
-- 4. REQUEST_RIDE: guarda zonas del viaje + notifica solo a la ciudad
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
    total_fare_usd, discount_usd, final_fare_usd,
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
    (v_fare->>'discount')::NUMERIC,
    v_final_fare,
    p_payment_method, 'buscando'
  ) RETURNING id INTO v_ride_id;

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
-- 5. REQUEST_RIDE_WITH_PROOF: guarda zonas + notifica solo a la ciudad
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
    total_fare_usd, discount_usd, final_fare_usd,
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
    (v_fare->>'discount')::NUMERIC,
    (v_fare->>'final_fare')::NUMERIC,
    p_payment_method, 'buscando',
    CASE WHEN v_proof_required THEN p_proof_url ELSE NULL END,
    CASE WHEN v_proof_required THEN 'pendiente' ELSE 'aprobado' END
  ) RETURNING id INTO v_ride_id;

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
-- 6. GET_AVAILABLE_RIDES: el conductor solo ve su ciudad
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_available_rides()
RETURNS SETOF rides
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_profile RECORD;
BEGIN
  SELECT * INTO v_profile FROM profiles WHERE id = v_driver_id;

  IF v_profile.role != 'conductor' OR v_profile.driver_status != 'aprobado' THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF v_profile.zone_id IS NOT NULL THEN
    RETURN QUERY
    SELECT r.* FROM rides r
    WHERE r.status = 'buscando'
      AND (r.proof_status IS NULL OR r.proof_status = 'aprobado')
      AND r.origin_zone_id = v_profile.zone_id
      AND r.category IN (
        SELECT v.category FROM vehicles v
        WHERE v.driver_id = v_driver_id AND v.is_active = TRUE
      )
    ORDER BY r.created_at DESC
    LIMIT 20;
  ELSE
    RETURN QUERY
    SELECT r.* FROM rides r
    WHERE r.status = 'buscando'
      AND (r.proof_status IS NULL OR r.proof_status = 'aprobado')
      AND r.category IN (
        SELECT v.category FROM vehicles v
        WHERE v.driver_id = v_driver_id AND v.is_active = TRUE
      )
    ORDER BY r.created_at DESC
    LIMIT 20;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_available_rides TO anon, authenticated, service_role;

-- ============================================================
-- 7. GET_NEAREST_BARRIO: busca dentro de la ciudad del punto
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_nearest_barrio(
  p_lat NUMERIC,
  p_lng NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_barrio RECORD;
  v_zone_id UUID;
BEGIN
  SELECT z.id INTO v_zone_id
  FROM zones z
  WHERE z.zone_type = 'cobertura_general'
    AND z.is_active = TRUE
    AND ST_Contains(z.polygon, ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326))
  LIMIT 1;

  SELECT b.id, b.name, b.surcharge_usd,
         b.surcharge_moto_usd, b.surcharge_carro_usd, b.surcharge_camioneta_usd
  INTO v_barrio
  FROM barrios b
  WHERE b.is_active = TRUE
    AND (v_zone_id IS NULL OR b.zone_id = v_zone_id)
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

GRANT EXECUTE ON FUNCTION public.get_nearest_barrio TO anon, authenticated, service_role;

-- ============================================================
-- 8. UPSERT_BARRIO: cada barrio pertenece a una ciudad
-- ============================================================
DROP FUNCTION IF EXISTS public.upsert_barrio(text, numeric, numeric, numeric, text, uuid, numeric, numeric, numeric);
DROP FUNCTION IF EXISTS public.upsert_barrio(text, numeric, numeric, numeric, text, uuid);

CREATE OR REPLACE FUNCTION public.upsert_barrio(
  p_name TEXT,
  p_surcharge_usd NUMERIC,
  p_zone_id UUID,
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
  v_zone_ok BOOLEAN;
BEGIN
  IF public.get_user_role(v_admin_id) != 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM zones WHERE id = p_zone_id AND zone_type = 'cobertura_general' AND is_active = TRUE
  ) INTO v_zone_ok;
  IF NOT v_zone_ok THEN
    RAISE EXCEPTION 'Ciudad no válida';
  END IF;

  IF p_surcharge_moto_usd IS NULL THEN p_surcharge_moto_usd := p_surcharge_usd; END IF;
  IF p_surcharge_carro_usd IS NULL THEN p_surcharge_carro_usd := p_surcharge_usd; END IF;
  IF p_surcharge_camioneta_usd IS NULL THEN p_surcharge_camioneta_usd := p_surcharge_usd; END IF;

  IF p_barrio_id IS NULL THEN
    INSERT INTO barrios (name, zone_id, surcharge_usd, surcharge_moto_usd, surcharge_carro_usd, surcharge_camioneta_usd, lat, lng, description)
    VALUES (p_name, p_zone_id, p_surcharge_usd, p_surcharge_moto_usd, p_surcharge_carro_usd, p_surcharge_camioneta_usd, p_lat, p_lng, p_description)
    RETURNING id INTO v_barrio_id;
  ELSE
    UPDATE barrios
    SET name = p_name,
        zone_id = p_zone_id,
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

REVOKE ALL ON FUNCTION public.upsert_barrio FROM anon;
GRANT EXECUTE ON FUNCTION public.upsert_barrio TO authenticated, service_role;

-- ============================================================
-- 9. UPSERT_ZONE: crear Ciudades (cobertura_general) y zonas con centro
-- ============================================================
DROP FUNCTION IF EXISTS public.upsert_zone(text, text, numeric, jsonb, uuid);

CREATE OR REPLACE FUNCTION public.upsert_zone(
  p_name TEXT,
  p_description TEXT,
  p_surcharge_usd NUMERIC,
  p_polygon_geojson JSONB,
  p_zone_id UUID DEFAULT NULL,
  p_zone_type TEXT DEFAULT 'zona_especifica',
  p_center_lat NUMERIC DEFAULT NULL,
  p_center_lng NUMERIC DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_admin RECORD;
  v_zone_id UUID;
  v_polygon GEOMETRY;
BEGIN
  SELECT * INTO v_admin FROM profiles WHERE id = v_admin_id;
  IF v_admin.role != 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF p_zone_type NOT IN ('cobertura_general', 'zona_especifica') THEN
    RAISE EXCEPTION 'Tipo de zona no válido';
  END IF;

  v_polygon := ST_SetSRID(ST_GeomFromGeoJSON(p_polygon_geojson::text), 4326);

  IF p_zone_id IS NULL THEN
    INSERT INTO zones (name, description, surcharge_usd, polygon, zone_type, center_lat, center_lng, created_by)
    VALUES (p_name, p_description, p_surcharge_usd, v_polygon, p_zone_type::zone_type, p_center_lat, p_center_lng, v_admin_id)
    RETURNING id INTO v_zone_id;
  ELSE
    UPDATE zones
    SET name = p_name,
        description = p_description,
        surcharge_usd = p_surcharge_usd,
        polygon = v_polygon,
        zone_type = p_zone_type::zone_type,
        center_lat = p_center_lat,
        center_lng = p_center_lng,
        updated_at = NOW()
    WHERE id = p_zone_id
    RETURNING id INTO v_zone_id;
  END IF;

  RETURN v_zone_id;
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_zone FROM anon;
GRANT EXECUTE ON FUNCTION public.upsert_zone TO authenticated, service_role;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'OK: migración 046 aplicada' AS estado;
