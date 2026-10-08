-- ============================================================
-- BUNRIDER - Migracion 084: CIUDADES INDEPENDIENTES
-- ------------------------------------------------------------
-- 1) banners.zone_id (NULL = todas las ciudades)
-- 2) create_banner(p_zone_id): encargado => su ciudad; super_admin elige
-- 3) RLS: el encargado gestiona los banners de SU ciudad
-- 4) send_admin_notification(p_zone_id): filtra por ciudad; encargado => su ciudad
-- ============================================================

ALTER TABLE public.banners ADD COLUMN IF NOT EXISTS zone_id uuid REFERENCES public.zones(id);
CREATE INDEX IF NOT EXISTS idx_banners_active_zone ON public.banners(is_active, zone_id, sort_order);

DROP FUNCTION IF EXISTS public.create_banner(text, text, text, text, integer, timestamp with time zone, timestamp with time zone);
CREATE OR REPLACE FUNCTION public.create_banner(
  p_title text, p_subtitle text, p_image_url text, p_link_url text,
  p_sort_order integer DEFAULT 0,
  p_starts_at timestamp with time zone DEFAULT NULL,
  p_ends_at timestamp with time zone DEFAULT NULL,
  p_zone_id uuid DEFAULT NULL
)
RETURNS uuid LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role public.user_role;
  v_zone uuid := p_zone_id;
  v_banner_id uuid;
BEGIN
  SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;
  IF v_role = ''encargado'' THEN
    v_zone := public.caller_zone_id();
  ELSIF v_role IS DISTINCT FROM ''super_admin'' THEN
    RAISE EXCEPTION ''No autorizado'';
  END IF;
  IF v_zone IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.zones WHERE id = v_zone AND zone_type = ''cobertura_general'' AND is_active = TRUE
  ) THEN
    RAISE EXCEPTION ''Ciudad invalida'';
  END IF;
  INSERT INTO public.banners (title, subtitle, image_url, link_url, sort_order, starts_at, ends_at, created_by, zone_id)
  VALUES (p_title, p_subtitle, p_image_url, p_link_url, p_sort_order, p_starts_at, p_ends_at, v_uid, v_zone)
  RETURNING id INTO v_banner_id;
  RETURN v_banner_id;
END;
$$;
GRANT EXECUTE ON FUNCTION public.create_banner(text, text, text, text, integer, timestamp with time zone, timestamp with time zone, uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.create_banner(text, text, text, text, integer, timestamp with time zone, timestamp with time zone, uuid) FROM anon;

DROP POLICY IF EXISTS "encargado_manage_banners" ON public.banners;
CREATE POLICY "encargado_manage_banners" ON public.banners
  FOR ALL
  USING (public.get_user_role((SELECT auth.uid())) = ''encargado'' AND zone_id = public.caller_zone_id())
  WITH CHECK (public.get_user_role((SELECT auth.uid())) = ''encargado'' AND zone_id = public.caller_zone_id());

DROP FUNCTION IF EXISTS public.send_admin_notification(text, text, text);
CREATE OR REPLACE FUNCTION public.send_admin_notification(
  p_title text, p_body text DEFAULT NULL, p_target text DEFAULT ''todos'', p_zone_id uuid DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role public.user_role;
  v_zone uuid := p_zone_id;
  v_count integer;
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
  INSERT INTO public.notifications (user_id, title, body, type, data)
  SELECT p.id, p_title, p_body, ''admin_broadcast'', jsonb_build_object(''target'', p_target, ''zone_id'', v_zone)
  FROM public.profiles p
  WHERE (v_zone IS NULL OR p.zone_id = v_zone)
    AND CASE p_target WHEN ''todos'' THEN TRUE WHEN ''clientes'' THEN p.role = ''cliente'' WHEN ''conductores'' THEN p.role = ''conductor'' WHEN ''admins'' THEN p.role IN (''super_admin'', ''encargado'') ELSE FALSE END;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  INSERT INTO public.notification_outbox (notification_id, user_id)
  SELECT n.id, n.user_id FROM public.notifications n
  WHERE n.created_at >= NOW() - INTERVAL ''1 minute'' AND n.type = ''admin_broadcast''
    AND EXISTS (SELECT 1 FROM public.push_subscriptions ps WHERE ps.user_id = n.user_id)
  ON CONFLICT (notification_id) DO NOTHING;
  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_uid, ''SEND_BROADCAST'', ''notification'', NULL, jsonb_build_object(''title'', p_title, ''target'', p_target, ''zone_id'', v_zone, ''count'', v_count));
  RETURN jsonb_build_object(''success'', TRUE, ''sent'', v_count, ''target'', p_target, ''zone_id'', v_zone);
END;
$$;
GRANT EXECUTE ON FUNCTION public.send_admin_notification(text, text, text, uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.send_admin_notification(text, text, text, uuid) FROM anon;
