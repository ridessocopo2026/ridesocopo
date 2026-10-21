-- ============================================================
-- 100 - ESTADO DEL PERFIL DEL CONDUCTOR (FUENTE UNICA)
-- ============================================================

CREATE OR REPLACE FUNCTION public.driver_docs_complete(p_driver_id uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT EXISTS (
    SELECT 1
    FROM driver_documents d
    WHERE d.driver_id = p_driver_id
      AND NULLIF(BTRIM(COALESCE(d.cedula_number, '')), '') IS NOT NULL
      AND NULLIF(BTRIM(COALESCE(d.cedula_photo_url, '')), '') IS NOT NULL
      AND NULLIF(BTRIM(COALESCE(d.license_photo_url, '')), '') IS NOT NULL
      AND d.license_expiry_date IS NOT NULL
  );
$function$;

CREATE OR REPLACE FUNCTION public.get_driver_profile_state()
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_profile RECORD;
  v_docs RECORD;
  v_missing text[] := ARRAY[]::text[];
  v_vehicle_count integer := 0;
  v_approved_count integer := 0;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT * INTO v_profile FROM profiles WHERE id = v_uid;
  IF v_profile.id IS NULL THEN
    RAISE EXCEPTION 'Perfil no encontrado';
  END IF;

  SELECT * INTO v_docs FROM driver_documents WHERE driver_id = v_uid;

  SELECT count(*), count(*) FILTER (WHERE is_approved)
    INTO v_vehicle_count, v_approved_count
  FROM vehicles
  WHERE driver_id = v_uid;

  IF NULLIF(BTRIM(COALESCE(v_profile.full_name, '')), '') IS NULL THEN
    v_missing := array_append(v_missing, 'full_name');
  END IF;

  IF NULLIF(BTRIM(COALESCE(v_profile.phone, '')), '') IS NULL THEN
    v_missing := array_append(v_missing, 'phone');
  END IF;

  IF v_docs.id IS NULL THEN
    v_missing := array_append(v_missing, 'documents');
  ELSE
    IF NULLIF(BTRIM(COALESCE(v_docs.cedula_number, '')), '') IS NULL THEN
      v_missing := array_append(v_missing, 'cedula_number');
    END IF;
    IF NULLIF(BTRIM(COALESCE(v_docs.cedula_photo_url, '')), '') IS NULL THEN
      v_missing := array_append(v_missing, 'cedula_photo');
    END IF;
    IF NULLIF(BTRIM(COALESCE(v_docs.license_photo_url, '')), '') IS NULL THEN
      v_missing := array_append(v_missing, 'license_photo');
    END IF;
    IF v_docs.license_expiry_date IS NULL THEN
      v_missing := array_append(v_missing, 'license_expiry');
    END IF;
  END IF;

  IF v_vehicle_count = 0 THEN
    v_missing := array_append(v_missing, 'vehicle');
  END IF;

  RETURN jsonb_build_object(
    'approved', COALESCE(v_profile.driver_status = 'aprobado', FALSE),
    'complete', COALESCE(array_length(v_missing, 1), 0) = 0,
    'missing', to_jsonb(v_missing),
    'has_vehicle', v_vehicle_count > 0,
    'has_approved_vehicle', v_approved_count > 0,
    'pending_request', EXISTS (
      SELECT 1 FROM driver_change_requests
      WHERE driver_id = v_uid AND status = 'pendiente'
    ),
    'license_expired', (v_docs.license_expiry_date IS NOT NULL AND v_docs.license_expiry_date < CURRENT_DATE),
    'phone', v_profile.phone,
    'documents', CASE WHEN v_docs.id IS NULL THEN NULL ELSE jsonb_build_object(
      'cedula_number', v_docs.cedula_number,
      'cedula_photo_url', v_docs.cedula_photo_url,
      'license_number', v_docs.license_number,
      'license_photo_url', v_docs.license_photo_url,
      'license_expiry_date', v_docs.license_expiry_date
    ) END
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.driver_docs_complete(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.driver_docs_complete(uuid) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.get_driver_profile_state() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_driver_profile_state() TO authenticated, service_role;
