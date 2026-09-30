-- ============================================================
-- BUNRIDER - Migración 079: ESTADO DE CUENTAS
-- (pausar / bloquear / reactivar / eliminar)
-- ------------------------------------------------------------
-- OBJETIVO
--   Que el super_admin pueda PAUSAR, BLOQUEAR, REACTIVAR y
--   ELIMINAR cuentas sin romper nada y sin crear coste nuevo.
--
-- DECISIONES
--   - Solo el super_admin (en cualquier ciudad).
--   - "pausado"  = no opera, pero conserva su dinero e historial.
--                  Puede llevar fecha: se reactiva sola al vencer.
--   - "bloqueado"= no opera nada; entra y ve el aviso.
--   - "eliminado"= se anonimiza la cuenta y se conserva el
--                  historial financiero (requisito contable).
--                  El borrado REAL solo si la cuenta no tiene
--                  historial (se valida en la propia función).
--
-- POR QUÉ ES BARATO Y SEGURO
--   En vez de tocar 40 políticas RLS y 30 RPC, se blindan
--   3 puntos centrales que TODAS usan:
--     1) get_user_role()  -> NULL si la cuenta no está activa
--        (corta todas las políticas RLS por rol y los guards
--         de las RPC de administración)
--     2) guard_rate_limit() -> corta de una vez las 29 RPC
--        sensibles (viajes, dinero, aprobaciones). El cron
--        (auth.uid() NULL) sigue igual.
--     3) caller_zone_id() -> NULL si no está activa
--   Además se cierra el auto-desbloqueo: get_own_profile_guard()
--   incluye los campos de estado, así el usuario NO puede
--   ponerse 'activo' con un UPDATE directo.
--
-- COSTO: 1 enum + 5 columnas + 2 índices parciales.
--        0 tablas nuevas, 0 cron, 0 edge functions.
--        Todas las cuentas existentes quedan 'activo'.
-- ============================================================

-- ============================================================
-- 1. ENUM + COLUMNAS + ÍNDICES
-- ============================================================
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
                 WHERE t.typname = 'account_status' AND n.nspname = 'public') THEN
    CREATE TYPE public.account_status AS ENUM ('activo', 'pausado', 'bloqueado', 'eliminado');
  END IF;
END $$;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS status            public.account_status NOT NULL DEFAULT 'activo',
  ADD COLUMN IF NOT EXISTS status_reason     TEXT,
  ADD COLUMN IF NOT EXISTS status_until      TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS status_changed_by UUID,
  ADD COLUMN IF NOT EXISTS status_changed_at TIMESTAMPTZ;

COMMENT ON COLUMN public.profiles.status IS
  'Estado de la cuenta: activo | pausado (temporal) | bloqueado | eliminado (anonimizado)';
COMMENT ON COLUMN public.profiles.status_until IS
  'Fin de la pausa/bloqueo temporal. Al vencer, la cuenta vuelve a operar sola (sin cron).';

-- Índices parciales: los activos (99% de las filas) no se indexan
CREATE INDEX IF NOT EXISTS idx_profiles_status_no_activo
  ON public.profiles(status) WHERE status <> 'activo';
CREATE INDEX IF NOT EXISTS idx_profiles_status_created
  ON public.profiles(status, created_at DESC);

-- ============================================================
-- 2. IS_ACCOUNT_ACTIVE: fuente única de verdad
--    (STABLE, sin escrituras: una pausa vencida cuenta como activa)
-- ============================================================
CREATE OR REPLACE FUNCTION public.is_account_active(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = p_user_id
      AND (
        p.status = 'activo'
        OR (p.status = 'pausado'
            AND p.status_until IS NOT NULL
            AND p.status_until <= NOW())
      )
  );
$$;

GRANT EXECUTE ON FUNCTION public.is_account_active(uuid) TO anon, authenticated, service_role;

-- ============================================================
-- 3. PALANCA 1: GET_USER_ROLE devuelve NULL si la cuenta no está activa
--    Impacto automático: TODAS las políticas RLS de rol y los
--    guards de las RPC de administración (set_user_role,
--    approve_*, admin_pay_*, get_audit_logs, upsert_zone...).
--    Para una cuenta ACTIVA el resultado es idéntico al de antes.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_user_role(user_id uuid)
RETURNS user_role
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN public.is_account_active(user_id) THEN role
    ELSE NULL
  END
  FROM public.profiles
  WHERE id = user_id;
$$;

-- ============================================================
-- 4. CALLER_ZONE_ID: NULL si la cuenta no está activa
--    (un encargado bloqueado no ve ni su propia ciudad)
-- ============================================================
CREATE OR REPLACE FUNCTION public.caller_zone_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN role = 'encargado' AND public.is_account_active(auth.uid()) THEN zone_id
    ELSE NULL
  END
  FROM profiles
  WHERE id = auth.uid();
$$;

-- ============================================================
-- 5. PALANCA 2: GUARD_RATE_LIMIT corta las 29 RPC sensibles
--    Se conserva la firma y el comportamiento; solo se añade el
--    candado de cuenta. Si auth.uid() es NULL (cron, service_role,
--    SQL editor) NO se comprueba nada: el cron sigue igual.
-- ============================================================
CREATE OR REPLACE FUNCTION public.guard_rate_limit(p_function_name text, p_max_per_minute integer DEFAULT 20)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_count INTEGER;
  v_status public.account_status;
BEGIN
  -- 🔒 Cuenta no activa: no puede operar (viajes, dinero, aprobaciones...)
  IF v_user_id IS NOT NULL THEN
    SELECT status INTO v_status FROM public.profiles WHERE id = v_user_id;

    IF v_status IS NOT NULL AND NOT public.is_account_active(v_user_id) THEN
      IF v_status = 'bloqueado' THEN
        RAISE EXCEPTION 'Tu cuenta está bloqueada. Contacta a soporte.';
      ELSIF v_status = 'eliminado' THEN
        RAISE EXCEPTION 'Esta cuenta fue eliminada.';
      ELSE
        RAISE EXCEPTION 'Tu cuenta está pausada. Contacta a soporte.';
      END IF;
    END IF;
  END IF;

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

-- ============================================================
-- 6. ANTI AUTO-DESBLOQUEO
--    La política users_update_own_profile valida lo que el usuario
--    NO puede cambiarse a sí mismo (rol, email, driver_status,
--    is_online, avatar) usando get_own_profile_guard().
--    Hay que añadir ahí los campos de estado; si no, un usuario
--    bloqueado podría ponerse status='activo' con un UPDATE.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_own_profile_guard()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'role', role::text,
    'email', email,
    'driver_status', driver_status::text,
    'is_online', is_online,
    'avatar_url', COALESCE(avatar_url, ''),
    'status', status::text,
    'status_reason', COALESCE(status_reason, ''),
    'status_until', COALESCE(status_until::text, '')
  )
  FROM public.profiles
  WHERE id = auth.uid();
$$;

DROP POLICY IF EXISTS "users_update_own_profile" ON public.profiles;
CREATE POLICY "users_update_own_profile" ON public.profiles
  FOR UPDATE
  USING (auth.uid() = id)
  WITH CHECK (
    auth.uid() = id
    AND role = ((public.get_own_profile_guard() ->> 'role'::text))::public.user_role
    AND email = (public.get_own_profile_guard() ->> 'email'::text)
    AND COALESCE(driver_status, 'pendiente'::public.driver_status)
        = COALESCE(((public.get_own_profile_guard() ->> 'driver_status'::text))::public.driver_status, 'pendiente'::public.driver_status)
    AND is_online = ((public.get_own_profile_guard() ->> 'is_online'::text))::boolean
    AND COALESCE(avatar_url, ''::text) = (public.get_own_profile_guard() ->> 'avatar_url'::text)
    AND status = ((public.get_own_profile_guard() ->> 'status'::text))::public.account_status
    AND COALESCE(status_reason, ''::text) = COALESCE(public.get_own_profile_guard() ->> 'status_reason'::text, ''::text)
    AND COALESCE(status_until::text, ''::text) = COALESCE(public.get_own_profile_guard() ->> 'status_until'::text, ''::text)
  );

-- ============================================================
-- 7. GUARDIAS EN LAS RPC QUE NO PASAN POR GUARD_RATE_LIMIT
-- ============================================================

-- 7.1 TOGGLE_DRIVER_ONLINE: un conductor pausado/bloqueado no se
--     puede poner en línea (por eso no recibe ofertas de viaje)
CREATE OR REPLACE FUNCTION public.toggle_driver_online(p_online boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_profile RECORD;
  v_wallet RECORD;
BEGIN
  SELECT * INTO v_profile FROM profiles WHERE id = v_driver_id;

  IF v_profile.role != 'conductor' THEN
    RAISE EXCEPTION 'No es conductor';
  END IF;

  -- 🔒 Cuenta pausada / bloqueada / eliminada: no puede trabajar
  IF NOT public.is_account_active(v_driver_id) THEN
    RAISE EXCEPTION 'Tu cuenta no está activa. Contacta a soporte.';
  END IF;

  IF v_profile.driver_status != 'aprobado' THEN
    RAISE EXCEPTION 'Conductor no aprobado';
  END IF;

  -- Verificar límite de deuda (morosidad)
  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_driver_id;
  IF v_wallet.balance_usd < -v_wallet.debt_limit_usd THEN
    RETURN jsonb_build_object(
      'success', FALSE,
      'error', 'DEUDA_EXCEDIDA',
      'message', 'Tienes una deuda pendiente que supera el límite permitido. Recarga tu billetera o contacta al administrador.',
      'deuda_actual', v_wallet.balance_usd,
      'limite_deuda', v_wallet.debt_limit_usd
    );
  END IF;

  UPDATE profiles SET is_online = p_online WHERE id = v_driver_id;

  RETURN jsonb_build_object('success', TRUE, 'is_online', p_online);
END;
$$;

-- 7.2 UPDATE_DRIVER_LOCATION: si la cuenta no está activa no se
--     actualiza el rastreo (devuelve FALSE, sin romper la app)
CREATE OR REPLACE FUNCTION public.update_driver_location(p_ride_id uuid, p_lat numeric, p_lng numeric)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_ride RECORD;
  v_distance NUMERIC;
BEGIN
  IF NOT public.is_account_active(v_driver_id) THEN
    RETURN FALSE;
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;

  IF v_ride.id IS NULL OR v_ride.driver_id != v_driver_id THEN
    RETURN FALSE;
  END IF;

  -- Throttling: solo actualizar si se movió >8m o pasaron >20s
  IF v_ride.driver_location_lat IS NOT NULL THEN
    v_distance := ST_Distance(
      ST_SetSRID(ST_MakePoint(v_ride.driver_location_lng, v_ride.driver_location_lat), 4326)::geography,
      ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography
    );

    IF v_distance < 8 AND (NOW() - v_ride.driver_last_update) < INTERVAL '20 seconds' THEN
      RETURN FALSE;
    END IF;
  END IF;

  UPDATE rides
  SET driver_location_lat = p_lat,
      driver_location_lng = p_lng,
      driver_last_update = NOW()
  WHERE id = p_ride_id;

  RETURN TRUE;
END;
$$;

-- 7.3 COMPLETE_ONBOARDING: una cuenta no activa no puede
--     re-onboardearse (ni volver a pedir ser conductor)
CREATE OR REPLACE FUNCTION public.complete_onboarding(p_role user_role, p_zone_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_profile RECORD;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  -- 🔒 Cuenta no activa
  IF NOT public.is_account_active(v_user_id) THEN
    RAISE EXCEPTION 'Tu cuenta no está activa. Contacta a soporte.';
  END IF;

  -- Roles permitidos en onboarding: nunca encargado/super_admin
  IF p_role NOT IN ('cliente', 'conductor') THEN
    RAISE EXCEPTION 'Rol no permitido';
  END IF;

  SELECT * INTO v_profile FROM public.profiles WHERE id = v_user_id;
  IF v_profile.id IS NULL THEN
    RAISE EXCEPTION 'Perfil no encontrado';
  END IF;

  -- Si ya es conductor con estado definido (aprobado/rechazado/suspendido)
  -- no permitir volver a cambiarlo desde onboarding
  IF v_profile.role = 'conductor'
     AND v_profile.driver_status IS NOT NULL
     AND v_profile.driver_status != 'pendiente' THEN
    RAISE EXCEPTION 'Tu cuenta ya tiene un estado como conductor. Contacta al administrador.';
  END IF;

  -- Actualizar SOLO el propio perfil (SECURITY DEFINER bypasa RLS)
  UPDATE public.profiles
  SET role = p_role,
      zone_id = p_zone_id,
      driver_status = CASE WHEN p_role = 'conductor' THEN 'pendiente' ELSE driver_status END,
      onboarding_completed = TRUE,
      updated_at = NOW()
  WHERE id = v_user_id;

  RETURN jsonb_build_object('success', TRUE, 'role', p_role::text);
END;
$$;

-- ============================================================
-- 8. ADMIN_SET_ACCOUNT_STATUS: pausar / bloquear / reactivar
--    Solo super_admin. Auditoría + aviso al usuario.
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_set_account_status(
  p_user_id UUID,
  p_status TEXT,
  p_reason TEXT DEFAULT NULL,
  p_until TIMESTAMPTZ DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin UUID := auth.uid();
  v_target RECORD;
  v_new public.account_status;
  v_accion TEXT;
BEGIN
  IF public.get_user_role(v_admin) != 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('admin_set_account_status', 30);

  IF p_status IS NULL OR p_status NOT IN ('activo', 'pausado', 'bloqueado') THEN
    RAISE EXCEPTION 'Estado no válido';
  END IF;
  v_new := p_status::public.account_status;

  IF p_user_id = v_admin THEN
    RAISE EXCEPTION 'No puedes cambiar el estado de tu propia cuenta';
  END IF;

  SELECT id, full_name, role::text AS role, status::text AS status
  INTO v_target
  FROM public.profiles
  WHERE id = p_user_id;

  IF v_target.id IS NULL THEN
    RAISE EXCEPTION 'Usuario no encontrado';
  END IF;

  -- Nunca dejar la plataforma sin administradores
  IF v_target.role = 'super_admin' AND v_new <> 'activo' THEN
    RAISE EXCEPTION 'No puedes pausar ni bloquear a un administrador';
  END IF;

  IF v_new <> 'activo' AND COALESCE(TRIM(p_reason), '') = '' THEN
    RAISE EXCEPTION 'El motivo es obligatorio';
  END IF;

  IF v_new = 'pausado' AND p_until IS NOT NULL AND p_until <= NOW() THEN
    RAISE EXCEPTION 'La fecha de fin de la pausa debe estar en el futuro';
  END IF;

  UPDATE public.profiles
  SET status            = v_new,
      status_reason     = CASE WHEN v_new = 'activo' THEN NULL ELSE NULLIF(TRIM(p_reason), '') END,
      status_until      = CASE WHEN v_new = 'pausado' THEN p_until ELSE NULL END,
      status_changed_by = v_admin,
      status_changed_at = NOW(),
      updated_at        = NOW(),
      -- Mientras no esté activo no puede quedar "en línea" esperando ofertas.
      -- (No se toca su horario configurado, para que al reactivarlo no pierda nada.)
      is_online         = CASE WHEN v_new = 'activo' THEN is_online ELSE FALSE END
  WHERE id = p_user_id;

  v_accion := CASE v_new WHEN 'activo' THEN 'UNBLOCK_USER'
                         WHEN 'pausado' THEN 'PAUSE_USER'
                         ELSE 'BLOCK_USER' END;

  -- 📝 Auditoría
  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_admin, v_accion, 'profile', p_user_id,
          jsonb_build_object('from_status', v_target.status,
                             'to_status', v_new::text,
                             'reason', NULLIF(TRIM(p_reason), ''),
                             'until', p_until,
                             'role', v_target.role,
                             'name', v_target.full_name));

  -- 🔔 Aviso al usuario (in-app + push si tiene suscripciones)
  PERFORM public.notify_user(
    p_user_id,
    CASE v_new WHEN 'bloqueado' THEN 'Cuenta bloqueada'
               WHEN 'pausado'  THEN 'Cuenta pausada'
               ELSE 'Cuenta reactivada' END,
    CASE v_new
      WHEN 'bloqueado' THEN 'Tu cuenta fue bloqueada. Motivo: ' || COALESCE(NULLIF(TRIM(p_reason), ''), 'no especificado') || '. Contacta a soporte.'
      WHEN 'pausado'  THEN 'Tu cuenta fue pausada temporalmente. Motivo: ' || COALESCE(NULLIF(TRIM(p_reason), ''), 'no especificado') || '.'
      ELSE 'Tu cuenta volvió a estar activa. Ya puedes usar la app.'
    END,
    'account_status',
    jsonb_build_object('status', v_new::text, 'until', p_until, 'reason', NULLIF(TRIM(p_reason), ''), 'url', '/')
  );

  RETURN jsonb_build_object('success', TRUE, 'user_id', p_user_id,
                            'status', v_new::text, 'accion', v_accion);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_set_account_status(uuid, text, text, timestamptz) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.admin_set_account_status(uuid, text, text, timestamptz) FROM anon;

-- ============================================================
-- 9. ADMIN_DELETE_ACCOUNT: eliminar cuenta
--    p_mode = 'anonimizar' (por defecto)  -> borra los datos
--             personales y deja el historial financiero intacto
--             (requisito contable/auditoría).
--    p_mode = 'borrar_real' -> DELETE de verdad, SOLO si la cuenta
--             no tiene historial; si lo tiene, se rechaza.
--    Siempre: fuera suscripciones push y avisos pendientes.
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_delete_account(
  p_user_id UUID,
  p_mode TEXT DEFAULT 'anonimizar',
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin UUID := auth.uid();
  v_target RECORD;
  v_historial INTEGER := 0;
  v_mode TEXT := COALESCE(NULLIF(TRIM(p_mode), ''), 'anonimizar');
BEGIN
  IF public.get_user_role(v_admin) != 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('admin_delete_account', 10);

  IF v_mode NOT IN ('anonimizar', 'borrar_real') THEN
    RAISE EXCEPTION 'Modo no válido';
  END IF;

  IF p_user_id = v_admin THEN
    RAISE EXCEPTION 'No puedes eliminar tu propia cuenta';
  END IF;

  SELECT id, full_name, email, role::text AS role, status::text AS status
  INTO v_target
  FROM public.profiles
  WHERE id = p_user_id;

  IF v_target.id IS NULL THEN
    RAISE EXCEPTION 'Usuario no encontrado';
  END IF;

  IF v_target.role = 'super_admin' THEN
    RAISE EXCEPTION 'No puedes eliminar a un administrador';
  END IF;

  -- ¿Tiene historial que impide el borrado real?
  SELECT (
    (SELECT COUNT(*) FROM public.rides r
      WHERE r.client_id = p_user_id OR r.driver_id = p_user_id
         OR r.cancelled_by = p_user_id OR r.completed_by = p_user_id)
  + (SELECT COUNT(*) FROM public.transactions t
      WHERE t.user_id = p_user_id OR t.reviewed_by = p_user_id)
  + (SELECT COUNT(*) FROM public.payouts po
      WHERE po.driver_id = p_user_id OR po.created_by = p_user_id OR po.reviewed_by = p_user_id)
  + (SELECT COUNT(*) FROM public.driver_earnings de WHERE de.driver_id = p_user_id)
  + (SELECT COUNT(*) FROM public.ride_incidents ri
      WHERE ri.reported_by = p_user_id OR ri.resolved_by = p_user_id)
  + (SELECT COUNT(*) FROM public.audit_logs a WHERE a.user_id = p_user_id)
  + (SELECT COUNT(*) FROM public.zones z WHERE z.created_by = p_user_id)
  + (SELECT COUNT(*) FROM public.coupons c WHERE c.created_by = p_user_id)
  + (SELECT COUNT(*) FROM public.banners b WHERE b.created_by = p_user_id)
  ) INTO v_historial;

  -- Cortar el push siempre (no gastar notificaciones a una cuenta borrada)
  DELETE FROM public.notification_outbox WHERE user_id = p_user_id AND sent_at IS NULL;
  DELETE FROM public.push_subscriptions   WHERE user_id = p_user_id;

  IF v_mode = 'borrar_real' THEN
    IF v_historial > 0 THEN
      RAISE EXCEPTION 'Esta cuenta tiene % registros de historial (viajes, dinero o auditoría) y no se puede borrar de verdad: usa "anonimizar".', v_historial;
    END IF;

    -- Sin historial: borrado real. Los CASCADE limpian wallets, vehículos,
    -- documentos, notificaciones, favoritos, cupones usados y push.
    DELETE FROM public.profiles WHERE id = p_user_id;

    INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
    VALUES (v_admin, 'DELETE_USER', 'profile', p_user_id,
            jsonb_build_object('mode', 'borrar_real', 'name', v_target.full_name,
                               'email', v_target.email, 'role', v_target.role,
                               'reason', NULLIF(TRIM(p_reason), '')));

    RETURN jsonb_build_object('success', TRUE, 'user_id', p_user_id, 'mode', 'borrar_real');
  END IF;

  -- Anonimizar: se borran los datos personales, se conserva el historial
  UPDATE public.profiles
  SET full_name         = 'Usuario eliminado',
      email             = 'eliminado+' || p_user_id::text || '@bunrider.local',
      phone             = NULL,
      avatar_url        = NULL,
      avatar_pending_url = NULL,
      avatar_pending_at = NULL,
      is_online         = FALSE,
      status            = 'eliminado',
      status_reason     = COALESCE(NULLIF(TRIM(p_reason), ''), 'Cuenta eliminada a solicitud del administrador'),
      status_until      = NULL,
      status_changed_by = v_admin,
      status_changed_at = NOW(),
      updated_at        = NOW()
  WHERE id = p_user_id;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_admin, 'DELETE_USER', 'profile', p_user_id,
          jsonb_build_object('mode', 'anonimizar', 'name', v_target.full_name,
                             'email', v_target.email, 'role', v_target.role,
                             'historial_conservado', v_historial,
                             'reason', NULLIF(TRIM(p_reason), '')));

  RETURN jsonb_build_object('success', TRUE, 'user_id', p_user_id, 'mode', 'anonimizar',
                            'historial_conservado', v_historial);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_delete_account(uuid, text, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.admin_delete_account(uuid, text, text) FROM anon;

-- ============================================================
-- 10. GET_ADMIN_USERS: devuelve y filtra por estado de cuenta
--     (se borra la firma anterior para no dejar sobrecargas)
-- ============================================================
DROP FUNCTION IF EXISTS public.get_admin_users(text, text, text, integer, integer);

CREATE OR REPLACE FUNCTION public.get_admin_users(
  p_search TEXT DEFAULT NULL,
  p_role TEXT DEFAULT NULL,
  p_driver_status TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 25,
  p_offset INTEGER DEFAULT 0,
  p_estado TEXT DEFAULT NULL
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
  v_estado TEXT := NULLIF(TRIM(COALESCE(p_estado, '')), '');
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
    AND (p_driver_status IS NULL OR COALESCE(pr.driver_status::text, '') = p_driver_status)
    AND (v_estado IS NULL
         OR (v_estado = 'activo'
             AND (pr.status = 'activo'
                  OR (pr.status = 'pausado' AND pr.status_until IS NOT NULL AND pr.status_until <= NOW())))
         OR (v_estado <> 'activo' AND pr.status::text = v_estado));

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
      pr.status::text AS status,
      pr.status_reason,
      pr.status_until,
      public.is_account_active(pr.id) AS activo,
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
      AND (v_estado IS NULL
           OR (v_estado = 'activo'
               AND (pr.status = 'activo'
                    OR (pr.status = 'pausado' AND pr.status_until IS NOT NULL AND pr.status_until <= NOW())))
           OR (v_estado <> 'activo' AND pr.status::text = v_estado))
  ) t
  LIMIT p_limit OFFSET p_offset;

  RETURN jsonb_build_object('total', v_total, 'items', v_items);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_admin_users(text, text, text, integer, integer, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_admin_users(text, text, text, integer, integer, text) FROM anon;

-- ============================================================
-- 11. CERRAR EL GRANT POR DEFECTO A PUBLIC EN LAS RPC DE ADMIN/DINERO
-- ------------------------------------------------------------
-- En PostgreSQL toda función nace con EXECUTE para PUBLIC (la ACL
-- muestra "=X/"), así que un "REVOKE ALL ... FROM anon" NO basta:
-- el rol anon la hereda igualmente. Verificado en vivo con
-- has_function_privilege('anon', ...).
--
-- NO se tocan los helpers que evalúan las políticas RLS
-- (get_user_role, caller_zone_id, user_in_caller_zone,
-- is_account_active): 074 avisa de que revocarlos rompe cualquier
-- consulta con políticas.
-- ============================================================
DO $$
DECLARE
  r record;
BEGIN
  FOR r IN
    SELECT p.oid::regprocedure AS fn
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.proname IN (
        'admin_set_account_status', 'admin_delete_account',
        'get_admin_metrics', 'get_wallet_overview', 'get_admin_users', 'get_admin_rides',
        'get_admin_transactions', 'get_audit_logs',
        'get_payouts', 'approve_payout', 'admin_pay_driver', 'admin_pay_driver_manual',
        'adjust_driver_debt', 'approve_recharge', 'approve_ride_proof',
        'get_pending_proofs', 'get_pending_recharges',
        'driver_request_payout', 'driver_confirm_payout', 'set_user_role'
      )
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', r.fn);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', r.fn);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', r.fn);
  END LOOP;
END $$;

-- ============================================================
-- 12. VERIFICACIÓN
-- ============================================================
SELECT 'cuentas por estado' AS comprobacion,
       COALESCE(string_agg(s || '=' || n, ', ' ORDER BY s), '(sin datos)') AS valor
FROM (
  SELECT status::text AS s, COUNT(*)::text AS n FROM public.profiles GROUP BY 1
) x
UNION ALL
SELECT 'funciones con candado de estado (esperado 6)', COUNT(*)::text
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('get_user_role','guard_rate_limit','caller_zone_id',
                    'toggle_driver_online','update_driver_location','complete_onboarding')
  AND pg_get_functiondef(p.oid) LIKE '%is_account_active%'
UNION ALL
SELECT 'RPC nuevas de administración (esperado 2)', COUNT(*)::text
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname IN ('admin_set_account_status','admin_delete_account')
UNION ALL
SELECT 'firma vieja de get_admin_users eliminada (esperado 0)', COUNT(*)::text
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'get_admin_users'
  AND pg_get_function_identity_arguments(p.oid) = 'text, text, text, integer, integer'
UNION ALL
SELECT 'campos de estado en get_own_profile_guard (esperado 3)', (
  (CASE WHEN pg_get_functiondef(p.oid) LIKE '%''status''%' THEN 1 ELSE 0 END)
+ (CASE WHEN pg_get_functiondef(p.oid) LIKE '%status_reason%' THEN 1 ELSE 0 END)
+ (CASE WHEN pg_get_functiondef(p.oid) LIKE '%status_until%' THEN 1 ELSE 0 END))::text
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public' AND p.proname = 'get_own_profile_guard';

SELECT '✅ Migración 079: estado de cuentas (pausar / bloquear / eliminar) listo' AS estado;
