-- ============================================================
-- BUNRIDER - Migración 112: MÉTODOS DE PAGO REALES Y TESORERÍA
-- ------------------------------------------------------------
-- OBJETIVO
--   Saber con exactitud cuánto dinero hay en EFECTIVO, cuánto en
--   BANCO (Pago Móvil/Zelle) y cuánto está pendiente por cobrar,
--   además de un FONDO DE CAJA inicial por ciudad.
--
-- QUÉ SE HACE
--   1) Columnas payment_method en payouts y transactions.
--   2) Backfill desde las descripciones existentes (sin acentos).
--   3) Todas las RPC que mueven dinero guardan el método.
--   4) Los cobros manuales crean también un payout aprobado para
--      que la tesorería tenga un único libro de dinero externo.
--   5) get_treasury_overview devuelve buckets exactos:
--      efectivo / digital / billetera / sin clasificar + cuadre.
--   6) Fondo de caja inicial por ciudad (zones).
--   7) get_admin_transactions gana columna y filtro por método.
--
-- DECISIONES
--   - Columnas nullable (ALTER metadata-only). Sin índices nuevos:
--     a este volumen un seq scan es óptimo y un índice solo
--     encarecería las escrituras. Se documenta el índice parcial
--     a crear cuando transactions supere ~50k filas.
--   - El método nuevo va al final con DEFAULT NULL: las llamadas
--     viejas siguen funcionando; se eliminan sobrecargas ambiguas.
--   - La base permite NULL por compatibilidad. La UI siempre envía
--     el método; si falta, se muestra "sin clasificar" y NUNCA se
--     asume efectivo ni banco.
--   - adjust_driver_debt sigue siendo un AJUSTE (no dinero
--     externo): guarda el método para auditoría pero no suma caja.
--   - admin_collect_driver_debt sí es dinero real: crea payout.
--
-- COSTO: 3 columnas, 2 helpers, 0 tablas, 0 cron, 0 índices.
-- ============================================================

-- ============================================================
-- 1. ESQUEMA
-- ============================================================
ALTER TABLE public.payouts
  ADD COLUMN IF NOT EXISTS payment_method TEXT;
ALTER TABLE public.transactions
  ADD COLUMN IF NOT EXISTS payment_method TEXT;
ALTER TABLE public.zones
  ADD COLUMN IF NOT EXISTS cash_opening_balance_usd NUMERIC(12,2) NOT NULL DEFAULT 0;

COMMENT ON COLUMN public.payouts.payment_method IS
  'Método real usado en el pago (Efectivo, Pago Móvil, Zelle...). NULL = histórico sin clasificar.';
COMMENT ON COLUMN public.transactions.payment_method IS
  'Método real de la recarga o cobro. NULL = histórico sin clasificar.';
COMMENT ON COLUMN public.zones.cash_opening_balance_usd IS
  'Fondo de caja inicial de la ciudad (efectivo físico al empezar a usar la app).';

-- ============================================================
-- 2. HELPERS DE CLASIFICACIÓN (internos, sin acceso directo)
-- ============================================================
CREATE OR REPLACE FUNCTION public.normalize_method_text(p_text TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT translate(lower(coalesce(p_text, '')), 'áéíóúüñ', 'aeiouun')
$$;

CREATE OR REPLACE FUNCTION public.payment_method_kind(p_method TEXT)
RETURNS TEXT
LANGUAGE sql
IMMUTABLE
AS $$
  SELECT CASE
    WHEN NULLIF(btrim(coalesce(p_method, '')), '') IS NULL THEN NULL
    WHEN public.normalize_method_text(p_method) LIKE '%efectivo%'
      OR public.normalize_method_text(p_method) LIKE '%cash%' THEN 'efectivo'
    WHEN public.normalize_method_text(p_method) LIKE '%billetera%'
      OR public.normalize_method_text(p_method) LIKE '%wallet%' THEN 'billetera'
    ELSE 'externo'
  END
$$;

REVOKE ALL ON FUNCTION public.normalize_method_text(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.payment_method_kind(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.normalize_method_text(text) TO service_role;
GRANT EXECUTE ON FUNCTION public.payment_method_kind(text) TO service_role;

-- ============================================================
-- 3. BACKFILL (idempotente: solo filas NULL)
-- ------------------------------------------------------------
-- Las descripciones las generan nuestras RPC con el nombre exacto
-- del método, así que basta buscar el nombre dentro del texto.
-- normalize_method_text evita fallos por tildes (Pago Móvil /
-- Pago Movil) sin instalar la extensión unaccent.
-- ============================================================
UPDATE public.payouts po
SET payment_method = (
  SELECT pm.name
  FROM public.payment_methods pm
  WHERE po.description IS NOT NULL
    AND public.normalize_method_text(po.description)
        LIKE '%' || public.normalize_method_text(pm.name) || '%'
  ORDER BY length(pm.name) DESC
  LIMIT 1
)
WHERE po.payment_method IS NULL
  AND po.description IS NOT NULL;

UPDATE public.transactions t
SET payment_method = (
  SELECT pm.name
  FROM public.payment_methods pm
  WHERE t.description IS NOT NULL
    AND public.normalize_method_text(t.description)
        LIKE '%' || public.normalize_method_text(pm.name) || '%'
  ORDER BY length(pm.name) DESC
  LIMIT 1
)
WHERE t.payment_method IS NULL
  AND t.type = 'recarga'
  AND t.description IS NOT NULL;

-- ============================================================
-- 4. RECARGA DEL CLIENTE: guarda el método en la columna
--    (se elimina la sobrecarga vieja de 3 argumentos)
-- ============================================================
DROP FUNCTION IF EXISTS public.request_wallet_recharge(numeric, text, text);

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
  v_method TEXT;
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
      || CASE WHEN v_method IS NOT NULL THEN ' — ' || v_method ELSE '' END,
    p_proof_url, p_reference, v_method
  )
  RETURNING id INTO v_txn_id;

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
REVOKE ALL ON FUNCTION public.request_wallet_recharge(numeric, text, text, text)
  FROM PUBLIC, anon;

-- ============================================================
-- 5. PAGO DEL CONDUCTOR A LA PLATAFORMA: guarda el método
--    (misma firma de 5 argumentos)
-- ============================================================
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

  INSERT INTO public.payouts (
    driver_id, amount_usd, type, status, proof_url,
    description, created_by, payment_method
  ) VALUES (
    v_driver_id, v_amount_usd, 'driver_pay_platform', 'pendiente', v_proof,
    v_description, v_driver_id, v_method
  )
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

REVOKE ALL ON FUNCTION public.driver_pay_to_platform(numeric, text, text, text, numeric)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.driver_pay_to_platform(numeric, text, text, text, numeric)
  TO authenticated, service_role;

-- ============================================================
-- 6. PLATAFORMA PAGA AL CONDUCTOR: método en el payout
--    (nueva firma con p_payment_method al final)
-- ============================================================
DROP FUNCTION IF EXISTS public.admin_pay_driver_manual(uuid, numeric, text);

CREATE OR REPLACE FUNCTION public.admin_pay_driver_manual(
  p_driver_id UUID,
  p_amount_usd NUMERIC,
  p_description TEXT DEFAULT NULL,
  p_payment_method TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_role TEXT;
  v_wallet RECORD;
  v_payout_id UUID;
  v_method TEXT;
  v_description TEXT;
BEGIN
  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  v_role := public.get_user_role(v_admin_id)::text;
  IF v_role IS NULL OR v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('admin_pay_driver_manual', 20);

  IF p_amount_usd IS NULL OR p_amount_usd <= 0 THEN
    RAISE EXCEPTION 'Monto inválido';
  END IF;

  v_method := NULLIF(TRIM(COALESCE(p_payment_method, '')), '');
  IF v_method IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM payment_methods WHERE name = v_method) THEN
    RAISE EXCEPTION 'Método de pago no válido';
  END IF;

  IF v_role = 'encargado'
     AND (public.caller_zone_id() IS NULL
          OR NOT EXISTS (
            SELECT 1 FROM profiles p
            WHERE p.id = p_driver_id AND p.zone_id = public.caller_zone_id()
          )) THEN
    RAISE EXCEPTION 'No autorizado para pagar a conductores de otra ciudad';
  END IF;

  SELECT * INTO v_wallet FROM wallets WHERE user_id = p_driver_id;
  IF v_wallet.id IS NULL THEN
    RAISE EXCEPTION 'Billetera del conductor no encontrada';
  END IF;

  IF v_wallet.balance_usd < p_amount_usd THEN
    RAISE EXCEPTION USING MESSAGE =
      format('El conductor solo tiene disponible: $%s', v_wallet.balance_usd);
  END IF;

  v_description := COALESCE(NULLIF(TRIM(p_description), ''), 'Pago de la plataforma al conductor');

  INSERT INTO payouts (
    driver_id, amount_usd, type, status, description, created_by, payment_method
  ) VALUES (
    p_driver_id, p_amount_usd, 'platform_pay_driver', 'pendiente',
    v_description, v_admin_id, v_method
  )
  RETURNING id INTO v_payout_id;

  INSERT INTO notifications (user_id, title, body, type, data)
  VALUES (
    p_driver_id,
    'Pago disponible',
    CONCAT('La plataforma te pagará $', p_amount_usd, '. Confirma cuando lo recibas.'),
    'payout_platform_pay',
    jsonb_build_object('payout_id', v_payout_id, 'url', '/conductor/billetera')
  );

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (
    v_admin_id, 'ADMIN_PAY_DRIVER_MANUAL', 'payout', v_payout_id,
    jsonb_build_object(
      'driver_id', p_driver_id,
      'amount_usd', p_amount_usd,
      'description', v_description,
      'payment_method', v_method
    )
  );

  RETURN v_payout_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_pay_driver_manual(uuid, numeric, text, text)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.admin_pay_driver_manual(uuid, numeric, text, text)
  FROM PUBLIC, anon;

-- ============================================================
-- 7. APROBAR PAGOS: método al aprobar (nueva firma con método)
-- ============================================================
DROP FUNCTION IF EXISTS public.approve_payout(uuid, boolean);

CREATE OR REPLACE FUNCTION public.approve_payout(
  p_payout_id uuid,
  p_approve boolean,
  p_payment_method text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_admin_id uuid := auth.uid();
  v_role text;
  v_payout RECORD;
  v_wallet RECORD;
  v_driver_zone uuid;
  v_debt numeric;
  v_method text;
  v_effective_method text;
BEGIN
  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  v_role := public.get_user_role(v_admin_id)::text;
  IF v_role IS NULL OR v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('approve_payout', 30);

  v_method := NULLIF(TRIM(COALESCE(p_payment_method, '')), '');
  IF v_method IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM payment_methods WHERE name = v_method) THEN
    RAISE EXCEPTION 'Método de pago no válido';
  END IF;

  SELECT * INTO v_payout FROM public.payouts WHERE id = p_payout_id FOR UPDATE;
  IF v_payout.id IS NULL THEN
    RAISE EXCEPTION 'Pago no encontrado';
  END IF;

  SELECT zone_id INTO v_driver_zone FROM public.profiles WHERE id = v_payout.driver_id;
  IF v_role = 'encargado'
     AND (public.caller_zone_id() IS NULL
          OR COALESCE(v_driver_zone, '00000000-0000-0000-0000-000000000000'::uuid)
             != public.caller_zone_id()) THEN
    RAISE EXCEPTION 'No autorizado para pagos de otra ciudad';
  END IF;

  IF v_payout.status != 'pendiente' THEN
    RAISE EXCEPTION 'El pago ya fue procesado';
  END IF;

  IF v_payout.type = 'driver_pay_platform' AND p_approve THEN
    v_effective_method := COALESCE(v_payout.payment_method, v_method);

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
        payment_method = v_effective_method,
        updated_at = NOW()
    WHERE id = p_payout_id;

    INSERT INTO public.transactions (
      wallet_id, user_id, type, amount_usd, status, description, payment_method
    ) VALUES (
      v_wallet.id, v_payout.driver_id, 'credito', v_payout.amount_usd, 'completado',
      'Pago del conductor a la plataforma (aprobado)', v_effective_method
    );

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
    v_effective_method := COALESCE(v_method, v_payout.payment_method);

    UPDATE public.payouts
    SET status = 'aprobado',
        reviewed_by = v_admin_id,
        payment_method = v_effective_method,
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
          jsonb_build_object(
            'approved', p_approve,
            'type', v_payout.type,
            'amount_usd', v_payout.amount_usd,
            'driver_id', v_payout.driver_id,
            'zone_id', v_driver_zone,
            'payment_method', COALESCE(v_effective_method, v_payout.payment_method, v_method)
          ));

  RETURN jsonb_build_object('success', TRUE, 'payout_id', p_payout_id, 'status',
    (SELECT status FROM public.payouts WHERE id = p_payout_id));
END;
$function$;

GRANT EXECUTE ON FUNCTION public.approve_payout(uuid, boolean, text)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.approve_payout(uuid, boolean, text)
  FROM PUBLIC, anon;

-- ============================================================
-- 8. AJUSTE DE DEUDA (no es dinero externo; guarda método)
-- ============================================================
DROP FUNCTION IF EXISTS public.adjust_driver_debt(uuid, numeric, text);

CREATE OR REPLACE FUNCTION public.adjust_driver_debt(
  p_driver_id UUID,
  p_amount_usd NUMERIC,
  p_description TEXT DEFAULT 'Ajuste de deuda',
  p_payment_method TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_role TEXT;
  v_wallet RECORD;
  v_method TEXT;
  v_description TEXT;
BEGIN
  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  v_role := public.get_user_role(v_admin_id)::text;
  IF v_role IS NULL OR v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('adjust_driver_debt', 20);

  IF v_role = 'encargado'
     AND (public.caller_zone_id() IS NULL
          OR NOT EXISTS (
            SELECT 1 FROM profiles p
            WHERE p.id = p_driver_id AND p.zone_id = public.caller_zone_id()
          )) THEN
    RAISE EXCEPTION 'No autorizado para ajustar deuda de otra ciudad';
  END IF;

  v_method := NULLIF(TRIM(COALESCE(p_payment_method, '')), '');
  IF v_method IS NOT NULL
     AND NOT EXISTS (SELECT 1 FROM payment_methods WHERE name = v_method) THEN
    RAISE EXCEPTION 'Método de pago no válido';
  END IF;

  v_description := COALESCE(NULLIF(TRIM(p_description), ''), 'Ajuste de deuda');

  SELECT * INTO v_wallet FROM wallets WHERE user_id = p_driver_id FOR UPDATE;
  IF v_wallet.id IS NULL THEN
    RAISE EXCEPTION 'Billetera del conductor no encontrada';
  END IF;

  UPDATE wallets
  SET balance_usd = balance_usd + p_amount_usd,
      updated_at = NOW()
  WHERE user_id = p_driver_id;

  INSERT INTO transactions (
    wallet_id, user_id, type, amount_usd, status,
    description, reviewed_by, payment_method
  ) VALUES (
    v_wallet.id, p_driver_id, 'ajuste', p_amount_usd, 'completado',
    v_description, v_admin_id, v_method
  );

  PERFORM public.notify_user(
    p_driver_id,
    'Ajuste de deuda',
    'Tu billetera fue ajustada: $' || p_amount_usd || '. Motivo: ' || v_description,
    'debt_adjustment',
    jsonb_build_object('amount', p_amount_usd, 'url', '/conductor/billetera')
  );

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_admin_id, 'ADJUST_DRIVER_DEBT', 'profile', p_driver_id,
          jsonb_build_object(
            'amount_usd', p_amount_usd,
            'description', v_description,
            'payment_method', v_method
          ));

  RETURN jsonb_build_object(
    'success', TRUE,
    'driver_id', p_driver_id,
    'nuevo_balance', ROUND(COALESCE(v_wallet.balance_usd, 0) + p_amount_usd, 2)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.adjust_driver_debt(uuid, numeric, text, text)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.adjust_driver_debt(uuid, numeric, text, text)
  FROM PUBLIC, anon;

-- ============================================================
-- 9. CONFIRMACIÓN DEL CONDUCTOR: copia el método al débito
-- ============================================================
CREATE OR REPLACE FUNCTION public.driver_confirm_payout(p_payout_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_driver_id UUID := auth.uid();
  v_payout RECORD;
  v_wallet RECORD;
  v_new_balance NUMERIC;
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  IF NOT public.is_account_active(v_driver_id) THEN
    RAISE EXCEPTION 'Tu cuenta no está activa. Contacta a soporte.';
  END IF;

  SELECT * INTO v_payout FROM payouts WHERE id = p_payout_id FOR UPDATE;
  IF v_payout.id IS NULL THEN
    RAISE EXCEPTION 'Pago no encontrado';
  END IF;

  IF v_payout.driver_id != v_driver_id THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF v_payout.type != 'platform_pay_driver' OR v_payout.status != 'aprobado' THEN
    RAISE EXCEPTION 'El pago no está listo para confirmar. Debe estar aprobado por la plataforma.';
  END IF;

  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_driver_id;
  IF v_wallet.balance_usd < v_payout.amount_usd THEN
    RAISE EXCEPTION USING MESSAGE = format('Saldo insuficiente para confirmar este pago. Disponible: $%s', v_wallet.balance_usd);
  END IF;

  UPDATE wallets
  SET balance_usd = balance_usd - v_payout.amount_usd,
      updated_at = NOW()
  WHERE user_id = v_driver_id;

  SELECT balance_usd INTO v_new_balance FROM wallets WHERE user_id = v_driver_id;

  UPDATE payouts SET status = 'confirmado', updated_at = NOW() WHERE id = p_payout_id;

  INSERT INTO transactions (
    wallet_id, user_id, type, amount_usd, status, description, reviewed_by, payment_method
  ) VALUES (
    v_wallet.id, v_driver_id, 'debito', v_payout.amount_usd, 'completado',
    'Pago recibido de la plataforma (confirmado)', v_driver_id, v_payout.payment_method
  );

  RETURN jsonb_build_object('success', TRUE, 'new_balance', v_new_balance);
END;
$function$;

GRANT EXECUTE ON FUNCTION public.driver_confirm_payout(uuid)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.driver_confirm_payout(uuid)
  FROM PUBLIC, anon;

-- ============================================================
-- 10. COBRO MANUAL DE DEUDA: payout aprobado + método
--     (la tesorería cuenta SOLO el payout, no la transacción)
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_collect_driver_debt(
  p_driver_id UUID,
  p_amount_usd NUMERIC,
  p_payment_method TEXT,
  p_reference TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id    UUID := auth.uid();
  v_role        TEXT;
  v_wallet      RECORD;
  v_profile     RECORD;
  v_amount      NUMERIC;
  v_method      TEXT;
  v_ref         TEXT;
  v_debt        NUMERIC;
  v_new_balance NUMERIC;
  v_description TEXT;
  v_payout_id   UUID;
BEGIN
  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  v_role := public.get_user_role(v_admin_id)::text;
  IF v_role IS NULL OR v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('admin_collect_driver_debt', 20);

  SELECT id, full_name, role::text AS role, zone_id
  INTO v_profile
  FROM profiles
  WHERE id = p_driver_id;

  IF v_profile.id IS NULL OR v_profile.role <> 'conductor' THEN
    RAISE EXCEPTION 'Conductor no encontrado';
  END IF;

  IF v_role = 'encargado'
     AND (public.caller_zone_id() IS NULL
          OR v_profile.zone_id IS DISTINCT FROM public.caller_zone_id()) THEN
    RAISE EXCEPTION 'No autorizado para cobrar a conductores de otra ciudad';
  END IF;

  v_amount := ROUND(COALESCE(p_amount_usd, 0), 2);
  IF v_amount <= 0 THEN
    RAISE EXCEPTION 'Monto inválido';
  END IF;

  v_method := NULLIF(TRIM(COALESCE(p_payment_method, '')), '');
  IF v_method IS NULL THEN
    RAISE EXCEPTION 'Selecciona un método de pago';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM payment_methods WHERE name = v_method) THEN
    RAISE EXCEPTION 'Método de pago no válido';
  END IF;

  v_ref := NULLIF(TRIM(COALESCE(p_reference, '')), '');

  SELECT * INTO v_wallet
  FROM wallets
  WHERE user_id = p_driver_id
  FOR UPDATE;

  IF v_wallet.id IS NULL THEN
    RAISE EXCEPTION 'Billetera del conductor no encontrada';
  END IF;

  v_debt := ROUND(GREATEST(0, -COALESCE(v_wallet.balance_usd, 0)), 2);
  IF v_debt <= 0 THEN
    RAISE EXCEPTION 'Este conductor no tiene deuda pendiente';
  END IF;

  IF v_amount > v_debt THEN
    RAISE EXCEPTION USING MESSAGE =
      format('El monto supera la deuda actual ($%s)', v_debt);
  END IF;

  v_new_balance := ROUND(COALESCE(v_wallet.balance_usd, 0) + v_amount, 2);

  UPDATE wallets
  SET balance_usd = v_new_balance,
      updated_at = NOW()
  WHERE id = v_wallet.id;

  v_description := 'Cobro de deuda - ' || v_method
    || CASE WHEN v_ref IS NOT NULL THEN ' (Ref: ' || v_ref || ')' ELSE '' END;

  INSERT INTO transactions (
    wallet_id, user_id, type, amount_usd, status,
    description, reference, reviewed_by, reviewed_at, payment_method
  ) VALUES (
    v_wallet.id, p_driver_id, 'credito', v_amount, 'completado',
    v_description, v_ref, v_admin_id, NOW(), v_method
  );

  INSERT INTO payouts (
    driver_id, amount_usd, type, status, description,
    created_by, reviewed_by, payment_method
  ) VALUES (
    p_driver_id, v_amount, 'driver_pay_platform', 'aprobado', v_description,
    v_admin_id, v_admin_id, v_method
  )
  RETURNING id INTO v_payout_id;

  PERFORM public.notify_user(
    p_driver_id,
    'Pago registrado',
    'Registramos tu pago de $' || v_amount || ' (' || v_method || '). '
      || 'Deuda restante: $' || ROUND(GREATEST(0, -v_new_balance), 2),
    'debt_payment',
    jsonb_build_object(
      'amount_usd', v_amount,
      'payment_method', v_method,
      'balance_usd', v_new_balance,
      'url', '/conductor/billetera'
    )
  );

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (
    v_admin_id, 'ADJUST_DRIVER_DEBT', 'profile', p_driver_id,
    jsonb_build_object(
      'amount_usd', v_amount,
      'payment_method', v_method,
      'reference', v_ref,
      'previous_balance', v_wallet.balance_usd,
      'new_balance', v_new_balance,
      'payout_id', v_payout_id,
      'source', 'estado_cuentas'
    )
  );

  RETURN jsonb_build_object(
    'success', TRUE,
    'driver_id', p_driver_id,
    'amount_usd', v_amount,
    'nuevo_balance', v_new_balance,
    'deuda_restante', ROUND(GREATEST(0, -v_new_balance), 2),
    'payout_id', v_payout_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_collect_driver_debt(uuid, numeric, text, text)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.admin_collect_driver_debt(uuid, numeric, text, text)
  FROM PUBLIC, anon;

-- ============================================================
-- 11. RESUMEN DE TESORERÍA: buckets exactos + fondo de caja
--     Una sola pasada (CTE UNION ALL) por transacciones,
--     viajes y payouts.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_treasury_overview(p_zone_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id    UUID := auth.uid();
  v_caller_zone UUID;
  v_zone        UUID;
  v_role        TEXT;

  v_recargas          NUMERIC := 0;
  v_viajes_pm         NUMERIC := 0;
  v_cobros            NUMERIC := 0;
  v_pagos             NUMERIC := 0;
  v_banco_total       NUMERIC := 0;

  v_efectivo_in       NUMERIC := 0;
  v_efectivo_out      NUMERIC := 0;
  v_digital_in        NUMERIC := 0;
  v_digital_out       NUMERIC := 0;
  v_billetera_in      NUMERIC := 0;
  v_billetera_out     NUMERIC := 0;
  v_null_in           NUMERIC := 0;
  v_null_out          NUMERIC := 0;

  v_recargas_efectivo NUMERIC := 0;
  v_efectivo_cobrado  NUMERIC := 0;
  v_efectivo_pagado   NUMERIC := 0;
  v_en_caja           NUMERIC := 0;
  v_fondo             NUMERIC := 0;

  v_conductores_deben     NUMERIC := 0;
  v_app_debe_conductores  NUMERIC := 0;
  v_clientes_deben        NUMERIC := 0;
  v_app_debe_clientes     NUMERIC := 0;

  v_conductores_total        BIGINT := 0;
  v_conductores_con_deuda    BIGINT := 0;
  v_conductores_con_saldo    BIGINT := 0;
  v_conductores_sobre_limite BIGINT := 0;
BEGIN
  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  v_role := public.get_user_role(v_admin_id)::text;
  IF v_role IS NULL OR v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  v_caller_zone := public.caller_zone_id();
  IF v_role = 'encargado' AND v_caller_zone IS NULL THEN
    RAISE EXCEPTION 'Tu cuenta no tiene una ciudad asignada';
  END IF;
  v_zone := COALESCE(v_caller_zone, p_zone_id);

  WITH mov AS (
    SELECT 'recarga'::text AS origen,
           'in'::text AS direccion,
           t.amount_usd AS monto,
           public.payment_method_kind(t.payment_method) AS kind
    FROM transactions t
    JOIN profiles p ON p.id = t.user_id
    WHERE t.type = 'recarga'
      AND t.status IN ('aprobado', 'completado')
      AND p.role = 'cliente'
      AND (v_zone IS NULL OR p.zone_id = v_zone)

    UNION ALL

    SELECT 'viaje_pago_movil', 'in', r.final_fare_usd, 'externo'
    FROM rides r
    WHERE LOWER(r.payment_method) IN ('pago móvil', 'pago movil')
      AND r.proof_status = 'aprobado'
      AND (v_zone IS NULL OR r.origin_zone_id = v_zone)

    UNION ALL

    SELECT 'cobro_conductor', 'in', po.amount_usd,
           public.payment_method_kind(po.payment_method)
    FROM payouts po
    LEFT JOIN profiles p ON p.id = po.driver_id
    WHERE po.type = 'driver_pay_platform'
      AND po.status = 'aprobado'
      AND (v_zone IS NULL OR p.zone_id = v_zone)

    UNION ALL

    SELECT 'pago_conductor', 'out', po.amount_usd,
           public.payment_method_kind(po.payment_method)
    FROM payouts po
    LEFT JOIN profiles p ON p.id = po.driver_id
    WHERE po.type = 'platform_pay_driver'
      AND po.status IN ('aprobado', 'confirmado')
      AND (v_zone IS NULL OR p.zone_id = v_zone)
  )
  SELECT
    COALESCE(SUM(monto) FILTER (WHERE origen = 'recarga'), 0),
    COALESCE(SUM(monto) FILTER (WHERE origen = 'viaje_pago_movil'), 0),
    COALESCE(SUM(monto) FILTER (WHERE origen = 'cobro_conductor'), 0),
    COALESCE(SUM(monto) FILTER (WHERE origen = 'pago_conductor'), 0),
    COALESCE(SUM(monto) FILTER (WHERE direccion = 'in' AND kind = 'efectivo'), 0),
    COALESCE(SUM(monto) FILTER (WHERE direccion = 'out' AND kind = 'efectivo'), 0),
    COALESCE(SUM(monto) FILTER (WHERE direccion = 'in' AND kind = 'externo'), 0),
    COALESCE(SUM(monto) FILTER (WHERE direccion = 'out' AND kind = 'externo'), 0),
    COALESCE(SUM(monto) FILTER (WHERE direccion = 'in' AND kind = 'billetera'), 0),
    COALESCE(SUM(monto) FILTER (WHERE direccion = 'out' AND kind = 'billetera'), 0),
    COALESCE(SUM(monto) FILTER (WHERE direccion = 'in' AND kind IS NULL), 0),
    COALESCE(SUM(monto) FILTER (WHERE direccion = 'out' AND kind IS NULL), 0),
    COALESCE(SUM(monto) FILTER (WHERE origen = 'recarga' AND kind = 'efectivo'), 0),
    COALESCE(SUM(monto) FILTER (WHERE origen = 'cobro_conductor' AND kind = 'efectivo'), 0),
    COALESCE(SUM(monto) FILTER (WHERE origen = 'pago_conductor' AND kind = 'efectivo'), 0)
  INTO
    v_recargas, v_viajes_pm, v_cobros, v_pagos,
    v_efectivo_in, v_efectivo_out,
    v_digital_in, v_digital_out,
    v_billetera_in, v_billetera_out,
    v_null_in, v_null_out,
    v_recargas_efectivo, v_efectivo_cobrado, v_efectivo_pagado
  FROM mov;

  v_banco_total := v_recargas + v_viajes_pm + v_cobros - v_pagos;
  v_en_caja := v_efectivo_in - v_efectivo_out;

  IF v_zone IS NULL THEN
    SELECT COALESCE(SUM(cash_opening_balance_usd), 0) INTO v_fondo FROM zones;
  ELSE
    SELECT COALESCE(cash_opening_balance_usd, 0) INTO v_fondo FROM zones WHERE id = v_zone;
  END IF;

  SELECT
    COALESCE(SUM(ABS(w.balance_usd)) FILTER (WHERE w.balance_usd < 0), 0),
    COALESCE(SUM(w.balance_usd) FILTER (WHERE w.balance_usd > 0), 0),
    COUNT(*),
    COUNT(*) FILTER (WHERE w.balance_usd < 0),
    COUNT(*) FILTER (WHERE w.balance_usd > 0),
    COUNT(*) FILTER (WHERE w.balance_usd < 0
                       AND w.balance_usd < -COALESCE(w.debt_limit_usd, 0))
  INTO v_conductores_deben, v_app_debe_conductores,
       v_conductores_total, v_conductores_con_deuda,
       v_conductores_con_saldo, v_conductores_sobre_limite
  FROM wallets w
  JOIN profiles pr ON pr.id = w.user_id
  WHERE pr.role = 'conductor'
    AND (v_zone IS NULL OR pr.zone_id = v_zone);

  SELECT
    COALESCE(SUM(ABS(w.balance_usd)) FILTER (WHERE w.balance_usd < 0), 0),
    COALESCE(SUM(w.balance_usd) FILTER (WHERE w.balance_usd > 0), 0)
  INTO v_clientes_deben, v_app_debe_clientes
  FROM wallets w
  JOIN profiles pr ON pr.id = w.user_id
  WHERE pr.role = 'cliente'
    AND (v_zone IS NULL OR pr.zone_id = v_zone);

  RETURN jsonb_build_object(
    'zona', jsonb_build_object(
      'zone_id', v_zone,
      'es_global', v_zone IS NULL,
      'forzada_por_rol', v_caller_zone IS NOT NULL
    ),
    'banco', jsonb_build_object(
      'recargas', ROUND(v_recargas, 2),
      'viajes_pago_movil', ROUND(v_viajes_pm, 2),
      'cobros_conductores', ROUND(v_cobros, 2),
      'pagos_conductores', ROUND(v_pagos, 2),
      'total', ROUND(v_banco_total, 2),
      'digital', jsonb_build_object(
        'ingresos', ROUND(v_digital_in, 2),
        'egresos', ROUND(v_digital_out, 2),
        'neto', ROUND(v_digital_in - v_digital_out, 2)
      ),
      'billetera', jsonb_build_object(
        'ingresos', ROUND(v_billetera_in, 2),
        'egresos', ROUND(v_billetera_out, 2),
        'neto', ROUND(v_billetera_in - v_billetera_out, 2)
      ),
      'sin_clasificar', jsonb_build_object(
        'ingresos', ROUND(v_null_in, 2),
        'egresos', ROUND(v_null_out, 2),
        'neto', ROUND(v_null_in - v_null_out, 2)
      )
    ),
    'efectivo', jsonb_build_object(
      'por_cobrar', ROUND(v_conductores_deben, 2),
      'recargas_efectivo', ROUND(v_recargas_efectivo, 2),
      'cobrado_conductores', ROUND(v_efectivo_cobrado, 2),
      'pagado_conductores', ROUND(v_efectivo_pagado, 2),
      'en_caja', ROUND(v_en_caja, 2),
      'fondo_inicial', ROUND(v_fondo, 2),
      'en_caja_total', ROUND(v_fondo + v_en_caja, 2)
    ),
    'deudas', jsonb_build_object(
      'conductores_deben', ROUND(v_conductores_deben, 2),
      'app_debe_conductores', ROUND(v_app_debe_conductores, 2),
      'neto_conductores', ROUND(v_app_debe_conductores - v_conductores_deben, 2),
      'clientes_deben', ROUND(v_clientes_deben, 2),
      'app_debe_clientes', ROUND(v_app_debe_clientes, 2),
      'neto_general', ROUND(
        v_banco_total - v_app_debe_conductores - v_app_debe_clientes
        + v_conductores_deben + v_clientes_deben, 2)
    ),
    'conteos', jsonb_build_object(
      'conductores_total', v_conductores_total,
      'conductores_con_deuda', v_conductores_con_deuda,
      'conductores_con_saldo', v_conductores_con_saldo,
      'conductores_sobre_limite', v_conductores_sobre_limite
    ),
    'cuadre_diferencia', ROUND(
      v_banco_total
      - (v_en_caja
         + (v_digital_in - v_digital_out)
         + (v_billetera_in - v_billetera_out)
         + (v_null_in - v_null_out)), 2)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_treasury_overview(uuid)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_treasury_overview(uuid)
  FROM PUBLIC, anon;

-- ============================================================
-- 12. TRANSACCIONES: columna y filtro por método
--     (nueva firma con p_metodo al final)
-- ============================================================
DROP FUNCTION IF EXISTS public.get_admin_transactions(
  timestamptz, timestamptz, text, text, uuid, text, integer, integer
);

CREATE OR REPLACE FUNCTION public.get_admin_transactions(
  p_fecha_inicio TIMESTAMPTZ DEFAULT NOW() - INTERVAL '30 days',
  p_fecha_fin TIMESTAMPTZ DEFAULT NOW(),
  p_tipo TEXT DEFAULT NULL,
  p_rol TEXT DEFAULT NULL,
  p_usuario_id UUID DEFAULT NULL,
  p_busqueda TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0,
  p_metodo TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_role TEXT;
  v_caller_zone UUID;
  v_metodo TEXT := NULLIF(TRIM(COALESCE(p_metodo, '')), '');
  v_total INTEGER := 0;
  v_items JSONB;
BEGIN
  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  v_role := public.get_user_role(v_admin_id)::text;
  IF v_role IS NULL OR v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  v_caller_zone := public.caller_zone_id();
  IF v_role = 'encargado' AND v_caller_zone IS NULL THEN
    RAISE EXCEPTION 'Tu cuenta no tiene una ciudad asignada';
  END IF;

  IF p_limit > 100 THEN p_limit := 100; END IF;
  IF p_limit < 1 THEN p_limit := 50; END IF;
  IF p_offset < 0 THEN p_offset := 0; END IF;

  IF p_busqueda IS NOT NULL AND TRIM(p_busqueda) = '' THEN
    p_busqueda := NULL;
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM (
    SELECT id
    FROM (
      SELECT t.id AS id
      FROM transactions t
      LEFT JOIN profiles pr ON pr.id = t.user_id
      WHERE t.created_at >= p_fecha_inicio
        AND t.created_at <= p_fecha_fin
        AND (p_tipo IS NULL OR t.type::text = p_tipo)
        AND (p_usuario_id IS NULL OR t.user_id = p_usuario_id)
        AND (v_caller_zone IS NULL OR pr.zone_id = v_caller_zone)
        AND (v_metodo IS NULL
             OR (v_metodo = 'sin_clasificar' AND t.type = 'recarga' AND t.payment_method IS NULL)
             OR t.payment_method = v_metodo)
        AND (p_busqueda IS NULL
             OR pr.full_name ILIKE '%' || p_busqueda || '%'
             OR pr.email ILIKE '%' || p_busqueda || '%'
             OR pr.phone ILIKE '%' || p_busqueda || '%'
             OR t.reference ILIKE '%' || p_busqueda || '%'
             OR t.ride_id IN (SELECT r.id FROM rides r WHERE UPPER(r.tracking_code) LIKE UPPER('%' || p_busqueda || '%')))
        AND (
          p_rol IS NULL
          OR (p_rol = 'cliente' AND pr.role = 'cliente')
          OR (p_rol = 'conductor' AND pr.role = 'conductor')
          OR (p_rol = 'admin' AND pr.role IN ('super_admin', 'encargado'))
        )
      UNION ALL
      SELECT po.id AS id
      FROM payouts po
      LEFT JOIN profiles pr ON pr.id = po.driver_id
      WHERE po.created_at >= p_fecha_inicio
        AND po.created_at <= p_fecha_fin
        AND (p_tipo IS NULL OR po.type::text = p_tipo)
        AND (p_usuario_id IS NULL OR po.driver_id = p_usuario_id)
        AND (v_caller_zone IS NULL OR pr.zone_id = v_caller_zone)
        AND (v_metodo IS NULL
             OR (v_metodo = 'sin_clasificar' AND po.payment_method IS NULL)
             OR po.payment_method = v_metodo)
        AND (p_busqueda IS NULL
             OR pr.full_name ILIKE '%' || p_busqueda || '%'
             OR pr.email ILIKE '%' || p_busqueda || '%'
             OR pr.phone ILIKE '%' || p_busqueda || '%'
             OR po.description ILIKE '%' || p_busqueda || '%'
             OR po.ride_id IN (SELECT r.id FROM rides r WHERE UPPER(r.tracking_code) LIKE UPPER('%' || p_busqueda || '%')))
        AND (
          p_rol IS NULL
          OR (p_rol = 'conductor' AND pr.role = 'conductor')
          OR (p_rol = 'admin' AND pr.role IN ('super_admin', 'encargado'))
        )
    ) sub
  ) sub2;

  SELECT COALESCE(jsonb_agg(t ORDER BY t.fecha DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT
      t.id::text AS id,
      'transaction' AS origen,
      t.created_at AS fecha,
      pr.full_name AS usuario,
      pr.role AS rol,
      t.user_id AS usuario_id,
      t.type::text AS tipo,
      t.amount_usd AS monto,
      t.status::text AS estado,
      t.description AS descripcion,
      t.reference AS referencia,
      t.ride_id AS viaje_id,
      NULL::text AS comprobante,
      COALESCE((SELECT balance_usd FROM wallets w WHERE w.id = t.wallet_id), 0) AS saldo_resultante,
      t.payment_method AS metodo
    FROM transactions t
    LEFT JOIN profiles pr ON pr.id = t.user_id
    WHERE t.created_at >= p_fecha_inicio
      AND t.created_at <= p_fecha_fin
      AND (p_tipo IS NULL OR t.type::text = p_tipo)
      AND (p_usuario_id IS NULL OR t.user_id = p_usuario_id)
      AND (v_caller_zone IS NULL OR pr.zone_id = v_caller_zone)
      AND (v_metodo IS NULL
           OR (v_metodo = 'sin_clasificar' AND t.type = 'recarga' AND t.payment_method IS NULL)
           OR t.payment_method = v_metodo)
      AND (p_busqueda IS NULL
           OR pr.full_name ILIKE '%' || p_busqueda || '%'
           OR pr.email ILIKE '%' || p_busqueda || '%'
           OR pr.phone ILIKE '%' || p_busqueda || '%'
           OR t.reference ILIKE '%' || p_busqueda || '%'
           OR t.ride_id IN (SELECT r.id FROM rides r WHERE UPPER(r.tracking_code) LIKE UPPER('%' || p_busqueda || '%')))
      AND (
        p_rol IS NULL
        OR (p_rol = 'cliente' AND pr.role = 'cliente')
        OR (p_rol = 'conductor' AND pr.role = 'conductor')
        OR (p_rol = 'admin' AND pr.role IN ('super_admin', 'encargado'))
      )

    UNION ALL

    SELECT
      po.id::text AS id,
      'payout' AS origen,
      po.created_at AS fecha,
      pr.full_name AS usuario,
      pr.role AS rol,
      po.driver_id AS usuario_id,
      po.type AS tipo,
      po.amount_usd AS monto,
      po.status AS estado,
      po.description AS descripcion,
      NULL::text AS referencia,
      po.ride_id AS viaje_id,
      po.proof_url AS comprobante,
      0 AS saldo_resultante,
      po.payment_method AS metodo
    FROM payouts po
    LEFT JOIN profiles pr ON pr.id = po.driver_id
    WHERE po.created_at >= p_fecha_inicio
      AND po.created_at <= p_fecha_fin
      AND (p_tipo IS NULL OR po.type::text = p_tipo)
      AND (p_usuario_id IS NULL OR po.driver_id = p_usuario_id)
      AND (v_caller_zone IS NULL OR pr.zone_id = v_caller_zone)
      AND (v_metodo IS NULL
           OR (v_metodo = 'sin_clasificar' AND po.payment_method IS NULL)
           OR po.payment_method = v_metodo)
      AND (p_busqueda IS NULL
           OR pr.full_name ILIKE '%' || p_busqueda || '%'
           OR pr.email ILIKE '%' || p_busqueda || '%'
           OR pr.phone ILIKE '%' || p_busqueda || '%'
           OR po.description ILIKE '%' || p_busqueda || '%'
           OR po.ride_id IN (SELECT r.id FROM rides r WHERE UPPER(r.tracking_code) LIKE UPPER('%' || p_busqueda || '%')))
      AND (
        p_rol IS NULL
        OR (p_rol = 'conductor' AND pr.role = 'conductor')
        OR (p_rol = 'admin' AND pr.role IN ('super_admin', 'encargado'))
      )
  ) t
  LIMIT p_limit OFFSET p_offset;

  RETURN jsonb_build_object('total', v_total, 'items', v_items);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_admin_transactions(
  timestamptz, timestamptz, text, text, uuid, text, integer, integer, text
) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_admin_transactions(
  timestamptz, timestamptz, text, text, uuid, text, integer, integer, text
) FROM PUBLIC, anon;

-- ============================================================
-- 13. FONDO DE CAJA INICIAL POR CIUDAD
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_set_cash_opening_balance(
  p_zone_id UUID,
  p_amount NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_role TEXT;
  v_prev NUMERIC := 0;
  v_amount NUMERIC;
BEGIN
  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  v_role := public.get_user_role(v_admin_id)::text;
  IF v_role IS NULL OR v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('admin_set_cash_opening_balance', 20);

  IF p_zone_id IS NULL THEN
    RAISE EXCEPTION 'Selecciona una ciudad';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM zones WHERE id = p_zone_id) THEN
    RAISE EXCEPTION 'Ciudad no encontrada';
  END IF;

  IF v_role = 'encargado'
     AND (public.caller_zone_id() IS NULL
          OR public.caller_zone_id() <> p_zone_id) THEN
    RAISE EXCEPTION 'No autorizado para cambiar el fondo de otra ciudad';
  END IF;

  v_amount := ROUND(COALESCE(p_amount, 0), 2);
  IF v_amount < 0 OR v_amount > 1000000 THEN
    RAISE EXCEPTION 'El fondo debe estar entre 0 y 1.000.000';
  END IF;

  SELECT cash_opening_balance_usd INTO v_prev
  FROM zones
  WHERE id = p_zone_id;

  UPDATE zones
  SET cash_opening_balance_usd = v_amount,
      updated_at = NOW()
  WHERE id = p_zone_id;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (
    v_admin_id, 'SET_CASH_OPENING_BALANCE', 'zone', p_zone_id,
    jsonb_build_object('previous', v_prev, 'new', v_amount)
  );

  RETURN jsonb_build_object(
    'success', TRUE,
    'zone_id', p_zone_id,
    'fondo_inicial', v_amount
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_set_cash_opening_balance(uuid, numeric)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.admin_set_cash_opening_balance(uuid, numeric)
  FROM PUBLIC, anon;

-- ============================================================
-- 14. VERIFICACIÓN
-- ============================================================
NOTIFY pgrst, 'reload schema';

SELECT 'columnas payment_method + fondo (esperado 3)' AS comprobacion,
       COUNT(*)::text AS valor
FROM information_schema.columns
WHERE table_schema = 'public'
  AND (
    (table_name = 'payouts' AND column_name = 'payment_method')
    OR (table_name = 'transactions' AND column_name = 'payment_method')
    OR (table_name = 'zones' AND column_name = 'cash_opening_balance_usd')
  )
UNION ALL
SELECT 'payouts clasificados / total', 
       (SELECT COUNT(*) FILTER (WHERE payment_method IS NOT NULL)::text || ' / ' || COUNT(*)::text
        FROM payouts)
UNION ALL
SELECT 'payouts sin clasificar',
       (SELECT COUNT(*)::text FROM payouts WHERE payment_method IS NULL)
UNION ALL
SELECT 'firmas viejas eliminadas (esperado 0)',
       (
         (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = 'public' AND p.proname = 'request_wallet_recharge'
            AND pg_get_function_identity_arguments(p.oid) = 'p_amount_usd numeric, p_proof_url text, p_reference text')::text
         || '/' ||
         (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = 'public' AND p.proname = 'admin_pay_driver_manual'
            AND pg_get_function_identity_arguments(p.oid) = 'p_driver_id uuid, p_amount_usd numeric, p_description text')::text
         || '/' ||
         (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = 'public' AND p.proname = 'approve_payout'
            AND pg_get_function_identity_arguments(p.oid) = 'p_payout_id uuid, p_approve boolean')::text
         || '/' ||
         (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = 'public' AND p.proname = 'adjust_driver_debt'
            AND pg_get_function_identity_arguments(p.oid) = 'p_driver_id uuid, p_amount_usd numeric, p_description text')::text
         || '/' ||
         (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = 'public' AND p.proname = 'get_admin_transactions'
            AND pg_get_function_identity_arguments(p.oid) = 'p_fecha_inicio timestamp with time zone, p_fecha_fin timestamp with time zone, p_tipo text, p_rol text, p_usuario_id uuid, p_busqueda text, p_limit integer, p_offset integer')::text
       )
UNION ALL
SELECT 'RPC nuevas con firma esperada (esperado 2)',
       (
         (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = 'public' AND p.proname = 'admin_set_cash_opening_balance')::text
         || '/' ||
         (SELECT COUNT(*) FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
          WHERE n.nspname = 'public' AND p.proname = 'get_admin_transactions'
            AND pg_get_function_identity_arguments(p.oid) LIKE '%p_metodo text')::text
       )
UNION ALL
SELECT 'anon sin EXECUTE en RPC de dinero (esperado 0)',
       COUNT(*)::text
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('get_treasury_overview','get_admin_transactions',
                    'admin_collect_driver_debt','admin_set_cash_opening_balance',
                    'admin_pay_driver_manual','approve_payout','adjust_driver_debt')
  AND has_function_privilege('anon', p.oid, 'EXECUTE');

SELECT '✅ Migración 112: métodos de pago reales y tesorería listo' AS estado;













