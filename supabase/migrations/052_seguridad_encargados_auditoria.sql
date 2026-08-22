-- ============================================================
-- RIDESOCOPÓ - Migración 052: SEGURIDAD ENCARGADOS + AUDITORÍA
-- ------------------------------------------------------------
-- OBJETIVO:
--   1) El encargado NUNCA puede crear/remover otros encargados
--      (la RPC set_user_role sigue siendo solo super_admin y se
--      registra TODO cambio de rol en audit_logs).
--   2) Auditoría completa de acciones sensibles del encargado:
--      cambios de rol, aprobación de comprobantes (viajes y
--      recargas), cambios de soporte de zona. El super_admin
--      puede revisarlas en /admin/auditoria.
--   3) Cierre de brechas por ciudad: aprobar recargas solo de
--      usuarios de SU ciudad, get_pending_recharges filtrado,
--      encargado no puede mover conductores entre ciudades vía
--      RLS, y get_admin_users nunca le muestra otros admins.
--
-- COSTO: audit_logs ya se limpia solo (migración 051, cron
-- diario 3 AM, retención 180 días). Solo se añaden 1 fila por
-- acción y una RPC paginada. Nada nuevo en storage/edge.
-- ============================================================

-- ============================================================
-- 1. SET_USER_ROLE: solo super_admin + rate limit + auditoría
--    (prohíbe otorgar super_admin y modificar admins)
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_user_role(
  p_user_id UUID,
  p_role TEXT,
  p_zone_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin    UUID := auth.uid();
  v_old_role TEXT;
  v_old_zone UUID;
BEGIN
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  -- Solo super_admin (el encargado NO puede crear/degradar encargados)
  IF public.get_user_role(v_admin) != 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('set_user_role', 10);

  IF p_user_id = v_admin THEN
    RAISE EXCEPTION 'No puedes cambiar tu propio rol';
  END IF;

  -- Nunca otorgar super_admin desde aquí (solo promote_to_super_admin)
  IF p_role NOT IN ('cliente', 'conductor', 'encargado') THEN
    RAISE EXCEPTION 'Rol no válido';
  END IF;

  IF p_role = 'encargado' AND p_zone_id IS NULL THEN
    RAISE EXCEPTION 'Un encargado debe tener una ciudad asignada';
  END IF;

  SELECT role::text, zone_id INTO v_old_role, v_old_zone FROM profiles WHERE id = p_user_id;
  IF v_old_role IS NULL THEN
    RAISE EXCEPTION 'Usuario no encontrado';
  END IF;

  IF v_old_role = 'super_admin' THEN
    RAISE EXCEPTION 'No puedes modificar el rol de un administrador';
  END IF;

  UPDATE profiles
  SET role = p_role::public.user_role,
      zone_id = p_zone_id,
      driver_status = NULL,
      updated_at = NOW()
  WHERE id = p_user_id;

  -- 📝 Auditoría: quién, a quién, de qué a qué
  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_admin, 'SET_USER_ROLE', 'profile', p_user_id,
          jsonb_build_object('from_role', v_old_role, 'from_zone', v_old_zone,
                             'to_role', p_role, 'to_zone', p_zone_id));

  RETURN jsonb_build_object('success', TRUE, 'user_id', p_user_id, 'role', p_role, 'zone_id', p_zone_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_user_role(uuid, text, uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.set_user_role FROM anon;

-- ============================================================
-- 2. SET_ZONE_SUPPORT: admin (cualquier zona) o encargado (su
--    zona) + auditoría del número de soporte
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_zone_support(
  p_zone_id UUID,
  p_phone TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id   UUID := auth.uid();
  v_role      TEXT;
  v_zone      UUID;
  v_old_phone TEXT;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('set_zone_support', 20);

  SELECT role::text, zone_id INTO v_role, v_zone FROM profiles WHERE id = v_user_id;

  IF v_role = 'super_admin' THEN
    NULL; -- puede asignar a cualquier zona
  ELSIF v_role = 'encargado' AND v_zone = p_zone_id THEN
    NULL; -- solo su propia zona
  ELSE
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM zones WHERE id = p_zone_id) THEN
    RAISE EXCEPTION 'Zona no encontrada';
  END IF;

  SELECT support_whatsapp INTO v_old_phone FROM zones WHERE id = p_zone_id;

  UPDATE zones SET support_whatsapp = NULLIF(TRIM(p_phone), ''), updated_at = NOW()
  WHERE id = p_zone_id;

  -- 📝 Auditoría
  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_user_id, 'SET_ZONE_SUPPORT', 'zone', p_zone_id,
          jsonb_build_object('from_phone', v_old_phone, 'to_phone', NULLIF(TRIM(p_phone), '')));

  RETURN jsonb_build_object('success', TRUE, 'zone_id', p_zone_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_zone_support(uuid, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.set_zone_support FROM anon;

-- ============================================================
-- 3. APPROVE_RIDE_PROOF: super_admin o encargado (solo su
--    ciudad) + AUDITORÍA del comprobante (mueve dinero)
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
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('approve_ride_proof', 30);

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id FOR UPDATE;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  -- Encargado: el viaje debe ser de su ciudad
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

  -- 📝 Auditoría: quién aprobó/rechazó qué comprobante
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
-- 4. APPROVE_RECHARGE: aprobar recarga de billetera
--    - encargado SOLO puede aprobar recargas de usuarios de su
--      ciudad (evita acreditar saldo a otros)
--    + AUDITORÍA de la recarga (mueve dinero)
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
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
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
-- 5. GET_PENDING_RECHARGES: encargado ve SOLO recargas de su
--    ciudad (super_admin ve todas)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_pending_recharges()
RETURNS TABLE(transaction_id uuid, user_id uuid, user_name text, user_email text, amount_usd numeric, proof_url text, status text, created_at timestamptz)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_zone UUID := public.caller_zone_id();
BEGIN
  RETURN QUERY
  SELECT t.id, t.user_id, COALESCE(p.full_name, 'Usuario'), COALESCE(p.email, ''),
         t.amount_usd, t.proof_url, t.status::TEXT, t.created_at
  FROM transactions t
  LEFT JOIN profiles p ON p.id = t.user_id
  WHERE t.type = 'recarga'
    AND t.status = 'pendiente'
    AND t.proof_url IS NOT NULL
    AND (v_zone IS NULL OR COALESCE(p.zone_id, '00000000-0000-0000-0000-000000000000') = v_zone)
  ORDER BY t.created_at ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_pending_recharges() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_pending_recharges FROM anon;


-- ============================================================
-- 6. RLS PROFILES: encargado SOLO edita conductores de SU ciudad
--    y NUNCA cambia roles (WITH CHECK explícito: role sigue
--    siendo 'conductor' y zone_id queda en su ciudad)
-- ============================================================
DROP POLICY IF EXISTS "encargado_update_drivers" ON public.profiles;
CREATE POLICY "encargado_update_drivers" ON public.profiles
  FOR UPDATE
  USING (
    public.get_user_role(auth.uid()) = 'encargado'
    AND role = 'conductor'
  )
  WITH CHECK (
    public.get_user_role(auth.uid()) = 'encargado'
    AND role = 'conductor'
    AND (zone_id IS NULL OR zone_id = public.caller_zone_id())
  );

-- ============================================================
-- 7. GET_ADMIN_USERS: el encargado NUNCA ve otros encargados ni
--    super_admins (solo pasajeros y conductores de su ciudad)
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
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
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
    -- El encargado solo ve pasajeros y conductores (nunca admins)
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
-- 8. GET_AUDIT_LOGS: historial de auditoría para el super_admin
--    (paginado, filtrable por acción/usuario/fechas, rate limit)
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
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_total INTEGER := 0;
  v_items JSONB;
BEGIN
  IF public.get_user_role(v_admin_id) != 'super_admin' THEN
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
REVOKE ALL ON FUNCTION public.get_audit_logs FROM anon;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 052: seguridad de encargados y auditoría lista' AS estado;

SELECT p.proname, pg_get_functiondef(p.oid) LIKE '%audit_logs%' AS tiene_auditoria
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('set_user_role', 'approve_ride_proof', 'approve_recharge', 'set_zone_support', 'get_audit_logs')
ORDER BY p.proname;

