-- 138 - El admin puede liquidar un pago al conductor sin esperar su confirmacion
--
-- Problema: approve_payout deja el pago en 'aprobado' y NO toca la billetera;
-- solo driver_confirm_payout descuenta. Si el conductor no confirma, el saldo
-- del conductor sigue igual y en Estado de cuentas parece que se le debe todo.
--
-- Se agrega:
--   admin_settle_payout  -> descuenta el saldo y marca el pago como confirmado
--   admin_cancel_payout  -> anula un pago duplicado/erroneo (con motivo)
--   get_driver_accounts  -> campo pending_confirm_usd (aprobados sin confirmar)

-- ------------------------------------------------------------
-- 1) Liquidar como admin (sin confirmacion del conductor)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_settle_payout(
  p_payout_id UUID,
  p_note TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin         UUID := auth.uid();
  v_role          TEXT;
  v_payout        RECORD;
  v_wallet        RECORD;
  v_amount        NUMERIC;
  v_balance       NUMERIC;
  v_driver_zone   UUID;
  v_note          TEXT := NULLIF(BTRIM(COALESCE(p_note, '')), '');
BEGIN
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  v_role := public.get_user_role(v_admin)::text;
  IF v_role IS NULL OR v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('admin_settle_payout', 30);

  SELECT * INTO v_payout FROM public.payouts WHERE id = p_payout_id FOR UPDATE;
  IF v_payout.id IS NULL THEN
    RAISE EXCEPTION 'Pago no encontrado';
  END IF;

  IF v_payout.type <> 'platform_pay_driver' THEN
    RAISE EXCEPTION 'Este pago no es de la plataforma al conductor';
  END IF;

  IF v_payout.status = 'confirmado' THEN
    RAISE EXCEPTION 'Este pago ya fue confirmado';
  END IF;

  IF v_payout.status NOT IN ('pendiente', 'aprobado') THEN
    RAISE EXCEPTION 'Este pago esta % y no se puede liquidar', v_payout.status;
  END IF;

  SELECT zone_id INTO v_driver_zone FROM public.profiles WHERE id = v_payout.driver_id;

  IF v_role = 'encargado' THEN
    IF public.caller_zone_id() IS NULL OR v_driver_zone IS DISTINCT FROM public.caller_zone_id() THEN
      RAISE EXCEPTION 'No autorizado para pagar a conductores de otra ciudad';
    END IF;
  END IF;

  SELECT * INTO v_wallet FROM public.wallets WHERE user_id = v_payout.driver_id FOR UPDATE;
  IF v_wallet.id IS NULL THEN
    RAISE EXCEPTION 'Billetera del conductor no encontrada';
  END IF;

  v_amount := ROUND(v_payout.amount_usd, 2);

  IF v_wallet.balance_usd < v_amount THEN
    RAISE EXCEPTION USING MESSAGE = format(
      'El conductor solo tiene %s$ disponibles; no alcanza para liquidar %s$',
      ROUND(v_wallet.balance_usd, 2), v_amount
    );
  END IF;

  UPDATE public.wallets
  SET balance_usd = balance_usd - v_amount,
      updated_at = NOW()
  WHERE user_id = v_payout.driver_id;

  SELECT balance_usd INTO v_balance FROM public.wallets WHERE user_id = v_payout.driver_id;

  UPDATE public.payouts
  SET status = 'confirmado',
      reviewed_by = v_admin,
      description = COALESCE(v_note, description),
      updated_at = NOW()
  WHERE id = p_payout_id;

  INSERT INTO public.transactions (
    wallet_id, user_id, type, amount_usd, status, description, reviewed_by, payment_method
  ) VALUES (
    v_wallet.id, v_payout.driver_id, 'debito', v_amount, 'completado',
    'Pago al conductor confirmado por la plataforma', v_admin, v_payout.payment_method
  );

  INSERT INTO public.notifications (user_id, title, body, type, data)
  VALUES (
    v_payout.driver_id,
    'Pago registrado',
    CONCAT('La plataforma registró el pago de $', v_amount, '...'),
    'payout_approved',
    jsonb_build_object('payout_id', p_payout_id, 'url', '/conductor/billetera')
  );

  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (
    v_admin, 'ADMIN_SETTLE_PAYOUT', 'payout', p_payout_id,
    jsonb_build_object(
      'driver_id', v_payout.driver_id,
      'amount_usd', v_amount,
      'payment_method', v_payout.payment_method,
      'note', v_note,
      'new_balance', v_balance
    )
  );

  RETURN jsonb_build_object(
    'success', TRUE,
    'payout_id', p_payout_id,
    'new_balance', v_balance
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_settle_payout(UUID, TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_settle_payout(UUID, TEXT) FROM anon;

-- ------------------------------------------------------------
-- 2) Anular un pago duplicado / erroneo
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_cancel_payout(
  p_payout_id UUID,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin       UUID := auth.uid();
  v_role        TEXT;
  v_payout      RECORD;
  v_driver_zone UUID;
  v_reason      TEXT := COALESCE(NULLIF(BTRIM(COALESCE(p_reason, '')), ''), 'pago duplicado o erroneo');
BEGIN
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  v_role := public.get_user_role(v_admin)::text;
  IF v_role IS NULL OR v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('admin_cancel_payout', 30);

  SELECT * INTO v_payout FROM public.payouts WHERE id = p_payout_id FOR UPDATE;
  IF v_payout.id IS NULL THEN
    RAISE EXCEPTION 'Pago no encontrado';
  END IF;

  IF v_payout.status = 'confirmado' THEN
    RAISE EXCEPTION 'Este pago ya esta confirmado; no se puede anular';
  END IF;

  IF v_payout.status = 'rechazado' THEN
    RAISE EXCEPTION 'Este pago ya esta anulado';
  END IF;

  SELECT zone_id INTO v_driver_zone FROM public.profiles WHERE id = v_payout.driver_id;

  IF v_role = 'encargado' THEN
    IF public.caller_zone_id() IS NULL OR v_driver_zone IS DISTINCT FROM public.caller_zone_id() THEN
      RAISE EXCEPTION 'No autorizado para anular pagos de otra ciudad';
    END IF;
  END IF;

  UPDATE public.payouts
  SET status = 'rechazado',
      reviewed_by = v_admin,
      description = CONCAT_WS(' · ', NULLIF(description, ''), 'Anulado: ' || v_reason),
      updated_at = NOW()
  WHERE id = p_payout_id;

  INSERT INTO public.notifications (user_id, title, body, type, data)
  VALUES (
    v_payout.driver_id,
    'Pago anulado',
    CONCAT('La plataforma anuló el pago de $', v_payout.amount_usd, '. Motivo: ', v_reason, '.'),
    'payout_rejected',
    jsonb_build_object('payout_id', p_payout_id, 'url', '/conductor/billetera')
  );

  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (
    v_admin, 'ADMIN_CANCEL_PAYOUT', 'payout', p_payout_id,
    jsonb_build_object(
      'driver_id', v_payout.driver_id,
      'amount_usd', v_payout.amount_usd,
      'reason', v_reason,
      'previous_status', v_payout.status
    )
  );

  RETURN jsonb_build_object('success', TRUE, 'payout_id', p_payout_id, 'status', 'rechazado');
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_cancel_payout(UUID, TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_cancel_payout(UUID, TEXT) FROM anon;

-- ------------------------------------------------------------
-- 3) get_driver_accounts: mostrar lo aprobado pero sin confirmar
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_driver_accounts(
  p_zone_id uuid DEFAULT NULL,
  p_filtro text DEFAULT 'todos',
  p_search text DEFAULT NULL,
  p_solo_limite boolean DEFAULT false,
  p_limit integer DEFAULT 25,
  p_offset integer DEFAULT 0
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id    UUID := auth.uid();
  v_caller_zone UUID;
  v_zone        UUID;
  v_role        TEXT;
  v_filtro      TEXT := LOWER(TRIM(COALESCE(p_filtro, 'todos')));
  v_search      TEXT := NULLIF(TRIM(COALESCE(p_search, '')), '');
  v_result      JSONB;
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

  IF v_filtro NOT IN ('deben', 'debo', 'todos') THEN
    v_filtro := 'todos';
  END IF;

  IF p_limit > 100 THEN p_limit := 100; END IF;
  IF p_limit < 1 THEN p_limit := 25; END IF;
  IF p_offset < 0 THEN p_offset := 0; END IF;

  WITH base AS (
    SELECT
      pr.id,
      pr.full_name,
      pr.email,
      pr.phone,
      pr.zone_id,
      z.name AS zone_name,
      pr.driver_status::text AS driver_status,
      COALESCE(pr.status::text, 'activo') AS account_status,
      ROUND(COALESCE(w.balance_usd, 0), 2) AS balance_usd,
      ROUND(COALESCE(w.debt_limit_usd, 0), 2) AS debt_limit_usd,
      (
        ROUND(COALESCE(w.balance_usd, 0), 2) < 0
        AND ROUND(COALESCE(w.balance_usd, 0), 2)
            < -ROUND(COALESCE(w.debt_limit_usd, 0), 2)
      ) AS excede_limite,
      COALESCE((
        SELECT SUM(po.amount_usd)
        FROM payouts po
        WHERE po.driver_id = pr.id
          AND po.status = 'pendiente'
      ), 0) AS pending_payout_usd,
      -- NUEVO: pagos ya aprobados que esperan confirmacion del conductor
      COALESCE((
        SELECT SUM(po.amount_usd)
        FROM payouts po
        WHERE po.driver_id = pr.id
          AND po.type = 'platform_pay_driver'
          AND po.status = 'aprobado'
      ), 0) AS pending_confirm_usd,
      (
        SELECT MAX(t.created_at)
        FROM transactions t
        WHERE t.user_id = pr.id
      ) AS last_movement_at
    FROM profiles pr
    LEFT JOIN wallets w ON w.user_id = pr.id
    LEFT JOIN zones z ON z.id = pr.zone_id
    WHERE pr.role = 'conductor'
      AND (v_zone IS NULL OR pr.zone_id = v_zone)
      AND (v_search IS NULL
           OR pr.full_name ILIKE '%' || v_search || '%'
           OR pr.email ILIKE '%' || v_search || '%'
           OR pr.phone ILIKE '%' || v_search || '%')
  ),
  filtrada AS (
    SELECT b.*
    FROM base b
    WHERE CASE v_filtro
            WHEN 'deben' THEN b.balance_usd < 0
            WHEN 'debo'  THEN b.balance_usd > 0
            ELSE b.balance_usd <> 0
          END
      AND (NOT COALESCE(p_solo_limite, FALSE) OR b.excede_limite)
  ),
  totales AS (
    SELECT
      COUNT(*) AS total,
      COALESCE(SUM(ABS(balance_usd)) FILTER (WHERE balance_usd < 0), 0) AS suma_deben,
      COALESCE(SUM(balance_usd) FILTER (WHERE balance_usd > 0), 0) AS suma_debo,
      COUNT(*) FILTER (WHERE balance_usd < 0) AS con_deuda,
      COUNT(*) FILTER (WHERE balance_usd > 0) AS con_saldo,
      COUNT(*) FILTER (WHERE excede_limite) AS sobre_limite
    FROM filtrada
  ),
  pagina AS (
    SELECT *
    FROM filtrada
    ORDER BY ABS(balance_usd) DESC, full_name
    LIMIT p_limit OFFSET p_offset
  )
  SELECT jsonb_build_object(
    'total', t.total,
    'totales', jsonb_build_object(
      'suma_deben', ROUND(t.suma_deben, 2),
      'suma_debo', ROUND(t.suma_debo, 2),
      'con_deuda', t.con_deuda,
      'con_saldo', t.con_saldo,
      'sobre_limite', t.sobre_limite
    ),
    'items', COALESCE((
      SELECT jsonb_agg(to_jsonb(pg) ORDER BY ABS(pg.balance_usd) DESC, pg.full_name)
      FROM pagina pg
    ), '[]'::jsonb)
  )
  INTO v_result
  FROM totales t;

  RETURN v_result;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_driver_accounts(uuid, text, text, boolean, integer, integer) TO authenticated;
REVOKE ALL ON FUNCTION public.get_driver_accounts(uuid, text, text, boolean, integer, integer) FROM anon;
