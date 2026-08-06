-- ============================================================
-- RIDESOCOPÓ - Migración 036: SEGURIDAD CRÍTICA + COSTOS
-- ------------------------------------------------------------
-- Aplica de forma VERSIONADA (en la historia de migraciones)
-- los fixes que antes vivían solo en scripts manuales
-- (security_hardening.sql, repair_*.sql), para que un
-- `supabase db push` limpio produzca una base SEGURA.
--
-- Incluye:
--  1. protege promote_to_super_admin (escalada de privilegios)
--  2. bloquea notify_user / notify_users_by_role (spam/phishing)
--  3. hace privada push_settings (secreto de la Edge Function)
--  4. evita auto-promoción de rol en profiles (INSERT/UPDATE)
--  5. corrige condición de carrera (TOCTOU) en débito de billetera
--  6. agrega rate limiting a RPCs críticas
--  7. restringe fan-out de notificaciones ride_available (costo)
--  8. endurece search_path en funciones SECURITY DEFINER
--  9. revoca permisos residuales a anon/authenticated
-- 10. agrega CHECK constraints de montos e índices (costo)
-- ============================================================

-- ============================================================
-- 1. ASEGURAR GET_USER_ROLE (base de todas las políticas RLS)
--    Se mantiene EXECUTE para anon/authenticated porque las
--    políticas RLS se evalúan con los privilegios del usuario.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_user_role(user_id UUID)
RETURNS public.user_role
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT role FROM public.profiles WHERE id = user_id;
$$;

GRANT EXECUTE ON FUNCTION public.get_user_role(UUID) TO anon, authenticated, service_role;

-- ============================================================
-- 2. PROTEGER PROMOTE_TO_SUPER_ADMIN (escalada de privilegios)
--    La versión original NO verificaba al llamador: cualquier
--    usuario (incluso anónimo) podía autopromoverse.
--    Nueva versión: requiere un super_admin existente, o el
--    bootstrap inicial desde el SQL Editor (postgres/sin JWT)
--    o con service_role.
-- ============================================================
CREATE OR REPLACE FUNCTION public.promote_to_super_admin(p_email TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_caller_id UUID := auth.uid();
  v_caller_role TEXT;
  v_jwt_role TEXT;
  v_target_id UUID;
BEGIN
  v_jwt_role := COALESCE(current_setting('request.jwt.claims', true)::jsonb ->> 'role', 'postgres');

  -- Permitido: super_admin autenticado, o SQL Editor (postgres), o service_role.
  IF v_caller_id IS NOT NULL THEN
    SELECT role::text INTO v_caller_role FROM public.profiles WHERE id = v_caller_id;
    IF v_caller_role != 'super_admin' THEN
      RAISE EXCEPTION 'No autorizado. Solo un super_admin puede promover usuarios.';
    END IF;
  ELSIF v_jwt_role IN ('anon', 'authenticated') THEN
    RAISE EXCEPTION 'No autorizado. Solo un super_admin puede promover usuarios.';
  END IF;

  SELECT id INTO v_target_id FROM public.profiles WHERE email = p_email;
  IF v_target_id IS NULL THEN
    RAISE EXCEPTION 'Usuario no encontrado';
  END IF;

  UPDATE public.profiles SET role = 'super_admin' WHERE id = v_target_id;

  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_caller_id, 'PROMOTE_SUPER_ADMIN', 'profile', v_target_id,
          jsonb_build_object('promoted_email', p_email));

  RETURN jsonb_build_object('success', TRUE, 'user_id', v_target_id, 'role', 'super_admin');
END;
$$;

-- ============================================================
-- 3. HACER PRIVADA PUSH_SETTINGS (secreto de la Edge Function)
--    Antes: policy "system_manage_push_settings" con USING(TRUE)
--    → cualquier usuario autenticado podía leer function_secret
--    y abusar de /functions/v1/push-notifications.
--    Ahora: sin acceso por RLS (solo owner/service_role, que
--    bypasean RLS). El trigger notify_push_after_insert es
--    SECURITY DEFINER → no se ve afectado.
-- ============================================================
DROP POLICY IF EXISTS "system_manage_push_settings" ON public.push_settings;
DROP POLICY IF EXISTS "push_settings_system_only" ON public.push_settings;

CREATE POLICY "push_settings_system_only" ON public.push_settings
  FOR ALL USING (FALSE);

REVOKE ALL ON public.push_settings FROM anon;
REVOKE ALL ON public.push_settings FROM authenticated;

-- ============================================================
-- 4. PROTEGER NOTIFY_USER / NOTIFY_USERS_BY_ROLE (spam/phishing)
--    Antes: cualquier usuario (incluso anónimo) podía insertar
--    notificaciones para CUALQUIER usuario (notify_user) o para
--    TODOS (notify_users_by_role).
--    Ahora: EXECUTE solo para service_role. Las llamadas internas
--    desde otras funciones SECURITY DEFINER (owner) siguen
--    funcionando porque corren con los privilegios del definidor.
-- ============================================================
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure::text AS fn
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN ('notify_user', 'notify_users_by_role')
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon, authenticated', r.fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO service_role', r.fn);
  END LOOP;
END $$;

-- ============================================================
-- 5. PREVENIR AUTO-PROMOCIÓN DE ROL EN PROFILES
--    5.1 INSERT: permitido solo para crear el propio perfil
--        (fallback OAuth) con rol forzado a 'cliente'.
--    5.2 UPDATE: el usuario solo puede editar su perfil sin
--        tocar role / driver_status / email / is_online.
-- ============================================================

-- 5.1 INSERT con rol forzado a 'cliente'
DROP POLICY IF EXISTS "users_insert_own_profile" ON public.profiles;
CREATE POLICY "users_insert_own_profile" ON public.profiles
  FOR INSERT WITH CHECK (
    auth.uid() = id
    AND role = 'cliente'
    AND driver_status IS NULL
    AND is_online = FALSE
  );

-- 5.2 UPDATE inmutable (evita escalada de rol / estado)
DROP POLICY IF EXISTS "users_update_own_profile" ON public.profiles;
CREATE POLICY "users_update_own_profile" ON public.profiles
  FOR UPDATE
  USING (auth.uid() = id)
  WITH CHECK (
    auth.uid() = id
    AND role = public.get_user_role(auth.uid())
    AND email = (SELECT email FROM public.profiles WHERE id = auth.uid())
    AND COALESCE(driver_status, 'pendiente') =
        COALESCE((SELECT driver_status FROM public.profiles WHERE id = auth.uid()), 'pendiente')
    AND is_online = (SELECT is_online FROM public.profiles WHERE id = auth.uid())
  );

-- ============================================================
-- 6. RATE LIMITING PARA RPCs CRÍTICAS
-- ============================================================
CREATE TABLE IF NOT EXISTS public.rpc_audit (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID,
  function_name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_rpc_audit_user_time
  ON public.rpc_audit(user_id, created_at DESC);

CREATE OR REPLACE FUNCTION public.guard_rate_limit(
  p_function_name TEXT,
  p_max_per_minute INTEGER DEFAULT 20
)
RETURNS VOID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_count INTEGER;
BEGIN
  INSERT INTO public.rpc_audit (user_id, function_name)
  VALUES (v_user_id, p_function_name);

  SELECT COUNT(*) INTO v_count
  FROM public.rpc_audit
  WHERE user_id = v_user_id
    AND function_name = p_function_name
    AND created_at > NOW() - INTERVAL '1 minute';

  -- Limpieza: borrar registros viejos (>1 hora)
  DELETE FROM public.rpc_audit WHERE created_at < NOW() - INTERVAL '1 hour';

  IF v_count > p_max_per_minute THEN
    RAISE EXCEPTION 'Demasiadas solicitudes. Intenta de nuevo en un minuto.';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.guard_rate_limit(TEXT, INTEGER) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.guard_rate_limit(TEXT, INTEGER) TO service_role;

-- ============================================================
-- 7. REQUEST_RIDE / REQUEST_RIDE_WITH_PROOF
--    - 🔒 FIX TOCTOU: SELECT ... FOR UPDATE sobre la billetera
--      antes de validar saldo (evita sobregiro concurrente).
--    - Rate limiting por usuario.
--    - 💰 COSTO: ride_available SOLO a conductores ONLINE y
--      tope de 25 (evita N push por viaje en Edge Functions).
-- ============================================================

CREATE OR REPLACE FUNCTION public.request_ride(
  p_origin_lat NUMERIC,
  p_origin_lng NUMERIC,
  p_origin_address TEXT,
  p_dest_lat NUMERIC,
  p_dest_lng NUMERIC,
  p_dest_address TEXT,
  p_category vehicle_category,
  p_payment_method TEXT DEFAULT 'efectivo',
  p_coupon_code TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_fare JSONB;
  v_ride_id UUID;
  v_final_fare NUMERIC;
  v_wallet RECORD;
  v_is_wallet BOOLEAN;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('request_ride', 15);

  v_fare := public.calculate_fare(
    p_origin_lat, p_origin_lng,
    p_dest_lat, p_dest_lng,
    p_category, p_coupon_code
  );

  IF NOT EXISTS (SELECT 1 FROM payment_methods WHERE name = p_payment_method AND is_active = TRUE) THEN
    RAISE EXCEPTION 'Método de pago no disponible';
  END IF;

  v_final_fare := (v_fare->>'final_fare')::NUMERIC;
  v_is_wallet := (p_payment_method = 'Billetera');

  -- ============================================================
  -- Si es Billetera: verificar saldo y DEBITAR de inmediato.
  -- 🔒 FIX TOCTOU: FOR UPDATE bloquea la fila de la billetera
  --    para que dos solicitudes concurrentes no pasen ambas la
  --    validación de saldo (evita sobregiro / viajes gratis).
  -- ============================================================
  IF v_is_wallet THEN
    SELECT * INTO v_wallet
    FROM wallets
    WHERE user_id = v_user_id
    FOR UPDATE;

    IF v_wallet.id IS NULL THEN
      RAISE EXCEPTION 'Billetera no encontrada';
    END IF;

    IF v_wallet.balance_usd < v_final_fare THEN
      RAISE EXCEPTION USING MESSAGE = format('Saldo insuficiente en billetera. Necesitas $%s y tienes $%s', v_final_fare, v_wallet.balance_usd);
    END IF;

    UPDATE wallets
    SET balance_usd = balance_usd - v_final_fare,
        updated_at = NOW()
    WHERE user_id = v_user_id;

    INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description)
    VALUES (v_wallet.id, v_user_id, 'debito', v_final_fare, 'completado',
            'Pago de viaje con billetera');
  END IF;

  -- ============================================================
  -- Crear el viaje
  -- ============================================================
  INSERT INTO rides (
    client_id, category,
    origin_lat, origin_lng, origin_address,
    destination_lat, destination_lng, destination_address,
    destination_barrio_id, destination_barrio_name,
    base_fare_usd, origin_surcharge_usd, destination_surcharge_usd,
    total_fare_usd, discount_usd, final_fare_usd,
    payment_method, status
  ) VALUES (
    v_user_id, p_category,
    p_origin_lat, p_origin_lng, p_origin_address,
    p_dest_lat, p_dest_lng, p_dest_address,
    (v_fare->>'destination_barrio_id')::UUID,
    v_fare->>'destination_barrio_name',
    (v_fare->>'base_fare')::NUMERIC,
    (v_fare->>'origin_surcharge')::NUMERIC,
    (v_fare->>'destination_surcharge')::NUMERIC,
    (v_fare->>'total_fare')::NUMERIC,
    (v_fare->>'discount')::NUMERIC,
    v_final_fare,
    p_payment_method, 'buscando'
  ) RETURNING id INTO v_ride_id;

  -- ============================================================
  -- Notificar a conductores aprobados con vehículo de la categoría.
  -- 💰 COSTO: solo ONLINE y tope de 25 (evita N push por viaje).
  -- ============================================================
  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT p.id, 'Nuevo viaje disponible',
         CONCAT('Viaje de ', v_fare->>'final_fare', '$ en ', p_category, '. ¿Lo aceptas?'),
         'ride_available',
         jsonb_build_object('ride_id', v_ride_id, 'category', p_category,
                            'fare', (v_fare->>'final_fare')::NUMERIC,
                            'url', '/conductor')
  FROM profiles p
  WHERE p.role = 'conductor'
    AND p.driver_status = 'aprobado'
    AND p.is_online = TRUE
    AND p.id IN (
      SELECT v.driver_id FROM vehicles v
      WHERE v.is_active = TRUE AND v.category = p_category
    )
  ORDER BY p.updated_at DESC
  LIMIT 25;

  -- Auditoría
  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_user_id, 'REQUEST_RIDE', 'ride', v_ride_id,
          jsonb_build_object('fare', v_fare, 'wallet_debited', v_is_wallet));

  RETURN v_ride_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_ride TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_ride TO service_role;
REVOKE ALL ON FUNCTION public.request_ride FROM anon;

-- 7.2 REQUEST_RIDE_WITH_PROOF (Pago Móvil) — rate limit + fan-out online
CREATE OR REPLACE FUNCTION public.request_ride_with_proof(
  p_origin_lat NUMERIC,
  p_origin_lng NUMERIC,
  p_origin_address TEXT,
  p_dest_lat NUMERIC,
  p_dest_lng NUMERIC,
  p_dest_address TEXT,
  p_category vehicle_category,
  p_payment_method TEXT,
  p_proof_url TEXT,
  p_coupon_code TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_fare JSONB;
  v_ride_id UUID;
  v_proof_required BOOLEAN;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('request_ride_with_proof', 15);

  SELECT proof_required INTO v_proof_required
  FROM payment_methods WHERE name = p_payment_method AND is_active = TRUE;

  IF v_proof_required IS NULL THEN
    RAISE EXCEPTION 'Método de pago no disponible';
  END IF;

  IF v_proof_required AND (p_proof_url IS NULL OR p_proof_url = '') THEN
    RAISE EXCEPTION 'Debes subir el comprobante del pago';
  END IF;

  v_fare := public.calculate_fare(
    p_origin_lat, p_origin_lng,
    p_dest_lat, p_dest_lng,
    p_category, p_coupon_code
  );

  INSERT INTO rides (
    client_id, category,
    origin_lat, origin_lng, origin_address,
    destination_lat, destination_lng, destination_address,
    destination_barrio_id, destination_barrio_name,
    base_fare_usd, origin_surcharge_usd, destination_surcharge_usd,
    total_fare_usd, discount_usd, final_fare_usd,
    payment_method, status, proof_url, proof_status
  ) VALUES (
    v_user_id, p_category,
    p_origin_lat, p_origin_lng, p_origin_address,
    p_dest_lat, p_dest_lng, p_dest_address,
    (v_fare->>'destination_barrio_id')::UUID,
    v_fare->>'destination_barrio_name',
    (v_fare->>'base_fare')::NUMERIC,
    (v_fare->>'origin_surcharge')::NUMERIC,
    (v_fare->>'destination_surcharge')::NUMERIC,
    (v_fare->>'total_fare')::NUMERIC,
    (v_fare->>'discount')::NUMERIC,
    (v_fare->>'final_fare')::NUMERIC,
    p_payment_method, 'buscando',
    CASE WHEN v_proof_required THEN p_proof_url ELSE NULL END,
    CASE WHEN v_proof_required THEN 'pendiente' ELSE 'aprobado' END
  ) RETURNING id INTO v_ride_id;

  IF v_proof_required THEN
    INSERT INTO notifications (user_id, title, body, type, data)
    SELECT id, 'Comprobante por aprobar',
           'Nuevo comprobante de pago pendiente de revisión para un viaje',
           'proof_pending',
           jsonb_build_object('ride_id', v_ride_id, 'url', '/admin/comprobantes')
    FROM profiles WHERE role IN ('super_admin', 'encargado');
  ELSE
    -- 💰 COSTO: solo notificar ride_available si NO requiere comprobante,
    --    y SOLO a conductores ONLINE (tope 25).
    INSERT INTO notifications (user_id, title, body, type, data)
    SELECT p.id, 'Nuevo viaje disponible',
           CONCAT('Viaje de ', v_fare->>'final_fare', '$ en ', p_category, '. ¿Lo aceptas?'),
           'ride_available',
           jsonb_build_object('ride_id', v_ride_id, 'category', p_category,
                              'fare', (v_fare->>'final_fare')::NUMERIC,
                              'url', '/conductor')
    FROM profiles p
    WHERE p.role = 'conductor'
      AND p.driver_status = 'aprobado'
      AND p.is_online = TRUE
      AND p.id IN (
        SELECT v.driver_id FROM vehicles v
        WHERE v.is_active = TRUE AND v.category = p_category
      )
    ORDER BY p.updated_at DESC
    LIMIT 25;
  END IF;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_user_id, 'REQUEST_RIDE_WITH_PROOF', 'ride', v_ride_id,
          jsonb_build_object('fare', v_fare, 'proof_required', v_proof_required));

  RETURN v_ride_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_ride_with_proof TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_ride_with_proof TO service_role;
REVOKE ALL ON FUNCTION public.request_ride_with_proof FROM anon;

-- ============================================================
-- 8. REQUEST_WALLET_RECHARGE — rate limit + monto acotado
-- ============================================================
CREATE OR REPLACE FUNCTION public.request_wallet_recharge(
  p_amount_usd NUMERIC,
  p_proof_url TEXT,
  p_reference TEXT DEFAULT NULL
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
          'Recarga de saldo', p_proof_url, p_reference)
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

GRANT EXECUTE ON FUNCTION public.request_wallet_recharge TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_wallet_recharge TO service_role;
REVOKE ALL ON FUNCTION public.request_wallet_recharge FROM anon;

-- ============================================================
-- 9. PERMISOS POR DEFECTO (tablas nuevas) — solo lectura
--    Antes: ALTER DEFAULT PRIVILEGES GRANT ALL a anon/authenticated
--    → cualquier tabla nueva creada quedaba expuesta si RLS fallaba.
-- ============================================================
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO authenticated;

ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON FUNCTIONS FROM authenticated;

-- ============================================================
-- 10. REVOCAR EXECUTE A ANON EN FUNCIONES SENSIBLES
--     (defensa en profundidad: aunque las funciones tengan checks
--      internos de rol, anon NO debe poder invocarlas)
-- ============================================================
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure::text AS fn
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'settle_ride_earnings','complete_ride','accept_ride','cancel_ride',
        'driver_pay_to_platform','admin_pay_driver','admin_pay_driver_manual',
        'approve_payout','driver_confirm_payout','driver_request_payout',
        'adjust_driver_debt','approve_ride_proof','approve_recharge',
        'request_wallet_recharge','request_ride','request_ride_with_proof',
        'review_driver','update_exchange_rate','upsert_zone','create_coupon',
        'create_banner','upsert_barrio','resolve_ride_incident',
        'get_admin_metrics','get_admin_transactions','get_wallet_overview',
        'send_admin_notification','get_pending_recharges','get_payouts',
        'get_driver_earnings','get_driver_metrics','get_available_rides'
      )
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', r.fn);
  END LOOP;
END $$;

-- ============================================================
-- 11. HARDENING SEARCH_PATH EN FUNCIONES SECURITY DEFINER
--     Evita hijacking de search_path (función maliciosa con el
--     mismo nombre en otro schema ejecutada por una definer).
--     🔧 FIX: solo altera funciones PROPIAS (evita el error
--     "must be owner of function st_estimatedextent" de PostGIS).
-- ============================================================
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure::text AS fn
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prosecdef = TRUE
      AND p.proowner = (SELECT oid FROM pg_roles WHERE rolname = current_user)
      AND p.oid NOT IN (SELECT objid FROM pg_depend WHERE deptype = 'e')
      AND NOT EXISTS (
        SELECT 1 FROM pg_proc p2
        CROSS JOIN LATERAL unnest(COALESCE(p2.proconfig, '{}')) AS cfg
        WHERE p2.oid = p.oid AND cfg LIKE 'search_path=%'
      )
  LOOP
    BEGIN
      EXECUTE format('ALTER FUNCTION %s SET search_path = public', r.fn);
    EXCEPTION WHEN insufficient_privilege THEN
      RAISE NOTICE 'Sin permiso para alterar %: %', r.fn, SQLERRM;
    END;
  END LOOP;
END $$;

-- ============================================================
-- 12. CHECK CONSTRAINTS DE MONTOS (integridad financiera)
-- ============================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'wallets_balance_check') THEN
    ALTER TABLE wallets ADD CONSTRAINT wallets_balance_check
      CHECK (balance_usd >= -999999.99 AND balance_usd <= 999999.99);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'transactions_amount_check') THEN
    ALTER TABLE transactions ADD CONSTRAINT transactions_amount_check
      CHECK (amount_usd >= 0 AND amount_usd <= 999999.99);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'payouts_amount_check') THEN
    ALTER TABLE payouts ADD CONSTRAINT payouts_amount_check
      CHECK (amount_usd >= 0 AND amount_usd <= 999999.99);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'rides_fares_check') THEN
    ALTER TABLE rides ADD CONSTRAINT rides_fares_check
      CHECK (
        base_fare_usd >= 0 AND base_fare_usd <= 999999.99
        AND total_fare_usd >= 0 AND total_fare_usd <= 999999.99
        AND discount_usd >= 0 AND discount_usd <= 999999.99
        AND final_fare_usd >= 0 AND final_fare_usd <= 999999.99
        AND commission_usd >= 0 AND commission_usd <= 999999.99
      );
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'vehicle_categories_base_fare_check') THEN
    ALTER TABLE vehicle_categories ADD CONSTRAINT vehicle_categories_base_fare_check
      CHECK (base_fare_usd >= 0 AND base_fare_usd <= 99999.99);
  END IF;

  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'barrios_surcharge_check') THEN
    ALTER TABLE barrios ADD CONSTRAINT barrios_surcharge_check
      CHECK (surcharge_usd >= 0 AND surcharge_usd <= 99999.99);
  END IF;
END $$;

-- ============================================================
-- 13. ÍNDICES PARA CONSULTAS FRECUENTES (costo Supabase)
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_rides_client_status ON rides(client_id, status);
CREATE INDEX IF NOT EXISTS idx_rides_driver_status ON rides(driver_id, status);
CREATE INDEX IF NOT EXISTS idx_rides_status_created ON rides(status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_notifications_user_created ON notifications(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_transactions_user_created ON transactions(user_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_push_subscriptions_user ON push_subscriptions(user_id);

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 036 de seguridad crítica + costos aplicada' AS estado;

SELECT p.proname, pg_get_function_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('promote_to_super_admin', 'request_ride', 'request_wallet_recharge')
ORDER BY p.proname;






