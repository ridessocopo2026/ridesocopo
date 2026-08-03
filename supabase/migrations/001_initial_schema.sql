-- ============================================================
-- RIDESOCOPÓ - Esquema Completo de Base de Datos
-- Transporte de Pasajeros en Socopó, Barinas, Venezuela
-- ============================================================

-- 1. HABILITAR POSTGIS (para polígonos de zonas)
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

-- ============================================================
-- 2. ENUMS
-- ============================================================
CREATE TYPE user_role AS ENUM ('cliente', 'conductor', 'encargado', 'super_admin');
CREATE TYPE driver_status AS ENUM ('pendiente', 'aprobado', 'rechazado', 'suspendido');
CREATE TYPE vehicle_category AS ENUM ('moto', 'carro', 'camioneta');
CREATE TYPE ride_status AS ENUM ('buscando', 'aceptada', 'en_ruta', 'completada', 'cancelada');
CREATE TYPE payment_method AS ENUM ('billetera', 'efectivo', 'pago_movil');
CREATE TYPE transaction_type AS ENUM ('recarga', 'comision', 'debito', 'credito', 'ajuste');
CREATE TYPE transaction_status AS ENUM ('pendiente', 'aprobado', 'rechazado', 'completado');
CREATE TYPE zone_type AS ENUM ('cobertura_general', 'zona_especifica');

-- ============================================================
-- 3. TABLA: PROFILES (Perfiles de usuario)
-- ============================================================
CREATE TABLE profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  full_name TEXT NOT NULL,
  email TEXT NOT NULL UNIQUE,
  phone TEXT,
  role user_role NOT NULL DEFAULT 'cliente',
  avatar_url TEXT,
  zone_id UUID,
  driver_status driver_status,
  is_online BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  onboarding_completed BOOLEAN DEFAULT FALSE
);

-- ============================================================
-- 4. TABLA: ZONES (Zonas de servicio)
-- ============================================================
CREATE TABLE zones (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT NOT NULL,
  description TEXT,
  zone_type zone_type NOT NULL DEFAULT 'zona_especifica',
  surcharge_usd NUMERIC(10,2) NOT NULL DEFAULT 0.00,
  polygon GEOMETRY(POLYGON, 4326),
  is_active BOOLEAN DEFAULT TRUE,
  created_by UUID REFERENCES profiles(id),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Zona de cobertura general (capa 0)
INSERT INTO zones (name, description, zone_type, surcharge_usd, polygon)
VALUES (
  'Cobertura General Socopó',
  'Cobertura base de toda la ciudad de Socopó',
  'cobertura_general',
  0.00,
  ST_GeomFromText('POLYGON((-70.25 8.23, -70.20 8.23, -70.20 8.27, -70.25 8.27, -70.25 8.23))', 4326)
);

-- ============================================================
-- 5. TABLA: VEHICLE_CATEGORIES (Categorías de vehículo)
-- ============================================================
CREATE TABLE vehicle_categories (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name vehicle_category NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  base_fare_usd NUMERIC(10,2) NOT NULL,
  max_passengers INTEGER NOT NULL,
  description TEXT,
  icon TEXT,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Categorías iniciales
INSERT INTO vehicle_categories (name, display_name, base_fare_usd, max_passengers, description) VALUES
  ('moto', 'Moto', 1.00, 1, 'Económica, 1 pasajero'),
  ('carro', 'Carro', 2.50, 4, 'Sedán / Hatchback, hasta 4 pasajeros'),
  ('camioneta', 'Camioneta / SUV', 4.00, 6, 'Grupos o equipaje');

-- ============================================================
-- 6. TABLA: VEHICLES (Vehículos de conductores)
-- ============================================================
CREATE TABLE vehicles (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  driver_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  category vehicle_category NOT NULL,
  brand TEXT NOT NULL,
  model TEXT NOT NULL,
  year INTEGER NOT NULL,
  color TEXT NOT NULL,
  plate TEXT NOT NULL UNIQUE,
  photo_url TEXT,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 7. TABLA: DRIVER_DOCUMENTS (Documentos del conductor)
-- ============================================================
CREATE TABLE driver_documents (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  driver_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  cedula_number TEXT NOT NULL,
  cedula_photo_url TEXT NOT NULL,
  license_number TEXT NOT NULL,
  license_photo_url TEXT NOT NULL,
  license_expiry_date DATE NOT NULL,
  profile_photo_url TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(driver_id)
);

-- ============================================================
-- 8. TABLA: WALLETS (Billeteras virtuales)
-- ============================================================
CREATE TABLE wallets (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  balance_usd NUMERIC(12,2) NOT NULL DEFAULT 0.00,
  debt_limit_usd NUMERIC(12,2) NOT NULL DEFAULT 5.00,
  is_blocked BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(user_id)
);

-- ============================================================
-- 9. TABLA: TRANSACTIONS (Transacciones de billetera)
-- ============================================================
CREATE TABLE transactions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  wallet_id UUID NOT NULL REFERENCES wallets(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES profiles(id),
  type transaction_type NOT NULL,
  amount_usd NUMERIC(12,2) NOT NULL,
  status transaction_status NOT NULL DEFAULT 'pendiente',
  description TEXT,
  reference TEXT,
  proof_url TEXT,
  ride_id UUID,
  reviewed_by UUID REFERENCES profiles(id),
  reviewed_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 10. TABLA: RIDES (Viajes)
-- ============================================================
CREATE TABLE rides (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  client_id UUID NOT NULL REFERENCES profiles(id),
  driver_id UUID REFERENCES profiles(id),
  vehicle_id UUID REFERENCES vehicles(id),
  category vehicle_category NOT NULL,
  origin_lat NUMERIC(10,7) NOT NULL,
  origin_lng NUMERIC(10,7) NOT NULL,
  origin_address TEXT,
  origin_zone_id UUID REFERENCES zones(id),
  destination_lat NUMERIC(10,7) NOT NULL,
  destination_lng NUMERIC(10,7) NOT NULL,
  destination_address TEXT,
  destination_zone_id UUID REFERENCES zones(id),
  base_fare_usd NUMERIC(10,2) NOT NULL,
  origin_surcharge_usd NUMERIC(10,2) NOT NULL DEFAULT 0.00,
  destination_surcharge_usd NUMERIC(10,2) NOT NULL DEFAULT 0.00,
  total_fare_usd NUMERIC(10,2) NOT NULL,
  coupon_id UUID,
  discount_usd NUMERIC(10,2) NOT NULL DEFAULT 0.00,
  final_fare_usd NUMERIC(10,2) NOT NULL,
  commission_usd NUMERIC(10,2) NOT NULL DEFAULT 0.00,
  commission_rate NUMERIC(5,2) NOT NULL DEFAULT 10.00,
  payment_method payment_method NOT NULL DEFAULT 'efectivo',
  status ride_status NOT NULL DEFAULT 'buscando',
  driver_location_lat NUMERIC(10,7),
  driver_location_lng NUMERIC(10,7),
  driver_last_update TIMESTAMPTZ,
  started_at TIMESTAMPTZ,
  completed_at TIMESTAMPTZ,
  cancelled_by UUID REFERENCES profiles(id),
  cancel_reason TEXT,
  rating INTEGER CHECK (rating >= 1 AND rating <= 5),
  review TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 11. TABLA: COUPONS (Cupones de descuento)
-- ============================================================
CREATE TABLE coupons (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  code TEXT NOT NULL UNIQUE,
  description TEXT,
  discount_type TEXT NOT NULL CHECK (discount_type IN ('percentage', 'fixed')),
  discount_value NUMERIC(10,2) NOT NULL,
  max_uses INTEGER,
  used_count INTEGER DEFAULT 0,
  valid_from TIMESTAMPTZ,
  valid_until TIMESTAMPTZ,
  is_active BOOLEAN DEFAULT TRUE,
  created_by UUID REFERENCES profiles(id),
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 12. TABLA: BANNERS (Banners promocionales)
-- ============================================================
CREATE TABLE banners (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  title TEXT NOT NULL,
  subtitle TEXT,
  image_url TEXT,
  link_url TEXT,
  is_active BOOLEAN DEFAULT TRUE,
  sort_order INTEGER DEFAULT 0,
  starts_at TIMESTAMPTZ,
  ends_at TIMESTAMPTZ,
  created_by UUID REFERENCES profiles(id),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 13. TABLA: FAVORITE_PLACES (Lugares guardados)
-- ============================================================
CREATE TABLE favorite_places (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  name TEXT NOT NULL,
  address TEXT,
  lat NUMERIC(10,7) NOT NULL,
  lng NUMERIC(10,7) NOT NULL,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 14. TABLA: EXCHANGE_RATES (Tasa de cambio Bs./USD)
-- ============================================================
CREATE TABLE exchange_rates (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  rate_bs_per_usd NUMERIC(12,2) NOT NULL,
  is_active BOOLEAN DEFAULT TRUE,
  updated_by UUID REFERENCES profiles(id),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Tasa inicial de ejemplo (el admin la actualizará)
INSERT INTO exchange_rates (rate_bs_per_usd) VALUES (48.00);

-- ============================================================
-- 15. TABLA: NOTIFICATIONS (Notificaciones)
-- ============================================================
CREATE TABLE notifications (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  body TEXT,
  type TEXT,
  data JSONB,
  is_read BOOLEAN DEFAULT FALSE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 16. TABLA: AUDIT_LOGS (Auditoría)
-- ============================================================
CREATE TABLE audit_logs (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID REFERENCES profiles(id),
  action TEXT NOT NULL,
  entity_type TEXT,
  entity_id UUID,
  details JSONB,
  ip_address TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 17. TRIGGERS: CREACIÓN AUTOMÁTICA
-- ============================================================

-- Trigger: Crear perfil automáticamente al registrarse
CREATE OR REPLACE FUNCTION handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO profiles (id, full_name, email)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.email),
    NEW.email
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION handle_new_user();

-- Trigger: Crear billetera automáticamente al crear perfil
CREATE OR REPLACE FUNCTION handle_new_profile()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO wallets (user_id) VALUES (NEW.id);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

CREATE TRIGGER on_profile_created
  AFTER INSERT ON profiles
  FOR EACH ROW EXECUTE FUNCTION handle_new_profile();

-- Trigger: Actualizar updated_at
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER update_profiles_updated_at BEFORE UPDATE ON profiles
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER update_vehicles_updated_at BEFORE UPDATE ON vehicles
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER update_rides_updated_at BEFORE UPDATE ON rides
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER update_wallets_updated_at BEFORE UPDATE ON wallets
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER update_zones_updated_at BEFORE UPDATE ON zones
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();
CREATE TRIGGER update_banners_updated_at BEFORE UPDATE ON banners
  FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- 18. FUNCIONES RPC: LÓGICA DE NEGOCIO
-- ============================================================

-- 18.1 Calcular tarifa atómica
CREATE OR REPLACE FUNCTION calculate_fare(
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
AS $$
DECLARE
  v_base_fare NUMERIC;
  v_origin_surcharge NUMERIC := 0.00;
  v_dest_surcharge NUMERIC := 0.00;
  v_origin_zone_id UUID;
  v_dest_zone_id UUID;
  v_total NUMERIC;
  v_discount NUMERIC := 0.00;
  v_final NUMERIC;
  v_coupon RECORD;
  v_origin_point GEOMETRY;
  v_dest_point GEOMETRY;
BEGIN
  -- Obtener tarifa base
  SELECT base_fare_usd INTO v_base_fare
  FROM vehicle_categories WHERE name = p_category;

  IF v_base_fare IS NULL THEN
    RAISE EXCEPTION 'Categoría de vehículo no válida';
  END IF;

  -- Crear puntos geográficos
  v_origin_point := ST_SetSRID(ST_MakePoint(p_origin_lng, p_origin_lat), 4326);
  v_dest_point := ST_SetSRID(ST_MakePoint(p_dest_lng, p_dest_lat), 4326);

  -- Buscar zona de origen (prioridad: mayor recargo en solapamiento)
  SELECT z.id, z.surcharge_usd INTO v_origin_zone_id, v_origin_surcharge
  FROM zones z
  WHERE z.is_active = TRUE
    AND z.zone_type = 'zona_especifica'
    AND ST_Contains(z.polygon, v_origin_point)
  ORDER BY z.surcharge_usd DESC
  LIMIT 1;

  -- Si no hay zona específica, usar cobertura general (recargo 0)
  IF v_origin_zone_id IS NULL THEN
    SELECT id INTO v_origin_zone_id FROM zones WHERE zone_type = 'cobertura_general' LIMIT 1;
    v_origin_surcharge := 0.00;
  END IF;

  -- Buscar zona de destino
  SELECT z.id, z.surcharge_usd INTO v_dest_zone_id, v_dest_surcharge
  FROM zones z
  WHERE z.is_active = TRUE
    AND z.zone_type = 'zona_especifica'
    AND ST_Contains(z.polygon, v_dest_point)
  ORDER BY z.surcharge_usd DESC
  LIMIT 1;

  IF v_dest_zone_id IS NULL THEN
    SELECT id INTO v_dest_zone_id FROM zones WHERE zone_type = 'cobertura_general' LIMIT 1;
    v_dest_surcharge := 0.00;
  END IF;

  -- Calcular total
  v_total := v_base_fare + v_origin_surcharge + v_dest_surcharge;

  -- Aplicar cupón si existe
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
    'origin_surcharge', v_origin_surcharge,
    'destination_surcharge', v_dest_surcharge,
    'total_fare', v_total,
    'discount', v_discount,
    'final_fare', v_final,
    'origin_zone_id', v_origin_zone_id,
    'destination_zone_id', v_dest_zone_id
  );
END;
$$;

-- 18.2 Solicitar viaje
CREATE OR REPLACE FUNCTION request_ride(
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
  v_fare := calculate_fare(
    p_origin_lat, p_origin_lng,
    p_dest_lat, p_dest_lng,
    p_category, p_coupon_code
  );

  -- Crear viaje
  INSERT INTO rides (
    client_id, category,
    origin_lat, origin_lng, origin_address, origin_zone_id,
    destination_lat, destination_lng, destination_address, destination_zone_id,
    base_fare_usd, origin_surcharge_usd, destination_surcharge_usd,
    total_fare_usd, discount_usd, final_fare_usd,
    payment_method, status
  ) VALUES (
    v_user_id, p_category,
    p_origin_lat, p_origin_lng, p_origin_address, (v_fare->>'origin_zone_id')::UUID,
    p_dest_lat, p_dest_lng, p_dest_address, (v_fare->>'destination_zone_id')::UUID,
    (v_fare->>'base_fare')::NUMERIC,
    (v_fare->>'origin_surcharge')::NUMERIC,
    (v_fare->>'destination_surcharge')::NUMERIC,
    (v_fare->>'total_fare')::NUMERIC,
    (v_fare->>'discount')::NUMERIC,
    (v_fare->>'final_fare')::NUMERIC,
    p_payment_method, 'buscando'
  ) RETURNING id INTO v_ride_id;

  -- Registrar auditoría
  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_user_id, 'REQUEST_RIDE', 'ride', v_ride_id, v_fare);

  RETURN v_ride_id;
END;
$$;

-- 18.3 Aceptar viaje (con verificación de saldo y bloqueo de comisión)
CREATE OR REPLACE FUNCTION accept_ride(p_ride_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
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

  -- Verificar que el conductor está aprobado
  SELECT driver_status INTO v_ride FROM profiles WHERE id = v_driver_id;
  IF v_ride.driver_status != 'aprobado' THEN
    RAISE EXCEPTION 'Conductor no aprobado';
  END IF;

  -- Obtener viaje
  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id AND status = 'buscando';
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no disponible';
  END IF;

  -- Obtener vehículo del conductor
  SELECT * INTO v_vehicle FROM vehicles
  WHERE driver_id = v_driver_id AND category = v_ride.category AND is_active = TRUE
  LIMIT 1;

  IF v_vehicle.id IS NULL THEN
    RAISE EXCEPTION 'No tiene un vehículo activo de la categoría requerida';
  END IF;

  -- Obtener billetera del conductor
  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_driver_id;

  -- Calcular comisión (10% del total)
  v_commission := ROUND(v_ride.total_fare_usd * v_ride.commission_rate / 100, 2);

  -- Verificar saldo suficiente para comisión
  IF v_wallet.balance_usd < v_commission THEN
    RETURN jsonb_build_object(
      'success', FALSE,
      'error', 'SALDO_INSUFICIENTE',
      'message', 'Saldo insuficiente para cubrir la comisión de $' || v_commission,
      'commission', v_commission,
      'balance', v_wallet.balance_usd
    );
  END IF;

  -- Verificar límite de deuda
  IF v_wallet.balance_usd < -v_wallet.debt_limit_usd THEN
    RAISE EXCEPTION 'Límite de deuda excedido';
  END IF;

  -- Bloquear comisión (débito atómico)
  UPDATE wallets
  SET balance_usd = balance_usd - v_commission,
      updated_at = NOW()
  WHERE user_id = v_driver_id;

  -- Registrar transacción de comisión
  INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
  VALUES (v_wallet.id, v_driver_id, 'comision', v_commission, 'completado',
          'Comisión por viaje', p_ride_id);

  -- Actualizar viaje
  UPDATE rides
  SET driver_id = v_driver_id,
      vehicle_id = v_vehicle.id,
      commission_usd = v_commission,
      status = 'aceptada',
      started_at = NOW()
  WHERE id = p_ride_id;

  -- Notificar al cliente
  INSERT INTO notifications (user_id, title, body, type, data)
  VALUES (
    v_ride.client_id,
    'Conductor asignado',
    'Un conductor ha aceptado tu viaje',
    'ride_accepted',
    jsonb_build_object('ride_id', p_ride_id)
  );

  -- Auditoría
  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_driver_id, 'ACCEPT_RIDE', 'ride', p_ride_id,
          jsonb_build_object('commission', v_commission));

  RETURN jsonb_build_object(
    'success', TRUE,
    'ride_id', p_ride_id,
    'commission', v_commission
  );
END;
$$;

-- 18.4 Completar viaje
CREATE OR REPLACE FUNCTION complete_ride(
  p_ride_id UUID,
  p_rating INTEGER DEFAULT NULL,
  p_review TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_ride RECORD;
BEGIN
  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;

  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  -- Verificar que el usuario es el conductor o el cliente
  IF v_ride.driver_id != v_user_id AND v_ride.client_id != v_user_id THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- Solo completar si está en ruta o aceptada
  IF v_ride.status NOT IN ('aceptada', 'en_ruta') THEN
    RAISE EXCEPTION 'Estado de viaje no válido para completar';
  END IF;

  UPDATE rides
  SET status = 'completada',
      completed_at = NOW(),
      rating = COALESCE(p_rating, rating),
      review = COALESCE(p_review, review)
  WHERE id = p_ride_id;

  -- Notificar al otro usuario
  IF v_user_id = v_ride.driver_id THEN
    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (v_ride.client_id, 'Viaje completado', 'Tu viaje ha finalizado', 'ride_completed',
            jsonb_build_object('ride_id', p_ride_id));
  ELSE
    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (v_ride.driver_id, 'Viaje completado', 'El viaje ha finalizado', 'ride_completed',
            jsonb_build_object('ride_id', p_ride_id));
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'ride_id', p_ride_id);
END;
$$;

-- 18.5 Cancelar viaje
CREATE OR REPLACE FUNCTION cancel_ride(
  p_ride_id UUID,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_ride RECORD;
  v_wallet RECORD;
BEGIN
  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;

  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF v_ride.client_id != v_user_id AND v_ride.driver_id != v_user_id THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- Si el conductor cancela después de aceptar, devolver comisión
  IF v_ride.status = 'aceptada' AND v_ride.driver_id = v_user_id THEN
    SELECT * INTO v_wallet FROM wallets WHERE user_id = v_user_id;
    UPDATE wallets SET balance_usd = balance_usd + v_ride.commission_usd
    WHERE user_id = v_user_id;

    INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
    VALUES (v_wallet.id, v_user_id, 'credito', v_ride.commission_usd, 'completado',
            'Reembolso de comisión por cancelación', p_ride_id);
  END IF;

  UPDATE rides
  SET status = 'cancelada',
      cancelled_by = v_user_id,
      cancel_reason = p_reason
  WHERE id = p_ride_id;

  RETURN jsonb_build_object('success', TRUE, 'ride_id', p_ride_id);
END;
$$;

-- 18.6 Actualizar ubicación del conductor (con throttling)
CREATE OR REPLACE FUNCTION update_driver_location(
  p_ride_id UUID,
  p_lat NUMERIC,
  p_lng NUMERIC
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_ride RECORD;
  v_distance NUMERIC;
BEGIN
  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;

  IF v_ride.id IS NULL OR v_ride.driver_id != v_driver_id THEN
    RETURN FALSE;
  END IF;

  -- Throttling: solo actualizar si se movió >8m o pasaron >20s
  IF v_ride.driver_location_lat IS NOT NULL THEN
    v_distance := ST_Distance(
      ST_SetSRID(ST_MakePoint(v_ride.driver_location_lng, v_ride.driver_location_lat), 4326)::geography,
      ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography
    );

    IF v_distance < 8 AND (NOW() - v_ride.driver_last_update) < INTERVAL '20 seconds' THEN
      RETURN FALSE;
    END IF;
  END IF;

  UPDATE rides
  SET driver_location_lat = p_lat,
      driver_location_lng = p_lng,
      driver_last_update = NOW()
  WHERE id = p_ride_id;

  RETURN TRUE;
END;
$$;

-- 18.7 Aprobar/rechazar conductor (Solo Super Admin o Encargado)
CREATE OR REPLACE FUNCTION review_driver(
  p_driver_id UUID,
  p_approve BOOLEAN,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_reviewer_id UUID := auth.uid();
  v_reviewer RECORD;
  v_new_status driver_status;
BEGIN
  -- Verificar que el revisor es Super Admin o Encargado
  SELECT * INTO v_reviewer FROM profiles WHERE id = v_reviewer_id;
  IF v_reviewer.role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado para revisar conductores';
  END IF;

  v_new_status := CASE WHEN p_approve THEN 'aprobado' ELSE 'rechazado' END;

  UPDATE profiles
  SET driver_status = v_new_status
  WHERE id = p_driver_id;

  -- Notificar al conductor
  INSERT INTO notifications (user_id, title, body, type, data)
  VALUES (
    p_driver_id,
    CASE WHEN p_approve THEN '¡Cuenta aprobada!' ELSE 'Cuenta rechazada' END,
    CASE WHEN p_approve THEN 'Ya puedes comenzar a trabajar. ¡Bienvenido a RideSocopó!'
         ELSE COALESCE(p_reason, 'Tu solicitud fue rechazada. Contacta al administrador.') END,
    'driver_review',
    jsonb_build_object('approved', p_approve)
  );

  -- Auditoría
  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_reviewer_id, 'REVIEW_DRIVER', 'profile', p_driver_id,
          jsonb_build_object('approved', p_approve, 'reason', p_reason));

  RETURN jsonb_build_object('success', TRUE, 'driver_id', p_driver_id, 'status', v_new_status);
END;
$$;

-- 18.8 Recargar saldo (solicitud)
CREATE OR REPLACE FUNCTION request_wallet_recharge(
  p_amount_usd NUMERIC,
  p_proof_url TEXT,
  p_reference TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_wallet RECORD;
  v_txn_id UUID;
BEGIN
  IF p_amount_usd <= 0 THEN
    RAISE EXCEPTION 'Monto inválido';
  END IF;

  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_user_id;

  INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, proof_url, reference)
  VALUES (v_wallet.id, v_user_id, 'recarga', p_amount_usd, 'pendiente',
          'Recarga de saldo', p_proof_url, p_reference)
  RETURNING id INTO v_txn_id;

  RETURN v_txn_id;
END;
$$;

-- 18.9 Aprobar recarga (Solo Super Admin o Encargado)
CREATE OR REPLACE FUNCTION approve_recharge(
  p_transaction_id UUID,
  p_approve BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_reviewer_id UUID := auth.uid();
  v_reviewer RECORD;
  v_txn RECORD;
  v_wallet RECORD;
BEGIN
  SELECT * INTO v_reviewer FROM profiles WHERE id = v_reviewer_id;
  IF v_reviewer.role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT * INTO v_txn FROM transactions WHERE id = p_transaction_id AND status = 'pendiente';
  IF v_txn.id IS NULL THEN
    RAISE EXCEPTION 'Transacción no encontrada o ya procesada';
  END IF;

  IF p_approve THEN
    -- Acreditar saldo
    UPDATE wallets SET balance_usd = balance_usd + v_txn.amount_usd
    WHERE user_id = v_txn.user_id;

    UPDATE transactions SET status = 'aprobado', reviewed_by = v_reviewer_id, reviewed_at = NOW()
    WHERE id = p_transaction_id;

    -- Notificar al usuario
    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (v_txn.user_id, 'Recarga aprobada',
            'Tu recarga de $' || v_txn.amount_usd || ' ha sido aprobada',
            'recharge_approved', jsonb_build_object('transaction_id', p_transaction_id));
  ELSE
    UPDATE transactions SET status = 'rechazado', reviewed_by = v_reviewer_id, reviewed_at = NOW()
    WHERE id = p_transaction_id;

    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (v_txn.user_id, 'Recarga rechazada',
            'Tu recarga fue rechazada. Verifica el comprobante e intenta de nuevo.',
            'recharge_rejected', jsonb_build_object('transaction_id', p_transaction_id));
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'transaction_id', p_transaction_id);
END;
$$;

-- 18.10 Cambiar estado en línea del conductor
CREATE OR REPLACE FUNCTION toggle_driver_online(p_online BOOLEAN)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_profile RECORD;
  v_wallet RECORD;
BEGIN
  SELECT * INTO v_profile FROM profiles WHERE id = v_driver_id;

  IF v_profile.role != 'conductor' THEN
    RAISE EXCEPTION 'No es conductor';
  END IF;

  IF v_profile.driver_status != 'aprobado' THEN
    RAISE EXCEPTION 'Conductor no aprobado';
  END IF;

  -- Verificar límite de deuda
  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_driver_id;
  IF v_wallet.balance_usd < -v_wallet.debt_limit_usd THEN
    RAISE EXCEPTION 'Límite de deuda excedido. Recargue su saldo.';
  END IF;

  UPDATE profiles SET is_online = p_online WHERE id = v_driver_id;

  RETURN jsonb_build_object('success', TRUE, 'is_online', p_online);
END;
$$;

-- 18.11 Guardar lugar favorito
CREATE OR REPLACE FUNCTION save_favorite_place(
  p_name TEXT,
  p_address TEXT,
  p_lat NUMERIC,
  p_lng NUMERIC
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_place_id UUID;
BEGIN
  INSERT INTO favorite_places (user_id, name, address, lat, lng)
  VALUES (v_user_id, p_name, p_address, p_lat, p_lng)
  RETURNING id INTO v_place_id;

  RETURN v_place_id;
END;
$$;

-- 18.12 Obtener viajes disponibles para conductores
CREATE OR REPLACE FUNCTION get_available_rides()
RETURNS SETOF rides
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_profile RECORD;
  v_vehicle RECORD;
BEGIN
  SELECT * INTO v_profile FROM profiles WHERE id = v_driver_id;

  IF v_profile.role != 'conductor' OR v_profile.driver_status != 'aprobado' OR NOT v_profile.is_online THEN
    RAISE EXCEPTION 'No autorizado o no en línea';
  END IF;

  -- Obtener categorías de vehículos del conductor
  RETURN QUERY
  SELECT r.* FROM rides r
  WHERE r.status = 'buscando'
    AND r.category IN (
      SELECT v.category FROM vehicles v
      WHERE v.driver_id = v_driver_id AND v.is_active = TRUE
    )
  ORDER BY r.created_at DESC
  LIMIT 20;
END;
$$;

-- 18.13 Obtener viaje activo del conductor
CREATE OR REPLACE FUNCTION get_driver_active_ride()
RETURNS SETOF rides
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
BEGIN
  RETURN QUERY
  SELECT r.* FROM rides r
  WHERE r.driver_id = v_driver_id
    AND r.status IN ('aceptada', 'en_ruta')
  ORDER BY r.created_at DESC
  LIMIT 1;
END;
$$;

-- 18.14 Obtener viaje activo del cliente
CREATE OR REPLACE FUNCTION get_client_active_ride()
RETURNS SETOF rides
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_client_id UUID := auth.uid();
BEGIN
  RETURN QUERY
  SELECT r.* FROM rides r
  WHERE r.client_id = v_client_id
    AND r.status IN ('buscando', 'aceptada', 'en_ruta')
  ORDER BY r.created_at DESC
  LIMIT 1;
END;
$$;

-- 18.15 Obtener tasa de cambio activa
CREATE OR REPLACE FUNCTION get_active_exchange_rate()
RETURNS NUMERIC
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_rate NUMERIC;
BEGIN
  SELECT rate_bs_per_usd INTO v_rate FROM exchange_rates
  WHERE is_active = TRUE ORDER BY updated_at DESC LIMIT 1;

  RETURN v_rate;
END;
$$;

-- 18.16 Actualizar tasa de cambio (Solo Super Admin)
CREATE OR REPLACE FUNCTION update_exchange_rate(p_rate NUMERIC)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_admin RECORD;
BEGIN
  SELECT * INTO v_admin FROM profiles WHERE id = v_admin_id;
  IF v_admin.role != 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  UPDATE exchange_rates SET is_active = FALSE WHERE is_active = TRUE;
  INSERT INTO exchange_rates (rate_bs_per_usd, updated_by) VALUES (p_rate, v_admin_id);

  RETURN jsonb_build_object('success', TRUE, 'rate', p_rate);
END;
$$;

-- 18.17 Crear/actualizar zona (Solo Super Admin)
CREATE OR REPLACE FUNCTION upsert_zone(
  p_name TEXT,
  p_description TEXT,
  p_surcharge_usd NUMERIC,
  p_polygon_geojson JSONB,
  p_zone_id UUID DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
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

  -- Convertir GeoJSON a geometría PostGIS
  v_polygon := ST_SetSRID(ST_GeomFromGeoJSON(p_polygon_geojson::text), 4326);

  IF p_zone_id IS NULL THEN
    INSERT INTO zones (name, description, surcharge_usd, polygon, created_by)
    VALUES (p_name, p_description, p_surcharge_usd, v_polygon, v_admin_id)
    RETURNING id INTO v_zone_id;
  ELSE
    UPDATE zones
    SET name = p_name,
        description = p_description,
        surcharge_usd = p_surcharge_usd,
        polygon = v_polygon,
        updated_at = NOW()
    WHERE id = p_zone_id
    RETURNING id INTO v_zone_id;
  END IF;

  RETURN v_zone_id;
END;
$$;

-- 18.18 Crear cupón (Solo Super Admin)
CREATE OR REPLACE FUNCTION create_coupon(
  p_code TEXT,
  p_description TEXT,
  p_discount_type TEXT,
  p_discount_value NUMERIC,
  p_max_uses INTEGER DEFAULT NULL,
  p_valid_from TIMESTAMPTZ DEFAULT NULL,
  p_valid_until TIMESTAMPTZ DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_admin RECORD;
  v_coupon_id UUID;
BEGIN
  SELECT * INTO v_admin FROM profiles WHERE id = v_admin_id;
  IF v_admin.role != 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  INSERT INTO coupons (code, description, discount_type, discount_value, max_uses, valid_from, valid_until, created_by)
  VALUES (UPPER(p_code), p_description, p_discount_type, p_discount_value, p_max_uses, p_valid_from, p_valid_until, v_admin_id)
  RETURNING id INTO v_coupon_id;

  RETURN v_coupon_id;
END;
$$;

-- 18.19 Crear banner (Solo Super Admin)
CREATE OR REPLACE FUNCTION create_banner(
  p_title TEXT,
  p_subtitle TEXT,
  p_image_url TEXT,
  p_link_url TEXT,
  p_sort_order INTEGER DEFAULT 0,
  p_starts_at TIMESTAMPTZ DEFAULT NULL,
  p_ends_at TIMESTAMPTZ DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_admin RECORD;
  v_banner_id UUID;
BEGIN
  SELECT * INTO v_admin FROM profiles WHERE id = v_admin_id;
  IF v_admin.role != 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  INSERT INTO banners (title, subtitle, image_url, link_url, sort_order, starts_at, ends_at, created_by)
  VALUES (p_title, p_subtitle, p_image_url, p_link_url, p_sort_order, p_starts_at, p_ends_at, v_admin_id)
  RETURNING id INTO v_banner_id;

  RETURN v_banner_id;
END;
$$;

-- 18.20 Registrar onboarding de conductor
CREATE OR REPLACE FUNCTION register_driver_onboarding(
  p_full_name TEXT,
  p_phone TEXT,
  p_cedula_number TEXT,
  p_cedula_photo_url TEXT,
  p_license_number TEXT,
  p_license_photo_url TEXT,
  p_license_expiry_date DATE,
  p_profile_photo_url TEXT,
  p_vehicle_category vehicle_category,
  p_vehicle_brand TEXT,
  p_vehicle_model TEXT,
  p_vehicle_year INTEGER,
  p_vehicle_color TEXT,
  p_vehicle_plate TEXT,
  p_vehicle_photo_url TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  -- Actualizar perfil
  UPDATE profiles
  SET full_name = p_full_name,
      phone = p_phone,
      role = 'conductor',
      driver_status = 'pendiente',
      onboarding_completed = TRUE
  WHERE id = v_user_id;

  -- Insertar documentos
  INSERT INTO driver_documents (
    driver_id, cedula_number, cedula_photo_url,
    license_number, license_photo_url, license_expiry_date, profile_photo_url
  ) VALUES (
    v_user_id, p_cedula_number, p_cedula_photo_url,
    p_license_number, p_license_photo_url, p_license_expiry_date, p_profile_photo_url
  );

  -- Insertar vehículo
  INSERT INTO vehicles (
    driver_id, category, brand, model, year, color, plate, photo_url
  ) VALUES (
    v_user_id, p_vehicle_category, p_vehicle_brand, p_vehicle_model,
    p_vehicle_year, p_vehicle_color, p_vehicle_plate, p_vehicle_photo_url
  );

  -- Notificar a encargados
  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT id, 'Nuevo conductor pendiente',
         p_full_name || ' ha solicitado ser conductor',
         'driver_pending',
         jsonb_build_object('driver_id', v_user_id)
  FROM profiles WHERE role IN ('super_admin', 'encargado');

  RETURN jsonb_build_object('success', TRUE, 'status', 'pendiente');
END;
$$;

-- ============================================================
-- 19. ROW LEVEL SECURITY (RLS) - SEGURIDAD BLINDADA
-- ============================================================

-- Habilitar RLS en todas las tablas
ALTER TABLE profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicles ENABLE ROW LEVEL SECURITY;
ALTER TABLE driver_documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE wallets ENABLE ROW LEVEL SECURITY;
ALTER TABLE transactions ENABLE ROW LEVEL SECURITY;
ALTER TABLE rides ENABLE ROW LEVEL SECURITY;
ALTER TABLE coupons ENABLE ROW LEVEL SECURITY;
ALTER TABLE banners ENABLE ROW LEVEL SECURITY;
ALTER TABLE favorite_places ENABLE ROW LEVEL SECURITY;
ALTER TABLE exchange_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE notifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE zones ENABLE ROW LEVEL SECURITY;
ALTER TABLE vehicle_categories ENABLE ROW LEVEL SECURITY;

-- ============================================================
-- 19.1 PROFILES - Políticas
-- ============================================================

-- Usuario puede ver su propio perfil
CREATE POLICY "users_view_own_profile" ON profiles
  FOR SELECT USING (auth.uid() = id);

-- Usuario puede actualizar su propio perfil
CREATE POLICY "users_update_own_profile" ON profiles
  FOR UPDATE USING (auth.uid() = id);

-- Super Admin puede ver todos los perfiles
CREATE POLICY "super_admin_view_all_profiles" ON profiles
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'super_admin')
  );

-- Encargado puede ver conductores de su zona
CREATE POLICY "encargado_view_drivers" ON profiles
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'encargado')
    AND (role = 'conductor' OR role = 'cliente')
  );

-- Super Admin puede actualizar cualquier perfil
CREATE POLICY "super_admin_update_all_profiles" ON profiles
  FOR UPDATE USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'super_admin')
  );

-- Encargado puede actualizar conductores (aprobar/rechazar)
CREATE POLICY "encargado_update_drivers" ON profiles
  FOR UPDATE USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'encargado')
    AND role = 'conductor'
  );

-- ============================================================
-- 19.2 VEHICLES - Políticas
-- ============================================================

-- Conductor puede ver/editar sus propios vehículos
CREATE POLICY "driver_manage_own_vehicles" ON vehicles
  FOR ALL USING (auth.uid() = driver_id);

-- Cliente puede ver vehículos de conductores en viaje activo
CREATE POLICY "client_view_vehicle_in_active_ride" ON vehicles
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM rides r
      WHERE r.vehicle_id = vehicles.id
        AND r.client_id = auth.uid()
        AND r.status IN ('aceptada', 'en_ruta')
    )
  );

-- Super Admin puede ver todos los vehículos
CREATE POLICY "super_admin_view_all_vehicles" ON vehicles
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'super_admin')
  );

-- Encargado puede ver vehículos de conductores
CREATE POLICY "encargado_view_vehicles" ON vehicles
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'encargado')
  );

-- ============================================================
-- 19.3 DRIVER_DOCUMENTS - Políticas
-- ============================================================

-- Conductor puede ver/editar sus propios documentos
CREATE POLICY "driver_manage_own_documents" ON driver_documents
  FOR ALL USING (auth.uid() = driver_id);

-- Super Admin puede ver todos los documentos
CREATE POLICY "super_admin_view_all_documents" ON driver_documents
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'super_admin')
  );

-- Encargado puede ver documentos de conductores
CREATE POLICY "encargado_view_documents" ON driver_documents
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'encargado')
  );

-- ============================================================
-- 19.4 WALLETS - Políticas
-- ============================================================

-- Usuario puede ver su propia billetera
CREATE POLICY "user_view_own_wallet" ON wallets
  FOR SELECT USING (auth.uid() = user_id);

-- Super Admin puede ver todas las billeteras
CREATE POLICY "super_admin_view_all_wallets" ON wallets
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'super_admin')
  );

-- Encargado puede ver billeteras de conductores
CREATE POLICY "encargado_view_wallets" ON wallets
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'encargado')
  );

-- ============================================================
-- 19.5 TRANSACTIONS - Políticas
-- ============================================================

-- Usuario puede ver sus propias transacciones
CREATE POLICY "user_view_own_transactions" ON transactions
  FOR SELECT USING (auth.uid() = user_id);

-- Usuario puede crear transacciones (recargas)
CREATE POLICY "user_create_transactions" ON transactions
  FOR INSERT WITH CHECK (auth.uid() = user_id AND type = 'recarga');

-- Super Admin puede ver todas las transacciones
CREATE POLICY "super_admin_view_all_transactions" ON transactions
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'super_admin')
  );

-- Encargado puede ver transacciones de conductores
CREATE POLICY "encargado_view_transactions" ON transactions
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'encargado')
  );

-- ============================================================
-- 19.6 RIDES - Políticas (PRIVACIDAD BIDIRECCIONAL)
-- ============================================================

-- Cliente puede ver sus propios viajes
CREATE POLICY "client_view_own_rides" ON rides
  FOR SELECT USING (auth.uid() = client_id);

-- Conductor puede ver viajes que le han sido asignados
CREATE POLICY "driver_view_assigned_rides" ON rides
  FOR SELECT USING (auth.uid() = driver_id);

-- Conductor puede ver viajes disponibles (buscando) de su categoría
CREATE POLICY "driver_view_available_rides" ON rides
  FOR SELECT USING (
    auth.uid() IN (
      SELECT driver_id FROM vehicles
      WHERE is_active = TRUE
    )
    AND status = 'buscando'
  );

-- Cliente puede crear viajes
CREATE POLICY "client_create_rides" ON rides
  FOR INSERT WITH CHECK (auth.uid() = client_id);

-- Cliente puede actualizar sus propios viajes (cancelar)
CREATE POLICY "client_update_own_rides" ON rides
  FOR UPDATE USING (auth.uid() = client_id AND status IN ('buscando', 'aceptada'));

-- Conductor puede actualizar viajes asignados
CREATE POLICY "driver_update_assigned_rides" ON rides
  FOR UPDATE USING (auth.uid() = driver_id);

-- Super Admin puede ver todos los viajes
CREATE POLICY "super_admin_view_all_rides" ON rides
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'super_admin')
  );

-- Encargado puede ver viajes de su zona
CREATE POLICY "encargado_view_rides" ON rides
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'encargado')
  );

-- ============================================================
-- 19.7 COUPONS - Políticas
-- ============================================================

-- Todos pueden ver cupones activos
CREATE POLICY "public_view_active_coupons" ON coupons
  FOR SELECT USING (is_active = TRUE);

-- Super Admin puede gestionar cupones
CREATE POLICY "super_admin_manage_coupons" ON coupons
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'super_admin')
  );

-- ============================================================
-- 19.8 BANNERS - Políticas
-- ============================================================

-- Todos pueden ver banners activos
CREATE POLICY "public_view_active_banners" ON banners
  FOR SELECT USING (is_active = TRUE);

-- Super Admin puede gestionar banners
CREATE POLICY "super_admin_manage_banners" ON banners
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'super_admin')
  );

-- ============================================================
-- 19.9 FAVORITE_PLACES - Políticas
-- ============================================================

-- Usuario puede gestionar sus propios lugares favoritos
CREATE POLICY "user_manage_own_favorites" ON favorite_places
  FOR ALL USING (auth.uid() = user_id);

-- ============================================================
-- 19.10 EXCHANGE_RATES - Políticas
-- ============================================================

-- Todos pueden ver la tasa activa
CREATE POLICY "public_view_exchange_rates" ON exchange_rates
  FOR SELECT USING (is_active = TRUE);

-- Super Admin puede gestionar tasas
CREATE POLICY "super_admin_manage_exchange_rates" ON exchange_rates
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'super_admin')
  );

-- ============================================================
-- 19.11 NOTIFICATIONS - Políticas
-- ============================================================

-- Usuario puede ver sus propias notificaciones
CREATE POLICY "user_view_own_notifications" ON notifications
  FOR SELECT USING (auth.uid() = user_id);

-- Usuario puede marcar sus notificaciones como leídas
CREATE POLICY "user_update_own_notifications" ON notifications
  FOR UPDATE USING (auth.uid() = user_id);

-- Sistema puede crear notificaciones (via RPC SECURITY DEFINER)
CREATE POLICY "system_create_notifications" ON notifications
  FOR INSERT WITH CHECK (true);

-- ============================================================
-- 19.12 AUDIT_LOGS - Políticas
-- ============================================================

-- Solo Super Admin puede ver auditoría
CREATE POLICY "super_admin_view_audit_logs" ON audit_logs
  FOR SELECT USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'super_admin')
  );

-- Sistema puede crear logs (via RPC SECURITY DEFINER)
CREATE POLICY "system_create_audit_logs" ON audit_logs
  FOR INSERT WITH CHECK (true);

-- ============================================================
-- 19.13 ZONES - Políticas
-- ============================================================

-- Todos pueden ver zonas activas
CREATE POLICY "public_view_zones" ON zones
  FOR SELECT USING (is_active = TRUE);

-- Super Admin puede gestionar zonas
CREATE POLICY "super_admin_manage_zones" ON zones
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'super_admin')
  );

-- ============================================================
-- 19.14 VEHICLE_CATEGORIES - Políticas
-- ============================================================

-- Todos pueden ver categorías
CREATE POLICY "public_view_vehicle_categories" ON vehicle_categories
  FOR SELECT USING (is_active = TRUE);

-- Super Admin puede gestionar categorías
CREATE POLICY "super_admin_manage_vehicle_categories" ON vehicle_categories
  FOR ALL USING (
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'super_admin')
  );

-- ============================================================
-- 20. STORAGE BUCKETS
-- ============================================================

INSERT INTO storage.buckets (id, name, public) VALUES
  ('avatars', 'avatars', FALSE),
  ('documents', 'documents', FALSE),
  ('vehicles', 'vehicles', FALSE),
  ('payments', 'payments', FALSE),
  ('banners', 'banners', TRUE);

-- Storage policies
CREATE POLICY "users_upload_own_avatar" ON storage.objects
  FOR INSERT WITH CHECK (bucket_id = 'avatars' AND auth.uid()::text = (storage.foldername(name))[1]);

CREATE POLICY "users_view_own_avatar" ON storage.objects
  FOR SELECT USING (bucket_id = 'avatars' AND auth.uid()::text = (storage.foldername(name))[1]);

CREATE POLICY "users_upload_own_documents" ON storage.objects
  FOR INSERT WITH CHECK (bucket_id = 'documents' AND auth.uid()::text = (storage.foldername(name))[1]);

CREATE POLICY "super_admin_view_documents" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'documents' AND
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'super_admin')
  );

CREATE POLICY "encargado_view_documents" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'documents' AND
    EXISTS (SELECT 1 FROM profiles WHERE id = auth.uid() AND role = 'encargado')
  );

CREATE POLICY "users_upload_own_vehicle_photos" ON storage.objects
  FOR INSERT WITH CHECK (bucket_id = 'vehicles' AND auth.uid()::text = (storage.foldername(name))[1]);

CREATE POLICY "users_upload_own_payment_proofs" ON storage.objects
  FOR INSERT WITH CHECK (bucket_id = 'payments' AND auth.uid()::text = (storage.foldername(name))[1]);

CREATE POLICY "super_admin_manage_banners" ON storage.objects
  FOR ALL USING (bucket_id = 'banners');

CREATE POLICY "public_view_banners" ON storage.objects
  FOR SELECT USING (bucket_id = 'banners');

-- ============================================================
-- 21. ÍNDICES PARA RENDIMIENTO
-- ============================================================

CREATE INDEX idx_profiles_role ON profiles(role);
CREATE INDEX idx_profiles_driver_status ON profiles(driver_status);
CREATE INDEX idx_profiles_zone ON profiles(zone_id);
CREATE INDEX idx_rides_status ON rides(status);
CREATE INDEX idx_rides_client ON rides(client_id);
CREATE INDEX idx_rides_driver ON rides(driver_id);
CREATE INDEX idx_rides_created ON rides(created_at DESC);
CREATE INDEX idx_vehicles_driver ON vehicles(driver_id);
CREATE INDEX idx_vehicles_category ON vehicles(category);
CREATE INDEX idx_transactions_wallet ON transactions(wallet_id);
CREATE INDEX idx_transactions_status ON transactions(status);
CREATE INDEX idx_notifications_user ON notifications(user_id);
CREATE INDEX idx_notifications_read ON notifications(user_id, is_read);
CREATE INDEX idx_zones_type ON zones(zone_type);
CREATE INDEX idx_zones_active ON zones(is_active);
CREATE INDEX idx_favorites_user ON favorite_places(user_id);
CREATE INDEX idx_coupons_code ON coupons(code);
CREATE INDEX idx_banners_active ON banners(is_active);
CREATE INDEX idx_rides_geo ON rides USING GIST (
  ST_SetSRID(ST_MakePoint(destination_lng, destination_lat), 4326)
);

-- Índice espacial para zonas
CREATE INDEX idx_zones_polygon ON zones USING GIST (polygon);

-- ============================================================
-- 22. FUNCIÓN PARA CREAR PRIMER SUPER ADMIN
-- ============================================================

CREATE OR REPLACE FUNCTION promote_to_super_admin(p_email TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_user_id UUID;
BEGIN
  SELECT id INTO v_user_id FROM profiles WHERE email = p_email;
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'Usuario no encontrado';
  END IF;

  UPDATE profiles SET role = 'super_admin' WHERE id = v_user_id;

  RETURN jsonb_build_object('success', TRUE, 'user_id', v_user_id, 'role', 'super_admin');
END;
$$;

-- ============================================================
-- 23. PERMISOS PARA ROLES DE SUPABASE (OBLIGATORIO)
-- ============================================================

-- Otorgar acceso al schema public
GRANT USAGE ON SCHEMA public TO anon, authenticated, service_role;

-- Asegurar permisos para tablas futuras
ALTER DEFAULT PRIVILEGES IN SCHEMA public 
  GRANT ALL ON TABLES TO anon, authenticated, service_role;

-- Otorgar permisos a todas las tablas
GRANT ALL ON public.profiles TO anon, authenticated, service_role;
GRANT ALL ON public.vehicles TO anon, authenticated, service_role;
GRANT ALL ON public.driver_documents TO anon, authenticated, service_role;
GRANT ALL ON public.zones TO anon, authenticated, service_role;
GRANT ALL ON public.vehicle_categories TO anon, authenticated, service_role;
GRANT ALL ON public.rides TO anon, authenticated, service_role;
GRANT ALL ON public.wallets TO anon, authenticated, service_role;
GRANT ALL ON public.transactions TO anon, authenticated, service_role;
GRANT ALL ON public.coupons TO anon, authenticated, service_role;
GRANT ALL ON public.banners TO anon, authenticated, service_role;
GRANT ALL ON public.favorite_places TO anon, authenticated, service_role;
GRANT ALL ON public.exchange_rates TO anon, authenticated, service_role;
GRANT ALL ON public.notifications TO anon, authenticated, service_role;
GRANT ALL ON public.audit_logs TO anon, authenticated, service_role;

-- ============================================================
-- 24. CORRECCIÓN DEL TRIGGER (search_path OBLIGATORIO EN SUPABASE)
-- ============================================================

-- Recrear la función del trigger con search_path garantizado
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.profiles (id, full_name, email)
  VALUES (
    NEW.id,
    COALESCE(NEW.raw_user_meta_data->>'full_name', NEW.email),
    NEW.email
  );
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER SET search_path = public;

CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ============================================================
-- FIN DEL ESQUEMA
-- ============================================================
