-- ============================================================
-- RIDESOCOPÓ - Migración: CAMPOS DE PAGO + COMPROBANTES
-- ============================================================

-- 1. TABLA: CAMPOS CONFIGURABLES POR MÉTODO DE PAGO
CREATE TABLE IF NOT EXISTS payment_method_fields (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  payment_method_id UUID NOT NULL REFERENCES payment_methods(id) ON DELETE CASCADE,
  label TEXT NOT NULL,
  value TEXT NOT NULL,
  is_copyable BOOLEAN DEFAULT TRUE,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- 2. PERMISOS
GRANT ALL ON public.payment_method_fields TO anon, authenticated, service_role;

-- 3. RLS
ALTER TABLE payment_method_fields ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "public_view_payment_method_fields" ON public.payment_method_fields;
CREATE POLICY "public_view_payment_method_fields" ON public.payment_method_fields
  FOR SELECT USING (TRUE);
DROP POLICY IF EXISTS "super_admin_manage_payment_method_fields" ON public.payment_method_fields;
CREATE POLICY "super_admin_manage_payment_method_fields" ON public.payment_method_fields
  FOR ALL USING (public.get_user_role(auth.uid()) = 'super_admin');

-- 4. AGREGAR proof_required A payment_methods
ALTER TABLE payment_methods ADD COLUMN IF NOT EXISTS proof_required BOOLEAN DEFAULT FALSE;

-- Actualizar métodos iniciales: Efectivo NO requiere comprobante; los demás SÍ
UPDATE payment_methods SET proof_required = FALSE WHERE name = 'Efectivo';
UPDATE payment_methods SET proof_required = TRUE WHERE name IN ('Billetera', 'Pago Móvil');

-- 5. AGREGAR COLUMNAS DE COMPROBANTE A RIDES
ALTER TABLE rides ADD COLUMN IF NOT EXISTS proof_url TEXT;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS proof_status TEXT DEFAULT NULL;

-- 6. FUNCIÓN: SOLICITAR VIAJE CON COMPROBANTE
DROP FUNCTION IF EXISTS public.request_ride_with_proof(numeric, numeric, text, numeric, numeric, text, vehicle_category, text, text, text);
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

  -- Validar método de pago
  SELECT proof_required INTO v_proof_required
  FROM payment_methods WHERE name = p_payment_method AND is_active = TRUE;

  IF v_proof_required IS NULL THEN
    RAISE EXCEPTION 'Método de pago no disponible';
  END IF;

  -- Si el método requiere comprobante, debe enviarlo
  IF v_proof_required AND (p_proof_url IS NULL OR p_proof_url = '') THEN
    RAISE EXCEPTION 'Debes subir el comprobante del pago';
  END IF;

  -- Calcular tarifa con la lógica existente
  v_fare := public.calculate_fare(
    p_origin_lat, p_origin_lng,
    p_dest_lat, p_dest_lng,
    p_category, p_coupon_code
  );

  INSERT INTO rides (
    client_id, category,
    origin_lat, origin_lng, origin_address,
    destination_lat, destination_lng, destination_address,
    destination_barrio_id, destination_barrio_name,
    base_fare_usd, origin_surcharge_usd, destination_surcharge_usd,
    total_fare_usd, discount_usd, final_fare_usd,
    payment_method, status, proof_url, proof_status
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
    p_payment_method, 'buscando',
    CASE WHEN v_proof_required THEN p_proof_url ELSE NULL END,
    CASE WHEN v_proof_required THEN 'pendiente' ELSE 'aprobado' END
  ) RETURNING id INTO v_ride_id;

  -- Notificar al admin/encargado si requiere aprobación
  IF v_proof_required THEN
    INSERT INTO notifications (user_id, title, body, type, data)
    SELECT id, 'Comprobante por aprobar',
           'Nuevo comprobante de pago pendiente de revisión para un viaje',
           'proof_pending',
           jsonb_build_object('ride_id', v_ride_id)
    FROM profiles WHERE role IN ('super_admin', 'encargado');
  END IF;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_user_id, 'REQUEST_RIDE_WITH_PROOF', 'ride', v_ride_id, v_fare);

  RETURN v_ride_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_ride_with_proof TO anon, authenticated, service_role;

-- 7. FUNCIÓN: APROBAR/RECHAZAR COMPROBANTE
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
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF v_ride.proof_status != 'pendiente' THEN
    RAISE EXCEPTION 'El comprobante ya fue procesado';
  END IF;

  v_status := CASE WHEN p_approve THEN 'aprobado' ELSE 'rechazado' END;

  UPDATE rides SET proof_status = v_status WHERE id = p_ride_id;

  -- Notificar cliente
  INSERT INTO notifications (user_id, title, body, type, data)
  VALUES (
    v_ride.client_id,
    CASE WHEN p_approve THEN 'Comprobante aprobado' ELSE 'Comprobante rechazado' END,
    CASE WHEN p_approve THEN 'Tu pago fue aprobado. El viaje puede continuar.'
         ELSE 'Tu comprobante fue rechazado. Sube uno válido.' END,
    'proof_reviewed',
    jsonb_build_object('ride_id', p_ride_id, 'approved', p_approve)
  );

  RETURN jsonb_build_object('success', TRUE, 'proof_status', v_status);
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_ride_proof TO anon, authenticated, service_role;

-- 8. FUNCIÓN: LISTAR COMPROBANTES PENDIENTES
CREATE OR REPLACE FUNCTION public.get_pending_proofs()
RETURNS SETOF rides
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT * FROM rides
  WHERE proof_status = 'pendiente'
  ORDER BY created_at ASC;
$$;

GRANT EXECUTE ON FUNCTION public.get_pending_proofs TO anon, authenticated, service_role;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'Migración de comprobantes de pago completada' AS estado;