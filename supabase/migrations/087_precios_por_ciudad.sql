-- ============================================================
-- BUNRIDER - Migracion 087: PRECIOS POR CIUDAD
-- ------------------------------------------------------------
-- Precio BASE por categoria distinto en cada ciudad, con respaldo
-- al global (vehicle_categories.base_fare_usd).
-- Super admin edita todas las ciudades; el encargado solo la suya.
-- calculate_fare usa COALESCE(precio_ciudad, global). El precio se
-- guarda en cada viaje al crearlo => cambiar precios solo afecta a
-- viajes futuros.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.city_fares (
  zone_id uuid NOT NULL REFERENCES public.zones(id),
  category public.vehicle_category NOT NULL,
  base_fare_usd numeric NOT NULL,
  is_active boolean NOT NULL DEFAULT true,
  updated_at timestamptz DEFAULT now(),
  PRIMARY KEY (zone_id, category)
);
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname=''city_fares_base_fare_check'') THEN
    ALTER TABLE public.city_fares ADD CONSTRAINT city_fares_base_fare_check CHECK (base_fare_usd >= 0 AND base_fare_usd <= 99999.99);
  END IF;
END $$;

ALTER TABLE public.city_fares ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "super_admin_manage_city_fares" ON public.city_fares;
CREATE POLICY "super_admin_manage_city_fares" ON public.city_fares
  FOR ALL USING (public.get_user_role((SELECT auth.uid())) = ''super_admin'')
  WITH CHECK (public.get_user_role((SELECT auth.uid())) = ''super_admin'');
DROP POLICY IF EXISTS "encargado_manage_city_fares" ON public.city_fares;
CREATE POLICY "encargado_manage_city_fares" ON public.city_fares
  FOR ALL
  USING (public.get_user_role((SELECT auth.uid())) = ''encargado'' AND zone_id = public.caller_zone_id())
  WITH CHECK (public.get_user_role((SELECT auth.uid())) = ''encargado'' AND zone_id = public.caller_zone_id());
REVOKE ALL ON public.city_fares FROM anon;
GRANT SELECT, INSERT, UPDATE, DELETE ON public.city_fares TO authenticated;
GRANT ALL ON public.city_fares TO service_role;

CREATE OR REPLACE FUNCTION public.get_city_categories(p_zone_id uuid DEFAULT NULL)
RETURNS TABLE(id uuid, name text, display_name text, base_fare_usd numeric, max_passengers integer, description text, icon text, is_active boolean, created_at timestamptz)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT c.id, c.name::text, c.display_name,
         COALESCE(cf.base_fare_usd, c.base_fare_usd),
         c.max_passengers, c.description, c.icon, c.is_active, c.created_at
  FROM public.vehicle_categories c
  LEFT JOIN public.city_fares cf
    ON cf.zone_id = p_zone_id AND cf.category = c.name AND cf.is_active = TRUE
  WHERE c.is_active = TRUE
  ORDER BY COALESCE(cf.base_fare_usd, c.base_fare_usd);
$$;
GRANT EXECUTE ON FUNCTION public.get_city_categories(uuid) TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_city_fare_matrix(p_zone_id uuid)
RETURNS TABLE(category text, display_name text, global_fare numeric, override_fare numeric, effective_fare numeric, is_override boolean)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role public.user_role;
  v_zone uuid := p_zone_id;
BEGIN
  SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;
  IF v_role = ''encargado'' THEN v_zone := public.caller_zone_id();
  ELSIF v_role IS DISTINCT FROM ''super_admin'' THEN RAISE EXCEPTION ''No autorizado''; END IF;
  RETURN QUERY
  SELECT c.name::text, c.display_name, c.base_fare_usd, cf.base_fare_usd,
         COALESCE(cf.base_fare_usd, c.base_fare_usd), (cf.base_fare_usd IS NOT NULL)
  FROM public.vehicle_categories c
  LEFT JOIN public.city_fares cf ON cf.zone_id = v_zone AND cf.category = c.name AND cf.is_active = TRUE
  WHERE c.is_active = TRUE
  ORDER BY c.base_fare_usd;
END; $$;
GRANT EXECUTE ON FUNCTION public.get_city_fare_matrix(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_city_fare_matrix(uuid) FROM anon;

CREATE OR REPLACE FUNCTION public.admin_set_city_fare(p_zone_id uuid, p_category public.vehicle_category, p_base_fare_usd numeric DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_uid uuid := auth.uid();
  v_role public.user_role;
  v_zone uuid := p_zone_id;
BEGIN
  SELECT role INTO v_role FROM public.profiles WHERE id = v_uid;
  IF v_role = ''encargado'' THEN v_zone := public.caller_zone_id();
  ELSIF v_role IS DISTINCT FROM ''super_admin'' THEN RAISE EXCEPTION ''No autorizado''; END IF;
  IF v_zone IS NULL OR NOT EXISTS (SELECT 1 FROM public.zones z WHERE z.id = v_zone AND z.zone_type=''cobertura_general'' AND z.is_active = TRUE) THEN
    RAISE EXCEPTION ''Ciudad invalida'';
  END IF;
  IF p_base_fare_usd IS NULL THEN
    DELETE FROM public.city_fares WHERE zone_id = v_zone AND category = p_category;
    RETURN jsonb_build_object(''success'', true, ''cleared'', true);
  END IF;
  INSERT INTO public.city_fares (zone_id, category, base_fare_usd, is_active, updated_at)
  VALUES (v_zone, p_category, p_base_fare_usd, TRUE, NOW())
  ON CONFLICT (zone_id, category) DO UPDATE SET base_fare_usd = EXCLUDED.base_fare_usd, is_active = TRUE, updated_at = NOW();
  RETURN jsonb_build_object(''success'', true);
END; $$;
GRANT EXECUTE ON FUNCTION public.admin_set_city_fare(uuid, public.vehicle_category, numeric) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.admin_set_city_fare(uuid, public.vehicle_category, numeric) FROM anon;

-- calculate_fare: (ver migracion aplicada; incluye el override COALESCE(city_fares, global))