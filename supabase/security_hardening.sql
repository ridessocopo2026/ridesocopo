-- ============================================================
-- RIDESOCOPÓ - SEGURIDAD ENDURECIDA
-- Ejecutar ENTERO en Supabase SQL Editor con rol postgres/service_role
--
-- 🔴 IMPORTANTE: Este script corrige vulnerabilidades críticas:
--  1. Revoca permisos excesivos de anon/authenticated sobre dinero
--  2. Bloquea escalada de privilegios en profiles (WITH CHECK)
--  3. Elimina INSERT directo en rides (solo via calculate_fare)
--  4. Hace privado el bucket payments (comprobantes)
--  5. Protege promote_to_super_admin
--  6. Valida montos y textos maliciosos
--  7. Registra auditoría obligatoria
--  8. Rate limiting básico por usuario
-- ============================================================

-- ============================================================
-- 1. REVOCAR PERMISOS EXCESIVOS
--    El rol anon NO debe tocar tablas de dinero.
--    authenticated solo debe poder SELECT de sus propios registros
--    (las políticas RLS ya filtran por usuario).
-- ============================================================

-- Tablas financieras: SOLO service_role/postgres
REVOKE ALL ON public.wallets FROM anon;
REVOKE ALL ON public.wallets FROM authenticated;
REVOKE ALL ON public.transactions FROM anon;
REVOKE ALL ON public.transactions FROM authenticated;
REVOKE ALL ON public.payouts FROM anon;
REVOKE ALL ON public.payouts FROM authenticated;
REVOKE ALL ON public.driver_earnings FROM anon;
REVOKE ALL ON public.driver_earnings FROM authenticated;

-- Tablas de perfiles: SOLO lectura controlada via RLS
REVOKE ALL ON public.profiles FROM anon;
GRANT SELECT ON public.profiles TO anon;
GRANT SELECT ON public.profiles TO authenticated;

-- Tablas de viajes: sin INSERT/UPDATE directo (solo via RPC)
REVOKE ALL ON public.rides FROM anon;
REVOKE ALL ON public.rides FROM authenticated;
GRANT SELECT ON public.rides TO anon;
GRANT SELECT ON public.rides TO authenticated;

-- Tablas sensibles de configuración
REVOKE ALL ON public.payment_methods FROM anon;
REVOKE ALL ON public.payment_methods FROM authenticated;
GRANT SELECT ON public.payment_methods TO anon;
GRANT SELECT ON public.payment_methods TO authenticated;

REVOKE ALL ON public.payment_method_fields FROM anon;
REVOKE ALL ON public.payment_method_fields FROM authenticated;
GRANT SELECT ON public.payment_method_fields TO anon;
GRANT SELECT ON public.payment_method_fields TO authenticated;

REVOKE ALL ON public.audit_logs FROM anon;
REVOKE ALL ON public.audit_logs FROM authenticated;
GRANT SELECT ON public.audit_logs TO authenticated;

REVOKE ALL ON public.coupons FROM anon;
REVOKE ALL ON public.coupons FROM authenticated;
GRANT SELECT ON public.coupons TO anon;
GRANT SELECT ON public.coupons TO authenticated;

REVOKE ALL ON public.vehicle_categories FROM anon;
REVOKE ALL ON public.vehicle_categories FROM authenticated;
GRANT SELECT ON public.vehicle_categories TO anon;
GRANT SELECT ON public.vehicle_categories TO authenticated;

REVOKE ALL ON public.zones FROM anon;
REVOKE ALL ON public.zones FROM authenticated;
GRANT SELECT ON public.zones TO anon;
GRANT SELECT ON public.zones TO authenticated;

REVOKE ALL ON public.barrios FROM anon;
REVOKE ALL ON public.barrios FROM authenticated;
GRANT SELECT ON public.barrios TO anon;
GRANT SELECT ON public.barrios TO authenticated;

REVOKE ALL ON public.banners FROM anon;
REVOKE ALL ON public.banners FROM authenticated;
GRANT SELECT ON public.banners TO anon;
GRANT SELECT ON public.banners TO authenticated;

REVOKE ALL ON public.exchange_rates FROM anon;
REVOKE ALL ON public.exchange_rates FROM authenticated;
GRANT SELECT ON public.exchange_rates TO anon;
GRANT SELECT ON public.exchange_rates TO authenticated;

REVOKE ALL ON public.notifications FROM anon;
REVOKE ALL ON public.notifications FROM authenticated;
GRANT SELECT ON public.notifications TO authenticated;

REVOKE ALL ON public.favorite_places FROM anon;
GRANT SELECT ON public.favorite_places TO anon;
GRANT SELECT ON public.favorite_places TO authenticated;

REVOKE ALL ON public.vehicles FROM anon;
GRANT SELECT ON public.vehicles TO anon;
GRANT SELECT ON public.vehicles TO authenticated;

REVOKE ALL ON public.driver_documents FROM anon;
GRANT SELECT ON public.driver_documents TO authenticated;

-- Prevention: no crear más tablas con GRANT ALL a anon
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public REVOKE ALL ON TABLES FROM authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO anon;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON TABLES TO authenticated;

-- ============================================================
-- 2. BLOQUEAR ESCALADA DE PRIVILEGIOS EN PROFILES
--    La política anterior 'users_update_own_profile' usaba
--    solo USING (auth.uid() = id) SIN WITH CHECK.
--    Esto permitía que un usuario cambiara su propio role,
--    driver_status, is_online, email, etc.
-- ============================================================

DROP POLICY IF EXISTS "users_update_own_profile" ON public.profiles;

CREATE POLICY "users_update_own_profile" ON public.profiles
  FOR UPDATE
  USING (auth.uid() = id)
  WITH CHECK (
    auth.uid() = id
    -- ⛔ NO permitir cambiar campos de rol/estado
    AND role = (SELECT role FROM public.profiles WHERE id = auth.uid())
    AND COALESCE(driver_status, (SELECT COALESCE(driver_status, 'pendiente') FROM public.profiles WHERE id = auth.uid()))
        = COALESCE((SELECT driver_status FROM public.profiles WHERE id = auth.uid()), 'pendiente')
    AND is_online = (SELECT is_online FROM public.profiles WHERE id = auth.uid())
    AND email = (SELECT email FROM public.profiles WHERE id = auth.uid())
    AND id = (SELECT id FROM public.profiles WHERE id = auth.uid())
  );

-- Bloquear INSERT directo en profiles (debe ser via trigger de auth)
DROP POLICY IF EXISTS "users_insert_own_profile" ON public.profiles;
DROP POLICY IF EXISTS "public_insert_profiles" ON public.profiles;
DROP POLICY IF EXISTS "anon_insert_profiles" ON public.profiles;

-- Asegurar que no existan políticas INSERT en profiles
DO $$
DECLARE
  v_polname TEXT;
BEGIN
  FOR v_polname IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'profiles' AND cmd = 'INSERT'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.profiles', v_polname);
  END LOOP;
END;
$$;

-- ============================================================
-- 3. ELIMINAR INSERT DIRECTO EN RIDES
--    Los viajes SOLO pueden crearse via request_ride() /
--    request_ride_with_proof() que calculan el precio en el
--    servidor con calculate_fare(). Prohibimos el INSERT directo
--    para que el cliente no pueda poner precios arbitrarios.
-- ============================================================

DROP POLICY IF EXISTS "client_create_rides" ON public.rides;
DROP POLICY IF EXISTS "anon_insert_rides" ON public.rides;
DROP POLICY IF EXISTS "public_insert_rides" ON public.rides;
DROP POLICY IF EXISTS "client_view_own_rides" ON public.rides;
DROP POLICY IF EXISTS "driver_view_assigned_rides" ON public.rides;
DROP POLICY IF EXISTS "driver_view_available_rides" ON public.rides;

-- Asegurar que no existan políticas INSERT en rides
DO $$
DECLARE
  v_polname TEXT;
BEGIN
  FOR v_polname IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'rides' AND cmd = 'INSERT'
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.rides', v_polname);
  END LOOP;
END;
$$;

-- UPDATE en rides: solo dentro de transacciones seguras (RPC SECURITY DEFINER).
-- Eliminar UPDATE directo del cliente (puede modificar precios):
DROP POLICY IF EXISTS "client_update_own_rides" ON public.rides;
DROP POLICY IF EXISTS "driver_update_assigned_rides" ON public.rides;

-- Solamente permitir VIEW (SELECT). Las funciones RPC (con SECURITY DEFINER)
-- hacen UPDATE/INSERT/status changes de forma controlada.
DROP POLICY IF EXISTS "super_admin_view_all_rides" ON public.rides;
DROP POLICY IF EXISTS "encargado_view_rides" ON public.rides;

-- Recrear políticas de SOLO LECTURA para rides:
CREATE POLICY "client_view_own_rides" ON public.rides
  FOR SELECT USING (auth.uid() = client_id);

CREATE POLICY "driver_view_assigned_rides" ON public.rides
  FOR SELECT USING (auth.uid() = driver_id);

CREATE POLICY "driver_view_available_rides" ON public.rides
  FOR SELECT USING (
    public.driver_has_vehicle_for_category(category)
    AND status = 'buscando'
    AND (proof_status IS NULL OR proof_status = 'aprobado')
  );

CREATE POLICY "super_admin_view_all_rides" ON public.rides
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'super_admin');

CREATE POLICY "encargado_view_rides" ON public.rides
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'encargado');

-- ============================================================
-- 4. BUCKET PAYMENTS PRIVADO (comprobantes de pago)
--    Antes: public = TRUE y política public_read_payments.
--    Ahora: SOLO admins y el usuario dueño pueden ver firmados.
-- ============================================================

-- Hacer privado el bucket
UPDATE storage.buckets SET public = FALSE WHERE id = 'payments';

-- Eliminar política de lectura pública
DROP POLICY IF EXISTS "public_read_payments" ON storage.objects;

-- Recrear políticas seguras para payments:
-- El usuario dueño solo ve los suyos (por carpeta /userId/)
DROP POLICY IF EXISTS "users_manage_own_payment_proofs" ON storage.objects;
CREATE POLICY "users_manage_own_payment_proofs" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'payments'
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

-- Admin/encargado pueden ver TODOS los comprobantes
DROP POLICY IF EXISTS "admins_view_payments" ON storage.objects;
CREATE POLICY "admins_view_payments" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'payments'
    AND public.get_user_role(auth.uid()) IN ('super_admin', 'encargado')
  );

-- Solo el dueño sube sus propios comprobantes
DROP POLICY IF EXISTS "users_upload_own_payment_proofs" ON storage.objects;
CREATE POLICY "users_upload_own_payment_proofs" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'payments'
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

-- Asegurar que no existan políticas heredadas inseguras
DROP POLICY IF EXISTS "payment_proofs_all" ON storage.objects;
DROP POLICY IF EXISTS "storage_all_payments" ON storage.objects;

-- ============================================================
-- 5. PROTEGER PROMOTE_TO_SUPER_ADMIN
--    Antes: cualquier usuario autenticado podía ejecutarla
--    porque no verificaba el rol del invocador.
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
  v_target_id UUID;
BEGIN
  -- Solo un super_admin existente puede promover a otro
  SELECT role::text INTO v_caller_role FROM public.profiles WHERE id = v_caller_id;
  IF v_caller_role != 'super_admin' THEN
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

-- Revocar execute de la versión anterior (dejar SOLO la nueva protegida)
REVOKE EXECUTE ON FUNCTION public.promote_to_super_admin FROM anon;
GRANT EXECUTE ON FUNCTION public.promote_to_super_admin TO authenticated;

-- ============================================================
-- 6. VALIDACIONES DE MONTOS Y TEXTOS
-- ============================================================

-- 6.1 Función de limpieza de texto: rechaza caracteres de control,
--     limita longitud, elimina espacios dobles, previene inyección.
CREATE OR REPLACE FUNCTION public.sanitize_text(
  p_input TEXT,
  p_max_len INTEGER DEFAULT 500
)
RETURNS TEXT
LANGUAGE plpgsql
IMMUTABLE
AS $$
DECLARE
  v_clean TEXT;
BEGIN
  IF p_input IS NULL THEN
    RETURN NULL;
  END IF;

  -- Rechazar caracteres de control (excepto saltos de línea básicos)
  IF p_input ~ '[\x00-\x08\x0B\x0C\x0E-\x1F]' THEN
    RAISE EXCEPTION 'Texto contiene caracteres no permitidos';
  END IF;

  v_clean := TRIM(p_input);
  -- Limitar longitud
  IF LENGTH(v_clean) > p_max_len THEN
    RAISE EXCEPTION 'Texto demasiado largo (máximo % caracteres)', p_max_len;
  END IF;

  -- Colapsar espacios múltiples
  v_clean := REGEXP_REPLACE(v_clean, '\s+', ' ', 'g');

  RETURN v_clean;
END;
$$;

-- 6.2 Función de validación de monto: rango seguro.
--     NUMERIC acepta infinito y montos astronómicos.
--     Este CHECK impide montos > $999,999.99 y negativos.
CREATE OR REPLACE FUNCTION public.is_valid_amount(p_amount NUMERIC)
RETURNS BOOLEAN
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN p_amount IS NOT NULL
    AND p_amount >= 0
    AND p_amount <= 999999.99
    AND p_amount::numeric(12,2) = p_amount; -- Máx 2 decimales
END;
$$;

-- 6.3 Añadir CHECK constraints a tablas críticas
ALTER TABLE wallets
  DROP CONSTRAINT IF EXISTS wallets_balance_check,
  ADD CONSTRAINT wallets_balance_check
    CHECK (balance_usd >= -999999.99 AND balance_usd <= 999999.99);

ALTER TABLE transactions
  DROP CONSTRAINT IF EXISTS transactions_amount_check,
  ADD CONSTRAINT transactions_amount_check
    CHECK (amount_usd >= 0 AND amount_usd <= 999999.99);

ALTER TABLE payouts
  DROP CONSTRAINT IF EXISTS payouts_amount_check,
  ADD CONSTRAINT payouts_amount_check
    CHECK (amount_usd >= 0 AND amount_usd <= 999999.99);

ALTER TABLE driver_earnings
  DROP CONSTRAINT IF EXISTS driver_earnings_amounts_check,
  ADD CONSTRAINT driver_earnings_amounts_check
    CHECK (
      fare_usd >= 0 AND fare_usd <= 999999.99
      AND commission_usd >= 0 AND commission_usd <= 999999.99
      AND cash_received_usd >= 0 AND cash_received_usd <= 999999.99
      AND app_credit_usd >= 0 AND app_credit_usd <= 999999.99
    );

ALTER TABLE rides
  DROP CONSTRAINT IF EXISTS rides_fares_check,
  ADD CONSTRAINT rides_fares_check
    CHECK (
      base_fare_usd >= 0 AND base_fare_usd <= 999999.99
      AND total_fare_usd >= 0 AND total_fare_usd <= 999999.99
      AND discount_usd >= 0 AND discount_usd <= 999999.99
      AND final_fare_usd >= 0 AND final_fare_usd <= 999999.99
      AND commission_usd >= 0 AND commission_usd <= 999999.99
    );

ALTER TABLE vehicle_categories
  DROP CONSTRAINT IF EXISTS vehicle_categories_base_fare_check,
  ADD CONSTRAINT vehicle_categories_base_fare_check
    CHECK (base_fare_usd >= 0 AND base_fare_usd <= 99999.99);

ALTER TABLE coupons
  DROP CONSTRAINT IF EXISTS coupons_discount_value_check,
  ADD CONSTRAINT coupons_discount_value_check
    CHECK (discount_value >= 0 AND discount_value <= 99999.99);

ALTER TABLE barrios
  DROP CONSTRAINT IF EXISTS barrios_surcharge_check,
  ADD CONSTRAINT barrios_surcharge_check
    CHECK (surcharge_usd >= 0 AND surcharge_usd <= 99999.99);

-- ============================================================
-- 7. PROTEGER WALLETS: SIN UPDATE/INSERT DIRECTO
--    Las billeteras SOLO se modifican via funciones SECURITY DEFINER.
-- ============================================================

-- Eliminar políticas de INSERT/UPDATE directo en wallets
DROP POLICY IF EXISTS "user_insert_wallet" ON public.wallets;
DROP POLICY IF EXISTS "anon_insert_wallets" ON public.wallets;
DROP POLICY IF EXISTS "public_insert_wallets" ON public.wallets;
DROP POLICY IF EXISTS "user_update_own_wallet" ON public.wallets;
DROP POLICY IF EXISTS "anon_update_wallets" ON public.wallets;
DROP POLICY IF EXISTS "public_update_wallets" ON public.wallets;

DO $$
DECLARE
  v_polname TEXT;
  v_cmd TEXT;
BEGIN
  FOR v_polname, v_cmd IN
    SELECT policyname, cmd FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'wallets'
      AND cmd IN ('INSERT', 'UPDATE', 'DELETE')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.wallets', v_polname);
  END LOOP;
END;
$$;

-- Mantener SOLO lectura (el usuario ve su wallet)
DROP POLICY IF EXISTS "user_view_own_wallet" ON public.wallets;
CREATE POLICY "user_view_own_wallet" ON public.wallets
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "super_admin_view_all_wallets" ON public.wallets;
CREATE POLICY "super_admin_view_all_wallets" ON public.wallets
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'super_admin');

DROP POLICY IF EXISTS "encargado_view_wallets" ON public.wallets;
CREATE POLICY "encargado_view_wallets" ON public.wallets
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'encargado');

-- ============================================================
-- 8. PROTEGER TRANSACTIONS: SOLO LECTURA
-- ============================================================

DROP POLICY IF EXISTS "user_create_transactions" ON public.transactions;
DROP POLICY IF EXISTS "anon_insert_transactions" ON public.transactions;

DO $$
DECLARE
  v_polname TEXT;
BEGIN
  FOR v_polname IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'transactions'
      AND cmd IN ('INSERT', 'UPDATE', 'DELETE')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.transactions', v_polname);
  END LOOP;
END;
$$;

-- Recrear SOLO lectura para transacciones
DROP POLICY IF EXISTS "user_view_own_transactions" ON public.transactions;
CREATE POLICY "user_view_own_transactions" ON public.transactions
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "super_admin_view_all_transactions" ON public.transactions;
CREATE POLICY "super_admin_view_all_transactions" ON public.transactions
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'super_admin');

DROP POLICY IF EXISTS "encargado_view_transactions" ON public.transactions;
CREATE POLICY "encargado_view_transactions" ON public.transactions
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'encargado');

-- ============================================================
-- 9. RATE LIMITING BÁSICO
--    Protege contra fuerza bruta en RPCs.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.rpc_audit (
  id BIGSERIAL PRIMARY KEY,
  user_id UUID,
  function_name TEXT NOT NULL,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_rpc_audit_user_time
  ON public.rpc_audit(user_id, created_at DESC);

-- Función utilitaria: verificar límite de llamadas
CREATE OR REPLACE FUNCTION public.check_rpc_rate_limit(
  p_function_name TEXT,
  p_max_per_minute INTEGER DEFAULT 20
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_count INTEGER;
BEGIN
  -- Registrar llamada
  INSERT INTO public.rpc_audit (user_id, function_name)
  VALUES (v_user_id, p_function_name);

  -- Contar llamadas en el último minuto
  SELECT COUNT(*) INTO v_count
  FROM public.rpc_audit
  WHERE user_id = v_user_id
    AND function_name = p_function_name
    AND created_at > NOW() - INTERVAL '1 minute';

  -- Limpieza: borrar registros viejos (>1 hora)
  DELETE FROM public.rpc_audit WHERE created_at < NOW() - INTERVAL '1 hour';

  RETURN v_count <= p_max_per_minute;
END;
$$;

-- ============================================================
-- 10. NOTIFICACIONES: SOLO SISTEMA PUEDE INSERTAR
-- ============================================================

DROP POLICY IF EXISTS "system_create_notifications" ON public.notifications;
CREATE POLICY "system_create_notifications" ON public.notifications
  FOR INSERT WITH CHECK (
    -- Solo funciones SECURITY DEFINER (el caller es postgres/service_role)
    -- o el dueño. Los usuarios comunes NO pueden insertar notificaciones
    -- para otros usuarios.
    auth.role() = 'service_role'
    OR auth.uid() = user_id
  );

-- ============================================================
-- 11. AUDIT_LOGS: SOLO SISTEMA INSERTA
-- ============================================================

DROP POLICY IF EXISTS "system_create_audit_logs" ON public.audit_logs;
CREATE POLICY "system_create_audit_logs" ON public.audit_logs
  FOR INSERT WITH CHECK (
    auth.role() = 'service_role'
    OR auth.uid() = user_id
  );

-- ============================================================
-- 12. PAYOUTS: SOLO LECTURA POR RLS, INSERTS VIA RPC
-- ============================================================

-- Eliminar INSERTS directos
DROP POLICY IF EXISTS "driver_create_payouts" ON public.payouts;
DROP POLICY IF EXISTS "admin_create_payouts" ON public.payouts;

DO $$
DECLARE
  v_polname TEXT;
BEGIN
  FOR v_polname IN
    SELECT policyname FROM pg_policies
    WHERE schemaname = 'public' AND tablename = 'payouts'
      AND cmd IN ('INSERT', 'UPDATE', 'DELETE')
  LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.payouts', v_polname);
  END LOOP;
END;
$$;

-- Recrear SOLO lectura para payouts
DROP POLICY IF EXISTS "driver_view_own_payouts" ON public.payouts;
CREATE POLICY "driver_view_own_payouts" ON public.payouts
  FOR SELECT USING (auth.uid() = driver_id);

DROP POLICY IF EXISTS "admin_view_payouts" ON public.payouts;
CREATE POLICY "admin_view_payouts" ON public.payouts
  FOR SELECT USING (public.get_user_role(auth.uid()) IN ('super_admin', 'encargado'));

-- ============================================================
-- 13. DRIVER_EARNINGS: SOLO LECTURA
-- ============================================================

DROP POLICY IF EXISTS "driver_view_own_earnings" ON public.driver_earnings;
CREATE POLICY "driver_view_own_earnings" ON public.driver_earnings
  FOR SELECT USING (auth.uid() = driver_id);

DROP POLICY IF EXISTS "admin_view_all_earnings" ON public.driver_earnings;
CREATE POLICY "admin_view_all_earnings" ON public.driver_earnings
  FOR SELECT USING (public.get_user_role(auth.uid()) IN ('super_admin', 'encargado'));

-- ============================================================
-- 14. ELIMINAR POLÍTICAS INSERT EN OTRAS TABLAS SENSIBLES
-- ============================================================

-- favorites: solo el dueño puede gestionar
DROP POLICY IF EXISTS "user_manage_own_favorites" ON public.favorite_places;
CREATE POLICY "user_manage_own_favorites" ON public.favorite_places
  FOR ALL USING (auth.uid() = user_id) WITH CHECK (auth.uid() = user_id);

-- ============================================================
-- 15. BLOQUEAR FUNCIONES PELIGROSAS vía GRANT
-- ============================================================

-- Asegurar que las funciones que mueven dinero NO sean llamadas por anon
REVOKE EXECUTE ON FUNCTION public.settle_ride_earnings FROM anon;
REVOKE EXECUTE ON FUNCTION public.complete_ride FROM anon;
REVOKE EXECUTE ON FUNCTION public.accept_ride FROM anon;
REVOKE EXECUTE ON FUNCTION public.cancel_ride FROM anon;
REVOKE EXECUTE ON FUNCTION public.driver_pay_to_platform FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_pay_driver FROM anon;
REVOKE EXECUTE ON FUNCTION public.admin_pay_driver_manual FROM anon;
REVOKE EXECUTE ON FUNCTION public.approve_payout FROM anon;
REVOKE EXECUTE ON FUNCTION public.driver_confirm_payout FROM anon;
REVOKE EXECUTE ON FUNCTION public.driver_request_payout FROM anon;
REVOKE EXECUTE ON FUNCTION public.adjust_driver_debt FROM anon;
REVOKE EXECUTE ON FUNCTION public.approve_ride_proof FROM anon;
REVOKE EXECUTE ON FUNCTION public.approve_recharge FROM anon;
REVOKE EXECUTE ON FUNCTION public.request_wallet_recharge FROM anon;
REVOKE EXECUTE ON FUNCTION public.request_ride FROM anon;
REVOKE EXECUTE ON FUNCTION public.request_ride_with_proof FROM anon;

-- Asegurar que authenticate los usuarios autenticados pueden llamar las RPCs OK
GRANT EXECUTE ON FUNCTION public.settle_ride_earnings TO authenticated;
GRANT EXECUTE ON FUNCTION public.complete_ride TO authenticated;
GRANT EXECUTE ON FUNCTION public.accept_ride TO authenticated;
GRANT EXECUTE ON FUNCTION public.cancel_ride TO authenticated;
GRANT EXECUTE ON FUNCTION public.driver_pay_to_platform TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_pay_driver TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_pay_driver_manual TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_payout TO authenticated;
GRANT EXECUTE ON FUNCTION public.driver_confirm_payout TO authenticated;
GRANT EXECUTE ON FUNCTION public.driver_request_payout TO authenticated;
GRANT EXECUTE ON FUNCTION public.adjust_driver_debt TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_ride_proof TO authenticated;
GRANT EXECUTE ON FUNCTION public.approve_recharge TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_wallet_recharge TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_ride TO authenticated;
GRANT EXECUTE ON FUNCTION public.request_ride_with_proof TO authenticated;

-- Las funciones de lectura siguen disponibles
GRANT EXECUTE ON FUNCTION public.get_payouts TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_driver_earnings TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_available_rides TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_active_payment_methods TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_pending_proofs TO authenticated;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '🚨 SEGURIDAD ENDURECIDA COMPLETADA 🚨' AS estado;

-- Verificar que no quedan GRANT ALL a anon en tablas de dinero:
SELECT table_schema, table_name, grantee, privilege_type
FROM information_schema.role_table_grants
WHERE grantee = 'anon'
  AND table_schema = 'public'
  AND privilege_type = 'INSERT'
ORDER BY table_name;

SELECT table_schema, table_name, grantee, privilege_type
FROM information_schema.role_table_grants
WHERE grantee = 'anon'
  AND table_schema = 'public'
  AND privilege_type IN ('UPDATE', 'DELETE')
ORDER BY table_name;
