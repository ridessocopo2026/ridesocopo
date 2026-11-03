-- ============================================================
-- 124 - COMPENSACION AL CONDUCTOR SOLO POR DECISION DEL ADMIN
-- ------------------------------------------------------------
-- Problema:
--   cancel_ride acreditaba automaticamente el 50% del fee al
--   conductor en el momento de cancelar. Al resolver el
--   incidente el admin no podia reducir ese monto porque
--   resolve_ride_incident usaba GREATEST(ya_pagado, nuevo):
--   poner 0 no revertia lo ya acreditado.
--
-- Nuevo comportamiento:
--   · cancel_ride NO paga nada al conductor. Solo calcula una
--     compensacion SUGERIDA (informativa) segun la politica.
--   · El monto real lo decide el admin al resolver el incidente.
--   · resolve_ride_incident (migracion 125) acredita o REVIERTE
--     la diferencia contra lo que ya se hubiera pagado.
--
-- Rollback: reaplicar 113 (cancel_ride) y 115 (resolve).
-- ============================================================

-- ============================================================
-- 1. SUGERENCIA (INFORMATIVA, NO PAGO)
-- ============================================================
ALTER TABLE public.ride_incidents
  ADD COLUMN IF NOT EXISTS suggested_compensation_usd NUMERIC(10,2) NOT NULL DEFAULT 0;

-- ============================================================
-- 2. CANCEL_RIDE SIN COMPENSACION AUTOMATICA
--    · Billetera  -> reembolso automatico a la wallet
--    · Efectivo   -> sin reembolso; cargo PENDIENTE por verificar
--    · Pago Movil -> reembolso manual pendiente (admin)
--    · Viaje aceptado/en curso -> incidente automatico
--    · Conductor  -> NO se compensa hasta que el admin resuelva
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
  v_suggested_compensation NUMERIC := 0.00;
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
      'already_processed', TRUE, 'note', 'El viaje ya fue procesado. No se reembolso de nuevo.'
    );
  END IF;

  IF v_ride.status NOT IN ('buscando', 'aceptada', 'en_ruta') THEN
    RAISE EXCEPTION 'Estado del viaje no permite cancelacion';
  END IF;

  v_prev_status := v_ride.status::text;
  v_was_in_progress := v_prev_status IN ('aceptada', 'en_ruta');

  v_is_driver := (v_ride.driver_id = v_user_id);
  v_effective_fault := p_at_fault;
  IF v_effective_fault IS NULL THEN
    v_effective_fault := CASE WHEN v_is_driver THEN 'conductor' ELSE 'cliente' END;
  END IF;

  IF v_effective_fault NOT IN ('cliente', 'conductor', 'accidente') THEN
    RAISE EXCEPTION 'Culpable no valido';
  END IF;

  IF v_effective_fault = 'accidente' AND v_ride.incident_id IS NULL THEN
    RAISE EXCEPTION 'Debe reportar un incidente antes de cancelar por accidente';
  END IF;

  SELECT * INTO v_policy FROM cancellation_policies
  WHERE ride_status = v_prev_status AND at_fault = v_effective_fault AND is_active = TRUE;

  IF v_policy.id IS NULL THEN
    v_fee := 0.00;
    v_suggested_compensation := 0.00;
  ELSE
    v_fee := ROUND((v_ride.final_fare_usd * v_policy.fee_rate / 100), 2);
    IF v_fee < v_policy.min_fee THEN v_fee := v_policy.min_fee; END IF;
    IF v_policy.max_fee IS NOT NULL AND v_fee > v_policy.max_fee THEN v_fee := v_policy.max_fee; END IF;
    -- Solo sugerencia: NO se paga en este momento.
    v_suggested_compensation := ROUND((v_fee * v_policy.driver_compensation_rate / 100), 2);
  END IF;

  -- La compensacion real la decide el admin al resolver el incidente.
  v_compensation := 0.00;

  v_method := LOWER(COALESCE(v_ride.payment_method, 'efectivo'));

  -- ----------------------------------------------------------
  -- 3.1 REEMBOLSO / CARGO SEGUN METODO DE PAGO
  --     (la compensacion al conductor ya NO se paga aqui)
  -- ----------------------------------------------------------
  IF v_method = 'billetera' THEN
    -- El cliente pago la tarifa al pedir el viaje: se devuelve a su wallet
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
    -- que el admin/encargado aprobara o eximira.
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
    -- Pago Movil u otro metodo digital: el dinero si esta retenido.
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
  -- 3.2 INCIDENTE AUTOMATICO SI EL VIAJE YA ESTABA EN CURSO
  -- ----------------------------------------------------------
  IF v_was_in_progress AND v_ride.incident_id IS NULL THEN
    INSERT INTO ride_incidents (
      ride_id, reported_by, incident_type, description, photo_urls, status,
      suggested_compensation_usd
    )
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
        '. Compensación sugerida al conductor: $', v_suggested_compensation,
        ' (el administrador decide el monto final).',
        CASE WHEN v_charge_pending THEN ' Cargo pendiente al cliente por verificar.' ELSE '' END
      ),
      '[]'::jsonb,
      'abierto',
      v_suggested_compensation
    )
    RETURNING id INTO v_incident_id;
  END IF;

  UPDATE rides
  SET status = 'cancelada',
      cancelled_by = v_user_id,
      cancel_reason = COALESCE(p_reason, 'Cancelado'),
      cancellation_fee_usd = v_fee,
      driver_compensation_usd = 0.00,
      reimbursement_status = v_reimbursement,
      incident_id = COALESCE(v_incident_id, v_ride.incident_id),
      updated_at = NOW()
  WHERE id = p_ride_id;

  -- Liberar el cupon: la promo no se consume en un viaje que no ocurrio
  IF v_ride.coupon_id IS NOT NULL THEN
    DELETE FROM coupon_redemptions WHERE ride_id = p_ride_id;
    UPDATE coupons SET used_count = GREATEST(used_count - 1, 0), updated_at = NOW()
    WHERE id = v_ride.coupon_id;
  END IF;

  -- ----------------------------------------------------------
  -- 3.3 AVISO A ADMIN / ENCARGADO DE LA ZONA
  -- ----------------------------------------------------------
  IF v_incident_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, title, body, type, data)
    SELECT p.id,
           '🚫 Cancelación en curso',
           CONCAT('Viaje ', substring(p_ride_id::text, 1, 8), ' cancelado por ',
                  CASE WHEN v_is_driver THEN 'el conductor' ELSE 'el cliente' END,
                  '. Fee: $', v_fee,
                  '. Compensación sugerida: $', v_suggested_compensation,
                  ' (tú decides el monto). Revisa y resuelve.'),
           'incident_reported',
           jsonb_build_object(
             'incident_id', v_incident_id,
             'ride_id', p_ride_id,
             'amount', v_fee,
             'suggested_compensation', v_suggested_compensation,
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
  -- 3.4 NOTIFICACIONES A LOS PARTICIPANTES
  -- ----------------------------------------------------------
  IF v_ride.client_id IS NOT NULL AND v_ride.driver_id IS NOT NULL THEN
    v_other_user := CASE WHEN v_user_id = v_ride.client_id THEN v_ride.driver_id ELSE v_ride.client_id END;
    PERFORM public.notify_user(
      v_other_user,
      'Viaje cancelado',
      CONCAT(
        CASE WHEN v_effective_fault = 'accidente' THEN 'Viaje cancelado por incidente'
             WHEN v_fee > 0 THEN CONCAT('Cancelado. Fee: $', v_fee)
             ELSE 'El viaje fue cancelado' END,
        CASE WHEN v_other_user = v_ride.driver_id
             THEN ' Un administrador revisará si corresponde compensación.'
             ELSE '' END
      ),
      'ride_cancelled',
      jsonb_build_object('ride_id', p_ride_id, 'fee', v_fee,
                         'compensation', 0,
                         'suggested_compensation', v_suggested_compensation,
                         'incident_id', v_incident_id));
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
      CONCAT('Fee: $', v_fee),
      'ride_cancelled_confirmation',
      jsonb_build_object('ride_id', p_ride_id, 'fee', v_fee));
  END IF;

  BEGIN
    INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
    VALUES (v_user_id, 'CANCEL_RIDE', 'ride', p_ride_id,
            jsonb_build_object(
              'at_fault', v_effective_fault,
              'fee', v_fee,
              'compensation', 0,
              'suggested_compensation', v_suggested_compensation,
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
    'driver_compensation_usd', 0.00,
    'suggested_driver_compensation_usd', v_suggested_compensation,
    'refunded_commission', FALSE,
    'reimbursement_status', v_reimbursement,
    'incident_id', v_incident_id,
    'charge_pending', v_charge_pending
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.cancel_ride TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.cancel_ride FROM anon;
