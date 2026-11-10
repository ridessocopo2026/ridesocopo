-- ============================================================
-- 132 - RECARGA: GUARDAR MONTO EN BS Y TASA USADA
-- ------------------------------------------------------------
-- La recarga por Pago Móvil se hace en bolivares, pero la app solo
-- guardaba el monto en USD. Al aprobar el comprobante el admin no
-- sabia cuanto se transfirio realmente ni con que tasa.
--
-- Ahora request_wallet_recharge acepta (opcionales):
--   p_amount_bs     monto exacto en bolivares
--   p_exchange_rate tasa usada (Bs por USD)
-- y los deja en la descripcion del movimiento y en la notificacion
-- al admin:  "Recarga de saldo — Pago Móvil — Bs 10000.00 @ 1000.00"
--
-- Compatible: los parametros son opcionales (4 argumentos sigue funcionando).
-- ============================================================
CREATE OR REPLACE FUNCTION public.request_wallet_recharge(
  p_amount_usd numeric,
  p_proof_url text,
  p_reference text DEFAULT NULL,
  p_payment_method text DEFAULT NULL,
  p_amount_bs numeric DEFAULT NULL,
  p_exchange_rate numeric DEFAULT NULL
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id UUID := auth.uid();
  v_wallet RECORD;
  v_txn_id UUID;
  v_user_profile RECORD;
  v_method TEXT;
  v_bs_note TEXT := '';
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('request_wallet_recharge', 5);

  IF p_amount_usd <= 0 OR p_amount_usd > 999999.99 THEN
    RAISE EXCEPTION 'Monto inválido';
  END IF;

  IF p_proof_url IS NULL OR p_proof_url = '' THEN
    RAISE EXCEPTION 'Debes adjuntar el comprobante del pago';
  END IF;

  v_method := NULLIF(TRIM(COALESCE(p_payment_method, '')), '');
  IF v_method IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM payment_methods WHERE name = v_method) THEN
    RAISE EXCEPTION 'Método de pago no válido';
  END IF;

  -- Monto en Bs y tasa: informativos para verificar el comprobante del banco
  IF p_amount_bs IS NOT NULL AND (p_amount_bs <= 0 OR p_amount_bs > 999999999.99) THEN
    p_amount_bs := NULL;
  END IF;
  IF p_exchange_rate IS NOT NULL AND (p_exchange_rate <= 0 OR p_exchange_rate > 1000000) THEN
    p_exchange_rate := NULL;
  END IF;

  IF p_amount_bs IS NOT NULL THEN
    v_bs_note := CONCAT(' — Bs ', ROUND(p_amount_bs, 2));
    IF p_exchange_rate IS NOT NULL THEN
      v_bs_note := v_bs_note || CONCAT(' @ ', ROUND(p_exchange_rate, 2));
    END IF;
  END IF;

  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_user_id;
  IF v_wallet.id IS NULL THEN
    RAISE EXCEPTION 'Billetera no encontrada';
  END IF;

  INSERT INTO transactions (
    wallet_id, user_id, type, amount_usd, status,
    description, proof_url, reference, payment_method
  ) VALUES (
    v_wallet.id, v_user_id, 'recarga', p_amount_usd, 'pendiente',
    'Recarga de saldo'
      || CASE WHEN v_method IS NOT NULL THEN ' — ' || v_method ELSE '' END
      || v_bs_note,
    p_proof_url, p_reference, v_method
  )
  RETURNING id INTO v_txn_id;

  SELECT * INTO v_user_profile FROM profiles WHERE id = v_user_id;
  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT id, 'Recarga por aprobar',
         CONCAT(COALESCE(v_user_profile.full_name, 'Usuario'), ' solicitó una recarga de $', p_amount_usd, v_bs_note),
         'recharge_pending',
         jsonb_build_object('transaction_id', v_txn_id, 'url', '/admin/comprobantes')
  FROM profiles WHERE role IN ('super_admin', 'encargado');

  RETURN v_txn_id;
END;
$function$;

DROP FUNCTION IF EXISTS public.request_wallet_recharge(numeric, text, text, text);

REVOKE ALL ON FUNCTION public.request_wallet_recharge(numeric, text, text, text, numeric, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.request_wallet_recharge(numeric, text, text, text, numeric, numeric) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.request_wallet_recharge(numeric, text, text, text, numeric, numeric) FROM anon;