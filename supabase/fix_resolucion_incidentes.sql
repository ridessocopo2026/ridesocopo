-- ============================================================
-- RIDESOCOPÓ - RESOLUCIÓN DE INCIDENTES V3 FINAL
-- ============================================================
-- 🔑 Cambio clave: el admin introduce MONTOS EN DÓLARES explícitos.
--    Nada de porcentajes ambiguos ni cálculos ocultos.
--
-- Firma:
--   p_refund_client:    $ exacto a reembolsar al cliente
--   p_penalize_culpable: $ exacto a descontar al culpable
--   p_compensate_driver: $ exacto a compensar al conductor
--
-- Validaciones de integridad:
--   - 0 ≤ cada monto ≤ $999,999.99
--   - No se puede reembolsar más de lo que se pagó
--   - No se puede penalizar a un inocente
--   - La penalización no puede exceder el saldo del culpable
-- ============================================================

DROP FUNCTION IF EXISTS public.resolve_ride_incident(UUID, TEXT, TEXT, NUMERIC, BOOLEAN, BOOLEAN);

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
BEGIN
  -- ================================================================
  -- 1. VALIDACIONES DE SEGURIDAD
  -- ================================================================
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

  -- Validar montos no negativos y dentro de rango
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

  v_final_fare := COALESCE(v_ride.final_fare_usd, 0);

  -- Integridad: no reembolsar más de lo pagado (solo métodos digitales)
  IF v_ride.payment_method = 'Efectivo' THEN
    -- En efectivo el conductor ya cobró; NO se reembolsa al cliente.
    -- Si el admin pone refund > 0, es un error de lógica.
    IF p_refund_client > 0 THEN
      RAISE EXCEPTION 'El cliente pagó en efectivo (al conductor). No se puede reembolsar desde la app.';
    END IF;
  ELSIF p_refund_client > v_final_fare THEN
    RAISE EXCEPTION 'El reembolso ($%s) excede la tarifa pagada ($%s)', p_refund_client, v_final_fare;
  END IF;

  -- Integridad: no penalizar a un inocente
  IF p_at_fault = 'accidente' AND p_penalize_culpable > 0 THEN
    RAISE EXCEPTION 'No se puede penalizar a nadie en un accidente (no hay culpable)';
  END IF;

  -- Identificar al culpable (para penalizar correctamente)
  IF p_at_fault = 'cliente' THEN
    v_culpable_id := v_ride.client_id;
  ELSIF p_at_fault = 'conductor' THEN
    v_culpable_id := v_ride.driver_id;
  END IF;

  -- ================================================================
  -- 2. APLICAR CAMBIOS FINANCIEROS (atómico)
  -- ================================================================

  -- 2A. REEMBOLSO AL CLIENTE
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

  -- 2B. COMPENSACIÓN AL CONDUCTOR
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
            'Compensación por incidente del viaje', v_ride.id);
  END IF;

  -- 2C. PENALIZACIÓN AL CULPABLE
  IF p_penalize_culpable > 0 AND v_culpable_id IS NOT NULL THEN
    SELECT * INTO v_culpable_wallet FROM wallets WHERE user_id = v_culpable_id;
    IF v_culpable_wallet.id IS NULL THEN
      RAISE EXCEPTION 'Billetera del culpable no encontrada';
    END IF;
    -- No dejar saldo negativo más allá del límite
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

  -- ================================================================
  -- 3. ACTUALIZAR VIAJE
  -- ================================================================
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

  -- ================================================================
  -- 4. CERRAR INCIDENTE (guardar TODOS los montos en JSONB)
  -- ================================================================
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

GRANT EXECUTE ON FUNCTION public.resolve_ride_incident TO authenticated;
GRANT EXECUTE ON FUNCTION public.resolve_ride_incident TO service_role;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Resolución de incidentes V3 (montos en $) aplicada' AS estado;