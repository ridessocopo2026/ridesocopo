-- ============================================================
-- 113 - CANCELACIONES EN EFECTIVO + INCIDENTES DE CANCELACIÓN
-- ------------------------------------------------------------
-- Problemas corregidos:
--   1) driver_compensation_rate estaba en 0.50 (0.5%) en vez de
--      50.00 (50%) -> el conductor recibía $0.01.
--   2) El efectivo generaba un "reembolso" de dinero que nunca se
--      cobró y avisaba al admin sin crear ningún incidente.
--   3) El Pago Móvil (dinero sí retenido) no se reembolsaba.
--   4) Se "devolvía" una comisión que solo se cobra al completar.
--
-- Nuevo flujo en EFECTIVO (cliente culpable, viaje en curso):
--   cargo PENDIENTE visible en la app -> incidente automático ->
--   el admin/encargado de la zona aprueba o exime -> el conductor
--   se compensa de inmediato.
--
-- ROLLBACK (si hiciera falta):
--   · Reaplicar 047 (cancel_ride), 037 (report_ride_incident) y
--     050 (resolve_ride_incident), y volver a poner
--     driver_compensation_rate = 0.50 en las políticas.
--   · Quitar 'cancelacion_cliente' del CHECK de ride_incidents.
-- ============================================================

-- ============================================================
-- 1. POLÍTICAS
-- ============================================================
UPDATE public.cancellation_policies
SET driver_compensation_rate = 50.00,
    updated_at = NOW()
WHERE ride_status IN ('aceptada', 'en_ruta')
  AND at_fault = 'cliente'
  AND driver_compensation_rate = 0.50;

-- La comisión solo se cobra al completar (settle_ride_earnings),
-- así que en una cancelación nunca hay comisión que devolver.
UPDATE public.cancellation_policies
SET refunds_commission = FALSE,
    updated_at = NOW()
WHERE refunds_commission = TRUE;

-- ============================================================
-- 2. NUEVO TIPO DE INCIDENTE
-- ============================================================
ALTER TABLE public.ride_incidents
  DROP CONSTRAINT IF EXISTS ride_incidents_incident_type_check;

ALTER TABLE public.ride_incidents
  ADD CONSTRAINT ride_incidents_incident_type_check
  CHECK (incident_type = ANY (ARRAY[
    'accidente', 'falla_mecanica', 'urgencia_medica', 'clima', 'otro',
    'viaje_no_realizado', 'disputa_cobro', 'cancelacion_cliente'
  ]));

-- ============================================================
-- 3. CANCEL_RIDE
--    · Billetera  -> reembolso automático a la wallet
--    · Efectivo   -> sin reembolso; cargo PENDIENTE por verificar
--    · Pago Móvil -> reembolso manual pendiente (admin)
--    · Viaje en curso -> incidente automático para el admin
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
  v_prev_status TEXT;
  v_fee NUMERIC := 0.00;
  v_compensation NUMERIC := 0.00;
  v_refund NUMERIC := 0.00;
  v_effective_fault TEXT;
  v_is_driver BOOLEAN;
  v_method TEXT;
  v_charge_pending BOOLEAN := FALSE;
  v_incident_id UUID;
  v_was_in_progress BOOLEAN := FALSE;
  v_reimbursement TEXT := 'no_aplica';
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

  v_prev_status := v_ride.status::text;
  v_was_in_progress := v_prev_status IN ('aceptada', 'en_ruta');

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
  WHERE ride_status = v_prev_status AND at_fault = v_effective_fault AND is_active = TRUE;

  IF v_policy.id IS NULL THEN
    v_fee := 0.00;
    v_compensation := 0.00;
  ELSE
    v_fee := ROUND((v_ride.final_fare_usd * v_policy.fee_rate / 100), 2);
    IF v_fee < v_policy.min_fee THEN v_fee := v_policy.min_fee; END IF;
    IF v_policy.max_fee IS NOT NULL AND v_fee > v_policy.max_fee THEN v_fee := v_policy.max_fee; END IF;
    v_compensation := ROUND((v_fee * v_policy.driver_compensation_rate / 100), 2);
  END IF;

  v_method := LOWER(COALESCE(v_ride.payment_method, 'efectivo'));

  -- ----------------------------------------------------------
  -- 3.1 COMPENSACIÓN AL CONDUCTOR (se acredita de inmediato)
  --     Si el admin luego exime el cargo, la plataforma asume
  --     esta compensación (queda registrado en auditoría).
  -- ----------------------------------------------------------
  IF v_compensation > 0 AND v_ride.driver_id IS NOT NULL THEN
    SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.driver_id;
    IF v_wallet.id IS NOT NULL THEN
      UPDATE wallets
      SET balance_usd = balance_usd + v_compensation, updated_at = NOW()
      WHERE user_id = v_ride.driver_id;

      INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
      VALUES (v_wallet.id, v_ride.driver_id, 'credito', v_compensation, 'completado',
              'Compensación por cancelación', p_ride_id);
    END IF;
  END IF;

  -- ----------------------------------------------------------
  -- 3.2 REEMBOLSO / CARGO SEGÚN MÉTODO DE PAGO
  -- ----------------------------------------------------------
  IF v_method = 'billetera' THEN
    -- El cliente pagó la tarifa al pedir el viaje: se devuelve a su wallet
    v_refund := GREATEST(v_ride.final_fare_usd - v_fee, 0);
    IF v_refund > 0 THEN
      SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.client_id;
      IF v_wallet.id IS NOT NULL THEN
        UPDATE wallets
        SET balance_usd = balance_usd + v_refund, updated_at = NOW()
        WHERE user_id = v_ride.client_id;

        INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
        VALUES (v_wallet.id, v_ride.client_id, 'credito', v_refund, 'completado',
                CONCAT('Reembolso por cancelación. Fee: $', v_fee), p_ride_id);
      END IF;
    END IF;
    v_reimbursement := 'auto_completado';

  ELSIF v_method = 'efectivo' THEN
    -- No hay dinero retenido: no se reembolsa nada.
    -- Si el cliente es culpable, se registra un cargo PENDIENTE
    -- que el admin/encargado aprobará o eximirá.
    v_refund := 0.00;
    IF v_fee > 0 AND v_effective_fault = 'cliente' AND v_ride.driver_id IS NOT NULL THEN
      SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.client_id;
      IF v_wallet.id IS NOT NULL THEN
        INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id, payment_method)
        VALUES (v_wallet.id, v_ride.client_id, 'debito', v_fee, 'pendiente',
                'Cargo por cancelación en curso (efectivo) — por verificar',
                p_ride_id, v_ride.payment_method);
        v_charge_pending := TRUE;
      END IF;
    END IF;
    v_reimbursement := 'no_aplica';

  ELSE
    -- Pago Móvil u otro método digital: el dinero sí está retenido.
    -- Se deja reembolso manual pendiente para que el admin lo procese.
    v_refund := 0.00;
    IF v_ride.final_fare_usd > 0 AND v_ride.proof_status = 'aprobado' THEN
      v_refund := GREATEST(v_ride.final_fare_usd - v_fee, 0);
      IF v_refund > 0 THEN
        SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.client_id;
        IF v_wallet.id IS NOT NULL THEN
          INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id, payment_method)
          VALUES (v_wallet.id, v_ride.client_id, 'credito', v_refund, 'pendiente',
                  CONCAT('Reembolso pendiente por cancelación (', v_ride.payment_method, '). Fee: $', v_fee),
                  p_ride_id, v_ride.payment_method);
          v_reimbursement := 'pendiente_manual';
        END IF;
      END IF;
    END IF;
    IF v_reimbursement IS DISTINCT FROM 'pendiente_manual' THEN
      v_reimbursement := 'no_aplica';
    END IF;
  END IF;

  -- ----------------------------------------------------------
  -- 3.3 INCIDENTE AUTOMÁTICO SI EL VIAJE YA ESTABA EN CURSO
  -- ----------------------------------------------------------
  IF v_was_in_progress AND v_ride.incident_id IS NULL THEN
    INSERT INTO ride_incidents (ride_id, reported_by, incident_type, description, photo_urls, status)
    VALUES (
      p_ride_id,
      v_user_id,
      'cancelacion_cliente',
      CONCAT(
        'Cancelación de un viaje ',
        CASE WHEN v_prev_status = 'en_ruta' THEN 'en curso' ELSE 'ya aceptado' END,
        '. Canceló: ', CASE WHEN v_is_driver THEN 'el conductor' ELSE 'el cliente' END,
        '. Método: ', COALESCE(v_ride.payment_method, 'No especificado'),
        '. Fee: $', v_fee,
        '. Compensación al conductor: $', v_compensation,
        CASE WHEN v_charge_pending THEN '. Cargo pendiente al cliente por verificar.' ELSE '.' END
      ),
      '[]'::jsonb,
      'abierto'
    )
    RETURNING id INTO v_incident_id;
  END IF;

  UPDATE rides
  SET status = 'cancelada',
      cancelled_by = v_user_id,
      cancel_reason = COALESCE(p_reason, 'Cancelado'),
      cancellation_fee_usd = v_fee,
      driver_compensation_usd = v_compensation,
      reimbursement_status = v_reimbursement,
      incident_id = COALESCE(v_incident_id, v_ride.incident_id),
      updated_at = NOW()
  WHERE id = p_ride_id;

  -- Liberar el cupón: la promo no se consume en un viaje que no ocurrió
  IF v_ride.coupon_id IS NOT NULL THEN
    DELETE FROM coupon_redemptions WHERE ride_id = p_ride_id;
    UPDATE coupons SET used_count = GREATEST(used_count - 1, 0), updated_at = NOW()
    WHERE id = v_ride.coupon_id;
  END IF;

  -- ----------------------------------------------------------
  -- 3.4 AVISO A ADMIN / ENCARGADO DE LA ZONA
  -- ----------------------------------------------------------
  IF v_incident_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, title, body, type, data)
    SELECT p.id,
           '🚫 Cancelación en curso',
           CONCAT('Viaje ', substring(p_ride_id::text, 1, 8), ' cancelado por ',
                  CASE WHEN v_is_driver THEN 'el conductor' ELSE 'el cliente' END,
                  '. Fee: $', v_fee, '. Revisa y resuelve.'),
           'incident_reported',
           jsonb_build_object(
             'incident_id', v_incident_id,
             'ride_id', p_ride_id,
             'amount', v_fee,
             'url', CASE WHEN p.role = 'encargado' THEN '/encargado/incidentes' ELSE '/admin/incidentes' END
           )
    FROM profiles p
    WHERE p.role = 'super_admin'
       OR (p.role = 'encargado' AND p.zone_id = v_ride.origin_zone_id);

  ELSIF v_reimbursement = 'pendiente_manual' THEN
    INSERT INTO notifications (user_id, title, body, type, data)
    SELECT p.id,
           'Reembolso pendiente',
           CONCAT('Reembolsar $', v_refund, ' al cliente por el viaje ', substring(p_ride_id::text, 1, 8)),
           'refund_pending',
           jsonb_build_object('ride_id', p_ride_id, 'amount', v_refund, 'url', '/admin/transacciones')
    FROM profiles p
    WHERE p.role = 'super_admin'
       OR (p.role = 'encargado' AND p.zone_id = v_ride.origin_zone_id);
  END IF;

  -- ----------------------------------------------------------
  -- 3.5 NOTIFICACIONES A LOS PARTICIPANTES
  -- ----------------------------------------------------------
  IF v_ride.client_id IS NOT NULL AND v_ride.driver_id IS NOT NULL THEN
    v_other_user := CASE WHEN v_user_id = v_ride.client_id THEN v_ride.driver_id ELSE v_ride.client_id END;
    PERFORM public.notify_user(
      v_other_user,
      'Viaje cancelado',
      CASE WHEN v_effective_fault = 'accidente' THEN 'Viaje cancelado por incidente'
           WHEN v_fee > 0 THEN CONCAT('Cancelado. Fee: $', v_fee)
           ELSE 'El viaje fue cancelado' END,
      'ride_cancelled',
      jsonb_build_object('ride_id', p_ride_id, 'fee', v_fee,
                         'compensation', v_compensation, 'incident_id', v_incident_id));
  END IF;

  IF v_charge_pending THEN
    PERFORM public.notify_user(
      v_ride.client_id,
      'Cargo por cancelación',
      CONCAT('Se registró un cargo pendiente de $', v_fee,
             ' por cancelar un viaje en curso. Un administrador lo verificará. ',
             'Si no estás de acuerdo, reporta un incidente desde el detalle del viaje.'),
      'cancellation_charge_pending',
      jsonb_build_object('ride_id', p_ride_id, 'amount', v_fee, 'url', '/cliente/billetera'));
  END IF;

  IF v_fee > 0 THEN
    PERFORM public.notify_user(
      v_user_id,
      'Viaje cancelado',
      CONCAT('Fee: $', v_fee,
             CASE WHEN v_compensation > 0 THEN CONCAT('. Conductor compensado: $', v_compensation) ELSE '' END),
      'ride_cancelled_confirmation',
      jsonb_build_object('ride_id', p_ride_id, 'fee', v_fee));
  END IF;

  BEGIN
    INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
    VALUES (v_user_id, 'CANCEL_RIDE', 'ride', p_ride_id,
            jsonb_build_object(
              'at_fault', v_effective_fault,
              'fee', v_fee,
              'compensation', v_compensation,
              'prev_status', v_prev_status,
              'incident_id', v_incident_id,
              'charge_pending', v_charge_pending,
              'reimbursement_status', v_reimbursement,
              'payment_method', v_ride.payment_method
            ));
  EXCEPTION WHEN OTHERS THEN
    NULL; -- La auditoría nunca debe romper el flujo
  END;

  RETURN jsonb_build_object(
    'success', TRUE,
    'ride_id', p_ride_id,
    'status', 'cancelada',
    'at_fault', v_effective_fault,
    'cancellation_fee_usd', v_fee,
    'driver_compensation_usd', v_compensation,
    'refunded_commission', FALSE,
    'reimbursement_status', v_reimbursement,
    'incident_id', v_incident_id,
    'charge_pending', v_charge_pending
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.cancel_ride TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.cancel_ride FROM anon;
