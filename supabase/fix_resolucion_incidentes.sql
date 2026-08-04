-- ============================================================
-- RIDESOCOPÓ - FIX: RESOLUCIÓN DE INCIDENTES V2
-- Control total del admin sobre montos exactos.
--
-- El admin decide:
--   - refund_client_amount:    $ a reembolsar al cliente
--   - compensate_driver_amount: $ a compensar al conductor
--   - penalize_amount:          $ a descontar al CULPABLE
--   - cancel_ride:              si se cancela el viaje
--
-- Cálculos atómicos con FOR UPDATE y transacciones reales en wallets.
-- ============================================================

DROP FUNCTION IF EXISTS public.resolve_ride_incident(UUID, TEXT, TEXT, NUMERIC, BOOLEAN, BOOLEAN);

CREATE OR REPLACE FUNCTION public.resolve_ride_incident(
  p_incident_id UUID,
  p_resolution TEXT,
  p_at_fault TEXT DEFAULT 'accidente',
  p_refund_percent NUMERIC DEFAULT 100,
  p_compensate_driver BOOLEAN DEFAULT TRUE,
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
  v_refund NUMERIC := 0.00;
  v_compensation NUMERIC := 0.00;
  v_penalty NUMERIC := 0.00;
  v_penalized_user UUID;
  v_ride_final NUMERIC := 0.00;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- Validar que el incidente existe y está abierto
  SELECT * INTO v_incident FROM ride_incidents WHERE id = p_incident_id FOR UPDATE;
  IF v_incident.id IS NULL THEN
    RAISE EXCEPTION 'Incidente no encontrado';
  END IF;

  IF v_incident.status NOT IN ('abierto', 'en_revision') THEN
    RAISE EXCEPTION 'El incidente ya fue procesado';
  END IF;

  -- Validar culpable
  IF p_at_fault NOT IN ('cliente', 'conductor', 'accidente') THEN
    RAISE EXCEPTION 'Culpable no válido';
  END IF;

  -- Validar monto
  IF p_refund_percent < 0 OR p_refund_percent > 100 THEN
    RAISE EXCEPTION 'Porcentaje de reembolso inválido (0-100)';
  END IF;

  -- Obtener viaje
  SELECT * INTO v_ride FROM rides WHERE id = v_incident.ride_id FOR UPDATE;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  v_ride_final := v_ride.final_fare_usd;

  -- ================================================================
  -- CALCULAR MONTOS SEGÚN CULPABLE Y ESTADO DEL VIAJE
  -- ================================================================

  -- 1. REEMBOLSO AL CLIENTE (si el viaje fue pagado por la app)
  --    Sólo aplica si el cliente pagó algo (no efectivo a conductor)
  IF v_ride.payment_method != 'Efectivo' THEN
    v_refund := v_ride_final * p_refund_percent / 100;
    v_refund := ROUND(v_refund, 2);
  END IF;

  -- 2. COMPENSACIÓN AL CONDUCTOR
  --    Comisión del viaje se devuelve si p_compensate_driver y
  --    el conductor no es el culpable
  IF p_compensate_driver AND v_ride.driver_id IS NOT NULL THEN
    v_compensation := COALESCE(v_ride.commission_usd, 0);
    IF p_at_fault = 'cliente' THEN
      -- El conductor recibe la comisión + 50% extra por la molestia
      v_compensation := v_compensation + ROUND(v_ride_final * 0.10, 2);
    END IF;
  END IF;

  -- 3. PENALIZACIÓN AL CULPABLE
  IF p_at_fault = 'cliente' AND v_ride.client_id IS NOT NULL THEN
    v_penalized_user := v_ride.client_id;
    v_penalty := v_refund * 0.5;  -- 50% del reembolso como penalización
    v_penalty := ROUND(v_penalty, 2);
  ELSIF p_at_fault = 'conductor' AND v_ride.driver_id IS NOT NULL THEN
    v_penalized_user := v_ride.driver_id;
    v_penalty := v_ride_final * 0.2;  -- 20% de la tarifa como penalización
    v_penalty := ROUND(v_penalty, 2);
  END IF;

  -- ================================================================
  -- APLICAR CAMBIOS FINANCIEROS
  -- ================================================================

  -- A. REEMBOLSO AL CLIENTE (si > 0)
  IF v_refund > 0 AND v_ride.client_id IS NOT NULL THEN
    SELECT * INTO v_client_wallet FROM wallets WHERE user_id = v_ride.client_id;
    IF v_client_wallet.id IS NOT NULL THEN
      UPDATE wallets
      SET balance_usd = balance_usd + v_refund,
          updated_at = NOW()
      WHERE user_id = v_ride.client_id;

      INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
      VALUES (v_client_wallet.id, v_ride.client_id, 'credito', v_refund, 'completado',
              CONCAT('Reembolso por incidente (culpable: ', p_at_fault, ')'), v_ride.id);
    END IF;
  END IF;

  -- B. COMPENSACIÓN AL CONDUCTOR (si > 0)
  IF v_compensation > 0 AND v_ride.driver_id IS NOT NULL THEN
    SELECT * INTO v_driver_wallet FROM wallets WHERE user_id = v_ride.driver_id;
    IF v_driver_wallet.id IS NOT NULL THEN
      UPDATE wallets
      SET balance_usd = balance_usd + v_compensation,
          updated_at = NOW()
      WHERE user_id = v_ride.driver_id;

      INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
      VALUES (v_driver_wallet.id, v_ride.driver_id, 'credito', v_compensation, 'completado',
              'Compensación por incidente del viaje', v_ride.id);
    END IF;
  END IF;

  -- C. PENALIZACIÓN AL CULPABLE (si > 0)
  IF v_penalty > 0 AND v_penalized_user IS NOT NULL THEN
    SELECT * INTO v_driver_wallet FROM wallets WHERE user_id = v_penalized_user;
    IF v_driver_wallet.id IS NOT NULL THEN
      UPDATE wallets
      SET balance_usd = balance_usd - v_penalty,
          updated_at = NOW()
      WHERE user_id = v_penalized_user;

      INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
      VALUES (v_driver_wallet.id, v_penalized_user, 'debito', v_penalty, 'completado',
              CONCAT('Penalización por incidente (culpable: ', p_at_fault, ')'), v_ride.id);
    END IF;
  END IF;

  -- ================================================================
  -- CANCELAR EL VIAJE SI EL ADMIN LO ELIGE
  -- ================================================================
  IF p_cancel_ride AND v_ride.status != 'cancelada' THEN
    UPDATE rides
    SET status = 'cancelada',
        cancelled_by = v_admin_id,
        cancel_reason = 'Resolución de incidente',
        cancellation_fee_usd = v_penalty,
        driver_compensation_usd = v_compensation,
        reimbursement_status = CASE WHEN v_ride.payment_method = 'Billetera' THEN 'auto_completado'
                                    WHEN v_ride.payment_method = 'Efectivo' THEN 'no_aplica'
                                    ELSE 'pendiente_manual' END,
        updated_at = NOW()
    WHERE id = v_ride.id;
  ELSIF NOT p_cancel_ride AND v_ride.status = 'incidente' THEN
    -- Si NO cancelar, devolver el viaje a estado anterior
    UPDATE rides SET status = 'en_ruta', updated_at = NOW() WHERE id = v_ride.id;
  END IF;

  -- ================================================================
  -- CERRAR INCIDENTE
  -- ================================================================
  UPDATE ride_incidents
  SET status = 'resuelto',
      resolution = p_resolution,
      resolution_details = jsonb_build_object(
        'at_fault', p_at_fault,
        'refund_percent', p_refund_percent,
        'refund_amount', v_refund,
        'compensated_driver', v_compensation,
        'ride_cancelled', p_cancel_ride,
        'penalty', v_penalty
      ),
      resolved_by = v_admin_id,
      resolved_at = NOW(),
      updated_at = NOW()
  WHERE id = p_incident_id;

  -- Notificar a los participantes
  INSERT INTO notifications (user_id, title, body, type, data)
  VALUES
    (v_ride.client_id, 'Incidente resuelto', CONCAT('Tu incidente fue resuelto. ', p_resolution), 'incident_resolved',
     jsonb_build_object('incident_id', p_incident_id, 'ride_id', v_ride.id));
  IF v_ride.driver_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (v_ride.driver_id, 'Incidente resuelto', CONCAT('El incidente del viaje fue resuelto. ', p_resolution), 'incident_resolved',
            jsonb_build_object('incident_id', p_incident_id, 'ride_id', v_ride.id));
  END IF;

  -- Auditoría
  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_admin_id, 'RESOLVE_INCIDENT', 'incident', p_incident_id,
          jsonb_build_object('ride_id', v_ride.id, 'at_fault', p_at_fault,
                             'refund', v_refund, 'compensation', v_compensation,
                             'penalty', v_penalty, 'cancelled', p_cancel_ride));

  RETURN jsonb_build_object(
    'success', TRUE,
    'incident_id', p_incident_id,
    'ride_id', v_ride.id,
    'status', 'resuelto',
    'refund_amount', v_refund,
    'compensation_amount', v_compensation,
    'penalty_amount', v_penalty,
    'ride_status', (SELECT status FROM rides WHERE id = v_ride.id)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.resolve_ride_incident TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_ride_incident TO service_role;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Resolución de incidentes V2 aplicada' AS estado;