-- ============================================================
-- 109 - CODIGO DE VIAJE ALEATORIO (SOLO NUMEROS)
-- ============================================================
-- Reemplaza la secuencia RS-000001, RS-000002... por un codigo
-- aleatorio de 6 digitos, sin duplicados.
--
-- Unicidad:
--   1) tracking_code ya tiene UNIQUE.
--   2) El trigger comprueba que el codigo no exista.
--   3) Un advisory lock evita colisiones entre inserts concurrentes.
--   4) Reintenta hasta 50 veces si el codigo ya esta ocupado.
-- ============================================================

-- 1) Generador: RS-000000 ... RS-999999
CREATE OR REPLACE FUNCTION public.generate_tracking_code()
RETURNS text
LANGUAGE plpgsql
VOLATILE
SET search_path = public
AS $function$
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
$function$;

-- 2) Trigger: asigna el codigo y reintenta si ya existe
CREATE OR REPLACE FUNCTION public.assign_tracking_code()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
  v_attempt integer := 0;
BEGIN
  IF NEW.tracking_code IS NOT NULL THEN
    RETURN NEW;
  END IF;

  -- Serializa solo la asignacion de codigos. El lock se libera al
  -- terminar la transaccion del insert.
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
$function$;

-- Recrear trigger por si no existe o apunta a otra funcion
DROP TRIGGER IF EXISTS trg_assign_tracking_code ON public.rides;
CREATE TRIGGER trg_assign_tracking_code
  BEFORE INSERT ON public.rides
  FOR EACH ROW EXECUTE FUNCTION public.assign_tracking_code();

-- 3) Backfill: quitar los codigos secuenciales existentes
DO $block$
DECLARE
  v_ride RECORD;
  v_code text;
  v_attempt integer;
BEGIN
  PERFORM pg_advisory_xact_lock(hashtext('public.assign_tracking_code'));

  FOR v_ride IN
    SELECT id
    FROM public.rides
    ORDER BY created_at
  LOOP
    v_attempt := 0;

    LOOP
      v_attempt := v_attempt + 1;
      v_code := public.generate_tracking_code();

      EXIT WHEN NOT EXISTS (
        SELECT 1
        FROM public.rides
        WHERE tracking_code = v_code
      );

      IF v_attempt >= 50 THEN
        RAISE EXCEPTION 'No se pudo generar un codigo unico para el viaje %', v_ride.id;
      END IF;
    END LOOP;

    UPDATE public.rides
    SET tracking_code = v_code
    WHERE id = v_ride.id;
  END LOOP;
END;
$block$;

-- 4) El generador es interno: solo lo usa el trigger (security definer)
REVOKE ALL ON FUNCTION public.generate_tracking_code() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.generate_tracking_code() FROM anon, authenticated;

-- 5) La secuencia anterior queda obsoleta (no se elimina para no romper
-- scripts antiguos que pudieran consultarla).
COMMENT ON SEQUENCE public.tracking_code_seq IS
  'Obsoleta desde migracion 109: los codigos ahora son aleatorios.';

NOTIFY pgrst, 'reload schema';

-- Verificacion
SELECT 'Codigos aleatorios aplicados' AS estado,
       COUNT(*) AS viajes,
       COUNT(DISTINCT tracking_code) AS codigos_unicos,
       COUNT(*) FILTER (WHERE tracking_code !~ '^RS-[0-9]{6}$') AS codigos_invalidos
FROM public.rides;
