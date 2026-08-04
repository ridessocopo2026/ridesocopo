-- ============================================================
-- RIDESOCOPÓ - Migración: CORRECCIÓN FINANZAS EFECTIVO
-- 1. Corregir case-sensitive (LOWER) en settle_ride_earnings
-- 2. Comisión de efectivo NO toca la billetera virtual
-- 3. Reconciliación total de wallets desde cero
-- ============================================================

-- ============================================================
-- 1. CORREGIR SETTLE_RIDE_EARNINGS con LOWER y lógica exacta
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

  IF EXISTS (SELECT 1 FROM driver_earnings WHERE ride_id = p_ride_id) THEN
    RETURN jsonb_build_object('success', TRUE, 'already_settled', TRUE);
  END IF;

  v_commission := COALESCE(v_ride.commission_usd, 0);
  v_method := LOWER(v_ride.payment_method);

  -- ============================================================
  -- Lógica exacta por método
  -- ============================================================
  IF v_method = 'efectivo' THEN
    -- El conductor YA cobró al cliente.
    -- La app NO le debe nada. La comisión NO toca la wallet.
    -- La comisión se muestra como deuda en efectivo (el conductor
    -- debe pagar a la plataforma aparte, por payouts/ajuste).
    v_cash := v_ride.final_fare_usd;
    v_app_credit := 0.00;
  ELSIF v_method = 'billetera' THEN
    -- Cliente pagó a la app. La app le debe al conductor.
    v_cash := 0.00;
    v_app_credit := GREATEST(v_ride.final_fare_usd - v_commission, 0);
  ELSE
    -- Pago Móvil u otro: solo acreditar si comprobante aprobado
    IF v_ride.proof_status = 'aprobado' THEN
      v_cash := 0.00;
      v_app_credit := GREATEST(v_ride.final_fare_usd - v_commission, 0);
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
    p_ride_id, v_ride.driver_id, v_ride.final_fare_usd, v_commission,
    v_cash, v_app_credit, v_method, 'completado'
  )
  ON CONFLICT (ride_id) DO UPDATE
  SET cash_received_usd = EXCLUDED.cash_received_usd,
      app_credit_usd = EXCLUDED.app_credit_usd,
      commission_usd = EXCLUDED.commission_usd,
      payment_method = EXCLUDED.payment_method;

  -- Acreditar en la wallet SOLO lo que la app realmente le debe
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
-- 2. CORREGIR CANCEL_RIDE: usar LOWER para comparar método
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
              'Reembolso de comisión por cancelación', p_ride_id);
    END IF;
  END IF;

  -- Reembolso al cliente
  IF v_method = 'billetera' AND v_ride.final_fare_usd > 0 THEN
    v_refund := GREATEST(v_ride.final_fare_usd - v_fee, 0);
    IF v_refund > 0 THEN
      SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.client_id;
      IF v_wallet.id IS NOT NULL THEN
        UPDATE wallets SET balance_usd = balance_usd + v_refund, updated_at = NOW()
        WHERE user_id = v_ride.client_id;
        INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
        VALUES (v_wallet.id, v_ride.client_id, 'credito', v_refund, 'completado',
                'Reembolso por cancelación', p_ride_id);
      END IF;
    END IF;
    v_ride.reimbursement_status := 'auto_completado';
  ELSIF v_method NOT IN ('billetera', 'efectivo') AND v_ride.final_fare_usd > 0 THEN
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

GRANT EXECUTE ON FUNCTION public.cancel_ride TO anon, authenticated, service_role;

-- ============================================================
-- 3. RECONCILIACIÓN TOTAL CON LÓGICA CORREGIDA
-- ============================================================
DO $$
DECLARE
  v_ride RECORD;
  v_wallet RECORD;
  v_method TEXT;
  v_cash NUMERIC;
  v_app_credit NUMERIC;
  v_commission NUMERIC;
  v_recon_cursor CURSOR FOR
    SELECT r.* FROM rides r
    WHERE r.status = 'completada' AND r.driver_id IS NOT NULL;
BEGIN
  -- Resetear wallets de conductores
  UPDATE wallets w SET balance_usd = 0, updated_at = NOW()
  FROM profiles p WHERE p.id = w.user_id AND p.role = 'conductor';

  -- Borrar transacciones históricas (se reconstruirán)
  DELETE FROM transactions t USING profiles p
  WHERE p.id = t.user_id AND p.role = 'conductor';

  -- Limpiar y reconstruir driver_earnings
  DELETE FROM driver_earnings;

  FOR v_ride IN v_recon_cursor LOOP
    v_commission := COALESCE(v_ride.commission_usd, 0);
    v_method := LOWER(COALESCE(v_ride.payment_method, 'efectivo'));
    v_cash := 0;
    v_app_credit := 0;

    IF v_method = 'efectivo' THEN
      v_cash := v_ride.final_fare_usd;
    ELSIF v_method = 'billetera' THEN
      v_app_credit := GREATEST(v_ride.final_fare_usd - v_commission, 0);
    ELSE
      IF v_ride.proof_status = 'aprobado' THEN
        v_app_credit := GREATEST(v_ride.final_fare_usd - v_commission, 0);
      END IF;
    END IF;

    INSERT INTO driver_earnings (ride_id, driver_id, fare_usd, commission_usd,
      cash_received_usd, app_credit_usd, payment_method, status)
    VALUES (v_ride.id, v_ride.driver_id, v_ride.final_fare_usd, v_commission,
            v_cash, v_app_credit, v_method, 'completado');

    -- Solo sumar app_credit a la wallet (comisión NO se descuenta en efectivo)
    IF v_app_credit > 0 THEN
      SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.driver_id;
      IF v_wallet.id IS NOT NULL THEN
        UPDATE wallets SET balance_usd = balance_usd + v_app_credit, updated_at = NOW()
        WHERE user_id = v_ride.driver_id;

        INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
        VALUES (v_wallet.id, v_ride.driver_id, 'credito', v_app_credit, 'completado',
                CONCAT('Ganancia del viaje por ', v_method), v_ride.id);
      END IF;
    END IF;
  END LOOP;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (auth.uid(), 'RECONCILE_WALLETS_V2', 'wallet', NULL,
          jsonb_build_object('note', 'reconciliacion con LOWER y comision fuera de wallet'));
END;
$$;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'Migración de corrección efectivo completada' AS estado;