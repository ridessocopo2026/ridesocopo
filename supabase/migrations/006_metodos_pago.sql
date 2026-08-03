-- ============================================================
-- RIDESOCOPÓ - Migración: MÉTODOS DE PAGO CONFIGURABLES
-- El Admin puede activar/desactivar métodos de pago de la app.
-- ============================================================

-- 1. TABLA payment_methods
CREATE TABLE IF NOT EXISTS payment_methods (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  name TEXT NOT NULL UNIQUE,
  description TEXT,
  icon TEXT,
  is_active BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. PERMISOS
GRANT ALL ON public.payment_methods TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;

-- 3. RLS
ALTER TABLE payment_methods ENABLE ROW LEVEL SECURITY;

-- Todos pueden ver métodos activos
DROP POLICY IF EXISTS "public_view_payment_methods" ON public.payment_methods;
CREATE POLICY "public_view_payment_methods" ON public.payment_methods
  FOR SELECT USING (is_active = TRUE);

-- Super Admin gestiona métodos
DROP POLICY IF EXISTS "super_admin_manage_payment_methods" ON public.payment_methods;
CREATE POLICY "super_admin_manage_payment_methods" ON public.payment_methods
  FOR ALL USING (public.get_user_role(auth.uid()) = 'super_admin');

-- 4. SEED DE MÉTODOS INICIALES
INSERT INTO payment_methods (name, description, icon) VALUES
  ('Billetera', 'Paga con tu saldo en la app', 'wallet'),
  ('Efectivo', 'Paga en efectivo al conductor', 'cash'),
  ('Pago Móvil', 'Paga por pago móvil directo', 'phone')
ON CONFLICT (name) DO NOTHING;

-- 5. FUNCIÓN: OBTENER MÉTODOS DE PAGO ACTIVOS
CREATE OR REPLACE FUNCTION public.get_active_payment_methods()
RETURNS SETOF payment_methods
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT * FROM payment_methods WHERE is_active = TRUE ORDER BY name;
$$;

GRANT EXECUTE ON FUNCTION public.get_active_payment_methods TO anon, authenticated, service_role;

-- 6. CONVERSIÓN DEL TIPO payment_method (manejar nombres dinámicos)
-- Como el enum payment_method solo permite 3 valores fijos pero ahora los métodos
-- son dinámicos, cambiamos rides.payment_method a TEXT para flexibilidad.
ALTER TABLE rides ALTER COLUMN payment_method DROP DEFAULT;
ALTER TABLE rides ALTER COLUMN payment_method TYPE TEXT USING payment_method::text;
ALTER TABLE rides ALTER COLUMN payment_method SET DEFAULT 'efectivo';

-- 7. ELIMINAR LAS VERSIONES ANTERIORES DE REQUEST_RIDE (para evitar sobrecarga)
DROP FUNCTION IF EXISTS public.request_ride(numeric, numeric, text, numeric, numeric, text, vehicle_category, payment_method, text);
DROP FUNCTION IF EXISTS public.request_ride(numeric, numeric, text, numeric, numeric, text, vehicle_category, text, text);
DROP FUNCTION IF EXISTS public.request_ride(numeric, numeric, text, numeric, numeric, text, vehicle_category, payment_method);

-- 8. RECREAR REQUEST_RIDE con p_payment_method TEXT
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

  -- Validar que el método de pago existe y está activo
  IF NOT EXISTS (SELECT 1 FROM payment_methods WHERE name = p_payment_method AND is_active = TRUE) THEN
    RAISE EXCEPTION 'Método de pago no disponible';
  END IF;

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

GRANT EXECUTE ON FUNCTION public.request_ride TO anon, authenticated, service_role;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'Migración de métodos de pago completada' AS estado;