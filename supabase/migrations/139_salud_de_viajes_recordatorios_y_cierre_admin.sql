-- 139 - Salud de viajes:
--   1) Recordatorio al cliente si el conductor confirmo la recogida y el
--      cliente no confirma el inicio (viaje trabado en 'aceptada').
--   2) Alerta a los admins si un viaje lleva > 2 h en curso.
--   3) admin_close_ride: el admin finaliza un viaje trabado y liquida ganancias.
--
-- Idempotente: cada recordatorio/alerta se envia UNA vez por viaje
-- (start_reminder_at / stale_alert_at) y corre en el cron de 5 minutos.

ALTER TABLE public.rides
  ADD COLUMN IF NOT EXISTS start_reminder_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS stale_alert_at TIMESTAMPTZ;

COMMENT ON COLUMN public.rides.start_reminder_at IS 'Cuando se le recordo al cliente confirmar el inicio del viaje';
COMMENT ON COLUMN public.rides.stale_alert_at IS 'Cuando se alerto al admin de un viaje atascado';

CREATE INDEX IF NOT EXISTS idx_rides_active_started
  ON public.rides (started_at)
  WHERE status IN ('aceptada', 'en_ruta');

-- ------------------------------------------------------------
-- 1) Recordar al cliente que confirme el inicio
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.remind_pending_start_confirmations(
  p_min_minutes INTEGER DEFAULT 3,
  p_max_minutes INTEGER DEFAULT 90
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ride RECORD;
  v_count INTEGER := 0;
BEGIN
  IF p_min_minutes IS NULL OR p_min_minutes < 1 THEN p_min_minutes := 3; END IF;
  IF p_max_minutes IS NULL OR p_max_minutes < p_min_minutes THEN p_max_minutes := 90; END IF;

  FOR v_ride IN
    SELECT r.id, r.client_id, r.tracking_code, r.started_at
    FROM public.rides r
    WHERE r.status = 'aceptada'
      AND r.driver_start_confirmed = TRUE
      AND r.client_start_confirmed = FALSE
      AND r.started_at IS NOT NULL
      AND r.started_at <= NOW() - make_interval(mins => p_min_minutes)
      AND r.started_at >= NOW() - make_interval(mins => p_max_minutes)
      AND r.start_reminder_at IS NULL
    ORDER BY r.started_at
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE public.rides SET start_reminder_at = NOW() WHERE id = v_ride.id;

    PERFORM public.notify_user(
      v_ride.client_id,
      'Confirma tu viaje',
      'Tu conductor ya te recogió. Confirma el inicio para continuar.',
      'ride_start_reminder',
      jsonb_build_object('ride_id', v_ride.id, 'url', '/cliente/viaje/' || v_ride.id)
    );

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.remind_pending_start_confirmations(INTEGER, INTEGER) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.remind_pending_start_confirmations(INTEGER, INTEGER) TO service_role;

-- ------------------------------------------------------------
-- 2) Alertar a los admins de un viaje atascado
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.alert_stale_rides(p_hours INTEGER DEFAULT 2)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ride RECORD;
  v_admin RECORD;
  v_count INTEGER := 0;
BEGIN
  IF p_hours IS NULL OR p_hours < 1 THEN p_hours := 2; END IF;

  FOR v_ride IN
    SELECT r.id, r.tracking_code, r.status, r.origin_zone_id, r.created_at
    FROM public.rides r
    WHERE r.status IN ('aceptada', 'en_ruta')
      AND r.created_at <= NOW() - make_interval(hours => p_hours)
      AND r.stale_alert_at IS NULL
    ORDER BY r.created_at
    FOR UPDATE SKIP LOCKED
  LOOP
    UPDATE public.rides SET stale_alert_at = NOW() WHERE id = v_ride.id;

    FOR v_admin IN
      SELECT p.id, p.role::text AS role
      FROM public.profiles p
      WHERE p.role = 'super_admin'
         OR (
           p.role = 'encargado'
           AND (v_ride.origin_zone_id IS NULL OR p.zone_id = v_ride.origin_zone_id)
         )
    LOOP
      PERFORM public.notify_user(
        v_admin.id,
        'Viaje sin cerrar',
        'El viaje ' || COALESCE(v_ride.tracking_code, '') || ' lleva más de ' || p_hours ||
          ' h en curso. Revísalo y ciérralo si ya terminó.',
        'ride_stale_alert',
        jsonb_build_object(
          'ride_id', v_ride.id,
          'url', CASE WHEN v_admin.role = 'encargado' THEN '/encargado/viajes' ELSE '/admin/viajes' END
        )
      );
    END LOOP;

    v_count := v_count + 1;
  END LOOP;

  RETURN v_count;
END;
$$;

REVOKE ALL ON FUNCTION public.alert_stale_rides(INTEGER) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.alert_stale_rides(INTEGER) TO service_role;

-- ------------------------------------------------------------
-- 3) El admin finaliza un viaje trabado (liquida ganancias)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_close_ride(
  p_ride_id UUID,
  p_note TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin UUID := auth.uid();
  v_role TEXT;
  v_ride RECORD;
  v_zone UUID;
  v_settlement JSONB;
  v_note TEXT := COALESCE(NULLIF(BTRIM(COALESCE(p_note, '')), ''), 'Finalizado por la plataforma');
BEGIN
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  v_role := public.get_user_role(v_admin)::text;
  IF v_role IS NULL OR v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('admin_close_ride', 30);

  SELECT * INTO v_ride FROM public.rides WHERE id = p_ride_id FOR UPDATE;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF v_ride.status NOT IN ('aceptada', 'en_ruta') THEN
    RAISE EXCEPTION 'Solo se pueden finalizar viajes en curso (estado actual: %)', v_ride.status;
  END IF;

  IF v_role = 'encargado' THEN
    v_zone := public.caller_zone_id();
    IF v_zone IS NULL OR (v_ride.origin_zone_id IS NOT NULL AND v_ride.origin_zone_id <> v_zone) THEN
      RAISE EXCEPTION 'No autorizado para viajes de otra ciudad';
    END IF;
  END IF;

  UPDATE public.rides
  SET status = 'completada',
      completed_at = NOW(),
      completed_by = v_admin
  WHERE id = p_ride_id;

  IF v_ride.driver_id IS NOT NULL THEN
    v_settlement := public.settle_ride_earnings(p_ride_id);
  END IF;

  IF v_ride.client_id IS NOT NULL THEN
    PERFORM public.notify_user(
      v_ride.client_id,
      'Viaje finalizado',
      'La plataforma finalizó tu viaje. Si no lo confirmaste, revisa el detalle.',
      'ride_completed',
      jsonb_build_object('ride_id', p_ride_id, 'url', '/cliente/viaje/' || p_ride_id)
    );
  END IF;

  IF v_ride.driver_id IS NOT NULL THEN
    PERFORM public.notify_user(
      v_ride.driver_id,
      'Viaje finalizado por la plataforma',
      'Tu viaje fue cerrado por el equipo. Revisa tus ganancias.',
      'ride_completed',
      jsonb_build_object('ride_id', p_ride_id, 'url', '/conductor/viaje/' || p_ride_id)
    );
  END IF;

  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (
    v_admin, 'ADMIN_CLOSE_RIDE', 'ride', p_ride_id,
    jsonb_build_object(
      'previous_status', v_ride.status,
      'note', v_note,
      'driver_id', v_ride.driver_id,
      'client_id', v_ride.client_id,
      'final_fare_usd', v_ride.final_fare_usd
    )
  );

  RETURN jsonb_build_object(
    'success', TRUE,
    'ride_id', p_ride_id,
    'settlement', v_settlement
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_close_ride(UUID, TEXT) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_close_ride(UUID, TEXT) FROM anon;

-- ------------------------------------------------------------
-- 4) Enganchar al cron de cada 5 minutos
-- ------------------------------------------------------------
SELECT cron.alter_job(
  job_id := 7,
  command := 'SELECT public.process_availability_reminders(); SELECT public.expire_unassigned_rides(); SELECT public.alert_unattended_rides(); SELECT public.remind_pending_start_confirmations(); SELECT public.alert_stale_rides();'
);
