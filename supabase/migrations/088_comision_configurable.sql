-- ============================================================
-- BUNRIDER - Migracion 088: COMISION CONFIGURABLE
-- ------------------------------------------------------------
-- Antes: el % de comision estaba fijo en 10.00 (default de la
-- columna rides.commission_rate). AdminConfig lo mostraba pero
-- NO lo guardaba (era decorativo).
--
-- set_commission_rate() cambia el DEFAULT de rides.commission_rate.
-- El DEFAULT se evalua al INSERTAR, asi que solo aplica a viajes
-- NUEVOS: el historico queda intacto. ALTER ... SET DEFAULT es solo
-- metadata (instantaneo, sin reescritura de tabla, sin costo extra).
--
-- get_admin_settings() ahora devuelve tambien 'commission_rate'.
-- ============================================================

CREATE OR REPLACE FUNCTION public.set_commission_rate(p_rate numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
BEGIN
  IF v_uid IS NULL OR public.get_user_role(v_uid) IS DISTINCT FROM 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF p_rate IS NULL OR p_rate < 0 OR p_rate > 100 THEN
    RAISE EXCEPTION 'Porcentaje de comision invalido (0 a 100)';
  END IF;

  EXECUTE format('ALTER TABLE public.rides ALTER COLUMN commission_rate SET DEFAULT %s', p_rate::numeric);

  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_uid, 'SET_COMMISSION_RATE', 'settings', NULL,
          jsonb_build_object('commission_rate', p_rate));

  RETURN jsonb_build_object('success', true, 'commission_rate', p_rate);
END;
$function$;

REVOKE ALL ON FUNCTION public.set_commission_rate(numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_commission_rate(numeric) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_admin_settings()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_default text;
  v_rate numeric;
BEGIN
  IF public.get_user_role(auth.uid()) != 'super_admin' THEN RAISE EXCEPTION 'No autorizado'; END IF;

  SELECT c.column_default INTO v_default
  FROM information_schema.columns c
  WHERE c.table_schema = 'public'
    AND c.table_name = 'rides'
    AND c.column_name = 'commission_rate';

  v_rate := COALESCE(
    NULLIF(regexp_replace(COALESCE(v_default, ''), '[^0-9.\-]', '', 'g'), '')::numeric,
    10
  );

  RETURN jsonb_build_object(
    'new_ride_alerts', COALESCE((SELECT new_ride_alerts FROM public.push_settings LIMIT 1), true),
    'commission_rate', v_rate
  );
END;
$function$;