-- ============================================================
-- BUNRIDER - Migracion 093: FIX del casteo de driver_status
-- El CASE devolvia text y la columna es del tipo enum driver_status.
-- Se agrega ( ... )::driver_status.
-- ============================================================

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

  INSERT INTO driver_documents (
    driver_id, cedula_number, cedula_photo_url,
    license_number, license_photo_url, license_expiry_date, profile_photo_url
  ) VALUES (
    v_user_id, NULLIF(TRIM(p_cedula_number), ''), NULLIF(TRIM(p_cedula_photo_url), ''),
    NULLIF(TRIM(p_license_number), ''), NULLIF(TRIM(p_license_photo_url), ''),
    p_license_expiry_date, NULLIF(TRIM(p_profile_photo_url), '')
  )
  ON CONFLICT (driver_id) DO UPDATE SET
    cedula_number = COALESCE(EXCLUDED.cedula_number, driver_documents.cedula_number),
    cedula_photo_url = COALESCE(EXCLUDED.cedula_photo_url, driver_documents.cedula_photo_url),
    license_number = COALESCE(EXCLUDED.license_number, driver_documents.license_number),
    license_photo_url = COALESCE(EXCLUDED.license_photo_url, driver_documents.license_photo_url),
    license_expiry_date = COALESCE(EXCLUDED.license_expiry_date, driver_documents.license_expiry_date),
    profile_photo_url = COALESCE(EXCLUDED.profile_photo_url, driver_documents.profile_photo_url);

  SELECT id, driver_id INTO v_vehicle_id, v_vehicle_driver
  FROM vehicles WHERE plate = UPPER(TRIM(p_vehicle_plate));

  IF v_vehicle_id IS NULL THEN
    INSERT INTO vehicles (driver_id, category, brand, model, year, color, plate, photo_url)
    VALUES (
      v_user_id, p_vehicle_category, NULLIF(TRIM(p_vehicle_brand), ''),
      NULLIF(TRIM(p_vehicle_model), ''), p_vehicle_year, NULLIF(TRIM(p_vehicle_color), ''),
      UPPER(TRIM(p_vehicle_plate)), NULLIF(TRIM(p_vehicle_photo_url), '')
    ) RETURNING id INTO v_vehicle_id;
  ELSIF v_vehicle_driver = v_user_id THEN
    UPDATE vehicles SET
      category = p_vehicle_category,
      brand = COALESCE(NULLIF(TRIM(p_vehicle_brand), ''), brand),
      model = COALESCE(NULLIF(TRIM(p_vehicle_model), ''), model),
      year = COALESCE(p_vehicle_year, year),
      color = COALESCE(NULLIF(TRIM(p_vehicle_color), ''), color),
      photo_url = COALESCE(NULLIF(TRIM(p_vehicle_photo_url), ''), photo_url)
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

  RETURN jsonb_build_object('success', TRUE, 'status', v_status);
END;
$function$;