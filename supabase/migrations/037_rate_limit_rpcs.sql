-- ============================================================
-- RIDESOCOPÓ - Migración 037: RATE LIMITING EN RPCS DE VIAJES
-- Conecta guard_rate_limit (creada en 036) a las funciones que
-- mueven estado/dinero de viajes, para evitar abuso y DoS de costo:
--   - cancel_ride           20 llamadas/min
--   - accept_ride           30 llamadas/min
--   - complete_ride         30 llamadas/min
--   - report_ride_incident   5 llamadas/min
-- Requiere que la migración 036 esté aplicada (rpc_audit + guard).
-- ============================================================

-- ============================================================
-- 1. CANCEL_RIDE con rate limit
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

  PERFORM public.guard_rate_limit('cancel_ride', 20);

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

GRANT EXECUTE ON FUNCTION public.cancel_ride TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.cancel_ride FROM anon;

-- ============================================================
-- 2. ACCEPT_RIDE con rate limit
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

  PERFORM public.guard_rate_limit('accept_ride', 30);

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

GRANT EXECUTE ON FUNCTION public.accept_ride TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.accept_ride FROM anon;

-- ============================================================
-- 3. COMPLETE_RIDE con rate limit
-- ============================================================
CREATE OR REPLACE FUNCTION public.complete_ride(
  p_ride_id UUID,
  p_rating INTEGER DEFAULT NULL,
  p_review TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_ride RECORD;
  v_settlement JSONB;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('complete_ride', 30);

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF v_ride.driver_id != v_user_id AND v_ride.client_id != v_user_id THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF v_ride.status NOT IN ('aceptada', 'en_ruta') THEN
    RAISE EXCEPTION 'Estado inválido';
  END IF;

  UPDATE rides
  SET status = 'completada',
      completed_at = NOW(),
      rating = COALESCE(p_rating, rating),
      review = COALESCE(p_review, review)
  WHERE id = p_ride_id;

  -- Liquidar ganancias exactas (inserta en driver_earnings)
  IF v_ride.driver_id IS NOT NULL THEN
    v_settlement := public.settle_ride_earnings(p_ride_id);
  END IF;

  -- Notificar
  IF v_user_id = v_ride.driver_id THEN
    PERFORM public.notify_user(
      v_ride.client_id, 'Viaje completado', 'Tu viaje ha finalizado',
      'ride_completed', jsonb_build_object('ride_id', p_ride_id, 'url', '/cliente/viaje/' || p_ride_id)
    );
  ELSE
    PERFORM public.notify_user(
      v_ride.driver_id, 'Viaje completado', 'El viaje ha finalizado',
      'ride_completed', jsonb_build_object('ride_id', p_ride_id, 'url', '/conductor/viaje/' || p_ride_id)
    );
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'ride_id', p_ride_id, 'settlement', v_settlement);
END;
$$;

GRANT EXECUTE ON FUNCTION public.complete_ride TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.complete_ride FROM anon;

-- ============================================================
-- 4. REPORT_RIDE_INCIDENT con rate limit
-- ============================================================
CREATE OR REPLACE FUNCTION public.report_ride_incident(
  p_ride_id UUID,
  p_incident_type TEXT,
  p_description TEXT DEFAULT NULL,
  p_photo_urls JSONB DEFAULT '[]'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_ride RECORD;
  v_incident_id UUID;
  v_is_dispute BOOLEAN;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('report_ride_incident', 5);

  -- Validar tipo
  IF p_incident_type NOT IN ('accidente', 'falla_mecanica', 'urgencia_medica', 'clima', 'otro',
                             'viaje_no_realizado', 'disputa_cobro') THEN
    RAISE EXCEPTION 'Tipo de incidente no válido';
  END IF;

  -- Obtener viaje con bloqueo
  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id FOR UPDATE;

  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  -- Solo participantes del viaje pueden reportar
  IF v_ride.client_id != v_user_id AND v_ride.driver_id != v_user_id THEN
    RAISE EXCEPTION 'No autorizado para este viaje';
  END IF;

  -- Determinar si es disputa post-viaje
  v_is_dispute := (v_ride.status = 'completada');

  IF NOT v_is_dispute AND v_ride.status NOT IN ('aceptada', 'en_ruta') THEN
    RAISE EXCEPTION 'Solo se puede reportar un incidente durante un viaje activo';
  END IF;

  -- En viajes completados, solo el CLIENTE puede disputar
  IF v_is_dispute AND v_user_id != v_ride.client_id THEN
    RAISE EXCEPTION 'Solo el cliente puede disputar un viaje completado';
  END IF;

  -- En disputas solo se permiten tipos de disputa
  IF v_is_dispute AND p_incident_type NOT IN ('viaje_no_realizado', 'disputa_cobro', 'otro') THEN
    RAISE EXCEPTION 'Tipo de reporte no válido para un viaje completado';
  END IF;

  -- Evitar duplicados
  IF EXISTS (
    SELECT 1 FROM ride_incidents
    WHERE ride_id = p_ride_id AND status IN ('abierto', 'en_revision')
  ) THEN
    RAISE EXCEPTION 'Este viaje ya tiene un reporte en revisión';
  END IF;

  -- Crear incidente
  INSERT INTO ride_incidents (ride_id, reported_by, incident_type, description, photo_urls, status)
  VALUES (p_ride_id, v_user_id, p_incident_type, p_description, COALESCE(p_photo_urls, '[]'::jsonb), 'abierto')
  RETURNING id INTO v_incident_id;

  -- Actualizar el viaje
  IF v_is_dispute THEN
    UPDATE rides
    SET incident_id = v_incident_id,
        updated_at = NOW()
    WHERE id = p_ride_id;
  ELSE
    UPDATE rides
    SET status = 'incidente',
        incident_id = v_incident_id,
        updated_at = NOW()
    WHERE id = p_ride_id;
  END IF;

  -- Notificar a admins con prioridad
  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT id,
         CONCAT('🚨 ', CASE WHEN v_is_dispute THEN 'Disputa: ' ELSE 'Incidente: ' END, p_incident_type),
         CONCAT('Reportado en el viaje ', substring(p_ride_id::text, 1, 8), '. Revisa y resuelve.'),
         'incident_reported',
         jsonb_build_object('incident_id', v_incident_id, 'ride_id', p_ride_id, 'url', '/admin/incidentes')
  FROM profiles WHERE role IN ('super_admin', 'encargado');

  -- Notificar al otro participante
  IF v_ride.client_id IS NOT NULL AND v_ride.driver_id IS NOT NULL THEN
    PERFORM public.notify_user(
      CASE WHEN v_user_id = v_ride.client_id THEN v_ride.driver_id ELSE v_ride.client_id END,
      CASE WHEN v_is_dispute THEN 'Disputa de viaje' ELSE 'Incidente reportado' END,
      'Se reportó un problema en tu viaje. La plataforma lo está revisando.',
      'ride_incident',
      jsonb_build_object('ride_id', p_ride_id, 'incident_id', v_incident_id)
    );
  END IF;

  -- Auditoría
  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_user_id, 'REPORT_INCIDENT', 'incident', v_incident_id,
          jsonb_build_object('ride_id', p_ride_id, 'type', p_incident_type, 'dispute', v_is_dispute));

  RETURN jsonb_build_object(
    'success', TRUE,
    'incident_id', v_incident_id,
    'ride_id', p_ride_id,
    'status', CASE WHEN v_is_dispute THEN v_ride.status ELSE 'incidente' END,
    'dispute', v_is_dispute
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.report_ride_incident TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.report_ride_incident FROM anon;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 037: rate limiting en RPCs de viajes aplicado' AS estado;

SELECT p.proname, pg_get_function_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('cancel_ride', 'accept_ride', 'complete_ride', 'report_ride_incident')
ORDER BY p.proname;



