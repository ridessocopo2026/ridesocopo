-- ============================================================
-- RIDESOCOPÓ - Migración: BILLETERA AUTOMÁTICA
-- 1. Billetera ya no requiere comprobante (directo a conductores)
-- 2. Al solicitar con Billetera: valida saldo y debita la tarifa
-- 3. Al cancelar: reintegra el saldo al cliente
-- ============================================================

-- ============================================================
-- 1. Billetera sin comprobante (automático a conductores)
-- ============================================================
UPDATE payment_methods
SET proof_required = FALSE
WHERE name = 'Billetera';

-- ============================================================
-- 2. FUNCIÓN REQUEST_RIDE con débito de billetera
-- Si el método es Billetera: verifica saldo y descuenta.
-- (Se hace la validación ANTES de insertar el viaje para evitar
--  viajes sin fondos)
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

  -- Calcular tarifa
  v_fare := public.calculate_fare(
    p_origin_lat, p_origin_lng,
    p_dest_lat, p_dest_lng,
    p_category, p_coupon_code
  );

  -- Verificar método de pago válido
  IF NOT EXISTS (SELECT 1 FROM payment_methods WHERE name = p_payment_method AND is_active = TRUE) THEN
    RAISE EXCEPTION 'Método de pago no disponible';
  END IF;

  v_final_fare := (v_fare->>'final_fare')::NUMERIC;
  v_is_wallet := (p_payment_method = 'Billetera');

  -- ============================================================
  -- Si es Billetera: verificar saldo y DEBITAR de inmediato
  -- ============================================================
  IF v_is_wallet THEN
    SELECT * INTO v_wallet FROM wallets WHERE user_id = v_user_id;

    IF v_wallet.id IS NULL THEN
      RAISE EXCEPTION 'Billetera no encontrada';
    END IF;

    -- Saldo suficiente (incluye límite de deuda = 0 para clientes)
    IF v_wallet.balance_usd < v_final_fare THEN
      RAISE EXCEPTION USING MESSAGE = format('Saldo insuficiente en billetera. Necesitas $%s y tienes $%s', v_final_fare, v_wallet.balance_usd);
    END IF;

    -- Debitar tarifa del cliente
    UPDATE wallets
    SET balance_usd = balance_usd - v_final_fare,
        updated_at = NOW()
    WHERE user_id = v_user_id;

    -- Registrar transacción
    INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description)
    VALUES (v_wallet.id, v_user_id, 'debito', v_final_fare, 'completado',
            'Pago de viaje con billetera');
  END IF;

  -- ============================================================
  -- Crear el viaje
  -- ============================================================
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

  -- Notificar a conductores disponibles
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
    AND public.driver_has_vehicle_for_category(p_category) = TRUE;

  -- Auditoría
  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_user_id, 'REQUEST_RIDE', 'ride', v_ride_id,
          jsonb_build_object('fare', v_fare, 'wallet_debited', v_is_wallet));

  RETURN v_ride_id;
END;
$$;

-- ============================================================
-- 3. CANCEL_RIDE: reintegrar billetera si el viaje fue pagado
-- ============================================================
CREATE OR REPLACE FUNCTION public.cancel_ride(
  p_ride_id UUID,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_ride RECORD;
  v_wallet RECORD;
  v_other_user UUID;
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

  -- SI EL CLIENTE PAGÓ CON BILLETERA, REINTEGRAR SU SALDO
  IF v_ride.payment_method = 'Billetera' AND v_ride.final_fare_usd > 0 THEN
    SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.client_id;

    IF v_wallet.id IS NOT NULL THEN
      UPDATE wallets
      SET balance_usd = balance_usd + v_ride.final_fare_usd,
          updated_at = NOW()
      WHERE user_id = v_ride.client_id;

      INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
      VALUES (v_wallet.id, v_ride.client_id, 'credito', v_ride.final_fare_usd, 'completado',
              'Reembolso por cancelación del viaje', p_ride_id);
    END IF;
  END IF;

  UPDATE rides
  SET status = 'cancelada',
      cancelled_by = v_user_id,
      cancel_reason = p_reason
  WHERE id = p_ride_id;

  -- Notificar al otro usuario
  IF v_ride.client_id IS NOT NULL AND v_ride.driver_id IS NOT NULL THEN
    v_other_user := CASE WHEN v_user_id = v_ride.client_id THEN v_ride.driver_id ELSE v_ride.client_id END;

    PERFORM public.notify_user(
      v_other_user,
      'Viaje cancelado',
      COALESCE(p_reason, 'El viaje fue cancelado'),
      'ride_cancelled',
      jsonb_build_object('ride_id', p_ride_id)
    );
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'ride_id', p_ride_id);
END;
$$;

-- ============================================================
SELECT 'Migración de billetera automática completada' AS estado;