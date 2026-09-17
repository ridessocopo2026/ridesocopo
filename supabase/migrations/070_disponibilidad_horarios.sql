-- ============================================================
-- BUNRIDER - Migración 070: DISPONIBILIDAD CON HORARIO + AVISOS
-- ------------------------------------------------------------
-- 1. El conductor puede definir un HORARIO (desde/hasta + días)
--    y si quiere avisos push al abrir/cerrar su horario.
-- 2. La disponibilidad efectiva se CALCULA en la BD:
--      is_online AND dentro de horario (+ override manual).
--    Sin cron obligatorio y sin costos extra.
-- 3. Las ofertas de viaje NO se crean para conductores fuera de
--    su horario (trigger sobre notifications) → sin reescribir
--    request_ride.
-- 4. get_available_driver_counts: conteo por categoría para que
--    el cliente vea qué vehículos están disponibles AHORA.
-- 5. process_availability_reminders(): inserta la notificación
--    (→ push ya existente vía pg_net) al abrir/cerrar horario.
-- 6. Se intenta programar con pg_cron SIN fallar si no está
--    disponible (respaldo: la app / Cloudflare cron).
-- Todo es idempotente y con defaults seguros: quien no configure
-- horario se comporta EXACTAMENTE igual que hoy.
-- ============================================================

-- ============================================================
-- 1. COLUMNAS DE DISPONIBILIDAD EN PROFILES
-- ============================================================
ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS availability_auto BOOLEAN NOT NULL DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS available_from TIME,
  ADD COLUMN IF NOT EXISTS available_to TIME,
  ADD COLUMN IF NOT EXISTS available_days SMALLINT[],
  ADD COLUMN IF NOT EXISTS available_override_until TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS availability_push BOOLEAN NOT NULL DEFAULT TRUE,
  ADD COLUMN IF NOT EXISTS last_open_reminder_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS last_close_reminder_at TIMESTAMPTZ;

-- Índice parcial para el conteo de disponibles (barato)
CREATE INDEX IF NOT EXISTS idx_profiles_driver_online
  ON public.profiles (zone_id)
  WHERE role = 'conductor' AND driver_status = 'aprobado' AND is_online = TRUE;

-- ============================================================
-- 2. ¿EL CONDUCTOR ESTÁ DENTRO DE SU HORARIO AHORA?
--    (override manual manda; sin horario definido no restringe)
-- ============================================================
CREATE OR REPLACE FUNCTION public.driver_in_schedule_now(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v RECORD;
  v_local TIMESTAMP;
  v_time TIME;
  v_dow INTEGER;
BEGIN
  SELECT availability_auto, available_from, available_to, available_days,
         available_override_until
  INTO v
  FROM public.profiles WHERE id = p_user_id;

  IF NOT FOUND THEN
    RETURN TRUE; -- sin perfil: no restringir
  END IF;

  -- Override manual ("1 hora" / "hasta mañana") tiene prioridad
  IF v.available_override_until IS NOT NULL AND v.available_override_until > NOW() THEN
    RETURN TRUE;
  END IF;

  -- Sin horario automático (o sin horas definidas) no restringe
  IF v.availability_auto IS NOT TRUE
     OR v.available_from IS NULL
     OR v.available_to IS NULL THEN
    RETURN TRUE;
  END IF;

  v_local := NOW() AT TIME ZONE 'America/Caracas';
  v_time := v_local::time;
  v_dow := EXTRACT(ISODOW FROM v_local)::INTEGER;

  IF v.available_days IS NOT NULL AND NOT (v_dow = ANY(v.available_days)) THEN
    RETURN FALSE;
  END IF;

  -- Soporta horarios que cruzan medianoche (ej. 20:00 → 02:00)
  IF v.available_from <= v.available_to THEN
    RETURN v_time >= v.available_from AND v_time <= v.available_to;
  ELSE
    RETURN v_time >= v.available_from OR v_time <= v.available_to;
  END IF;
END;
$$;

-- ¿Está disponible para recibir viajes? (conectado + dentro de horario)
CREATE OR REPLACE FUNCTION public.driver_available_now(p_user_id UUID)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT COALESCE(p.is_online, FALSE) AND public.driver_in_schedule_now(p_user_id)
  FROM public.profiles p
  WHERE p.id = p_user_id;
$$;

GRANT EXECUTE ON FUNCTION public.driver_in_schedule_now(uuid) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.driver_available_now(uuid) TO authenticated, service_role;

-- ============================================================
-- 3. CONTEO DE DISPONIBLES POR CATEGORÍA (para el cliente)
--    Solo agregados: no expone datos personales. Barato (índice).
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_available_driver_counts(p_zone_id UUID DEFAULT NULL)
RETURNS TABLE (category TEXT, available INTEGER)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT c.name::TEXT AS category, COUNT(p.id)::INTEGER AS available
  FROM public.vehicle_categories c
  LEFT JOIN public.profiles p
    ON p.role = 'conductor'
   AND p.driver_status = 'aprobado'
   AND (p_zone_id IS NULL OR p.zone_id IS NULL OR p.zone_id = p_zone_id)
   AND public.driver_available_now(p.id)
   AND EXISTS (
     SELECT 1 FROM public.vehicles v
     WHERE v.driver_id = p.id
       AND v.category = c.name
       AND v.is_active = TRUE
   )
  WHERE c.is_active = TRUE
  GROUP BY c.name, c.base_fare_usd
  ORDER BY c.base_fare_usd;
$$;

GRANT EXECUTE ON FUNCTION public.get_available_driver_counts(uuid) TO anon, authenticated, service_role;

-- ============================================================
-- 4. MI DISPONIBILIDAD (para recordatorios en la app)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_my_availability()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v RECORD;
  v_local TIMESTAMP;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT * INTO v FROM public.profiles WHERE id = v_uid;
  IF v.id IS NULL THEN
    RAISE EXCEPTION 'Perfil no encontrado';
  END IF;

  v_local := NOW() AT TIME ZONE 'America/Caracas';

  RETURN jsonb_build_object(
    'is_online', COALESCE(v.is_online, FALSE),
    'auto', COALESCE(v.availability_auto, FALSE),
    'from', v.available_from,
    'to', v.available_to,
    'days', COALESCE(to_jsonb(v.available_days), '[]'::jsonb),
    'in_schedule', public.driver_in_schedule_now(v_uid),
    'override_until', v.available_override_until,
    'push', COALESCE(v.availability_push, TRUE),
    'local_now', to_char(v_local, 'HH24:MI'),
    'dow', EXTRACT(ISODOW FROM v_local)::INTEGER
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_my_availability() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_my_availability() FROM anon;

-- ============================================================
-- 5. GUARDAR MI DISPONIBILIDAD (conexión + horario + avisos)
--    Mismas validaciones que toggle_driver_online (aprobado/deuda).
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_my_availability(
  p_online BOOLEAN,
  p_auto BOOLEAN,
  p_from TIME DEFAULT NULL,
  p_to TIME DEFAULT NULL,
  p_days SMALLINT[] DEFAULT NULL,
  p_push BOOLEAN DEFAULT TRUE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_profile RECORD;
  v_wallet RECORD;
  v_day SMALLINT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT * INTO v_profile FROM public.profiles WHERE id = v_uid;
  IF v_profile.role != 'conductor' THEN
    RAISE EXCEPTION 'No es conductor';
  END IF;
  IF v_profile.driver_status != 'aprobado' THEN
    RAISE EXCEPTION 'Conductor no aprobado';
  END IF;

  IF p_auto IS TRUE AND (p_from IS NULL OR p_to IS NULL) THEN
    RAISE EXCEPTION 'Define la hora de inicio y de cierre del horario';
  END IF;

  IF p_days IS NOT NULL THEN
    FOREACH v_day IN ARRAY p_days LOOP
      IF v_day < 1 OR v_day > 7 THEN
        RAISE EXCEPTION 'Día inválido en el horario (usa 1=lunes … 7=domingo)';
      END IF;
    END LOOP;
  END IF;

  -- Límite de deuda solo al conectarse (desconectarse siempre se permite)
  IF p_online IS TRUE THEN
    SELECT * INTO v_wallet FROM public.wallets WHERE user_id = v_uid;
    IF FOUND AND v_wallet.balance_usd < -v_wallet.debt_limit_usd THEN
      RAISE EXCEPTION 'Límite de deuda excedido. Recargue su saldo.';
    END IF;
  END IF;

  UPDATE public.profiles
  SET is_online = p_online,
      availability_auto = COALESCE(p_auto, FALSE),
      available_from = p_from,
      available_to = p_to,
      available_days = p_days,
      availability_push = COALESCE(p_push, TRUE),
      available_override_until = CASE WHEN p_online IS TRUE THEN available_override_until ELSE NULL END
  WHERE id = v_uid;

  RETURN jsonb_build_object(
    'success', TRUE,
    'is_online', p_online,
    'auto', COALESCE(p_auto, FALSE),
    'in_schedule', public.driver_in_schedule_now(v_uid)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_my_availability(boolean, boolean, time, time, smallint[], boolean) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.set_my_availability(boolean, boolean, time, time, smallint[], boolean) FROM anon;

-- ============================================================
-- 6. OVERRIDE MANUAL: "1 hora" o "hasta mañana"
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_my_availability_override(p_minutes INTEGER DEFAULT 60)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_profile RECORD;
  v_wallet RECORD;
  v_until TIMESTAMPTZ;
  v_local_date DATE;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT * INTO v_profile FROM public.profiles WHERE id = v_uid;
  IF v_profile.role != 'conductor' OR v_profile.driver_status != 'aprobado' THEN
    RAISE EXCEPTION 'Conductor no aprobado';
  END IF;

  SELECT * INTO v_wallet FROM public.wallets WHERE user_id = v_uid;
  IF FOUND AND v_wallet.balance_usd < -v_wallet.debt_limit_usd THEN
    RAISE EXCEPTION 'Límite de deuda excedido. Recargue su saldo.';
  END IF;

  IF p_minutes IS NOT NULL AND p_minutes > 0 THEN
    v_until := NOW() + (p_minutes || ' minutes')::INTERVAL;
  ELSE
    -- Hasta mañana: medianoche local (Venezuela)
    v_local_date := (NOW() AT TIME ZONE 'America/Caracas')::DATE;
    v_until := ((v_local_date + 1)::TIMESTAMP AT TIME ZONE 'America/Caracas');
  END IF;

  UPDATE public.profiles
  SET is_online = TRUE,
      available_override_until = v_until
  WHERE id = v_uid;

  RETURN jsonb_build_object('success', TRUE, 'is_online', TRUE, 'override_until', v_until);
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_my_availability_override(integer) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.set_my_availability_override(integer) FROM anon;

-- ============================================================
-- 7. RECORDATORIOS DE APERTURA/CIERRE DEL HORARIO
--    Inserta una notificación (el push ya se envía solo por el
--    trigger existente de notifications → pg_net → Edge Function).
--    Idempotente: no repite el aviso dentro de 4 horas.
-- ============================================================
CREATE OR REPLACE FUNCTION public.process_availability_reminders()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_row RECORD;
  v_local TIMESTAMP;
  v_time TIME;
  v_dow INTEGER;
  v_in BOOLEAN;
  v_open INTEGER := 0;
  v_close INTEGER := 0;
BEGIN
  FOR v_row IN
    SELECT id, available_from, available_to, available_days,
           last_open_reminder_at, last_close_reminder_at, available_override_until
    FROM public.profiles
    WHERE role = 'conductor'
      AND driver_status = 'aprobado'
      AND availability_auto = TRUE
      AND available_from IS NOT NULL
      AND available_to IS NOT NULL
      AND COALESCE(availability_push, TRUE) = TRUE
  LOOP
    -- Override manual activo: no molestar
    IF v_row.available_override_until IS NOT NULL AND v_row.available_override_until > NOW() THEN
      CONTINUE;
    END IF;

    v_local := NOW() AT TIME ZONE 'America/Caracas';
    v_time := v_local::time;
    v_dow := EXTRACT(ISODOW FROM v_local)::INTEGER;

    IF v_row.available_days IS NOT NULL AND NOT (v_dow = ANY(v_row.available_days)) THEN
      CONTINUE;
    END IF;

    IF v_row.available_from <= v_row.available_to THEN
      v_in := v_time >= v_row.available_from AND v_time <= v_row.available_to;
    ELSE
      v_in := v_time >= v_row.available_from OR v_time <= v_row.available_to;
    END IF;

    IF v_in THEN
      IF v_row.last_open_reminder_at IS NULL
         OR v_row.last_open_reminder_at < NOW() - INTERVAL '4 hours' THEN
        INSERT INTO public.notifications (user_id, title, body, type, data)
        VALUES (v_row.id,
          '🟢 Tu horario comenzó',
          'Estás en tu horario (' || to_char(v_row.available_from, 'HH24:MI') || '–' || to_char(v_row.available_to, 'HH24:MI') || '). Actívate para recibir viajes.',
          'schedule_open',
          jsonb_build_object('kind', 'schedule_open'));
        UPDATE public.profiles SET last_open_reminder_at = NOW() WHERE id = v_row.id;
        v_open := v_open + 1;
      END IF;
    ELSE
      IF v_row.last_close_reminder_at IS NULL
         OR v_row.last_close_reminder_at < NOW() - INTERVAL '4 hours' THEN
        INSERT INTO public.notifications (user_id, title, body, type, data)
        VALUES (v_row.id,
          '🔴 Tu horario terminó',
          'Ya no estás en tu horario de disponibilidad. Entra y desactívate para dejar de recibir ofertas.',
          'schedule_close',
          jsonb_build_object('kind', 'schedule_close'));
        UPDATE public.profiles SET last_close_reminder_at = NOW() WHERE id = v_row.id;
        v_close := v_close + 1;
      END IF;
    END IF;
  END LOOP;

  RETURN jsonb_build_object('success', TRUE, 'open_reminders', v_open, 'close_reminders', v_close);
END;
$$;

REVOKE ALL ON FUNCTION public.process_availability_reminders() FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.process_availability_reminders() TO service_role;

-- ============================================================
-- 8. FUERA DE HORARIO NO LLEGAN OFERTAS DE VIAJE
--    (evita reescribir request_ride; no afecta a nadie sin horario)
-- ============================================================
CREATE OR REPLACE FUNCTION public.filter_ride_offers_by_schedule()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.type = 'ride_available'
     AND EXISTS (
       SELECT 1 FROM public.profiles p
       WHERE p.id = NEW.user_id AND p.availability_auto = TRUE
     )
     AND NOT public.driver_in_schedule_now(NEW.user_id) THEN
    RETURN NULL; -- fuera de horario: no se crea la oferta ni se envía push
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_filter_ride_offers_by_schedule ON public.notifications;
CREATE TRIGGER trg_filter_ride_offers_by_schedule
  BEFORE INSERT ON public.notifications
  FOR EACH ROW
  EXECUTE FUNCTION public.filter_ride_offers_by_schedule();

-- ============================================================
-- 9. PROGRAMACIÓN CON PG_CRON (tolerante: si no está, no falla)
--    Respaldo sin costo: la app del conductor al abrir, o un
--    Cron Trigger de Cloudflare que llame a la RPC.
-- ============================================================
DO $$
BEGIN
  BEGIN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
  EXCEPTION WHEN OTHERS THEN
    RAISE NOTICE 'pg_cron no disponible: recordatorios sin cron (app/Cloudflare)';
    RETURN;
  END;

  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    BEGIN
      PERFORM cron.unschedule('bunrider-availability-reminders');
    EXCEPTION WHEN OTHERS THEN
      NULL; -- aún no existía el job
    END;

    PERFORM cron.schedule(
      'bunrider-availability-reminders',
      '*/5 * * * *',
      'SELECT public.process_availability_reminders()'
    );

    RAISE NOTICE '✅ Recordatorios de disponibilidad programados cada 5 minutos';
  END IF;
END
$$;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 070: disponibilidad con horario + avisos lista' AS estado;
