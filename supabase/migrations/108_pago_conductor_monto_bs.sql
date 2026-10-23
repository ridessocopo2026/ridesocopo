-- ============================================================
-- 108 - PAGO DEL CONDUCTOR: TOPE DE DEUDA, BS Y EFECTIVO
-- ============================================================

DROP FUNCTION IF EXISTS public.driver_pay_to_platform(numeric, text, text, text);

CREATE OR REPLACE FUNCTION public.driver_pay_to_platform(
  p_amount_usd numeric DEFAULT NULL,
  p_proof_url text DEFAULT NULL,
  p_payment_method text DEFAULT NULL,
  p_reference text DEFAULT NULL,
  p_amount_bs numeric DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_driver_id uuid := auth.uid();
  v_payout_id uuid;
  v_method text;
  v_ref text;
  v_proof text;
  v_method_row RECORD;
  v_is_cash boolean := FALSE;
  v_is_bs boolean := FALSE;
  v_rate numeric;
  v_amount_usd numeric;
  v_amount_bs numeric;
  v_wallet RECORD;
  v_debt numeric;
  v_pending numeric;
  v_available numeric;
  v_description text;
  v_proof_required boolean;
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('driver_pay_to_platform', 5);

  v_method := NULLIF(TRIM(COALESCE(p_payment_method, '')), '');
  IF v_method IS NULL THEN
    RAISE EXCEPTION 'Selecciona un metodo de pago';
  END IF;
  v_ref := NULLIF(TRIM(COALESCE(p_reference, '')), '');

  SELECT * INTO v_method_row
  FROM public.payment_methods
  WHERE name = v_method;

  IF v_method_row.id IS NULL THEN
    RAISE EXCEPTION 'Metodo de pago no valido';
  END IF;

  v_is_cash := v_method ILIKE '%efectivo%';
  v_is_bs := v_method ILIKE '%pago%m%vil%';

  IF NOT v_is_cash AND COALESCE(v_method_row.for_recharge, FALSE) = FALSE THEN
    RAISE EXCEPTION 'Este metodo no esta habilitado para pagos a la plataforma';
  END IF;

  v_proof_required := NOT v_is_cash AND COALESCE(v_method_row.proof_required, TRUE);
  IF v_proof_required AND (p_proof_url IS NULL OR btrim(p_proof_url) = '') THEN
    RAISE EXCEPTION 'Debes subir un comprobante';
  END IF;
  v_proof := CASE WHEN v_is_cash THEN NULL ELSE NULLIF(btrim(p_proof_url), '') END;

  IF v_is_bs THEN
    IF p_amount_bs IS NOT NULL AND p_amount_bs > 0 THEN
      v_amount_bs := round(p_amount_bs, 2);
      SELECT rate_bs_per_usd INTO v_rate
      FROM public.exchange_rates
      WHERE is_active = TRUE
      ORDER BY updated_at DESC
      LIMIT 1;
      IF v_rate IS NULL OR v_rate <= 0 THEN
        RAISE EXCEPTION 'No hay tasa de cambio configurada';
      END IF;
      v_amount_usd := round(v_amount_bs / v_rate, 2);
    ELSIF p_amount_usd IS NOT NULL AND p_amount_usd > 0 THEN
      -- Compatibilidad con el frontend anterior (monto en USD)
      v_amount_usd := round(p_amount_usd, 2);
      v_amount_bs := NULL;
    ELSE
      RAISE EXCEPTION 'Monto invalido';
    END IF;
  ELSE
    IF p_amount_usd IS NULL OR p_amount_usd <= 0 THEN
      RAISE EXCEPTION 'Monto invalido';
    END IF;
    v_amount_usd := round(p_amount_usd, 2);
  END IF;

  IF v_amount_usd IS NULL OR v_amount_usd <= 0 THEN
    RAISE EXCEPTION 'Monto invalido';
  END IF;

  SELECT * INTO v_wallet
  FROM public.wallets
  WHERE user_id = v_driver_id
  FOR UPDATE;

  IF v_wallet.id IS NULL THEN
    RAISE EXCEPTION 'Billetera no encontrada';
  END IF;

  v_debt := GREATEST(0, -COALESCE(v_wallet.balance_usd, 0));
  IF v_debt <= 0 THEN
    RAISE EXCEPTION 'No tienes deuda pendiente con la plataforma';
  END IF;

  SELECT COALESCE(SUM(amount_usd), 0) INTO v_pending
  FROM public.payouts
  WHERE driver_id = v_driver_id
    AND type = 'driver_pay_platform'
    AND status = 'pendiente';

  v_available := round(GREATEST(0, v_debt - v_pending), 2);
  IF v_available <= 0 THEN
    RAISE EXCEPTION 'Ya tienes un pago pendiente por el total de tu deuda';
  END IF;

  IF v_amount_usd > v_available THEN
    IF v_is_bs AND v_rate IS NOT NULL THEN
      RAISE EXCEPTION 'El monto supera lo que debes. Disponible: Bs. % (aprox. $%) a la tasa %',
        round(v_available * v_rate, 2), v_available, v_rate;
    ELSE
      RAISE EXCEPTION 'El monto supera lo que debes. Disponible: $%', v_available;
    END IF;
  END IF;

  v_description := 'Pago del conductor a la plataforma'
    || CASE WHEN v_method IS NOT NULL THEN ' - ' || v_method ELSE '' END
    || CASE WHEN v_amount_bs IS NOT NULL THEN
         ' (Bs. ' || to_char(v_amount_bs, 'FM999999990.00') || ' @ Bs. ' ||
         to_char(v_rate, 'FM999999990.00') || '/$)' ELSE '' END
    || CASE WHEN v_ref IS NOT NULL THEN ' (Ref: ' || v_ref || ')' ELSE '' END;

  INSERT INTO public.payouts (driver_id, amount_usd, type, status, proof_url, description, created_by)
  VALUES (v_driver_id, v_amount_usd, 'driver_pay_platform', 'pendiente', v_proof, v_description, v_driver_id)
  RETURNING id INTO v_payout_id;

  INSERT INTO public.notifications (user_id, title, body, type, data)
  SELECT id,
         'Pago de conductor por aprobar',
         CASE
           WHEN v_amount_bs IS NOT NULL THEN
             'Un conductor pago Bs. ' || to_char(v_amount_bs, 'FM999999990.00') ||
             ' (aprox. $' || v_amount_usd || ') a la plataforma. Revisar.'
           WHEN v_is_cash THEN
             'Un conductor pago $' || v_amount_usd ||
             ' en efectivo a la plataforma. Confirma cuando lo recibas.'
           ELSE
             'Un conductor pago $' || v_amount_usd || ' a la plataforma. Revisar.'
         END,
         'payout_driver_pay',
         jsonb_build_object('payout_id', v_payout_id, 'url', '/admin/liquidaciones')
  FROM public.profiles
  WHERE role IN ('super_admin', 'encargado');

  RETURN v_payout_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.driver_pay_to_platform(numeric, text, text, text, numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.driver_pay_to_platform(numeric, text, text, text, numeric) TO authenticated, service_role;

-- ============================================================
-- 2) APROBACION DE PAGOS: no acreditar mas que la deuda actual
-- ============================================================
CREATE OR REPLACE FUNCTION public.approve_payout(
  p_payout_id uuid,
  p_approve boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_admin_id uuid := auth.uid();
  v_payout RECORD;
  v_wallet RECORD;
  v_driver_zone uuid;
  v_debt numeric;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('approve_payout', 30);

  SELECT * INTO v_payout FROM public.payouts WHERE id = p_payout_id FOR UPDATE;
  IF v_payout.id IS NULL THEN
    RAISE EXCEPTION 'Pago no encontrado';
  END IF;

  SELECT zone_id INTO v_driver_zone FROM public.profiles WHERE id = v_payout.driver_id;
  IF public.get_user_role(v_admin_id) = 'encargado'
     AND (public.caller_zone_id() IS NULL
          OR COALESCE(v_driver_zone, '00000000-0000-0000-0000-000000000000'::uuid) != public.caller_zone_id()) THEN
    RAISE EXCEPTION 'No autorizado para pagos de otra ciudad';
  END IF;

  IF v_payout.status != 'pendiente' THEN
    RAISE EXCEPTION 'El pago ya fue procesado';
  END IF;

  IF v_payout.type = 'driver_pay_platform' AND p_approve THEN
    SELECT * INTO v_wallet
    FROM public.wallets
    WHERE user_id = v_payout.driver_id
    FOR UPDATE;

    IF v_wallet.id IS NULL THEN
      RAISE EXCEPTION 'Billetera del conductor no encontrada';
    END IF;

    v_debt := GREATEST(0, -COALESCE(v_wallet.balance_usd, 0));
    IF v_payout.amount_usd > v_debt THEN
      RAISE EXCEPTION 'El pago supera la deuda actual del conductor ($%). Rechaza el pago y pide que ajuste el monto.',
        round(v_debt, 2);
    END IF;

    UPDATE public.wallets
    SET balance_usd = balance_usd + v_payout.amount_usd,
        updated_at = NOW()
    WHERE user_id = v_payout.driver_id;

    UPDATE public.payouts
    SET status = 'aprobado',
        reviewed_by = v_admin_id,
        updated_at = NOW()
    WHERE id = p_payout_id;

    INSERT INTO public.transactions (wallet_id, user_id, type, amount_usd, status, description)
    VALUES (v_wallet.id, v_payout.driver_id, 'credito', v_payout.amount_usd, 'completado',
            'Pago del conductor a la plataforma (aprobado)');

    INSERT INTO public.notifications (user_id, title, body, type, data)
    VALUES (v_payout.driver_id, 'Pago aprobado',
            'Tu pago de ' || v_payout.amount_usd || '$ fue aprobado. Tu deuda fue actualizada.',
            'payout_approved', jsonb_build_object('payout_id', p_payout_id));

  ELSIF v_payout.type = 'driver_pay_platform' AND NOT p_approve THEN
    UPDATE public.payouts
    SET status = 'rechazado',
        reviewed_by = v_admin_id,
        updated_at = NOW()
    WHERE id = p_payout_id;

    INSERT INTO public.notifications (user_id, title, body, type, data)
    VALUES (v_payout.driver_id, 'Pago rechazado',
            'Tu pago de ' || v_payout.amount_usd || '$ fue rechazado. Verifica el comprobante.',
            'payout_rejected', jsonb_build_object('payout_id', p_payout_id));

  ELSIF v_payout.type = 'platform_pay_driver' AND p_approve THEN
    UPDATE public.payouts
    SET status = 'aprobado',
        reviewed_by = v_admin_id,
        updated_at = NOW()
    WHERE id = p_payout_id;

    INSERT INTO public.notifications (user_id, title, body, type, data)
    VALUES (v_payout.driver_id, 'Pago aprobado - Confirma recibo',
            CONCAT('La plataforma te pago $', v_payout.amount_usd, '. Confirma que lo recibiste.'),
            'payout_approved_confirm',
            jsonb_build_object('payout_id', p_payout_id, 'url', '/conductor/billetera'));

  ELSIF v_payout.type = 'platform_pay_driver' AND NOT p_approve THEN
    UPDATE public.payouts
    SET status = 'rechazado',
        reviewed_by = v_admin_id,
        updated_at = NOW()
    WHERE id = p_payout_id;

    INSERT INTO public.notifications (user_id, title, body, type, data)
    VALUES (v_payout.driver_id, 'Solicitud de retiro rechazada',
            CONCAT('Tu solicitud de retiro de $', v_payout.amount_usd, ' fue rechazada. Contacta a la plataforma.'),
            'payout_rejected', jsonb_build_object('payout_id', p_payout_id));
  END IF;

  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_admin_id, 'APPROVE_PAYOUT', 'payout', p_payout_id,
          jsonb_build_object('approved', p_approve, 'type', v_payout.type,
                             'amount_usd', v_payout.amount_usd,
                             'driver_id', v_payout.driver_id,
                             'zone_id', v_driver_zone));

  RETURN jsonb_build_object('success', TRUE, 'payout_id', p_payout_id, 'status',
    (SELECT status FROM public.payouts WHERE id = p_payout_id));
END;
$function$;

NOTIFY pgrst, 'reload schema';
