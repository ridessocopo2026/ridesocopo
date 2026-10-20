-- ============================================================
-- BUNRIDER - Migracion 095: get_commission_rate()
-- Devuelve el % de comision vigente (default de
-- rides.commission_rate) para que el panel del conductor no
-- muestre un numero fijo. Accesible a usuarios con sesion.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_commission_rate()
RETURNS numeric
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT COALESCE(
    NULLIF(regexp_replace(COALESCE(column_default, ''), '[^0-9.\-]', '', 'g'), '')::numeric,
    10
  )
  FROM information_schema.columns
  WHERE table_schema = 'public'
    AND table_name = 'rides'
    AND column_name = 'commission_rate';
$function$;

REVOKE ALL ON FUNCTION public.get_commission_rate() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_commission_rate() TO authenticated, service_role;