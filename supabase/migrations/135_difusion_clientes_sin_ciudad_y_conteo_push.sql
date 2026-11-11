-- 135 - Difusion: incluye a los usuarios SIN ciudad asignada (zone_id NULL)
-- y arregla el conteo de push.
--
-- Dos bugs encontrados en produccion:
--  1) El filtro por ciudad excluia a todo perfil con zone_id NULL. Dejaba
--     fuera a los clientes registrados sin ciudad (8 de 45) y al super_admin.
--     Ej: Yaneth Duran (cliente, zone_id NULL) nunca recibia las difusiones
--     enviadas filtrando por Socopo.
--  2) v_push se tomaba con GET DIAGNOSTICS despues del INSERT ... ON CONFLICT
--     DO NOTHING, pero el trigger por fila (notify_push_queue_row) YA habia
--     insertado esas filas en el mismo statement, asi que siempre daba 0
--     ("nadie tiene el push activo") aunque el push si se enviaba.
--
-- Devuelve:
--   sent    = notificaciones creadas (usuarios alcanzados)
--   push    = usuarios con push activo (filas reales en notification_outbox)
--   devices = dispositivos (suscripciones) de esos usuarios

CREATE OR REPLACE FUNCTION public.send_admin_notification(
  p_title TEXT,
  p_body TEXT DEFAULT NULL,
  p_target TEXT DEFAULT ''todos'',
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
  v_devices INTEGER := 0;
BEGIN
  SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;
  IF v_role = ''encargado'' THEN
    v_zone := public.caller_zone_id();
  ELSIF v_role IS DISTINCT FROM ''super_admin'' THEN
    RAISE EXCEPTION ''No autorizado: solo super_admin o encargado'';
  END IF;

  IF p_target NOT IN (''todos'', ''clientes'', ''conductores'', ''admins'') THEN
    RAISE EXCEPTION ''Destino invalido'';
  END IF;

  IF p_title IS NULL OR btrim(p_title) = '''' OR p_body IS NULL OR btrim(p_body) = '''' THEN
    RAISE EXCEPTION ''Titulo y mensaje son obligatorios'';
  END IF;

  CREATE TEMP TABLE IF NOT EXISTS pg_temp.broadcast_sent (
    notification_id UUID,
    user_id UUID
  ) ON COMMIT DROP;
  TRUNCATE pg_temp.broadcast_sent;

  WITH creadas AS (
    INSERT INTO public.notifications (user_id, title, body, type, data)
    SELECT p.id, btrim(p_title), btrim(p_body), ''admin_broadcast'',
           jsonb_build_object(''target'', p_target, ''zone_id'', v_zone)
    FROM public.profiles p
    WHERE (
            v_zone IS NULL
            OR p.zone_id IS NULL
            OR p.zone_id = v_zone
            OR p.role = ''super_admin''
          )
      AND CASE p_target
            WHEN ''todos'' THEN TRUE
            WHEN ''clientes'' THEN p.role = ''cliente''
            WHEN ''conductores'' THEN p.role = ''conductor''
            WHEN ''admins'' THEN p.role IN (''super_admin'', ''encargado'')
            ELSE FALSE
          END
    RETURNING id, user_id
  )
  INSERT INTO pg_temp.broadcast_sent (notification_id, user_id)
  SELECT id, user_id FROM creadas;

  SELECT count(*) INTO v_total FROM pg_temp.broadcast_sent;

  INSERT INTO public.notification_outbox (notification_id, user_id)
  SELECT b.notification_id, b.user_id
  FROM pg_temp.broadcast_sent b
  WHERE EXISTS (
    SELECT 1 FROM public.push_subscriptions ps WHERE ps.user_id = b.user_id
  )
  ON CONFLICT (notification_id) DO NOTHING;

  SELECT count(*) INTO v_push
  FROM public.notification_outbox o
  WHERE o.notification_id IN (SELECT notification_id FROM pg_temp.broadcast_sent);

  SELECT count(*) INTO v_devices
  FROM public.push_subscriptions ps
  WHERE ps.user_id IN (SELECT user_id FROM pg_temp.broadcast_sent);

  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_uid, ''SEND_BROADCAST'', ''notification'', NULL,
          jsonb_build_object(
            ''title'', btrim(p_title), ''target'', p_target, ''zone_id'', v_zone,
            ''count'', v_total, ''push'', v_push, ''devices'', v_devices
          ));

  RETURN jsonb_build_object(
    ''success'', TRUE,
    ''sent'', v_total,
    ''push'', v_push,
    ''devices'', v_devices,
    ''target'', p_target,
    ''zone_id'', v_zone
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.send_admin_notification(TEXT, TEXT, TEXT, UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.send_admin_notification(TEXT, TEXT, TEXT, UUID) FROM anon;
