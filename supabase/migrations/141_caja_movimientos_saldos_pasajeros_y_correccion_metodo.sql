-- 141 - Administracion del dinero:
--   1) transactions.payout_id: enlaza cada movimiento con su pago.
--   2) admin_fix_payout_method: corrige el metodo de un pago y sus transacciones.
--   3) treasury_movements + admin_treasury_movement: inyecciones, retiros y gastos.
--   4) get_customer_accounts: saldo individual de cada pasajero.
--   5) Correccion puntual: el pago de 1,45 a Luis fue por Pago Movil, no efectivo.

ALTER TABLE public.transactions
  ADD COLUMN IF NOT EXISTS payout_id UUID REFERENCES public.payouts(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS idx_transactions_payout
  ON public.transactions (payout_id)
  WHERE payout_id IS NOT NULL;

CREATE OR REPLACE FUNCTION public.admin_fix_payout_method(
  p_payout_id UUID,
  p_method TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin UUID := auth.uid();
  v_role TEXT;
  v_payout RECORD;
  v_method TEXT;
  v_driver_zone UUID;
  v_tx INTEGER := 0;
  v_prev TEXT;
BEGIN
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  v_role := public.get_user_role(v_admin)::text;
  IF v_role IS NULL OR v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('admin_fix_payout_method', 30);

  v_method := NULLIF(BTRIM(COALESCE(p_method, '')), '');
  IF v_method IS NULL THEN
    RAISE EXCEPTION 'Indica el método de pago';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.payment_methods WHERE name = v_method AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION 'Método de pago no válido';
  END IF;

  SELECT * INTO v_payout FROM public.payouts WHERE id = p_payout_id FOR UPDATE;
  IF v_payout.id IS NULL THEN
    RAISE EXCEPTION 'Pago no encontrado';
  END IF;

  IF v_payout.payment_method IS NOT DISTINCT FROM v_method THEN
    RAISE EXCEPTION 'El pago ya está registrado con ese método';
  END IF;

  SELECT zone_id INTO v_driver_zone FROM public.profiles WHERE id = v_payout.driver_id;

  IF v_role = 'encargado' THEN
    IF public.caller_zone_id() IS NULL OR v_driver_zone IS DISTINCT FROM public.caller_zone_id() THEN
      RAISE EXCEPTION 'No autorizado para pagos de otra ciudad';
    END IF;
  END IF;

  v_prev := v_payout.payment_method;

  UPDATE public.payouts
  SET payment_method = v_method,
      updated_at = NOW()
  WHERE id = p_payout_id;

  UPDATE public.transactions
  SET payment_method = v_method
  WHERE payout_id = p_payout_id;

  GET DIAGNOSTICS v_tx = ROW_COUNT;

  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (
    v_admin, 'ADMIN_FIX_PAYMENT_METHOD', 'payout', p_payout_id,
    jsonb_build_object(
      'previous_method', v_prev,
      'new_method', v_method,
      'amount_usd', v_payout.amount_usd,
      'driver_id', v_payout.driver_id,
      'transactions_updated', v_tx
    )
  );

  RETURN jsonb_build_object(
    'success', TRUE,
    'payout_id', p_payout_id,
    'payment_method', v_method,
    'transactions_updated', v_tx
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_fix_payout_method(UUID, TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_fix_payout_method(UUID, TEXT) FROM anon;

-- ------------------------------------------------------------
-- Movimientos manuales de caja/tesoreria
--   kind: efectivo (caja) | externo (banco / pago movil)
--   direction: in (ingreso) | out (egreso)
-- ------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.treasury_movements (
  id          UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  zone_id     UUID REFERENCES public.zones(id) ON DELETE SET NULL,
  kind        TEXT NOT NULL CHECK (kind IN ('efectivo', 'externo')),
  direction   TEXT NOT NULL CHECK (direction IN ('in', 'out')),
  amount_usd  NUMERIC(12,2) NOT NULL CHECK (amount_usd > 0),
  category    TEXT NOT NULL,
  description TEXT,
  reference   TEXT,
  created_by  UUID REFERENCES public.profiles(id),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_treasury_movements_zone_date
  ON public.treasury_movements (zone_id, created_at DESC);

ALTER TABLE public.treasury_movements ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.admin_treasury_movement(
  p_kind TEXT,
  p_direction TEXT,
  p_amount_usd NUMERIC,
  p_category TEXT,
  p_description TEXT DEFAULT NULL,
  p_reference TEXT DEFAULT NULL,
  p_zone_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin UUID := auth.uid();
  v_role TEXT;
  v_zone UUID := p_zone_id;
  v_kind TEXT := LOWER(BTRIM(COALESCE(p_kind, '')));
  v_direction TEXT := LOWER(BTRIM(COALESCE(p_direction, '')));
  v_category TEXT := NULLIF(BTRIM(COALESCE(p_category, '')), '');
  v_amount NUMERIC;
  v_id UUID;
BEGIN
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  v_role := public.get_user_role(v_admin)::text;
  IF v_role IS NULL OR v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('admin_treasury_movement', 40);

  IF v_role = 'encargado' THEN
    v_zone := public.caller_zone_id();
    IF v_zone IS NULL THEN
      RAISE EXCEPTION 'Tu cuenta no tiene una ciudad asignada';
    END IF;
  END IF;

  IF v_zone IS NOT NULL AND NOT EXISTS (SELECT 1 FROM public.zones WHERE id = v_zone) THEN
    RAISE EXCEPTION 'Ciudad no encontrada';
  END IF;

  IF v_kind NOT IN ('efectivo', 'externo') THEN
    RAISE EXCEPTION 'Tipo inválido: usa efectivo o externo (banco)';
  END IF;

  IF v_direction NOT IN ('in', 'out') THEN
    RAISE EXCEPTION 'Dirección inválida: usa in (ingreso) u out (egreso)';
  END IF;

  v_amount := ROUND(COALESCE(p_amount_usd, 0), 2);
  IF v_amount <= 0 OR v_amount > 1000000 THEN
    RAISE EXCEPTION 'El monto debe estar entre 0,01 y 1.000.000';
  END IF;

  IF v_category IS NULL THEN
    RAISE EXCEPTION 'Indica una categoría (servidor, publicidad, retiro, inyección...)';
  END IF;

  INSERT INTO public.treasury_movements (
    zone_id, kind, direction, amount_usd, category, description, reference, created_by
  ) VALUES (
    v_zone, v_kind, v_direction, v_amount, v_category,
    NULLIF(BTRIM(COALESCE(p_description, '')), ''),
    NULLIF(BTRIM(COALESCE(p_reference, '')), ''),
    v_admin
  )
  RETURNING id INTO v_id;

  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (
    v_admin, 'TREASURY_MOVEMENT', 'treasury_movement', v_id,
    jsonb_build_object(
      'zone_id', v_zone,
      'kind', v_kind,
      'direction', v_direction,
      'amount_usd', v_amount,
      'category', v_category,
      'description', p_description,
      'reference', p_reference
    )
  );

  RETURN jsonb_build_object('success', TRUE, 'movement_id', v_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_treasury_movement(TEXT, TEXT, NUMERIC, TEXT, TEXT, TEXT, UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_treasury_movement(TEXT, TEXT, NUMERIC, TEXT, TEXT, TEXT, UUID) FROM anon;

CREATE OR REPLACE FUNCTION public.get_treasury_movements(
  p_zone_id UUID DEFAULT NULL,
  p_limit INTEGER DEFAULT 20,
  p_offset INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin UUID := auth.uid();
  v_role TEXT;
  v_zone UUID := p_zone_id;
  v_items JSONB;
  v_total BIGINT;
BEGIN
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  v_role := public.get_user_role(v_admin)::text;
  IF v_role IS NULL OR v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF v_role = 'encargado' THEN
    v_zone := public.caller_zone_id();
  END IF;

  IF p_limit > 100 THEN p_limit := 100; END IF;
  IF p_limit < 1 THEN p_limit := 20; END IF;
  IF p_offset < 0 THEN p_offset := 0; END IF;

  SELECT COUNT(*) INTO v_total
  FROM public.treasury_movements tm
  WHERE (v_zone IS NULL OR tm.zone_id = v_zone);

  SELECT COALESCE(jsonb_agg(to_jsonb(t) ORDER BY t.created_at DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT tm.id, tm.zone_id, z.name AS zone_name, tm.kind, tm.direction,
           tm.amount_usd, tm.category, tm.description, tm.reference,
           pr.full_name AS created_by_name, tm.created_at
    FROM public.treasury_movements tm
    LEFT JOIN public.zones z ON z.id = tm.zone_id
    LEFT JOIN public.profiles pr ON pr.id = tm.created_by
    WHERE (v_zone IS NULL OR tm.zone_id = v_zone)
    ORDER BY tm.created_at DESC
    LIMIT p_limit OFFSET p_offset
  ) t;

  RETURN jsonb_build_object('total', v_total, 'items', v_items);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_treasury_movements(UUID, INTEGER, INTEGER) TO authenticated;
REVOKE ALL ON FUNCTION public.get_treasury_movements(UUID, INTEGER, INTEGER) FROM anon;

-- ------------------------------------------------------------
-- Saldos individuales de pasajeros
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_customer_accounts(
  p_zone_id UUID DEFAULT NULL,
  p_filtro TEXT DEFAULT 'con_saldo',
  p_search TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 25,
  p_offset INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin UUID := auth.uid();
  v_role TEXT;
  v_zone UUID := p_zone_id;
  v_filtro TEXT := LOWER(TRIM(COALESCE(p_filtro, 'con_saldo')));
  v_search TEXT := NULLIF(TRIM(COALESCE(p_search, '')), '');
  v_result JSONB;
BEGIN
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  v_role := public.get_user_role(v_admin)::text;
  IF v_role IS NULL OR v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF v_role = 'encargado' THEN
    v_zone := public.caller_zone_id();
    IF v_zone IS NULL THEN
      RAISE EXCEPTION 'Tu cuenta no tiene una ciudad asignada';
    END IF;
  END IF;

  IF v_filtro NOT IN ('con_saldo', 'con_deuda', 'todos') THEN
    v_filtro := 'con_saldo';
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
      COALESCE(pr.status::text, 'activo') AS account_status,
      ROUND(COALESCE(w.balance_usd, 0), 2) AS balance_usd,
      (
        SELECT MAX(t.created_at)
        FROM public.transactions t
        WHERE t.user_id = pr.id
      ) AS last_movement_at
    FROM public.profiles pr
    LEFT JOIN public.wallets w ON w.user_id = pr.id
    LEFT JOIN public.zones z ON z.id = pr.zone_id
    WHERE pr.role = 'cliente'
      AND (v_zone IS NULL OR pr.zone_id = v_zone)
      AND (
        v_search IS NULL
        OR pr.full_name ILIKE '%' || v_search || '%'
        OR pr.email ILIKE '%' || v_search || '%'
        OR pr.phone ILIKE '%' || v_search || '%'
      )
  ),
  filtrada AS (
    SELECT b.*
    FROM base b
    WHERE CASE v_filtro
            WHEN 'con_saldo' THEN b.balance_usd > 0
            WHEN 'con_deuda' THEN b.balance_usd < 0
            ELSE b.balance_usd <> 0
          END
  ),
  totales AS (
    SELECT
      COUNT(*) AS total,
      COALESCE(SUM(balance_usd), 0) AS suma_saldo,
      COUNT(*) FILTER (WHERE balance_usd > 0) AS con_saldo,
      COUNT(*) FILTER (WHERE balance_usd < 0) AS con_deuda
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
      'suma_saldo', ROUND(t.suma_saldo, 2),
      'con_saldo', t.con_saldo,
      'con_deuda', t.con_deuda
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

GRANT EXECUTE ON FUNCTION public.get_customer_accounts(UUID, TEXT, TEXT, INTEGER, INTEGER) TO authenticated;
REVOKE ALL ON FUNCTION public.get_customer_accounts(UUID, TEXT, TEXT, INTEGER, INTEGER) FROM anon;

-- ------------------------------------------------------------
-- Correccion puntual: pago de 1,45 en efectivo -> Pago Movil
-- ------------------------------------------------------------
UPDATE public.transactions
SET payout_id = '3a732f60-b654-4d68-84f8-5a4c67068ee0'::uuid,
    payment_method = 'Pago Móvil'
WHERE id = 'df13c478-8520-4725-9e21-1f03c99a4c71'::uuid;

UPDATE public.payouts
SET payment_method = 'Pago Móvil',
    updated_at = NOW()
WHERE id = '3a732f60-b654-4d68-84f8-5a4c67068ee0'::uuid;

INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
SELECT p.reviewed_by,
       'ADMIN_FIX_PAYMENT_METHOD',
       'payout',
       p.id,
       jsonb_build_object(
         'previous_method', 'Efectivo',
         'new_method', 'Pago Móvil',
         'amount_usd', p.amount_usd,
         'driver_id', p.driver_id,
         'transaction_id', 'df13c478-8520-4725-9e21-1f03c99a4c71',
         'note', 'Correccion: el pago fue por Pago Movil, no en efectivo'
       )
FROM public.payouts p
WHERE p.id = '3a732f60-b654-4d68-84f8-5a4c67068ee0'::uuid
  AND p.reviewed_by IS NOT NULL;
