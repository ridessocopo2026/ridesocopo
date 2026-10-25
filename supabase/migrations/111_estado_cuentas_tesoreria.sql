-- ============================================================
-- BUNRIDER - Migración 111: ESTADO DE CUENTAS / TESORERÍA
-- ------------------------------------------------------------
-- OBJETIVO
--   Que el super_admin (global) y el encargado (solo su ciudad)
--   vean en una sola pantalla:
--     - cuánto debe cada conductor y cuánto se le debe a cada uno
--     - cuánto dinero hay en banco (Pago Móvil / Zelle)
--     - cuánto efectivo está por cobrar
--     - la lista de conductores con saldo, buscable y paginada
--   Y puedan COBRAR la deuda o PAGAR al conductor desde ahí.
--
-- DECISIONES
--   - No se toca get_wallet_overview: lo usan Dashboard, Métricas
--     y el panel del encargado. Se crea una RPC nueva y aislada
--     (regresión cero en esas pantallas).
--   - No se añaden tablas ni columnas. El método de pago de los
--     cobros queda en transactions.description y en audit_logs.
--     La separación exacta efectivo/banco para TODOS los pagos
--     necesita una columna payment_method (fase posterior).
--   - El encargado NUNCA elige ciudad: COALESCE(caller_zone_id(),
--     p_zone_id) y caller_zone_id() gana. El super_admin puede
--     filtrar por ciudad (NULL = todas).
--   - La lista NO filtra por driver_status='aprobado': un
--     conductor suspendido/rechazado también puede deber y hay
--     que poder cobrarle.
--   - Cobrar bloquea la wallet (FOR UPDATE), valida contra la
--     deuda real y nunca deja saldo positivo por error.
--
-- COSTO: 0 tablas, 0 columnas, 0 cron. 3 funciones nuevas.
--        Índices ya existentes: idx_profiles_role/zone,
--        idx_transactions_user_created, idx_payouts_driver_id.
-- ============================================================

-- ============================================================
-- 1. RESUMEN DE TESORERÍA (solo lectura)
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

  -- Banco (dinero que entró/salió por vías digitales)
  v_recargas            NUMERIC := 0;
  v_pagos_pago_movil    NUMERIC := 0;
  v_cobros_conductores  NUMERIC := 0;
  v_pagos_conductores   NUMERIC := 0;
  v_banco_total         NUMERIC := 0;

  -- Efectivo
  v_cobrado_efectivo    NUMERIC := 0;

  -- Deudas actuales (wallets)
  v_conductores_deben     NUMERIC := 0;
  v_app_debe_conductores  NUMERIC := 0;
  v_clientes_deben        NUMERIC := 0;
  v_app_debe_clientes     NUMERIC := 0;

  -- Conteos
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

  -- ------------------------------------------------------------
  -- 1.1 Entradas de dinero al banco
  -- ------------------------------------------------------------
  -- Recargas aprobadas de clientes (Pago Móvil / Zelle / banco)
  SELECT COALESCE(SUM(t.amount_usd), 0)
  INTO v_recargas
  FROM transactions t
  JOIN profiles p ON p.id = t.user_id
  WHERE t.type = 'recarga'
    AND t.status IN ('aprobado', 'completado')
    AND p.role = 'cliente'
    AND (v_zone IS NULL OR p.zone_id = v_zone);

  -- Viajes con Pago Móvil ya aprobado (el dinero llegó al banco)
  SELECT COALESCE(SUM(r.final_fare_usd), 0)
  INTO v_pagos_pago_movil
  FROM rides r
  WHERE LOWER(r.payment_method) IN ('pago móvil', 'pago movil')
    AND r.proof_status = 'aprobado'
    AND (v_zone IS NULL OR r.origin_zone_id = v_zone);

  -- Conductores que pagaron a la plataforma (comprobante aprobado)
  SELECT COALESCE(SUM(po.amount_usd), 0)
  INTO v_cobros_conductores
  FROM payouts po
  LEFT JOIN profiles p ON p.id = po.driver_id
  WHERE po.type = 'driver_pay_platform'
    AND po.status = 'aprobado'
    AND (v_zone IS NULL OR p.zone_id = v_zone);

  -- Plataforma que pagó a conductores
  SELECT COALESCE(SUM(po.amount_usd), 0)
  INTO v_pagos_conductores
  FROM payouts po
  LEFT JOIN profiles p ON p.id = po.driver_id
  WHERE po.type = 'platform_pay_driver'
    AND po.status IN ('aprobado', 'confirmado')
    AND (v_zone IS NULL OR p.zone_id = v_zone);

  -- ------------------------------------------------------------
  -- 1.2 Efectivo cobrado a conductores
  --     (hoy el método solo vive en la descripción del payout)
  -- ------------------------------------------------------------
  SELECT COALESCE(SUM(po.amount_usd), 0)
  INTO v_cobrado_efectivo
  FROM payouts po
  LEFT JOIN profiles p ON p.id = po.driver_id
  WHERE po.type = 'driver_pay_platform'
    AND po.status = 'aprobado'
    AND po.description ILIKE '%efectivo%'
    AND (v_zone IS NULL OR p.zone_id = v_zone);

  -- ------------------------------------------------------------
  -- 1.3 Deudas actuales de conductores
  --     balance < 0 => debe a la app (comisiones en efectivo)
  --     balance > 0 => la app le debe al conductor
  -- ------------------------------------------------------------
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

  -- ------------------------------------------------------------
  -- 1.4 Deudas de clientes (informativo)
  -- ------------------------------------------------------------
  SELECT
    COALESCE(SUM(ABS(w.balance_usd)) FILTER (WHERE w.balance_usd < 0), 0),
    COALESCE(SUM(w.balance_usd) FILTER (WHERE w.balance_usd > 0), 0)
  INTO v_clientes_deben, v_app_debe_clientes
  FROM wallets w
  JOIN profiles pr ON pr.id = w.user_id
  WHERE pr.role = 'cliente'
    AND (v_zone IS NULL OR pr.zone_id = v_zone);

  v_banco_total := v_recargas + v_pagos_pago_movil
                 + v_cobros_conductores - v_pagos_conductores;

  RETURN jsonb_build_object(
    'zona', jsonb_build_object(
      'zone_id', v_zone,
      'es_global', v_zone IS NULL,
      'forzada_por_rol', v_caller_zone IS NOT NULL
    ),
    'banco', jsonb_build_object(
      'recargas', ROUND(v_recargas, 2),
      'viajes_pago_movil', ROUND(v_pagos_pago_movil, 2),
      'cobros_conductores', ROUND(v_cobros_conductores, 2),
      'pagos_conductores', ROUND(v_pagos_conductores, 2),
      'total', ROUND(v_banco_total, 2)
    ),
    'efectivo', jsonb_build_object(
      'por_cobrar', ROUND(v_conductores_deben, 2),
      'cobrado_conductores', ROUND(v_cobrado_efectivo, 2),
      'pagado_conductores', NULL,
      'nota', 'Los pagos en efectivo hechos a conductores aún no se registran por método'
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
    )
  );
END;
$$;

-- ============================================================
-- 2. LISTA DE CONDUCTORES CON SALDO (paginada y buscable)
--    - 'deben': balance < 0 (debe a la app)
--    - 'debo' : balance > 0 (la app le debe)
--    - 'todos': cualquier balance distinto de 0
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_driver_accounts(
  p_zone_id UUID DEFAULT NULL,
  p_filtro TEXT DEFAULT 'todos',
  p_search TEXT DEFAULT NULL,
  p_solo_limite BOOLEAN DEFAULT FALSE,
  p_limit INTEGER DEFAULT 25,
  p_offset INTEGER DEFAULT 0
)
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

-- ============================================================
-- 3. COBRAR DEUDA DE UN CONDUCTOR (mueve dinero)
--    - Solo admin/encargado, con candado de ciudad
--    - No permite cobrar más que la deuda actual
--    - Deja el comprobante del método en la descripción + auditoría
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

  -- El encargado solo puede cobrar a conductores de SU ciudad
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
    description, reference, reviewed_by, reviewed_at
  ) VALUES (
    v_wallet.id, p_driver_id, 'credito', v_amount, 'completado',
    v_description, v_ref, v_admin_id, NOW()
  );

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
      'source', 'estado_cuentas'
    )
  );

  RETURN jsonb_build_object(
    'success', TRUE,
    'driver_id', p_driver_id,
    'amount_usd', v_amount,
    'nuevo_balance', v_new_balance,
    'deuda_restante', ROUND(GREATEST(0, -v_new_balance), 2)
  );
END;
$$;

-- ============================================================
-- 4. PERMISOS (solo usuarios autenticados; la RPC valida el rol)
-- ============================================================
GRANT EXECUTE ON FUNCTION public.get_treasury_overview(uuid)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_treasury_overview(uuid) FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.get_driver_accounts(uuid, text, text, boolean, integer, integer)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_driver_accounts(uuid, text, text, boolean, integer, integer)
  FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.admin_collect_driver_debt(uuid, numeric, text, text)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.admin_collect_driver_debt(uuid, numeric, text, text)
  FROM PUBLIC, anon;

-- ============================================================
-- 5. VERIFICACIÓN
-- ============================================================
NOTIFY pgrst, 'reload schema';

SELECT 'RPC de estado de cuentas creadas (esperado 3)' AS comprobacion,
       COUNT(*)::text AS valor
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('get_treasury_overview', 'get_driver_accounts', 'admin_collect_driver_debt')
UNION ALL
SELECT 'con candado caller_zone_id (esperado 3)', COUNT(*)::text
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('get_treasury_overview', 'get_driver_accounts', 'admin_collect_driver_debt')
  AND pg_get_functiondef(p.oid) LIKE '%caller_zone_id%'
UNION ALL
SELECT 'anon sin EXECUTE (esperado 0)', COUNT(*)::text
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('get_treasury_overview', 'get_driver_accounts', 'admin_collect_driver_debt')
  AND has_function_privilege('anon', p.oid, 'EXECUTE')
UNION ALL
SELECT 'authenticated con EXECUTE (esperado 3)', COUNT(*)::text
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('get_treasury_overview', 'get_driver_accounts', 'admin_collect_driver_debt')
  AND has_function_privilege('authenticated', p.oid, 'EXECUTE');

SELECT '✅ Migración 111: estado de cuentas / tesorería listo' AS estado;



