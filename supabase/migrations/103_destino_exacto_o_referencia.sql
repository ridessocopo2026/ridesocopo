-- ============================================================
-- 103 - DESTINO EXACTO O REFERENCIA DE SECTOR
-- Si el cliente marca un pin exacto, la ruta es exacta.
-- Si no, el destino es el punto de referencia del barrio.
-- ============================================================

ALTER TABLE public.rides
  ADD COLUMN IF NOT EXISTS destination_is_exact boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.set_ride_destination_exact()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_barrio RECORD;
BEGIN
  NEW.destination_is_exact := FALSE;

  IF NEW.destination_barrio_id IS NOT NULL THEN
    SELECT lat, lng INTO v_barrio
    FROM public.barrios
    WHERE id = NEW.destination_barrio_id;

    IF v_barrio.lat IS NOT NULL AND v_barrio.lng IS NOT NULL THEN
      -- ~11 m de tolerancia: si el pin coincide con el punto del sector,
      -- se considera referencia; si se movió, es un punto exacto.
      NEW.destination_is_exact := (
        abs(NEW.destination_lat - v_barrio.lat) > 0.0001
        OR abs(NEW.destination_lng - v_barrio.lng) > 0.0001
      );
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_set_ride_destination_exact ON public.rides;
CREATE TRIGGER trg_set_ride_destination_exact
  BEFORE INSERT ON public.rides
  FOR EACH ROW EXECUTE FUNCTION public.set_ride_destination_exact();

-- Backfill: los viajes existentes usaban el punto del barrio (referencia).
UPDATE public.rides
SET destination_is_exact = FALSE
WHERE destination_is_exact IS DISTINCT FROM FALSE;
