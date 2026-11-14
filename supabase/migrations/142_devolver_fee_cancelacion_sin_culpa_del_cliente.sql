-- 142 - Si el culpable de la cancelacion NO es el cliente, el fee retenido se devuelve.
--
-- Caso real (Andrea Acosta, RS-570988): el sistema retuvo $0.50 al cancelar
-- (reembolso = tarifa - fee). Al resolver el incidente con culpable = conductor,
-- la pantalla enviaba refund_client = 0 y el cliente perdia ese fee.
--
--   1) admin_refund_cancellation_fee: devolver el fee retenido (manual, auditado).
--   2) Trigger: al resolver con culpable conductor/accidente y pago por billetera,
--      se devuelve el fee automaticamente (una sola vez).
--   3) Correccion puntual del caso RS-570988.

CREATE OR REPLACE FUNCTION public.admin_refund_cancellation_fee(
  p_ride_id UUID,
  p_note TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin UUID := auth.uid();
  v_role TEXT;
  v_ride RECORD;
  v_wallet RECORD;
  v_fee NUMERIC;
  v_balance NUMERIC;
  v_note TEXT := COALESCE(NULLIF(BTRIM(COALESCE(p_note, '')), ''), 'Cancelación sin culpa del cliente');
BEGIN
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  v_role := public.get_user_role(v_admin)::text;
  IF v_role IS NULL OR v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('admin_refund_cancellation_fee', 30);

  SELECT * INTO v_ride FROM public.rides WHERE id = p_ride_id FOR UPDATE;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF v_ride.status <> 'cancelada' THEN
    RAISE EXCEPTION 'Solo se devuelve el fee de viajes cancelados';
  END IF;

  v_fee := ROUND(COALESCE(v_ride.cancellation_fee_usd, 0), 2);
  IF v_fee <= 0 THEN
    RAISE EXCEPTION 'Este viaje no tiene fee retenido';
  END IF;

  IF v_ride.client_id IS NULL THEN
    RAISE EXCEPTION 'El viaje no tiene cliente';
  END IF;

  IF COALESCE(v_ride.payment_method, '') NOT ILIKE '%billetera%' THEN
    RAISE EXCEPTION 'Solo aplica cuando el cliente pagó por billetera (ahí sí se retuvo el fee)';
  END IF;

  IF v_role = 'encargado' THEN
    IF public.caller_zone_id() IS NULL OR v_ride.origin_zone_id IS DISTINCT FROM public.caller_zone_id() THEN
      RAISE EXCEPTION 'No autorizado para viajes de otra ciudad';
    END IF;
  END IF;

  SELECT * INTO v_wallet FROM public.wallets WHERE user_id = v_ride.client_id FOR UPDATE;
  IF v_wallet.id IS NULL THEN
    RAISE EXCEPTION 'Billetera del cliente no encontrada';
  END IF;

  UPDATE public.wallets
  SET balance_usd = balance_usd + v_fee,
      updated_at = NOW()
  WHERE user_id = v_ride.client_id;

  SELECT balance_usd INTO v_balance FROM public.wallets WHERE user_id = v_ride.client_id;

  INSERT INTO public.transactions (
    wallet_id, user_id, type, amount_usd, status, description, reviewed_by, ride_id
  ) VALUES (
    v_wallet.id, v_ride.client_id, 'credito', v_fee, 'completado',
    'Reembolso de fee por cancelación: ' || v_note, v_admin, p_ride_id
  );

  UPDATE public.rides
  SET cancellation_fee_usd = 0,
      updated_at = NOW()
  WHERE id = p_ride_id;

  UPDATE public.ride_incidents
  SET resolution_details = COALESCE(resolution_details, '{}'::jsonb)
      || jsonb_build_object(
           'refund_client', ROUND(COALESCE((resolution_details->>'refund_client')::numeric, 0) + v_fee, 2),
           'charge_waived', TRUE,
           'fee_refunded_admin', v_fee
         ),
      updated_at = NOW()
  WHERE ride_id = p_ride_id;

  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (
    v_admin, 'ADMIN_REFUND_CANCELLATION_FEE', 'ride', p_ride_id,
    jsonb_build_object(
      'refunded_usd', v_fee,
      'client_id', v_ride.client_id,
      'payment_method', v_ride.payment_method,
      'note', v_note,
      'new_balance', v_balance
    )
  );

  PERFORM public.notify_user(
    v_ride.client_id,
    'Reembolso de cancelación',
    CONCAT('Te devolvimos $', v_fee, ' del fee de la cancelación.'),
    'refund_completed',
    jsonb_build_object('ride_id', p_ride_id, 'url', '/cliente/billetera')
  );

  RETURN jsonb_build_object(
    'success', TRUE,
    'ride_id', p_ride_id,
    'refunded_usd', v_fee,
    'new_balance', v_balance
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_refund_cancellation_fee(UUID, TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_refund_cancellation_fee(UUID, TEXT) FROM anon;

-- ------------------------------------------------------------
-- Trigger: devolver el fee automaticamente cuando el culpable no es el cliente
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.auto_refund_cancellation_fee_on_resolve()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ride RECORD;
  v_wallet RECORD;
  v_fee NUMERIC;
  v_fault TEXT := COALESCE(NEW.resolution_details->>'at_fault', '');
BEGIN
  IF v_fault NOT IN ('conductor', 'accidente') THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_ride FROM public.rides WHERE id = NEW.ride_id FOR UPDATE;
  IF v_ride.id IS NULL OR v_ride.status <> 'cancelada' THEN
    RETURN NEW;
  END IF;

  v_fee := ROUND(COALESCE(v_ride.cancellation_fee_usd, 0), 2);
  IF v_fee <= 0 THEN
    RETURN NEW;
  END IF;

  IF v_ride.client_id IS NULL OR COALESCE(v_ride.payment_method, '') NOT ILIKE '%billetera%' THEN
    RETURN NEW;
  END IF;

  SELECT * INTO v_wallet FROM public.wallets WHERE user_id = v_ride.client_id FOR UPDATE;
  IF v_wallet.id IS NULL THEN
    RETURN NEW;
  END IF;

  UPDATE public.wallets
  SET balance_usd = balance_usd + v_fee,
      updated_at = NOW()
  WHERE user_id = v_ride.client_id;

  INSERT INTO public.transactions (
    wallet_id, user_id, type, amount_usd, status, description, ride_id
  ) VALUES (
    v_wallet.id, v_ride.client_id, 'credito', v_fee, 'completado',
    CONCAT('Reembolso automático del fee (culpable: ', v_fault, ')'), NEW.ride_id
  );

  UPDATE public.rides
  SET cancellation_fee_usd = 0,
      updated_at = NOW()
  WHERE id = NEW.ride_id;

  NEW.resolution_details := COALESCE(NEW.resolution_details, '{}'::jsonb)
    || jsonb_build_object(
         'refund_client', ROUND(COALESCE((NEW.resolution_details->>'refund_client')::numeric, 0) + v_fee, 2),
         'charge_waived', TRUE,
         'fee_auto_refunded', v_fee
       );

  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (
    NEW.resolved_by, 'AUTO_REFUND_CANCELLATION_FEE', 'ride', NEW.ride_id,
    jsonb_build_object(
      'refunded_usd', v_fee,
      'at_fault', v_fault,
      'client_id', v_ride.client_id,
      'incident_id', NEW.id
    )
  );

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_auto_refund_cancellation_fee ON public.ride_incidents;

CREATE TRIGGER trg_auto_refund_cancellation_fee
BEFORE UPDATE OF status ON public.ride_incidents
FOR EACH ROW
WHEN (NEW.status = 'resuelto' AND OLD.status IS DISTINCT FROM 'resuelto')
EXECUTE FUNCTION public.auto_refund_cancellation_fee_on_resolve();

-- ------------------------------------------------------------
-- Correccion puntual: RS-570988 (Andrea Acosta)
-- ------------------------------------------------------------
DO $$
DECLARE
  v_ride RECORD;
  v_wallet RECORD;
  v_fee NUMERIC;
  v_admin UUID;
BEGIN
  SELECT * INTO v_ride FROM public.rides
  WHERE id = '4f77f21d-248e-4d79-9247-d81479ff7d9a'::uuid
  FOR UPDATE;

  v_fee := ROUND(COALESCE(v_ride.cancellation_fee_usd, 0), 2);

  IF v_ride.id IS NOT NULL AND v_fee > 0 AND v_ride.client_id IS NOT NULL THEN
    SELECT * INTO v_wallet FROM public.wallets
    WHERE user_id = v_ride.client_id
    FOR UPDATE;

    IF v_wallet.id IS NOT NULL THEN
      UPDATE public.wallets
      SET balance_usd = balance_usd + v_fee,
          updated_at = NOW()
      WHERE user_id = v_ride.client_id;

      INSERT INTO public.transactions (
        wallet_id, user_id, type, amount_usd, status, description, ride_id
      ) VALUES (
        v_wallet.id, v_ride.client_id, 'credito', v_fee, 'completado',
        'Reembolso de fee por cancelación: el conductor no llegó (ajuste admin)',
        v_ride.id
      );

      UPDATE public.rides
      SET cancellation_fee_usd = 0,
          updated_at = NOW()
      WHERE id = v_ride.id;

      UPDATE public.ride_incidents
      SET resolution_details = COALESCE(resolution_details, '{}'::jsonb)
          || jsonb_build_object(
               'refund_client', v_fee,
               'charge_waived', TRUE,
               'fee_refunded_admin', v_fee
             ),
          updated_at = NOW()
      WHERE ride_id = v_ride.id;

      SELECT resolved_by INTO v_admin FROM public.ride_incidents
      WHERE ride_id = v_ride.id
      ORDER BY created_at DESC
      LIMIT 1;

      INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
      VALUES (
        v_admin, 'ADMIN_REFUND_CANCELLATION_FEE', 'ride', v_ride.id,
        jsonb_build_object(
          'refunded_usd', v_fee,
          'client_id', v_ride.client_id,
          'payment_method', v_ride.payment_method,
          'note', 'Culpable conductor: el cliente no debe pagar el fee'
        )
      );
    END IF;
  END IF;
END $$;
