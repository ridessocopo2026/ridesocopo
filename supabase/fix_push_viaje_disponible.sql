-- ============================================================
-- RIDESOCOPÓ - FIX: PUSH "NUEVO VIAJE DISPONIBLE" NO LLEGA
--
-- CAUSA RAÍZ:
--   La función public.driver_has_vehicle_for_category(category)
--   filtra con auth.uid() del USUARIO QUE LLAMA la RPC.
--   - request_ride: la llama el CLIENTE → auth.uid() = cliente → FALSE
--   - approve_ride_proof: la llama el ADMIN → auth.uid() = admin → FALSE
--   → La notificación ride_available NUNCA se inserta → sin push.
--
-- SOLUCIÓN:
--   Reemplazar el filtro por una subconsulta directa a vehicles:
--     p.id IN (SELECT driver_id FROM vehicles WHERE is_active AND category = ...)
--   que NO depende del auth.uid() del llamador.
-- ============================================================

-- ============================================================
-- 1. REWRITE REQUEST_RIDE (efectivo/billetera)
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

  -- ✅ FIX: filtrar por subconsulta directa a vehicles (NO usar auth.uid())
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
    AND p.id IN (
      SELECT v.driver_id FROM vehicles v
      WHERE v.is_active = TRUE AND v.category = p_category
    );

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_user_id, 'REQUEST_RIDE', 'ride', v_ride_id,
          jsonb_build_object('fare', v_fare, 'wallet_debited', v_is_wallet));

  RETURN v_ride_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_ride TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_ride TO service_role;

-- ============================================================
-- 2. REWRITE REQUEST_RIDE_WITH_PROOF (Pago Móvil)
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
  ELSE
    -- ✅ FIX: solo notificar ride_available si NO se requiere comprobante
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
      AND p.id IN (
        SELECT v.driver_id FROM vehicles v
        WHERE v.is_active = TRUE AND v.category = p_category
      );
  END IF;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_user_id, 'REQUEST_RIDE_WITH_PROOF', 'ride', v_ride_id,
          jsonb_build_object('fare', v_fare, 'proof_required', v_proof_required));

  RETURN v_ride_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_ride_with_proof TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_ride_with_proof TO service_role;

-- ============================================================
-- 3. REWRITE APPROVE_RIDE_PROOF (admin aprueba Pago Móvil)
--    Mantiene la notificación al conductor (fix anterior) y
--    corrige el filtro de vehículos con subconsulta directa.
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
    -- ✅ FIX: subconsulta directa a vehicles (NO usar driver_has_vehicle_for_category)
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
        AND p.id IN (
          SELECT v.driver_id FROM vehicles v
          WHERE v.is_active = TRUE AND v.category = v_category
        );
    END IF;

    -- Si el viaje YA se completó → acreditar ganancia al conductor Y NOTIFICARLE
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

      -- Notificar al conductor (fix anterior) para que reciba el PUSH
      IF NOT EXISTS (
        SELECT 1 FROM notifications
        WHERE user_id = v_ride.driver_id
          AND type = 'payout_approved'
          AND data->>'ride_id' = p_ride_id::text
      ) THEN
        INSERT INTO notifications (user_id, title, body, type, data)
        VALUES (
          v_ride.driver_id,
          '💰 Pago aprobado',
          CONCAT('Tu ganancia de $', v_app_credit, ' por el Pago Móvil fue acreditada a tu saldo.'),
          'payout_approved',
          jsonb_build_object('ride_id', p_ride_id, 'amount', v_app_credit, 'url', '/conductor/billetera')
        );
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

GRANT EXECUTE ON FUNCTION public.approve_ride_proof TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_ride_proof TO service_role;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Fix push "Nuevo viaje disponible" aplicado' AS estado;