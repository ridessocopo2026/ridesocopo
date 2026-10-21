-- ============================================================
-- 097 - PASAJEROS POR VEHICULO
-- - vehicles.max_passengers (default por categoria).
-- - Trigger: motos de 2 ruedas = 1; resto 1..max de la categoria.
-- - RPC set_vehicle_passengers para crear/editar de forma segura.
-- - register_driver_onboarding devuelve tambien vehicle_id.
-- ============================================================

ALTER TABLE public.vehicles ADD COLUMN IF NOT EXISTS max_passengers integer;

UPDATE public.vehicles v
SET max_passengers = COALESCE(vc.max_passengers, 1)
FROM public.vehicle_categories vc
WHERE vc.name = v.category
  AND (v.max_passengers IS NULL OR v.max_passengers > 1);

UPDATE public.vehicles
SET max_passengers = 1
WHERE max_passengers IS NULL OR max_passengers > 1;

ALTER TABLE public.vehicles ALTER COLUMN max_passengers SET DEFAULT 1;
ALTER TABLE public.vehicles ALTER COLUMN max_passengers SET NOT NULL;

CREATE OR REPLACE FUNCTION public.enforce_vehicle_passengers()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_cat_max integer;
BEGIN
  -- Motos de 2 ruedas: siempre 1 pasajero
  IF NEW.category::text IN ('moto_basica', 'moto_lujo', 'moto_carga', 'moto') THEN
    NEW.max_passengers := 1;
    RETURN NEW;
  END IF;

  SELECT max_passengers INTO v_cat_max
  FROM vehicle_categories
  WHERE name = NEW.category;

  IF NEW.max_passengers IS NULL OR NEW.max_passengers > 1 THEN
    NEW.max_passengers := COALESCE(v_cat_max, 1);
  END IF;

  IF v_cat_max IS NOT NULL AND NEW.max_passengers > v_cat_max THEN
    NEW.max_passengers := v_cat_max;
  END IF;

  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS trg_enforce_vehicle_passengers ON public.vehicles;
CREATE TRIGGER trg_enforce_vehicle_passengers
  BEFORE INSERT OR UPDATE ON public.vehicles
  FOR EACH ROW EXECUTE FUNCTION public.enforce_vehicle_passengers();

CREATE OR REPLACE FUNCTION public.set_vehicle_passengers(p_vehicle_id uuid, p_max_passengers integer)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_driver_id uuid := auth.uid();
  v_vehicle RECORD;
  v_result integer;
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('set_vehicle_passengers', 20);

  SELECT * INTO v_vehicle FROM vehicles WHERE id = p_vehicle_id;
  IF v_vehicle.id IS NULL THEN
    RAISE EXCEPTION 'Vehículo no encontrado';
  END IF;
  IF v_vehicle.driver_id <> v_driver_id THEN
    RAISE EXCEPTION 'No es tu vehículo';
  END IF;

  UPDATE vehicles
  SET max_passengers = p_max_passengers,
      updated_at = NOW()
  WHERE id = p_vehicle_id;

  SELECT max_passengers INTO v_result FROM vehicles WHERE id = p_vehicle_id;

  RETURN jsonb_build_object('success', TRUE, 'vehicle_id', p_vehicle_id, 'max_passengers', v_result);
END;
$function$;

REVOKE ALL ON FUNCTION public.set_vehicle_passengers(uuid, integer) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_vehicle_passengers(uuid, integer) TO authenticated, service_role;
-- register_driver_onboarding: misma firma, ahora devuelve vehicle_id
CREATE OR REPLACE FUNCTION public.register_driver_onboarding(
  p_full_name text,
  p_phone text,
  p_cedula_number text,
  p_cedula_photo_url text,
  p_license_number text,
  p_license_photo_url text,
  p_license_expiry_date date,
  p_profile_photo_url text,
  p_vehicle_category vehicle_category,
  p_vehicle_brand text,
  p_vehicle_model text,
  p_vehicle_year integer,
  p_vehicle_color text,
  p_vehicle_plate text,
  p_vehicle_photo_url text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id UUID := auth.uid();
  v_vehicle_id UUID;
  v_vehicle_driver UUID;
  v_status driver_status;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  IF NOT public.is_account_active(v_user_id) THEN
    RAISE EXCEPTION 'Tu cuenta no está activa. Contacta a soporte.';
  END IF;

  IF p_vehicle_plate IS NULL OR TRIM(p_vehicle_plate) = '' THEN
    RAISE EXCEPTION 'La placa del vehículo es obligatoria';
  END IF;

  UPDATE profiles
  SET full_name = COALESCE(NULLIF(TRIM(p_full_name), ''), full_name),
      phone = COALESCE(NULLIF(TRIM(p_phone), ''), phone),
      role = 'conductor',
      driver_status = (CASE WHEN driver_status = 'aprobado' THEN 'aprobado' ELSE 'pendiente' END)::driver_status,
      onboarding_completed = TRUE
  WHERE id = v_user_id;

  IF EXISTS (SELECT 1 FROM driver_documents WHERE driver_id = v_user_id) THEN
    UPDATE driver_documents SET
      cedula_number = COALESCE(NULLIF(TRIM(p_cedula_number), ''), cedula_number),
      cedula_photo_url = COALESCE(NULLIF(TRIM(p_cedula_photo_url), ''), cedula_photo_url),
      license_number = COALESCE(NULLIF(TRIM(p_license_number), ''), license_number),
      license_photo_url = COALESCE(NULLIF(TRIM(p_license_photo_url), ''), license_photo_url),
      license_expiry_date = COALESCE(p_license_expiry_date, license_expiry_date),
      profile_photo_url = COALESCE(NULLIF(TRIM(p_profile_photo_url), ''), profile_photo_url),
      updated_at = NOW()
    WHERE driver_id = v_user_id;
  ELSE
    IF NULLIF(TRIM(p_cedula_number), '') IS NULL THEN
      RAISE EXCEPTION 'Falta el número de cédula';
    END IF;
    IF NULLIF(TRIM(p_cedula_photo_url), '') IS NULL THEN
      RAISE EXCEPTION 'Falta la foto de la cédula';
    END IF;
    IF NULLIF(TRIM(p_license_photo_url), '') IS NULL THEN
      RAISE EXCEPTION 'Falta la foto de la licencia';
    END IF;
    IF p_license_expiry_date IS NULL THEN
      RAISE EXCEPTION 'Falta el vencimiento de la licencia';
    END IF;

    INSERT INTO driver_documents (
      driver_id, cedula_number, cedula_photo_url,
      license_number, license_photo_url, license_expiry_date, profile_photo_url
    ) VALUES (
      v_user_id, TRIM(p_cedula_number), TRIM(p_cedula_photo_url),
      NULLIF(TRIM(p_license_number), ''), TRIM(p_license_photo_url),
      p_license_expiry_date, NULLIF(TRIM(p_profile_photo_url), '')
    );
  END IF;

  SELECT id, driver_id INTO v_vehicle_id, v_vehicle_driver
  FROM vehicles WHERE plate = UPPER(TRIM(p_vehicle_plate));

  IF v_vehicle_id IS NULL THEN
    IF NULLIF(TRIM(p_vehicle_brand), '') IS NULL
       OR NULLIF(TRIM(p_vehicle_model), '') IS NULL
       OR p_vehicle_year IS NULL
       OR NULLIF(TRIM(p_vehicle_color), '') IS NULL THEN
      RAISE EXCEPTION 'Completa los datos del vehículo';
    END IF;

    INSERT INTO vehicles (driver_id, category, brand, model, year, color, plate, photo_url)
    VALUES (
      v_user_id, p_vehicle_category, TRIM(p_vehicle_brand),
      TRIM(p_vehicle_model), p_vehicle_year, TRIM(p_vehicle_color),
      UPPER(TRIM(p_vehicle_plate)), NULLIF(TRIM(p_vehicle_photo_url), '')
    ) RETURNING id INTO v_vehicle_id;
  ELSIF v_vehicle_driver = v_user_id THEN
    UPDATE vehicles SET
      category = p_vehicle_category,
      brand = COALESCE(NULLIF(TRIM(p_vehicle_brand), ''), brand),
      model = COALESCE(NULLIF(TRIM(p_vehicle_model), ''), model),
      year = COALESCE(p_vehicle_year, year),
      color = COALESCE(NULLIF(TRIM(p_vehicle_color), ''), color),
      photo_url = COALESCE(NULLIF(TRIM(p_vehicle_photo_url), ''), photo_url),
      updated_at = NOW()
    WHERE id = v_vehicle_id;
  ELSE
    RAISE EXCEPTION 'La placa % ya está registrada por otro conductor', UPPER(TRIM(p_vehicle_plate));
  END IF;

  SELECT driver_status INTO v_status FROM profiles WHERE id = v_user_id;

  IF v_status <> 'aprobado' THEN
    INSERT INTO notifications (user_id, title, body, type, data)
    SELECT id, 'Nuevo conductor pendiente',
           COALESCE(p_full_name, 'Un conductor') || ' ha solicitado ser conductor',
           'driver_pending',
           jsonb_build_object('driver_id', v_user_id, 'url', '/admin/conductores')
    FROM profiles WHERE role IN ('super_admin', 'encargado');
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'status', v_status, 'vehicle_id', v_vehicle_id);
END;
$function$;