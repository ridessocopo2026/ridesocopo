-- ============================================================
-- BUNRIDER - Migracion 096: guardar "Limite en USD"
-- wallets no tiene politica UPDATE (solo SELECT), por eso el
-- update desde el navegador no guardaba. Se usa un RPC seguro.
-- Tambien se agrega debt_limit_usd a get_admin_settings.
-- ============================================================

CREATE OR REPLACE FUNCTION public.admin_set_debt_limit(p_limit numeric)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_n integer := 0;
BEGIN
  IF v_uid IS NULL OR public.get_user_role(v_uid) IS DISTINCT FROM 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF p_limit IS NULL OR p_limit < 0 OR p_limit > 10000 THEN
    RAISE EXCEPTION 'Límite inválido (debe estar entre 0 y 10000)';
  END IF;

  UPDATE wallets
  SET debt_limit_usd = p_limit,
      updated_at = NOW()
  WHERE is_blocked = false;

  GET DIAGNOSTICS v_n = ROW_COUNT;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_uid, 'SET_DEBT_LIMIT', 'settings', NULL,
          jsonb_build_object('debt_limit_usd', p_limit, 'wallets_actualizadas', v_n));

  RETURN jsonb_build_object('success', TRUE, 'debt_limit_usd', p_limit, 'updated', v_n);
END;
$function$;

REVOKE ALL ON FUNCTION public.admin_set_debt_limit(numeric) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_debt_limit(numeric) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_admin_settings()
RETURNS jsonb
LANGUAGE plpgsql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_default text;
  v_rate numeric;
  v_debt numeric;
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

  SELECT w.debt_limit_usd INTO v_debt
  FROM wallets w
  WHERE w.is_blocked = false
  ORDER BY w.updated_at DESC NULLS LAST
  LIMIT 1;

  RETURN jsonb_build_object(
    'new_ride_alerts', COALESCE((SELECT new_ride_alerts FROM public.push_settings LIMIT 1), true),
    'commission_rate', v_rate,
    'debt_limit_usd', COALESCE(v_debt, 5)
  );
END;
$function$;