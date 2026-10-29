-- ============================================================
-- 115 - RESOLUCION DE INCIDENTES DE CANCELACION
-- ------------------------------------------------------------
-- Aprueba o exime el cargo pendiente, completa el reembolso
-- manual y paga solo el delta de compensacion (sin duplicar).
-- ============================================================

-- ============================================================
-- 5. RESOLVE_RIDE_INCIDENT
--    · 'cancelacion_cliente': aprueba o exime el cargo pendiente,
--      completa el reembolso manual y paga SOLO el delta de
--      compensación (nunca dos veces).
--    · Resto de incidentes: misma lógica que antes.
-- ============================================================
CREATE OR REPLACE FUNCTION public.resolve_ride_incident(
  p_incident_id UUID,
  p_resolution TEXT,
  p_at_fault TEXT DEFAULT 'accidente',
  p_refund_client NUMERIC DEFAULT 0,
  p_penalize_culpable NUMERIC DEFAULT 0,
  p_compensate_driver NUMERIC DEFAULT 0,
  p_cancel_ride BOOLEAN DEFAULT TRUE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_incident RECORD;
  v_ride RECORD;
  v_client_wallet RECORD;
  v_driver_wallet RECORD;
  v_culpable_wallet RECORD;
  v_culpable_id UUID;
  v_final_fare NUMERIC;
  v_charge RECORD;
  v_refund_txn RECORD;
  v_delta_comp NUMERIC := 0.00;
  v_charge_approved NUMERIC := 0.00;
  v_compensation_total NUMERIC := 0.00;
  v_charge_waived BOOLEAN := FALSE;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT * INTO v_incident FROM ride_incidents WHERE id = p_incident_id FOR UPDATE;
  IF v_incident.id IS NULL THEN
    RAISE EXCEPTION 'Incidente no encontrado';
  END IF;

  IF v_incident.status NOT IN ('abierto', 'en_revision') THEN
    RAISE EXCEPTION 'El incidente ya fue procesado';
  END IF;

  IF p_at_fault NOT IN ('cliente', 'conductor', 'accidente') THEN
    RAISE EXCEPTION 'Culpable no válido';
  END IF;

  IF p_refund_client < 0 OR p_refund_client > 999999.99 THEN
    RAISE EXCEPTION 'Reembolso al cliente inválido (0 - 999999.99)';
  END IF;
  IF p_penalize_culpable < 0 OR p_penalize_culpable > 999999.99 THEN
    RAISE EXCEPTION 'Penalización inválida (0 - 999999.99)';
  END IF;
  IF p_compensate_driver < 0 OR p_compensate_driver > 999999.99 THEN
    RAISE EXCEPTION 'Compensación al conductor inválida (0 - 999999.99)';
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = v_incident.ride_id FOR UPDATE;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF public.get_user_role(v_admin_id) = 'encargado'
     AND COALESCE(v_ride.origin_zone_id, '00000000-0000-0000-0000-000000000000') != public.caller_zone_id() THEN
    RAISE EXCEPTION 'No autorizado para incidentes de otra ciudad';
  END IF;

  v_final_fare := COALESCE(v_ride.final_fare_usd, 0);

  -- ==========================================================
  -- 5.1 CANCELACIÓN EN CURSO
  -- ==========================================================
  IF v_incident.incident_type = 'cancelacion_cliente' THEN
    -- (a) Cargo pendiente al cliente (efectivo)
    SELECT * INTO v_charge
    FROM transactions
    WHERE ride_id = v_ride.id
      AND type = 'debito'
      AND status = 'pendiente'
      AND description LIKE 'Cargo por cancelación%'
    ORDER BY created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF v_charge.id IS NOT NULL THEN
      IF p_at_fault = 'cliente' AND p_penalize_culpable > 0 THEN
        SELECT * INTO v_culpable_wallet FROM wallets WHERE user_id = v_ride.client_id;
        IF v_culpable_wallet.id IS NULL THEN
          RAISE EXCEPTION 'Billetera del cliente no encontrada';
        END IF;
        IF v_culpable_wallet.balance_usd - p_penalize_culpable < -COALESCE(v_culpable_wallet.debt_limit_usd, 5.00) THEN
          RAISE EXCEPTION 'El cargo excede el límite de deuda del cliente';
        END IF;

        UPDATE wallets
        SET balance_usd = balance_usd - p_penalize_culpable, updated_at = NOW()
        WHERE user_id = v_ride.client_id;

        UPDATE transactions
        SET amount_usd = p_penalize_culpable,
            status = 'completado',
            reviewed_by = v_admin_id,
            reviewed_at = NOW(),
            description = 'Cargo por cancelación en curso (efectivo) — aprobado'
        WHERE id = v_charge.id;

        v_charge_approved := p_penalize_culpable;

        PERFORM public.notify_user(
          v_ride.client_id,
          'Cargo por cancelación aprobado',
          CONCAT('Se cobraron $', p_penalize_culpable, ' de tu billetera por cancelar un viaje en curso.'),
          'cancellation_charge_approved',
          jsonb_build_object('ride_id', v_ride.id, 'amount', p_penalize_culpable)
        );
      ELSE
        UPDATE transactions
        SET status = 'rechazado',
            reviewed_by = v_admin_id,
            reviewed_at = NOW(),
            description = 'Cargo por cancelación en curso (efectivo) — eximido'
        WHERE id = v_charge.id;
        v_charge_waived := TRUE;

        PERFORM public.notify_user(
          v_ride.client_id,
          'Cargo por cancelación eximido',
          'Un administrador revisó la cancelación y no se te cobrará el cargo pendiente.',
          'cancellation_charge_waived',
          jsonb_build_object('ride_id', v_ride.id)
        );
      END IF;
    END IF;

    -- (b) Reembolso manual pendiente (Pago Móvil / otros)
    SELECT * INTO v_refund_txn
    FROM transactions
    WHERE ride_id = v_ride.id
      AND type = 'credito'
      AND status = 'pendiente'
      AND description LIKE 'Reembolso pendiente%'
    ORDER BY created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF v_refund_txn.id IS NOT NULL THEN
      SELECT * INTO v_client_wallet FROM wallets WHERE user_id = v_ride.client_id;
      IF v_client_wallet.id IS NOT NULL THEN
        UPDATE wallets
        SET balance_usd = balance_usd + v_refund_txn.amount_usd, updated_at = NOW()
        WHERE user_id = v_ride.client_id;

        UPDATE transactions
        SET status = 'completado', reviewed_by = v_admin_id, reviewed_at = NOW()
        WHERE id = v_refund_txn.id;

        PERFORM public.notify_user(
          v_ride.client_id,
          'Reembolso completado',
          CONCAT('Se reembolsaron $', v_refund_txn.amount_usd, ' a tu billetera.'),
          'refund_completed',
          jsonb_build_object('ride_id', v_ride.id, 'amount', v_refund_txn.amount_usd)
        );
      END IF;
    END IF;

    -- (c) Penalización al conductor (si el admin lo decide)
    IF p_at_fault = 'conductor' AND p_penalize_culpable > 0 AND v_ride.driver_id IS NOT NULL THEN
      SELECT * INTO v_culpable_wallet FROM wallets WHERE user_id = v_ride.driver_id;
      IF v_culpable_wallet.id IS NULL THEN
        RAISE EXCEPTION 'Billetera del conductor no encontrada';
      END IF;
      IF v_culpable_wallet.balance_usd - p_penalize_culpable < -COALESCE(v_culpable_wallet.debt_limit_usd, 5.00) THEN
        RAISE EXCEPTION 'La penalización excede el límite de deuda del conductor';
      END IF;

      UPDATE wallets
      SET balance_usd = balance_usd - p_penalize_culpable, updated_at = NOW()
      WHERE user_id = v_ride.driver_id;

      INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
      VALUES (v_culpable_wallet.id, v_ride.driver_id, 'debito', p_penalize_culpable, 'completado',
              'Penalización por cancelación en curso', v_ride.id);
    END IF;

    -- (d) Compensación adicional: solo el delta no pagado aún
    v_delta_comp := GREATEST(COALESCE(p_compensate_driver, 0) - COALESCE(v_ride.driver_compensation_usd, 0), 0);

    IF v_delta_comp > 0 AND v_ride.driver_id IS NOT NULL THEN
      SELECT * INTO v_driver_wallet FROM wallets WHERE user_id = v_ride.driver_id;
      IF v_driver_wallet.id IS NOT NULL THEN
        UPDATE wallets
        SET balance_usd = balance_usd + v_delta_comp, updated_at = NOW()
        WHERE user_id = v_ride.driver_id;

        INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
        VALUES (v_driver_wallet.id, v_ride.driver_id, 'credito', v_delta_comp, 'completado',
                'Compensación adicional por cancelación', v_ride.id);

        PERFORM public.notify_user(
          v_ride.driver_id,
          'Compensación adicional',
          CONCAT('Se te acreditaron $', v_delta_comp, ' adicionales por la cancelación del viaje.'),
          'driver_compensation',
          jsonb_build_object('ride_id', v_ride.id, 'amount', v_delta_comp)
        );
      END IF;
    END IF;

    v_compensation_total := GREATEST(COALESCE(v_ride.driver_compensation_usd, 0), COALESCE(p_compensate_driver, 0));

    -- (e) Actualizar viaje
    UPDATE rides
    SET cancellation_fee_usd = CASE WHEN v_charge.id IS NOT NULL THEN v_charge_approved ELSE v_ride.cancellation_fee_usd END,
        driver_compensation_usd = v_compensation_total,
        reimbursement_status = CASE WHEN v_refund_txn.id IS NOT NULL THEN 'auto_completado' ELSE v_ride.reimbursement_status END,
        updated_at = NOW()
    WHERE id = v_ride.id;

    -- (f) Resolver incidente
    UPDATE ride_incidents
    SET status = 'resuelto',
        resolution = p_resolution,
        resolution_details = jsonb_build_object(
          'at_fault', p_at_fault,
          'fare', v_final_fare,
          'refund_client', COALESCE(v_refund_txn.amount_usd, 0),
          'penalty', v_charge_approved,
          'compensate_driver', v_compensation_total,
          'ride_cancelled', TRUE,
          'charge_pending', (v_charge.id IS NOT NULL),
          'charge_waived', v_charge_waived,
          'payment_method', v_ride.payment_method
        ),
        resolved_by = v_admin_id,
        resolved_at = NOW(),
        updated_at = NOW()
    WHERE id = p_incident_id;

    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES
      (v_ride.client_id, 'Incidente resuelto', CONCAT('Tu incidente fue resuelto. ', p_resolution), 'incident_resolved',
       jsonb_build_object('incident_id', p_incident_id, 'ride_id', v_ride.id));

    IF v_ride.driver_id IS NOT NULL THEN
      INSERT INTO notifications (user_id, title, body, type, data)
      VALUES (v_ride.driver_id, 'Incidente resuelto', CONCAT('El incidente del viaje fue resuelto. ', p_resolution), 'incident_resolved',
              jsonb_build_object('incident_id', p_incident_id, 'ride_id', v_ride.id));
    END IF;

    INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
    VALUES (v_admin_id, 'RESOLVE_INCIDENT', 'incident', p_incident_id,
            jsonb_build_object('ride_id', v_ride.id, 'type', 'cancelacion_cliente',
                               'at_fault', p_at_fault,
                               'charge_approved', v_charge_approved,
                               'charge_waived', v_charge_waived,
                               'refund_completed', (v_refund_txn.id IS NOT NULL),
                               'compensate_driver', v_compensation_total));

    RETURN jsonb_build_object(
      'success', TRUE,
      'incident_id', p_incident_id,
      'ride_id', v_ride.id,
      'status', 'resuelto',
      'charge_approved', v_charge_approved,
      'charge_waived', v_charge_waived,
      'refund_completed', (v_refund_txn.id IS NOT NULL),
      'compensate_driver', v_compensation_total,
      'ride_status', (SELECT status FROM rides WHERE id = v_ride.id)
    );
  END IF;

  -- ==========================================================
  -- 5.2 RESTO DE INCIDENTES (lógica anterior)
  -- ==========================================================
  IF v_ride.payment_method = 'Efectivo' THEN
    IF p_refund_client > 0 THEN
      RAISE EXCEPTION 'El cliente pagó en efectivo (al conductor). No se puede reembolsar desde la app.';
    END IF;
  ELSIF p_refund_client > v_final_fare THEN
    RAISE EXCEPTION 'El reembolso ($%s) excede la tarifa pagada ($%s)', p_refund_client, v_final_fare;
  END IF;

  IF p_at_fault = 'accidente' AND p_penalize_culpable > 0 THEN
    RAISE EXCEPTION 'No se puede penalizar a nadie en un accidente (no hay culpable)';
  END IF;

  IF p_at_fault = 'cliente' THEN
    v_culpable_id := v_ride.client_id;
  ELSIF p_at_fault = 'conductor' THEN
    v_culpable_id := v_ride.driver_id;
  END IF;

  IF p_refund_client > 0 AND v_ride.client_id IS NOT NULL THEN
    SELECT * INTO v_client_wallet FROM wallets WHERE user_id = v_ride.client_id;
    IF v_client_wallet.id IS NULL THEN
      RAISE EXCEPTION 'Billetera del cliente no encontrada';
    END IF;
    UPDATE wallets
    SET balance_usd = balance_usd + p_refund_client, updated_at = NOW()
    WHERE user_id = v_ride.client_id;
    INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
    VALUES (v_client_wallet.id, v_ride.client_id, 'credito', p_refund_client, 'completado',
            CONCAT('Reembolso por incidente (culpable: ', p_at_fault, ')'), v_ride.id);
  END IF;

  IF p_compensate_driver > 0 AND v_ride.driver_id IS NOT NULL THEN
    SELECT * INTO v_driver_wallet FROM wallets WHERE user_id = v_ride.driver_id;
    IF v_driver_wallet.id IS NULL THEN
      RAISE EXCEPTION 'Billetera del conductor no encontrada';
    END IF;
    UPDATE wallets
    SET balance_usd = balance_usd + p_compensate_driver, updated_at = NOW()
    WHERE user_id = v_ride.driver_id;
    INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
    VALUES (v_driver_wallet.id, v_ride.driver_id, 'credito', p_compensate_driver, 'completado',
            CONCAT('Compensación por incidente (culpable: ', p_at_fault, ')'), v_ride.id);
  END IF;

  IF p_penalize_culpable > 0 AND v_culpable_id IS NOT NULL THEN
    SELECT * INTO v_culpable_wallet FROM wallets WHERE user_id = v_culpable_id;
    IF v_culpable_wallet.id IS NULL THEN
      RAISE EXCEPTION 'Billetera del culpable no encontrada';
    END IF;
    IF v_culpable_wallet.balance_usd - p_penalize_culpable < -COALESCE(v_culpable_wallet.debt_limit_usd, 5.00) THEN
      RAISE EXCEPTION 'La penalización excede el límite de deuda del culpable';
    END IF;

    UPDATE wallets
    SET balance_usd = balance_usd - p_penalize_culpable, updated_at = NOW()
    WHERE user_id = v_culpable_id;

    INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
    VALUES (v_culpable_wallet.id, v_culpable_id, 'debito', p_penalize_culpable, 'completado',
            CONCAT('Penalización por incidente (culpable: ', p_at_fault, ')'), v_ride.id);
  END IF;

  IF p_cancel_ride AND v_ride.status != 'cancelada' THEN
    UPDATE rides
    SET status = 'cancelada',
        cancelled_by = v_admin_id,
        cancel_reason = 'Resolución de incidente',
        cancellation_fee_usd = p_penalize_culpable,
        driver_compensation_usd = p_compensate_driver,
        reimbursement_status = CASE WHEN v_ride.payment_method = 'Billetera' THEN 'auto_completado'
                                    WHEN v_ride.payment_method = 'Efectivo' THEN 'no_aplica'
                                    ELSE 'pendiente_manual' END,
        updated_at = NOW()
    WHERE id = v_ride.id;
  ELSIF NOT p_cancel_ride AND v_ride.status = 'incidente' THEN
    UPDATE rides SET status = 'en_ruta', updated_at = NOW() WHERE id = v_ride.id;
  END IF;

  UPDATE ride_incidents
  SET status = 'resuelto',
      resolution = p_resolution,
      resolution_details = jsonb_build_object(
        'at_fault', p_at_fault,
        'fare', v_final_fare,
        'refund_client', p_refund_client,
        'penalty', p_penalize_culpable,
        'compensate_driver', p_compensate_driver,
        'ride_cancelled', p_cancel_ride,
        'payment_method', v_ride.payment_method
      ),
      resolved_by = v_admin_id,
      resolved_at = NOW(),
      updated_at = NOW()
  WHERE id = p_incident_id;

  INSERT INTO notifications (user_id, title, body, type, data)
  VALUES
    (v_ride.client_id, 'Incidente resuelto', CONCAT('Tu incidente fue resuelto. ', p_resolution), 'incident_resolved',
     jsonb_build_object('incident_id', p_incident_id, 'ride_id', v_ride.id));

  IF v_ride.driver_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (v_ride.driver_id, 'Incidente resuelto', CONCAT('El incidente del viaje fue resuelto. ', p_resolution), 'incident_resolved',
            jsonb_build_object('incident_id', p_incident_id, 'ride_id', v_ride.id));
  END IF;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_admin_id, 'RESOLVE_INCIDENT', 'incident', p_incident_id,
          jsonb_build_object('ride_id', v_ride.id, 'at_fault', p_at_fault,
                             'refund_client', p_refund_client,
                             'penalty', p_penalize_culpable,
                             'compensate_driver', p_compensate_driver,
                             'cancelled', p_cancel_ride));

  RETURN jsonb_build_object(
    'success', TRUE,
    'incident_id', p_incident_id,
    'ride_id', v_ride.id,
    'status', 'resuelto',
    'refund_client', p_refund_client,
    'penalty', p_penalize_culpable,
    'compensate_driver', p_compensate_driver,
    'ride_status', (SELECT status FROM rides WHERE id = v_ride.id)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.resolve_ride_incident TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.resolve_ride_incident FROM anon;
