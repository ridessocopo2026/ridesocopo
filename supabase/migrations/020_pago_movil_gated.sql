-- ============================================================
-- RIDESOCOPÓ - Migración: PAGO MÓVIL GATED + COMISIÓN LIQUIDADA
-- 1. Viaje con Pago Móvil NO disponible hasta aprobación del admin
-- 2. accept_ride NO descuenta comisión anticipada
-- 3. settle_ride_earnings liquida la comisión según método
-- 4. approve_ride_proof acredita ganancia si viaje ya completado
-- ============================================================

-- ============================================================
-- 1. REQUEST_RIDE_WITH_PROOF: NO notificar a conductores si pendiente
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

  -- Notificar SOLO al admin/encargado para revisar comprobante
  IF v_proof_required THEN
    INSERT INTO notifications (user_id, title, body, type, data)
    SELECT id, 'Comprobante por aprobar',
           'Nuevo comprobante de pago pendiente de revisión para un viaje',
           'proof_pending',
           jsonb_build_object('ride_id', v_ride_id, 'url', '/admin/comprobantes')
    FROM profiles WHERE role IN ('super_admin', 'encargado');
  ELSE
    -- Si NO requiere comprobante (efectivo/billetera) → notificar conductores
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
  END IF;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_user_id, 'REQUEST_RIDE_WITH_PROOF', 'ride', v_ride_id,
          jsonb_build_object('fare', v_fare, 'proof_required', v_proof_required));

  RETURN v_ride_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_ride_with_proof TO anon, authenticated, service_role;

-- ============================================================
-- 2. APPROVE_RIDE_PROOF: al aprobar → notificar conductores
--    Si el viaje ya se completó → acreditar ganancia al conductor
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
      v_app_credit := GREATEST(v_ride.final_fare_usd - v_commission, 0);

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
          p_ride_id, v_ride.driver_id, v_ride.final_fare_usd, v_commission,
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

    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (v_ride.client_id, 'Viaje cancelado',
            'Tu viaje fue cancelado porque el comprobante fue rechazado. Solicita de nuevo con un pago válido.',
            'ride_cancelled', jsonb_build_object('ride_id', p_ride_id));
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'proof_status', v_status);
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_ride_proof TO anon, authenticated, service_role;

-- ============================================================
-- 3. GET_AVAILABLE_RIDES: excluir viajes con comprobante pendiente
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_available_rides()
RETURNS SETOF rides
LANGUAGE plpgsql
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
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_available_rides TO anon, authenticated, service_role;

-- ============================================================
-- 4. ACCEPT_RIDE: eliminar descuento de comisión anticipado
--    La comisión se liquida en settle_ride_earnings al completar
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

  SELECT driver_status INTO v_ride FROM profiles WHERE id = v_driver_id;
  IF v_ride.driver_status != 'aprobado' THEN
    RAISE EXCEPTION 'Conductor no aprobado';
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id AND status = 'buscando';
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no disponible';
  END IF;

  -- NO aceptar viajes con comprobante pendiente
  IF v_ride.proof_status = 'pendiente' THEN
    RAISE EXCEPTION 'Este viaje aún no está disponible. Esperando aprobación del pago.';
  END IF;

  SELECT * INTO v_vehicle FROM vehicles
  WHERE driver_id = v_driver_id AND category = v_ride.category AND is_active = TRUE
  LIMIT 1;

  IF v_vehicle.id IS NULL THEN
    RAISE EXCEPTION 'No tiene un vehículo activo de la categoría requerida';
  END IF;

  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_driver_id;

  -- Comisión calculada sobre final_fare_usd (para guardar en el viaje)
  v_commission := ROUND(COALESCE(v_ride.final_fare_usd, 0) * v_ride.commission_rate / 100, 2);

  -- NO descontar comisión aquí — se liquida al completar/aprobar

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

GRANT EXECUTE ON FUNCTION public.accept_ride TO anon, authenticated, service_role;

-- ============================================================
-- 5. SETTLE_RIDE_EARNINGS: liquidar comisión completa al completar
--    - Efectivo: descontar comisión (deuda a la app) -$0.20
--    - Billetera: acreditar neto +$1.80
--    - Pago Móvil aprobado: acreditar neto +$1.80
--    - Pago Móvil pendiente: no tocar wallet
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

  -- ============================================================
  -- LIQUIDACIÓN SEGÚN MÉTODO
  -- ============================================================
  IF v_method = 'efectivo' THEN
    -- El conductor YA cobró al cliente. La app NO le debe nada.
    -- Pero DEBE la comisión → descontar de su wallet (deuda)
    v_cash := v_ride.final_fare_usd;
    v_app_credit := 0.00;

    -- Descontar comisión de la wallet (queda negativa = deuda)
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
    -- Cliente pagó a la app. La app le debe neto al conductor.
    v_cash := 0.00;
    v_app_credit := GREATEST(v_ride.final_fare_usd - v_commission, 0);
  ELSE
    -- Pago Móvil: solo acreditar si comprobante aprobado
    IF v_ride.proof_status = 'aprobado' THEN
      v_cash := 0.00;
      v_app_credit := GREATEST(v_ride.final_fare_usd - v_commission, 0);
    ELSE
      -- Pendiente/rechazado: NO tocar wallet (esperar aprobación)
      v_cash := 0.00;
      v_app_credit := 0.00;
    END IF;
  END IF;

  -- Insertar historial exacto
  INSERT INTO driver_earnings (
    ride_id, driver_id, fare_usd, commission_usd,
    cash_received_usd, app_credit_usd, payment_method, status
  ) VALUES (
    p_ride_id, v_ride.driver_id, v_ride.final_fare_usd, v_commission,
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
      'fare', v_ride.final_fare_usd,
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

GRANT EXECUTE ON FUNCTION public.settle_ride_earnings TO anon, authenticated, service_role;

-- ============================================================
-- Verificación
-- ============================================================
SELECT 'Migración pago móvil gated completada' AS estado;