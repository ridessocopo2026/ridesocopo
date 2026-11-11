-- 134 - Notificaciones: los super_admin reciben siempre la difusion, se cuenta
-- el push real y se agrega una prueba por dispositivo.
--
-- Contexto del bug: send_admin_notification filtraba por ciudad
-- (p.zone_id = v_zone). El super_admin tiene zone_id = NULL, asi que con una
-- ciudad seleccionada quedaba FUERA de su propia difusion: la notificacion se
-- creaba para 109 usuarios pero ninguna para el admin, por eso "no llegaba
-- nada". Ahora los super_admin entran siempre.

ALTER TABLE public.notification_outbox
  ADD COLUMN IF NOT EXISTS sent_count INTEGER,
  ADD COLUMN IF NOT EXISTS failed_count INTEGER;

COMMENT ON COLUMN public.notification_outbox.sent_count IS 'Dispositivos a los que se entrego el push';
COMMENT ON COLUMN public.notification_outbox.failed_count IS 'Dispositivos con error de envio (distintos de expirados)';

-- ------------------------------------------------------------
-- 1) DIFUSION: incluye a los super_admin aunque se filtre por ciudad
--    y devuelve cuantos destinatarios tienen push activo.
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.send_admin_notification(
  p_title TEXT,
  p_body TEXT DEFAULT NULL,
  p_target TEXT DEFAULT 'todos',
  p_zone_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_role public.user_role;
  v_zone UUID := p_zone_id;
  v_total INTEGER := 0;
  v_push INTEGER := 0;
BEGIN
  SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;
  IF v_role = 'encargado' THEN
    v_zone := public.caller_zone_id();
  ELSIF v_role IS DISTINCT FROM 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado: solo super_admin o encargado';
  END IF;

  IF p_target NOT IN ('todos', 'clientes', 'conductores', 'admins') THEN
    RAISE EXCEPTION 'Destino inválido. Use: todos, clientes, conductores, admins';
  END IF;

  IF p_title IS NULL OR btrim(p_title) = '' OR p_body IS NULL OR btrim(p_body) = '' THEN
    RAISE EXCEPTION 'Título y mensaje son obligatorios';
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.broadcast_sent (
    notification_id UUID,
    user_id UUID
  ) ON COMMIT DROP;
  TRUNCATE pg_temp.broadcast_sent;

  WITH creadas AS (
    INSERT INTO public.notifications (user_id, title, body, type, data)
    SELECT p.id, btrim(p_title), btrim(p_body), 'admin_broadcast',
           jsonb_build_object('target', p_target, 'zone_id', v_zone)
    FROM public.profiles p
    WHERE (
            v_zone IS NULL
            OR p.zone_id = v_zone
            OR p.role = 'super_admin'
          )
      AND CASE p_target
            WHEN 'todos' THEN TRUE
            WHEN 'clientes' THEN p.role = 'cliente'
            WHEN 'conductores' THEN p.role = 'conductor'
            WHEN 'admins' THEN p.role IN ('super_admin', 'encargado')
            ELSE FALSE
          END
    RETURNING id, user_id
  )
  INSERT INTO pg_temp.broadcast_sent (notification_id, user_id)
  SELECT id, user_id FROM creadas;

  SELECT count(*) INTO v_total FROM pg_temp.broadcast_sent;

  -- Solo se encola push para quien tenga suscripcion activa
  INSERT INTO public.notification_outbox (notification_id, user_id)
  SELECT b.notification_id, b.user_id
  FROM pg_temp.broadcast_sent b
  WHERE EXISTS (
    SELECT 1 FROM public.push_subscriptions ps WHERE ps.user_id = b.user_id
  )
  ON CONFLICT (notification_id) DO NOTHING;

  GET DIAGNOSTICS v_push = ROW_COUNT;

  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_uid, 'SEND_BROADCAST', 'notification', NULL,
          jsonb_build_object(
            'title', btrim(p_title), 'target', p_target, 'zone_id', v_zone,
            'count', v_total, 'push', v_push
          ));

  RETURN jsonb_build_object(
    'success', TRUE,
    'sent', v_total,
    'push', v_push,
    'target', p_target,
    'zone_id', v_zone
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.send_admin_notification(TEXT, TEXT, TEXT, UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.send_admin_notification(TEXT, TEXT, TEXT, UUID) FROM anon;

-- ------------------------------------------------------------
-- 2) PRUEBA: notificacion + push solo para el usuario que la pide
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.admin_test_push()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_role public.user_role;
  v_notif UUID;
  v_subs INTEGER := 0;
  v_url TEXT := '/';
BEGIN
  SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;
  IF v_role IS DISTINCT FROM 'super_admin' AND v_role IS DISTINCT FROM 'encargado' THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT count(*) INTO v_subs FROM public.push_subscriptions WHERE user_id = v_uid;

  IF v_role = 'encargado' THEN
    v_url := '/encargado/notificaciones';
  ELSE
    v_url := '/admin/notificaciones';
  END IF;

  INSERT INTO public.notifications (user_id, title, body, type, data)
  VALUES (
    v_uid,
    'Prueba de notificación',
    'Si ves este mensaje, las notificaciones push funcionan en este dispositivo.',
    'admin_broadcast',
    jsonb_build_object('test', TRUE, 'url', v_url)
  )
  RETURNING id INTO v_notif;

  RETURN jsonb_build_object(
    'success', TRUE,
    'notification_id', v_notif,
    'subscriptions', v_subs
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_test_push() TO authenticated;
REVOKE ALL ON FUNCTION public.admin_test_push() FROM anon;

-- ------------------------------------------------------------
-- 3) pg_net: mas margen para que la Edge Function alcance a responder
--    (un lote de decenas de push tardaba >5 s y timeouteaba).
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.notify_push_after_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_settings RECORD;
  v_pg_net_available BOOLEAN;
BEGIN
  SELECT * INTO v_settings FROM push_settings LIMIT 1;

  IF v_settings.id IS NULL OR v_settings.function_url IS NULL OR v_settings.function_secret IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM pg_extension WHERE extname = 'pg_net'
  ) INTO v_pg_net_available;

  IF NOT v_pg_net_available THEN
    RETURN NEW;
  END IF;

  PERFORM net.http_post(
    url := v_settings.function_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_settings.function_secret
    ),
    body := jsonb_build_object('notification_id', NEW.id),
    timeout_milliseconds := 20000
  );

  RETURN NEW;
EXCEPTION WHEN OTHERS THEN
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION public.notify_push_batch_statement()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_settings RECORD;
  v_pg_net_available BOOLEAN;
  v_pending UUID[];
  v_idx INTEGER;
  v_chunk_size CONSTANT INTEGER := 50;
BEGIN
  CREATE TEMP TABLE IF NOT EXISTS pg_temp.ridesocopo_pending_push (
    notification_id UUID PRIMARY KEY
  ) ON COMMIT PRESERVE ROWS;

  SELECT * INTO v_settings FROM push_settings LIMIT 1;
  IF v_settings.id IS NULL OR v_settings.function_url IS NULL OR v_settings.function_secret IS NULL THEN
    TRUNCATE pg_temp.ridesocopo_pending_push;
    RETURN NULL;
  END IF;

  SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_net')
  INTO v_pg_net_available;
  IF NOT v_pg_net_available THEN
    TRUNCATE pg_temp.ridesocopo_pending_push;
    RETURN NULL;
  END IF;

  SELECT ARRAY(
    SELECT notification_id FROM pg_temp.ridesocopo_pending_push ORDER BY notification_id
  ) INTO v_pending;

  TRUNCATE pg_temp.ridesocopo_pending_push;

  IF array_length(v_pending, 1) IS NULL THEN
    RETURN NULL;
  END IF;

  v_idx := 1;
  WHILE v_idx <= array_length(v_pending, 1) LOOP
    PERFORM net.http_post(
      url := v_settings.function_url,
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || v_settings.function_secret
      ),
      body := jsonb_build_object(
        'notification_ids', to_jsonb(
          v_pending[v_idx : LEAST(v_idx + v_chunk_size - 1, array_length(v_pending, 1))]
        )
      ),
      timeout_milliseconds := 20000
    );
    v_idx := v_idx + v_chunk_size;
  END LOOP;

  RETURN NULL;
EXCEPTION WHEN OTHERS THEN
  BEGIN
    TRUNCATE pg_temp.ridesocopo_pending_push;
  EXCEPTION WHEN OTHERS THEN NULL;
  END;
  RETURN NULL;
END;
$$;
