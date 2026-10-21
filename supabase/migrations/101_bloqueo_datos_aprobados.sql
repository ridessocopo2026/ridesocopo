-- ============================================================
-- 101 - BLOQUEO DE DATOS CUANDO EL CONDUCTOR ESTA APROBADO
-- Los admin/encargados siguen pudiendo escribir (revisiones).
-- ============================================================

-- 1) DOCUMENTOS: un aprobado con docs completos no puede cambiarlos.
CREATE OR REPLACE FUNCTION public.guard_approved_driver_documents()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_driver_id uuid;
  v_status driver_status;
  v_is_admin boolean;
BEGIN
  v_driver_id := COALESCE(NEW.driver_id, OLD.driver_id);

  IF v_uid IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT public.get_user_role(v_uid) IN ('super_admin', 'encargado') INTO v_is_admin;
  IF v_is_admin THEN
    RETURN NEW;
  END IF;

  SELECT driver_status INTO v_status FROM profiles WHERE id = v_driver_id;
  IF v_status = 'aprobado' AND public.driver_docs_complete(v_driver_id) THEN
    RAISE EXCEPTION 'Tus documentos están verificados. Solicita una corrección desde tu perfil.';
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_guard_approved_driver_documents ON public.driver_documents;
CREATE TRIGGER trg_guard_approved_driver_documents
  BEFORE INSERT OR UPDATE ON public.driver_documents
  FOR EACH ROW EXECUTE FUNCTION public.guard_approved_driver_documents();

-- 2) VEHICULOS: nada de auto-aprobacion y no se edita un vehiculo aprobado.
CREATE OR REPLACE FUNCTION public.guard_approved_driver_vehicle()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_is_admin boolean;
BEGIN
  IF v_uid IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT public.get_user_role(v_uid) IN ('super_admin', 'encargado') INTO v_is_admin;
  IF v_is_admin THEN
    RETURN NEW;
  END IF;

  IF TG_OP = 'INSERT' THEN
    NEW.is_approved := FALSE;
    NEW.is_active_vehicle := FALSE;
    RETURN NEW;
  END IF;

  IF COALESCE(OLD.is_approved, FALSE) THEN
    IF NEW.category IS DISTINCT FROM OLD.category
       OR NEW.brand IS DISTINCT FROM OLD.brand
       OR NEW.model IS DISTINCT FROM OLD.model
       OR NEW.year IS DISTINCT FROM OLD.year
       OR NEW.color IS DISTINCT FROM OLD.color
       OR NEW.plate IS DISTINCT FROM OLD.plate
       OR NEW.photo_url IS DISTINCT FROM OLD.photo_url THEN
      RAISE EXCEPTION 'Tu vehículo está aprobado. Solicita una corrección desde tu perfil.';
    END IF;
    NEW.is_approved := OLD.is_approved;
  ELSE
    NEW.is_approved := FALSE;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_guard_approved_driver_vehicle ON public.vehicles;
CREATE TRIGGER trg_guard_approved_driver_vehicle
  BEFORE INSERT OR UPDATE ON public.vehicles
  FOR EACH ROW EXECUTE FUNCTION public.guard_approved_driver_vehicle();

-- 3) PERFIL: nombre y telefono de un aprobado quedan bloqueados.
CREATE OR REPLACE FUNCTION public.guard_approved_driver_profile()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_is_admin boolean;
BEGIN
  IF v_uid IS NULL THEN
    RETURN NEW;
  END IF;

  SELECT public.get_user_role(v_uid) IN ('super_admin', 'encargado') INTO v_is_admin;
  IF v_is_admin THEN
    RETURN NEW;
  END IF;

  IF OLD.role = 'conductor' AND OLD.driver_status = 'aprobado' THEN
    IF NEW.full_name IS DISTINCT FROM OLD.full_name THEN
      RAISE EXCEPTION 'Tu nombre está verificado. Usa la solicitud de cambio de nombre.';
    END IF;
    IF NEW.phone IS DISTINCT FROM OLD.phone THEN
      RAISE EXCEPTION 'Tu teléfono está verificado. Solicita una corrección desde tu perfil.';
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_guard_approved_driver_profile ON public.profiles;
CREATE TRIGGER trg_guard_approved_driver_profile
  BEFORE UPDATE ON public.profiles
  FOR EACH ROW EXECUTE FUNCTION public.guard_approved_driver_profile();
