-- ============================================================
-- BUNRIDER - Migracion 086: PANEL DE CONSUMO (pedidos + Realtime)
-- ------------------------------------------------------------
-- get_ops_usage(): pedidos de hoy/mes/ultimos 7 dias y ESTIMACION de
-- mensajes Realtime del mes vs el limite del plan Pro (5.000.000).
-- Alcance por rol (encargado => su ciudad). Solo lectura.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_ops_usage(p_realtime_per_ride numeric DEFAULT 150)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role public.user_role;
  v_zone uuid;
  v_today integer;
  v_month integer;
  v_last7 jsonb;
  v_online integer;
  v_msgs numeric;
  v_limit numeric := 5000000;
BEGIN
  IF v_uid IS NULL THEN RAISE EXCEPTION ''No autenticado''; END IF;
  SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;
  IF v_role NOT IN (''super_admin'',''encargado'') THEN RAISE EXCEPTION ''No autorizado''; END IF;
  IF v_role = ''encargado'' THEN v_zone := public.caller_zone_id(); END IF;

  SELECT COUNT(*) INTO v_today FROM public.rides r
   WHERE r.created_at >= date_trunc(''day'', now()) AND (v_zone IS NULL OR r.origin_zone_id = v_zone);
  SELECT COUNT(*) INTO v_month FROM public.rides r
   WHERE r.created_at >= date_trunc(''month'', now()) AND (v_zone IS NULL OR r.origin_zone_id = v_zone);

  SELECT COALESCE(jsonb_agg(jsonb_build_object(''d'', d::date, ''n'', n) ORDER BY d), ''[]''::jsonb) INTO v_last7
  FROM (
    SELECT date_trunc(''day'', r.created_at) AS d, COUNT(*) AS n
    FROM public.rides r
    WHERE r.created_at >= date_trunc(''day'', now()) - interval ''6 days''
      AND (v_zone IS NULL OR r.origin_zone_id = v_zone)
    GROUP BY 1
  ) t;

  SELECT COUNT(*) INTO v_online FROM public.profiles p
   WHERE p.role = ''conductor'' AND p.driver_status = ''aprobado'' AND p.is_online = TRUE
     AND (v_zone IS NULL OR p.zone_id IS NULL OR p.zone_id = v_zone);

  v_msgs := v_month * COALESCE(p_realtime_per_ride, 150);

  RETURN jsonb_build_object(
    ''rides_today'', v_today, ''rides_month'', v_month, ''last7'', v_last7,
    ''drivers_online'', v_online, ''realtime_per_ride'', COALESCE(p_realtime_per_ride,150),
    ''msgs_month_est'', ROUND(v_msgs), ''pro_limit'', v_limit, ''pct_of_pro'', ROUND((v_msgs / v_limit) * 100, 1));
END;
$$;
GRANT EXECUTE ON FUNCTION public.get_ops_usage(numeric) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_ops_usage(numeric) FROM anon;