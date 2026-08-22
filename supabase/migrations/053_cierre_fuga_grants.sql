-- ============================================================
-- RIDESOCOPÓ - Migración 053: CIERRE DE FUGA DE DATOS
-- ------------------------------------------------------------
-- PROBLEMA CRÍTICO encontrado:
--   En PostgreSQL, las funciones nuevas reciben EXECUTE para
--   PUBLIC por defecto. Los REVOKE ALL ... FROM anon de las
--   migraciones anteriores NO quitaban ese grant público, así
--   que CUALQUIER persona con la clave anon (pública en la app)
--   podía ejecutar RPCs de admin: get_admin_users (emails,
--   teléfonos, saldos de todos), get_audit_logs (auditoría),
--   approve_ride_proof, etc.
--   Además, las comprobaciones `get_user_role(auth.uid()) !=
--   'super_admin'` fallan con auth.uid() NULL (anon) porque
--   NULL != 'x' → NULL (no dispara el RAISE).
--
-- SOLUCIÓN:
--   1) REVOKE EXECUTE ... FROM PUBLIC en TODO el esquema.
--   2) Re-grant a anon SOLO lo que la app usa sin login y los
--      helpers de RLS.
--   3) Guards NULL explícitos en las funciones de rol y dinero
--      (defensa en profundidad).
--   4) get_audit_logs pasa a VOLATILE (PostgREST no puede
--      ejecutar INSERT de guard_rate_limit en STABLE).
-- ============================================================

-- ============================================================
-- 1. REVOCAR PUBLIC (raíz de la fuga)
-- ============================================================
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;

-- ============================================================
-- 2. GARANTIZAR authenticated y service_role (no rompe la app)
-- ============================================================
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO authenticated;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO service_role;

-- guard_rate_limit vuelve a quedar SOLO para service_role
-- (según la intención original de la migración 036)
REVOKE EXECUTE ON FUNCTION public.guard_rate_limit(text, integer) FROM authenticated;

-- ============================================================
-- 3. RE-GRANT A ANON (solo flujo público + helpers de RLS)
-- ------------------------------------------------------------
-- Flujo público (ClientHome sin login):
--   get_active_cities, calculate_fare, find_city,
--   get_nearest_barrio, get_active_exchange_rate
-- Helpers usados por políticas RLS (deben poder evaluarse):
--   get_user_role, get_own_profile_guard, caller_zone_id,
--   driver_has_vehicle_for_category
-- ============================================================
GRANT EXECUTE ON FUNCTION public.get_active_cities() TO anon;
GRANT EXECUTE ON FUNCTION public.get_active_exchange_rate() TO anon;
GRANT EXECUTE ON FUNCTION public.calculate_fare(numeric, numeric, numeric, numeric, public.vehicle_category, text) TO anon;
GRANT EXECUTE ON FUNCTION public.find_city(numeric, numeric) TO anon;
GRANT EXECUTE ON FUNCTION public.get_nearest_barrio(numeric, numeric) TO anon;
GRANT EXECUTE ON FUNCTION public.get_user_role(uuid) TO anon;
GRANT EXECUTE ON FUNCTION public.get_own_profile_guard() TO anon;
GRANT EXECUTE ON FUNCTION public.caller_zone_id() TO anon;
GRANT EXECUTE ON FUNCTION public.driver_has_vehicle_for_category(public.vehicle_category) TO anon;

-- ============================================================
-- 4. GET_AUDIT_LOGS: VOLATILE (puede insertar guard_rate_limit)
--    + guard NULL explícito (anon NO puede consultar auditoría)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_audit_logs(
  p_action TEXT DEFAULT NULL,
  p_user_id UUID DEFAULT NULL,
  p_fecha_desde TIMESTAMPTZ DEFAULT NULL,
  p_fecha_hasta TIMESTAMPTZ DEFAULT NULL,
  p_limit INTEGER DEFAULT 25,
  p_offset INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_total INTEGER := 0;
  v_items JSONB;
BEGIN
  IF v_admin_id IS NULL OR public.get_user_role(v_admin_id) IS DISTINCT FROM 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('get_audit_logs', 30);

  IF p_limit > 50 THEN p_limit := 50; END IF;
  IF p_limit < 1 THEN p_limit := 25; END IF;
  IF p_offset < 0 THEN p_offset := 0; END IF;

  SELECT COUNT(*) INTO v_total
  FROM public.audit_logs a
  WHERE (p_action IS NULL OR a.action = p_action)
    AND (p_user_id IS NULL OR a.user_id = p_user_id)
    AND (p_fecha_desde IS NULL OR a.created_at >= p_fecha_desde)
    AND (p_fecha_hasta IS NULL OR a.created_at <= p_fecha_hasta);

  SELECT COALESCE(jsonb_agg(t ORDER BY t.fecha DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT
      a.id::text AS id,
      a.action,
      a.entity_type,
      a.entity_id::text AS entity_id,
      a.details,
      a.created_at AS fecha,
      pr.full_name AS usuario,
      pr.email AS usuario_email
    FROM public.audit_logs a
    LEFT JOIN public.profiles pr ON pr.id = a.user_id
    WHERE (p_action IS NULL OR a.action = p_action)
      AND (p_user_id IS NULL OR a.user_id = p_user_id)
      AND (p_fecha_desde IS NULL OR a.created_at >= p_fecha_desde)
      AND (p_fecha_hasta IS NULL OR a.created_at <= p_fecha_hasta)
  ) t
  LIMIT p_limit OFFSET p_offset;

  RETURN jsonb_build_object('total', v_total, 'items', v_items);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_audit_logs(text, uuid, timestamptz, timestamptz, integer, integer)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_audit_logs(text, uuid, timestamptz, timestamptz, integer, integer) FROM anon;

-- ============================================================
-- 5. GET_ADMIN_USERS: guard NULL (anon NO puede listar usuarios)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_admin_users(
  p_search TEXT DEFAULT NULL,
  p_role TEXT DEFAULT NULL,
  p_driver_status TEXT DEFAULT NULL,
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
  v_admin_id UUID := auth.uid();
  v_caller_zone UUID;
  v_search TEXT := NULLIF(TRIM(COALESCE(p_search, '')), '');
  v_total INTEGER := 0;
  v_items JSONB;
BEGIN
  IF v_admin_id IS NULL OR public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;
  v_caller_zone := public.caller_zone_id();

  IF p_limit > 100 THEN p_limit := 100; END IF;
  IF p_limit < 1 THEN p_limit := 25; END IF;
  IF p_offset < 0 THEN p_offset := 0; END IF;

  SELECT COUNT(*) INTO v_total
  FROM public.profiles pr
  WHERE (v_search IS NULL
         OR pr.full_name ILIKE '%' || v_search || '%'
         OR pr.email ILIKE '%' || v_search || '%'
         OR pr.phone ILIKE '%' || v_search || '%')
    AND (v_caller_zone IS NULL OR pr.zone_id = v_caller_zone)
    AND (v_caller_zone IS NULL OR pr.role IN ('cliente', 'conductor'))
    AND (p_role IS NULL
         OR (p_role = 'cliente' AND pr.role = 'cliente')
         OR (p_role = 'conductor' AND pr.role = 'conductor')
         OR (p_role = 'admin' AND pr.role IN ('super_admin', 'encargado')))
    AND (p_driver_status IS NULL OR COALESCE(pr.driver_status::text, '') = p_driver_status);

  SELECT COALESCE(jsonb_agg(t ORDER BY t.created_at DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT
      pr.id::text AS id,
      pr.full_name,
      pr.email,
      pr.phone,
      pr.role::text AS role,
      pr.driver_status::text AS driver_status,
      pr.is_online,
      pr.onboarding_completed,
      pr.created_at,
      COALESCE(w.balance_usd, 0) AS balance_usd
    FROM public.profiles pr
    LEFT JOIN public.wallets w ON w.user_id = pr.id
    WHERE (v_search IS NULL
           OR pr.full_name ILIKE '%' || v_search || '%'
           OR pr.email ILIKE '%' || v_search || '%'
           OR pr.phone ILIKE '%' || v_search || '%')
      AND (v_caller_zone IS NULL OR pr.zone_id = v_caller_zone)
      AND (v_caller_zone IS NULL OR pr.role IN ('cliente', 'conductor'))
      AND (p_role IS NULL
           OR (p_role = 'cliente' AND pr.role = 'cliente')
           OR (p_role = 'conductor' AND pr.role = 'conductor')
           OR (p_role = 'admin' AND pr.role IN ('super_admin', 'encargado')))
      AND (p_driver_status IS NULL OR COALESCE(pr.driver_status::text, '') = p_driver_status)
  ) t
  LIMIT p_limit OFFSET p_offset;

  RETURN jsonb_build_object('total', v_total, 'items', v_items);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_admin_users TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_admin_users FROM anon;


-- ============================================================
-- 6. APPROVE_RIDE_PROOF: guard NULL (anon NO puede aprobar
--    comprobantes ni mover dinero) + auditoría
-- ============================================================
CREATE OR REPLACE FUNCTION public.approve_ride_proof(
  p_ride_id UUID,
  p_approve BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_ride RECORD;
  v_status TEXT;
  v_wallet RECORD;
  v_app_credit NUMERIC := 0.00;
  v_commission NUMERIC := 0.00;
  v_earning RECORD;
  v_fare NUMERIC;
  v_category vehicle_category;
BEGIN
  IF v_admin_id IS NULL OR public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('approve_ride_proof', 30);

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id FOR UPDATE;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF public.get_user_role(v_admin_id) = 'encargado'
     AND COALESCE(v_ride.origin_zone_id, '00000000-0000-0000-0000-000000000000') != public.caller_zone_id() THEN
    RAISE EXCEPTION 'No autorizado para viajes de otra ciudad';
  END IF;

  IF v_ride.proof_status != 'pendiente' THEN
    RAISE EXCEPTION 'El comprobante ya fue procesado';
  END IF;

  v_status := CASE WHEN p_approve THEN 'aprobado' ELSE 'rechazado' END;
  v_fare := v_ride.final_fare_usd;
  v_category := v_ride.category;

  UPDATE rides SET proof_status = v_status WHERE id = p_ride_id;

  IF p_approve THEN
    IF v_ride.status = 'buscando' THEN
      INSERT INTO notifications (user_id, title, body, type, data)
      SELECT p.id, 'Nuevo viaje disponible',
             CONCAT('Viaje de ', v_fare, '$ en ', v_category, '. ¿Lo aceptas?'),
             'ride_available',
             jsonb_build_object('ride_id', p_ride_id, 'category', v_category,
                                'fare', v_fare, 'url', '/conductor')
      FROM profiles p
      WHERE p.role = 'conductor'
        AND p.driver_status = 'aprobado'
        AND public.driver_has_vehicle_for_category(v_category) = TRUE;
    END IF;

    IF v_ride.status = 'completada' AND v_ride.driver_id IS NOT NULL THEN
      v_commission := COALESCE(v_ride.commission_usd, 0);
      v_app_credit := GREATEST(COALESCE(v_ride.total_fare_usd, v_ride.final_fare_usd, 0) - v_commission, 0);

      SELECT * INTO v_earning FROM driver_earnings WHERE ride_id = p_ride_id;

      IF v_earning.id IS NOT NULL THEN
        UPDATE driver_earnings
        SET cash_received_usd = 0,
            app_credit_usd = v_app_credit,
            status = 'completado'
        WHERE ride_id = p_ride_id;
      ELSE
        INSERT INTO driver_earnings (
          ride_id, driver_id, fare_usd, commission_usd,
          cash_received_usd, app_credit_usd, payment_method, status
        ) VALUES (
          p_ride_id, v_ride.driver_id, COALESCE(v_ride.total_fare_usd, v_ride.final_fare_usd, 0), v_commission,
          0, v_app_credit, v_ride.payment_method, 'completado'
        );
      END IF;

      IF v_app_credit > 0 AND NOT EXISTS (
        SELECT 1 FROM transactions t
        WHERE t.ride_id = p_ride_id AND t.type = 'credito' AND t.user_id = v_ride.driver_id
      ) THEN
        SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.driver_id;
        IF v_wallet.id IS NOT NULL THEN
          UPDATE wallets
          SET balance_usd = balance_usd + v_app_credit,
              updated_at = NOW()
          WHERE user_id = v_ride.driver_id;

          INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
          VALUES (v_wallet.id, v_ride.driver_id, 'credito', v_app_credit, 'completado',
                  'Ganancia del viaje por Pago Móvil (comprobante aprobado)', p_ride_id);
        END IF;
      END IF;
    END IF;
  END IF;

  INSERT INTO notifications (user_id, title, body, type, data)
  VALUES (
    v_ride.client_id,
    CASE WHEN p_approve THEN 'Comprobante aprobado' ELSE 'Comprobante rechazado' END,
    CASE WHEN p_approve THEN 'Tu pago fue aprobado. El viaje ya está disponible para conductores.'
         ELSE 'Tu comprobante fue rechazado. Sube uno válido.' END,
    'proof_reviewed',
    jsonb_build_object('ride_id', p_ride_id, 'approved', p_approve)
  );

  IF NOT p_approve AND v_ride.status = 'buscando' THEN
    UPDATE rides SET status = 'cancelada',
                     cancelled_by = v_admin_id,
                     cancel_reason = 'Comprobante rechazado',
                     updated_at = NOW()
    WHERE id = p_ride_id;

    IF v_ride.coupon_id IS NOT NULL THEN
      DELETE FROM coupon_redemptions WHERE ride_id = p_ride_id;
      UPDATE coupons SET used_count = GREATEST(used_count - 1, 0), updated_at = NOW()
      WHERE id = v_ride.coupon_id;
    END IF;

    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (v_ride.client_id, 'Viaje cancelado',
            'Tu viaje fue cancelado porque el comprobante fue rechazado. Solicita de nuevo con un pago válido.',
            'ride_cancelled', jsonb_build_object('ride_id', p_ride_id));
  END IF;

  -- 📝 Auditoría
  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_admin_id, 'APPROVE_RIDE_PROOF', 'ride', p_ride_id,
          jsonb_build_object('approved', p_approve, 'status', v_status,
                             'fare', v_fare, 'zone_id', v_ride.origin_zone_id,
                             'driver_id', v_ride.driver_id, 'client_id', v_ride.client_id));

  RETURN jsonb_build_object('success', TRUE, 'proof_status', v_status);
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_ride_proof TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.approve_ride_proof FROM anon;


-- ============================================================
-- 7. APPROVE_RECHARGE: guard NULL (anon NO puede acreditar
--    saldo) + chequeo de ciudad + auditoría
-- ============================================================
CREATE OR REPLACE FUNCTION public.approve_recharge(p_transaction_id UUID, p_approve BOOLEAN)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_txn RECORD;
  v_wallet_id UUID;
BEGIN
  IF v_admin_id IS NULL OR public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('approve_recharge', 20);

  SELECT * INTO v_txn FROM transactions WHERE id = p_transaction_id;
  IF v_txn.id IS NULL THEN RAISE EXCEPTION 'Transaccion no encontrada'; END IF;
  IF v_txn.status != 'pendiente' THEN RAISE EXCEPTION 'La recarga ya fue procesada'; END IF;

  -- Encargado: la recarga debe ser de un usuario de SU ciudad
  IF public.get_user_role(v_admin_id) = 'encargado' THEN
    IF NOT EXISTS (
      SELECT 1 FROM profiles p
      WHERE p.id = v_txn.user_id
        AND COALESCE(p.zone_id, '00000000-0000-0000-0000-000000000000') = public.caller_zone_id()
    ) THEN
      RAISE EXCEPTION 'No autorizado para recargas de otra ciudad';
    END IF;
  END IF;

  IF p_approve THEN
    SELECT id INTO v_wallet_id FROM wallets WHERE user_id = v_txn.user_id;
    IF v_wallet_id IS NULL THEN
      INSERT INTO wallets (user_id, balance_usd, debt_limit_usd) VALUES (v_txn.user_id, 0, 0) RETURNING id INTO v_wallet_id;
    END IF;
    UPDATE wallets SET balance_usd = balance_usd + v_txn.amount_usd, updated_at = NOW() WHERE id = v_wallet_id;
    UPDATE transactions SET status = 'completado', reviewed_by = v_admin_id, reviewed_at = NOW() WHERE id = p_transaction_id;
    INSERT INTO notifications (user_id, title, body, type, data) VALUES
      (v_txn.user_id, 'Recarga aprobada', 'Tu recarga de $' || v_txn.amount_usd::TEXT || ' fue aprobada.', 'recharge_approved', jsonb_build_object('transaction_id', p_transaction_id));
  ELSE
    UPDATE transactions SET status = 'rechazado', reviewed_by = v_admin_id, reviewed_at = NOW() WHERE id = p_transaction_id;
    INSERT INTO notifications (user_id, title, body, type, data) VALUES
      (v_txn.user_id, 'Recarga rechazada', 'Tu recarga de $' || v_txn.amount_usd::TEXT || ' fue rechazada.', 'recharge_rejected', jsonb_build_object('transaction_id', p_transaction_id));
  END IF;

  -- 📝 Auditoría
  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_admin_id, 'APPROVE_RECHARGE', 'transaction', p_transaction_id,
          jsonb_build_object('approved', p_approve, 'amount_usd', v_txn.amount_usd,
                             'user_id', v_txn.user_id));

  RETURN jsonb_build_object('success', TRUE, 'transaction_id', p_transaction_id, 'approved', p_approve);
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_recharge TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.approve_recharge FROM anon;

-- ============================================================
-- 8. REVIEW_DRIVER: guard NULL (anon NO puede aprobar/rechazar
--    conductores) + auditoría existente
-- ============================================================
CREATE OR REPLACE FUNCTION public.review_driver(
  p_driver_id UUID,
  p_approve BOOLEAN,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reviewer_id UUID := auth.uid();
  v_reviewer RECORD;
  v_driver_zone UUID;
  v_new_status driver_status;
BEGIN
  IF v_reviewer_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT * INTO v_reviewer FROM profiles WHERE id = v_reviewer_id;
  IF v_reviewer.role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado para revisar conductores';
  END IF;

  -- Encargado: el conductor debe pertenecer a su ciudad
  IF v_reviewer.role = 'encargado' THEN
    SELECT zone_id INTO v_driver_zone FROM profiles WHERE id = p_driver_id;
    IF public.caller_zone_id() IS NULL OR COALESCE(v_driver_zone, '00000000-0000-0000-0000-000000000000') != public.caller_zone_id() THEN
      RAISE EXCEPTION 'No autorizado para revisar conductores de otra ciudad';
    END IF;
  END IF;

  v_new_status := CASE WHEN p_approve THEN 'aprobado' ELSE 'rechazado' END;

  UPDATE profiles
  SET driver_status = v_new_status
  WHERE id = p_driver_id;

  PERFORM public.notify_user(
    p_driver_id,
    CASE WHEN p_approve THEN '¡Cuenta aprobada!' ELSE 'Cuenta rechazada' END,
    CASE WHEN p_approve THEN 'Ya puedes comenzar a trabajar. ¡Bienvenido!'
         ELSE COALESCE(p_reason, 'Tu solicitud fue rechazada. Contacta al administrador.') END,
    'driver_review',
    jsonb_build_object('approved', p_approve, 'url', '/conductor')
  );

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_reviewer_id, 'REVIEW_DRIVER', 'profile', p_driver_id,
          jsonb_build_object('approved', p_approve, 'reason', p_reason));

  RETURN jsonb_build_object('success', TRUE, 'driver_id', p_driver_id, 'status', v_new_status);
END;
$$;

GRANT EXECUTE ON FUNCTION public.review_driver TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.review_driver FROM anon;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 053: fuga de datos cerrada' AS estado;

-- anon ya NO debe poder ejecutar las funciones sensibles
SELECT p.proname, has_function_privilege('anon', p.oid, 'EXECUTE') AS anon_puede
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('get_admin_users', 'get_audit_logs', 'approve_ride_proof', 'approve_recharge', 'review_driver', 'set_user_role')
ORDER BY p.proname;

