-- ============================================================
-- RIDESOCOPÓ - Migración: FIX PUSH "NUEVO VIAJE DISPONIBLE"
-- El filtro is_online=TRUE impedía que se creara la notificación
-- ride_available si el conductor no estaba "en línea" exactamente
-- en ese instante -> sin notificación -> sin push.
-- Ahora se notifica a TODOS los conductores aprobados con vehículo
-- de la categoría del viaje (el push sirve para avisarle incluso
-- si no está activo en la app).
-- ============================================================

-- ============================================================
-- 1. REQUEST_RIDE (efectivo/billetera): quitar is_online
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

  IF v_is_wallet THEN
    SELECT * INTO v_wallet FROM wallets WHERE user_id = v_user_id;

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
    v_final_fare,
    p_payment_method, 'buscando'
  ) RETURNING id INTO v_ride_id;

  -- NOTIFICAR a TODOS los conductores aprobados con vehículo
  -- de la categoría (SIN filtro is_online: el push avisa aunque
  -- el conductor no esté activo en la app en ese instante).
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
    AND public.driver_has_vehicle_for_category(p_category) = TRUE;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_user_id, 'REQUEST_RIDE', 'ride', v_ride_id,
          jsonb_build_object('fare', v_fare, 'wallet_debited', v_is_wallet));

  RETURN v_ride_id;
END;
$$;

-- ============================================================
-- 2. REQUEST_RIDE_WITH_PROOF (Pago Móvil): quitar is_online
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

  IF v_proof_required THEN
    INSERT INTO notifications (user_id, title, body, type, data)
    SELECT id, 'Comprobante por aprobar',
           'Nuevo comprobante de pago pendiente de revisión para un viaje',
           'proof_pending',
           jsonb_build_object('ride_id', v_ride_id, 'url', '/admin/comprobantes')
    FROM profiles WHERE role IN ('super_admin', 'encargado');
  END IF;

  -- Notificar a TODOS los conductores aprobados (SIN is_online)
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
    AND public.driver_has_vehicle_for_category(p_category) = TRUE;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_user_id, 'REQUEST_RIDE_WITH_PROOF', 'ride', v_ride_id, v_fare);

  RETURN v_ride_id;
END;
$$;

-- ============================================================
SELECT 'Fix push ride_available aplicado' AS estado;