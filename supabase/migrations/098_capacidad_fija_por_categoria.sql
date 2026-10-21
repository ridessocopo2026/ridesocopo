-- ============================================================
-- 098 - CAPACIDAD DE PASAJEROS FIJA POR CATEGORIA
-- La capacidad deja de ser editable por el conductor:
-- vehicles.max_passengers es un espejo de vehicle_categories.
-- Nota: set_vehicle_passengers (097) queda inactivo: el trigger de vehicles
-- sobrescribe cualquier valor con el de la categoria.
-- ============================================================

-- 1) El trigger siempre copia el maximo de la categoria (motos incluidas).
CREATE OR REPLACE FUNCTION public.enforce_vehicle_passengers()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_cat_max integer;
BEGIN
  SELECT max_passengers INTO v_cat_max
  FROM public.vehicle_categories
  WHERE name = NEW.category;

  NEW.max_passengers := COALESCE(v_cat_max, 1);
  RETURN NEW;
END;
$function$;

-- 2) Normalizar los vehiculos existentes a la capacidad de su categoria.
UPDATE public.vehicles v
SET max_passengers = COALESCE(vc.max_passengers, 1)
FROM public.vehicle_categories vc
WHERE vc.name = v.category;

UPDATE public.vehicles
SET max_passengers = 1
WHERE max_passengers IS NULL;

-- 3) Si el admin cambia la capacidad de una categoria, propagarla a sus vehiculos.
CREATE OR REPLACE FUNCTION public.sync_vehicle_passengers_from_category()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
BEGIN
  UPDATE public.vehicles
  SET max_passengers = NEW.max_passengers
  WHERE category = NEW.name
    AND max_passengers IS DISTINCT FROM NEW.max_passengers;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_sync_vehicle_passengers ON public.vehicle_categories;
CREATE TRIGGER trg_sync_vehicle_passengers
  AFTER UPDATE OF max_passengers ON public.vehicle_categories
  FOR EACH ROW
  WHEN (OLD.max_passengers IS DISTINCT FROM NEW.max_passengers)
  EXECUTE FUNCTION public.sync_vehicle_passengers_from_category();