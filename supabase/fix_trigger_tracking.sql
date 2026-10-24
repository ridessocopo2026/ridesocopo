-- ============================================================
-- RIDESOCOPÓ - FIX: TRIGGER TRACKING_CODE
-- ============================================================
-- Mantiene este script alineado con la migración 109:
--   RS- + 6 dígitos aleatorios, sin duplicados.
--
-- No volver a usar la secuencia tracking_code_seq.
-- Para reasignar los códigos de viajes existentes, aplicar
-- supabase/migrations/109_codigo_viaje_aleatorio.sql
-- ============================================================

CREATE OR REPLACE FUNCTION public.generate_tracking_code()
RETURNS text
LANGUAGE plpgsql
VOLATILE
SET search_path = public
AS $$
DECLARE
  v_bytes bytea := pg_catalog.uuid_send(pg_catalog.gen_random_uuid());
  v_num bigint;
BEGIN
  v_num := (
    (get_byte(v_bytes, 0)::bigint * 16777216) +
    (get_byte(v_bytes, 1)::bigint * 65536) +
    (get_byte(v_bytes, 2)::bigint * 256) +
    get_byte(v_bytes, 3)::bigint
  ) % 1000000;

  RETURN 'RS-' || lpad(v_num::text, 6, '0');
END;
$$;

CREATE OR REPLACE FUNCTION public.assign_tracking_code()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_attempt integer := 0;
BEGIN
  IF NEW.tracking_code IS NOT NULL THEN
    RETURN NEW;
  END IF;

  PERFORM pg_advisory_xact_lock(hashtext('public.assign_tracking_code'));

  LOOP
    v_attempt := v_attempt + 1;
    NEW.tracking_code := public.generate_tracking_code();

    EXIT WHEN NOT EXISTS (
      SELECT 1
      FROM public.rides
      WHERE tracking_code = NEW.tracking_code
    );

    IF v_attempt >= 50 THEN
      RAISE EXCEPTION 'No se pudo generar un codigo de viaje unico';
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

-- Recrear el trigger por si no está
DROP TRIGGER IF EXISTS trg_assign_tracking_code ON public.rides;
CREATE TRIGGER trg_assign_tracking_code
  BEFORE INSERT ON public.rides
  FOR EACH ROW EXECUTE FUNCTION public.assign_tracking_code();

REVOKE ALL ON FUNCTION public.generate_tracking_code() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.generate_tracking_code() FROM anon, authenticated;

NOTIFY pgrst, 'reload schema';

SELECT '✅ Trigger tracking_code reparado (RS + 6 dígitos aleatorios)' AS estado;