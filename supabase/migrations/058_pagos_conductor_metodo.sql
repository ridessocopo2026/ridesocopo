-- ============================================================
-- BUNRIDER - Migración 058: PAGO DEL CONDUCTOR A LA PLATAFORMA
-- ------------------------------------------------------------
-- 1) driver_pay_to_platform registra el método de pago usado
--    (Pago Móvil/Zelle/banco) y la referencia en la descripción
--    del payout, igual que request_wallet_recharge (056).
-- 2) Se añade rate limit (5/min) para proteger la RPC.
-- 3) Permisos: solo authenticated + service_role (anon revocado).
-- ============================================================

-- Eliminar firma anterior (3 args) para evitar sobrecarga
DROP FUNCTION IF EXISTS public.driver_pay_to_platform(numeric, text, text);

CREATE OR REPLACE FUNCTION public.driver_pay_to_platform(
  p_amount_usd NUMERIC,
  p_proof_url TEXT,
  p_payment_method TEXT DEFAULT NULL,
  p_reference TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_payout_id UUID;
  v_method TEXT;
  v_ref TEXT;
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('driver_pay_to_platform', 5);

  IF p_amount_usd <= 0 THEN
    RAISE EXCEPTION 'Monto inválido';
  END IF;

  IF p_proof_url IS NULL OR p_proof_url = '' THEN
    RAISE EXCEPTION 'Debes subir un comprobante';
  END IF;

  v_method := NULLIF(TRIM(COALESCE(p_payment_method, '')), '');
  v_ref := NULLIF(TRIM(COALESCE(p_reference, '')), '');

  INSERT INTO payouts (driver_id, amount_usd, type, status, proof_url, description, created_by)
  VALUES (v_driver_id, p_amount_usd, 'driver_pay_platform', 'pendiente', p_proof_url,
          'Pago del conductor a la plataforma'
            || CASE WHEN v_method IS NOT NULL THEN ' — ' || v_method ELSE '' END
            || CASE WHEN v_ref IS NOT NULL THEN ' (Ref: ' || v_ref || ')' ELSE '' END,
          v_driver_id)
  RETURNING id INTO v_payout_id;

  -- Notificar admin/encargado
  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT id, 'Pago de conductor por aprobar',
         'Un conductor pagó ' || p_amount_usd || '$ a la plataforma. Revisar.',
         'payout_driver_pay',
         jsonb_build_object('payout_id', v_payout_id, 'url', '/admin/liquidaciones')
  FROM profiles WHERE role IN ('super_admin', 'encargado');

  RETURN v_payout_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.driver_pay_to_platform(numeric, text, text, text)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.driver_pay_to_platform FROM anon;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 058: pago del conductor registra método y referencia' AS estado;

SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'driver_pay_to_platform'
ORDER BY 2;
