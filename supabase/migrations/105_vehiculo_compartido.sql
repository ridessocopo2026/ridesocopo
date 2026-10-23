-- ============================================================
-- 105 - VEHICULO COMPARTIDO (esquema, bloqueo de uso y RLS)
-- ------------------------------------------------------------
-- Permite que DOS conductores usen el mismo vehiculo fisico,
-- pero con reglas estrictas:
--   1) Una sola fila "principal" por placa.
--   2) Maximo UNA fila compartida por principal (2 conductores).
--   3) Un conductor no puede registrar dos veces la misma placa.
--   4) Solo uno de los dos puede estar en linea con ese vehiculo.
--   5) El conductor no puede escribir vehicles directo por PostgREST:
--      todo pasa por las RPC (add_vehicle, onboarding, etc.).
-- ============================================================

ALTER TABLE public.vehicles
  ADD COLUMN IF NOT EXISTS shared_with_vehicle_id uuid;

ALTER TABLE public.profiles
  ADD COLUMN IF NOT EXISTS active_vehicle_plate text;

-- FK e idempotencia (si la columna ya existia sin FK)
DO $do$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'vehicles_shared_with_vehicle_id_fkey'
      AND conrelid = 'public.vehicles'::regclass
  ) THEN
    ALTER TABLE public.vehicles
      ADD CONSTRAINT vehicles_shared_with_vehicle_id_fkey
      FOREIGN KEY (shared_with_vehicle_id)
      REFERENCES public.vehicles(id) ON DELETE SET NULL;
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'vehicles_shared_not_self'
      AND conrelid = 'public.vehicles'::regclass
  ) THEN
    ALTER TABLE public.vehicles
      ADD CONSTRAINT vehicles_shared_not_self
      CHECK (shared_with_vehicle_id IS NULL OR shared_with_vehicle_id <> id);
  END IF;
END
$do$;

-- Normalizar placas existentes
UPDATE public.vehicles
SET plate = upper(btrim(plate))
WHERE plate IS DISTINCT FROM upper(btrim(plate));

-- La unicidad global de placa se reemplaza por las reglas de pareja
ALTER TABLE public.vehicles DROP CONSTRAINT IF EXISTS vehicles_plate_key;

-- Una sola principal por placa (las compartidas quedan fuera de este indice)
CREATE UNIQUE INDEX IF NOT EXISTS vehicles_primary_plate_key
  ON public.vehicles (upper(btrim(plate)))
  WHERE shared_with_vehicle_id IS NULL;

-- Maximo una compartida por principal (=> maximo 2 conductores por placa)
CREATE UNIQUE INDEX IF NOT EXISTS vehicles_shared_primary_key
  ON public.vehicles (shared_with_vehicle_id)
  WHERE shared_with_vehicle_id IS NOT NULL;

-- Un conductor no puede tener dos filas con la misma placa
CREATE UNIQUE INDEX IF NOT EXISTS vehicles_driver_plate_key
  ON public.vehicles (driver_id, upper(btrim(plate)));

CREATE INDEX IF NOT EXISTS idx_vehicles_shared_with
  ON public.vehicles (shared_with_vehicle_id);

-- Backfill del bloqueo de uso: solo conductores aprobados y en linea
UPDATE public.profiles p
SET active_vehicle_plate = (
  SELECT upper(btrim(v.plate))
  FROM public.vehicles v
  WHERE v.driver_id = p.id
    AND v.is_approved = TRUE
    AND v.is_active_vehicle = TRUE
  ORDER BY v.updated_at DESC NULLS LAST
  LIMIT 1
)
WHERE p.role = 'conductor'::public.user_role
  AND p.is_online = TRUE;

UPDATE public.profiles
SET is_online = FALSE,
    active_vehicle_plate = NULL
WHERE is_online = TRUE
  AND (
    role IS DISTINCT FROM 'conductor'::public.user_role
    OR driver_status IS DISTINCT FROM 'aprobado'::public.driver_status
    OR NOT EXISTS (
      SELECT 1 FROM public.vehicles v
      WHERE v.driver_id = profiles.id
        AND v.is_approved = TRUE
        AND v.is_active_vehicle = TRUE
    )
  );

-- Si hubiera dos en linea con la misma placa, dejar solo uno
WITH ranked AS (
  SELECT id,
         row_number() OVER (PARTITION BY active_vehicle_plate ORDER BY updated_at, id) AS rn
  FROM public.profiles
  WHERE is_online = TRUE
    AND active_vehicle_plate IS NOT NULL
)
UPDATE public.profiles p
SET is_online = FALSE,
    active_vehicle_plate = NULL
FROM ranked r
WHERE p.id = r.id
  AND r.rn > 1;

CREATE UNIQUE INDEX IF NOT EXISTS profiles_online_plate_key
  ON public.profiles (active_vehicle_plate)
  WHERE is_online = TRUE
    AND active_vehicle_plate IS NOT NULL;

-- ------------------------------------------------------------
-- Trigger: mantener y validar la placa activa del conductor
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.sync_driver_active_vehicle_plate()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_plate text;
BEGIN
  -- Solo conductores aprobados pueden estar en linea
  IF NEW.role IS DISTINCT FROM 'conductor'::public.user_role
     OR NEW.driver_status IS DISTINCT FROM 'aprobado'::public.driver_status THEN
    NEW.is_online := FALSE;
    NEW.active_vehicle_plate := NULL;
    RETURN NEW;
  END IF;

  IF NEW.is_online IS NOT TRUE THEN
    NEW.active_vehicle_plate := NULL;
    RETURN NEW;
  END IF;

  SELECT upper(btrim(v.plate)) INTO v_plate
  FROM public.vehicles v
  WHERE v.driver_id = NEW.id
    AND v.is_approved = TRUE
    AND v.is_active_vehicle = TRUE
  ORDER BY v.updated_at DESC NULLS LAST
  LIMIT 1;

  IF v_plate IS NULL THEN
    RAISE EXCEPTION 'Selecciona y activa un vehiculo aprobado antes de conectarte.';
  END IF;

  -- El companero tiene un viaje en curso con este mismo vehiculo
  IF EXISTS (
    SELECT 1
    FROM public.rides r
    JOIN public.vehicles rv ON rv.id = r.vehicle_id
    WHERE r.status IN ('aceptada', 'en_ruta', 'incidente')
      AND r.driver_id <> NEW.id
      AND upper(btrim(rv.plate)) = v_plate
  ) THEN
    RAISE EXCEPTION 'Ese vehiculo esta en un viaje en curso con tu companero. Espera a que termine.';
  END IF;

  -- Otro conductor ya esta en linea con este vehiculo (mensaje claro;
  -- el indice unico protege la carrera concurrente)
  IF EXISTS (
    SELECT 1
    FROM public.profiles p
    JOIN public.vehicles pv
      ON pv.driver_id = p.id
     AND pv.is_approved = TRUE
     AND pv.is_active_vehicle = TRUE
    WHERE p.id <> NEW.id
      AND p.is_online = TRUE
      AND upper(btrim(pv.plate)) = v_plate
  ) THEN
    RAISE EXCEPTION 'Ese vehiculo esta en uso por tu companero. Solo uno de los dos puede estar en linea.';
  END IF;

  NEW.active_vehicle_plate := v_plate;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_sync_driver_active_vehicle_plate ON public.profiles;
CREATE TRIGGER trg_sync_driver_active_vehicle_plate
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.sync_driver_active_vehicle_plate();

-- ------------------------------------------------------------
-- Trigger: validar la relacion principal/compartida
-- Se llama trg_a_... para ejecutarse antes del guard de aprobados
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validate_shared_vehicle()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_primary RECORD;
  v_is_admin boolean := FALSE;
  v_uid uuid := auth.uid();
BEGIN
  NEW.plate := upper(btrim(NEW.plate));

  IF NEW.shared_with_vehicle_id IS NOT NULL THEN
    -- El conductor no puede cambiar el vinculo; solo un admin
    IF TG_OP = 'UPDATE'
       AND NEW.shared_with_vehicle_id IS DISTINCT FROM OLD.shared_with_vehicle_id
       AND v_uid IS NOT NULL THEN
      SELECT public.get_user_role(v_uid) IN ('super_admin', 'encargado') INTO v_is_admin;
      IF NOT COALESCE(v_is_admin, FALSE) THEN
        RAISE EXCEPTION 'El vinculo de vehiculo compartido solo lo puede cambiar un administrador';
      END IF;
    END IF;

    SELECT * INTO v_primary
    FROM public.vehicles
    WHERE id = NEW.shared_with_vehicle_id;

    IF v_primary.id IS NULL THEN
      RAISE EXCEPTION 'Vehiculo principal no encontrado';
    END IF;
    IF v_primary.shared_with_vehicle_id IS NOT NULL THEN
      RAISE EXCEPTION 'Un vehiculo compartido no puede ser principal de otro';
    END IF;
    IF v_primary.driver_id = NEW.driver_id THEN
      RAISE EXCEPTION 'El vehiculo compartido debe ser de otro conductor';
    END IF;
    IF upper(btrim(v_primary.plate)) <> NEW.plate THEN
      RAISE EXCEPTION 'La placa del vehiculo compartido debe coincidir con la principal';
    END IF;
  ELSE
    -- La principal con una compartida no puede cambiar de placa por si sola
    IF TG_OP = 'UPDATE'
       AND NEW.plate IS DISTINCT FROM OLD.plate
       AND EXISTS (
         SELECT 1 FROM public.vehicles s
         WHERE s.shared_with_vehicle_id = NEW.id
       ) THEN
      IF v_uid IS NOT NULL THEN
        SELECT public.get_user_role(v_uid) IN ('super_admin', 'encargado') INTO v_is_admin;
        IF NOT COALESCE(v_is_admin, FALSE) THEN
          RAISE EXCEPTION 'Este vehiculo esta compartido. Solicita la correccion al administrador.';
        END IF;
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_a_validate_shared_vehicle ON public.vehicles;
CREATE TRIGGER trg_a_validate_shared_vehicle
  BEFORE INSERT OR UPDATE ON public.vehicles
  FOR EACH ROW EXECUTE FUNCTION public.validate_shared_vehicle();

-- ------------------------------------------------------------
-- RLS: el conductor solo LEE sus vehiculos. Las escrituras
-- pasan por RPC (add_vehicle, onboarding, set_active, delete).
-- ------------------------------------------------------------
ALTER TABLE public.vehicles ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "driver_manage_own_vehicles" ON public.vehicles;
DROP POLICY IF EXISTS "driver_view_own_vehicles" ON public.vehicles;

CREATE POLICY "driver_view_own_vehicles" ON public.vehicles
  FOR SELECT USING ((select auth.uid()) = driver_id);

-- Las funciones de trigger no deben ser invocables por la API
REVOKE ALL ON FUNCTION public.validate_shared_vehicle() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.sync_driver_active_vehicle_plate() FROM PUBLIC, anon, authenticated;

NOTIFY pgrst, 'reload schema';
