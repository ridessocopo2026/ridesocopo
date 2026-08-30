-- ============================================================
-- BUNRIDER - Migración 056: MÉTODOS DE PAGO PARA RECARGAS
-- ------------------------------------------------------------
-- El pasajero ve "dónde pagar" al recargar la billetera:
--   - payment_methods.for_recharge marca qué métodos aplican
--     a recargas (el admin los elige en Admin → Métodos de pago).
--   - get_recharge_payment_methods(): métodos activos con sus
--     campos configurables (en 1 llamada).
--   - request_wallet_recharge registra el método usado en la
--     descripción de la transacción (el admin lo ve al aprobar).
-- ============================================================

-- 1. Columna: método disponible para recargas
ALTER TABLE public.payment_methods ADD COLUMN IF NOT EXISTS for_recharge BOOLEAN DEFAULT FALSE;

-- 2. Seed: Pago Móvil queda disponible para recargas por defecto
UPDATE public.payment_methods
SET for_recharge = TRUE
WHERE name ILIKE '%pago m%'
  AND COALESCE(for_recharge, FALSE) = FALSE;

-- ============================================================
-- 3. RPC: métodos de recarga (activos + con sus campos)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_recharge_payment_methods()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_result JSONB;
BEGIN
  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'id', pm.id,
      'name', pm.name,
      'description', pm.description,
      'icon', pm.icon,
      'proof_required', COALESCE(pm.proof_required, TRUE),
      'fields', COALESCE((
        SELECT jsonb_agg(jsonb_build_object('id', f.id, 'label', f.label, 'value', f.value) ORDER BY f.label)
        FROM payment_method_fields f
        WHERE f.payment_method_id = pm.id
      ), '[]'::jsonb)
    ) ORDER BY pm.name
  ), '[]'::jsonb)
  INTO v_result
  FROM public.payment_methods pm
  -- El admin decide qué métodos se usan para recargas (for_recharge).
  -- No se filtra por is_active: un método puede servir para recargas
  -- aunque no esté activo para los viajes.
  WHERE COALESCE(pm.for_recharge, FALSE) = TRUE;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_recharge_payment_methods() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_recharge_payment_methods() FROM anon;

-- ============================================================
-- 4. REQUEST_WALLET_RECHARGE: registra el método de pago usado
-- ============================================================
CREATE OR REPLACE FUNCTION public.request_wallet_recharge(
  p_amount_usd NUMERIC,
  p_proof_url TEXT,
  p_reference TEXT DEFAULT NULL,
  p_payment_method TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_wallet RECORD;
  v_txn_id UUID;
  v_user_profile RECORD;
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

  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_user_id;

  INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, proof_url, reference)
  VALUES (v_wallet.id, v_user_id, 'recarga', p_amount_usd, 'pendiente',
          'Recarga de saldo'
            || CASE WHEN NULLIF(TRIM(COALESCE(p_payment_method, '')), '') IS NOT NULL
                   THEN ' — ' || TRIM(p_payment_method) ELSE '' END,
          p_proof_url, p_reference)
  RETURNING id INTO v_txn_id;

  -- NOTIFICAR a admins
  SELECT * INTO v_user_profile FROM profiles WHERE id = v_user_id;
  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT id, 'Recarga por aprobar',
         CONCAT(COALESCE(v_user_profile.full_name, 'Usuario'), ' solicitó una recarga de $', p_amount_usd),
         'recharge_pending',
         jsonb_build_object('transaction_id', v_txn_id, 'url', '/admin/comprobantes')
  FROM profiles WHERE role IN ('super_admin', 'encargado');

  RETURN v_txn_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_wallet_recharge(numeric, text, text, text)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.request_wallet_recharge(numeric, text, text, text) FROM anon;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 056: métodos de pago para recargas lista' AS estado;

SELECT name, for_recharge FROM public.payment_methods ORDER BY name;
