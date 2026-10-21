-- ============================================================
-- 099 - SOLICITUDES DE CORRECCION DE DATOS DEL CONDUCTOR
-- Un conductor aprobado no edita directo: solicita, el admin aprueba.
-- ============================================================

DO $do$
BEGIN
  CREATE TYPE public.driver_change_kind AS ENUM ('documents', 'vehicle', 'phone');
EXCEPTION WHEN duplicate_object THEN NULL;
END
$do$;

DO $do$
BEGIN
  CREATE TYPE public.driver_change_status AS ENUM ('pendiente', 'aprobado', 'rechazado');
EXCEPTION WHEN duplicate_object THEN NULL;
END
$do$;

CREATE TABLE IF NOT EXISTS public.driver_change_requests (
  id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
  driver_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
  kind public.driver_change_kind NOT NULL,
  payload jsonb NOT NULL,
  status public.driver_change_status NOT NULL DEFAULT 'pendiente',
  reviewed_by uuid REFERENCES public.profiles(id),
  reviewed_at timestamp with time zone,
  rejection_reason text,
  created_at timestamp with time zone NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS one_pending_change_per_driver
  ON public.driver_change_requests (driver_id)
  WHERE status = 'pendiente';

CREATE INDEX IF NOT EXISTS idx_driver_change_requests_status
  ON public.driver_change_requests (status, created_at DESC);

ALTER TABLE public.driver_change_requests ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "driver_view_own_change_requests" ON public.driver_change_requests;
CREATE POLICY "driver_view_own_change_requests" ON public.driver_change_requests
  FOR SELECT USING (auth.uid() = driver_id);

DROP POLICY IF EXISTS "admin_view_change_requests" ON public.driver_change_requests;
CREATE POLICY "admin_view_change_requests" ON public.driver_change_requests
  FOR SELECT USING (public.get_user_role(auth.uid()) IN ('super_admin', 'encargado'));

REVOKE ALL ON public.driver_change_requests FROM anon;
GRANT SELECT ON public.driver_change_requests TO authenticated;

-- ------------------------------------------------------------
-- Solicitar correccion (solo conductor aprobado)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.request_driver_change(
  p_kind public.driver_change_kind,
  p_payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_profile RECORD;
  v_payload jsonb;
  v_vehicle_id uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('request_driver_change', 5);

  SELECT * INTO v_profile FROM profiles WHERE id = v_uid;
  IF v_profile.id IS NULL THEN
    RAISE EXCEPTION 'Perfil no encontrado';
  END IF;
  IF v_profile.role <> 'conductor' THEN
    RAISE EXCEPTION 'Solo los conductores pueden solicitar correcciones';
  END IF;
  IF v_profile.driver_status <> 'aprobado' THEN
    RAISE EXCEPTION 'Tu cuenta aún no está aprobada';
  END IF;

  IF p_kind = 'phone' THEN
    v_payload := jsonb_build_object('phone', NULLIF(BTRIM(p_payload->>'phone'), ''));
    IF v_payload->>'phone' IS NULL OR LENGTH(v_payload->>'phone') < 7 THEN
      RAISE EXCEPTION 'Teléfono inválido';
    END IF;

  ELSIF p_kind = 'documents' THEN
    v_payload := jsonb_build_object(
      'cedula_number', NULLIF(BTRIM(p_payload->>'cedula_number'), ''),
      'cedula_photo_url', NULLIF(BTRIM(p_payload->>'cedula_photo_url'), ''),
      'license_number', NULLIF(BTRIM(p_payload->>'license_number'), ''),
      'license_photo_url', NULLIF(BTRIM(p_payload->>'license_photo_url'), ''),
      'license_expiry_date', NULLIF(BTRIM(p_payload->>'license_expiry_date'), '')
    );

    IF v_payload->>'cedula_number' IS NULL
       OR v_payload->>'cedula_photo_url' IS NULL
       OR v_payload->>'license_photo_url' IS NULL
       OR v_payload->>'license_expiry_date' IS NULL THEN
      RAISE EXCEPTION 'Completa los documentos requeridos';
    END IF;

    BEGIN
      IF (v_payload->>'license_expiry_date')::date < CURRENT_DATE THEN
        RAISE EXCEPTION 'La licencia está vencida';
      END IF;
    EXCEPTION WHEN invalid_datetime_format THEN
      RAISE EXCEPTION 'Fecha de vencimiento inválida';
    END;

  ELSIF p_kind = 'vehicle' THEN
    IF NULLIF(BTRIM(p_payload->>'vehicle_id'), '') IS NULL THEN
      RAISE EXCEPTION 'Vehículo no indicado';
    END IF;

    v_vehicle_id := (p_payload->>'vehicle_id')::uuid;
    IF NOT EXISTS (SELECT 1 FROM vehicles WHERE id = v_vehicle_id AND driver_id = v_uid) THEN
      RAISE EXCEPTION 'Ese vehículo no es tuyo';
    END IF;

    v_payload := jsonb_build_object(
      'vehicle_id', v_vehicle_id,
      'category', NULLIF(BTRIM(p_payload->>'category'), ''),
      'brand', NULLIF(BTRIM(p_payload->>'brand'), ''),
      'model', NULLIF(BTRIM(p_payload->>'model'), ''),
      'year', NULLIF(BTRIM(p_payload->>'year'), ''),
      'color', NULLIF(BTRIM(p_payload->>'color'), ''),
      'plate', UPPER(NULLIF(BTRIM(p_payload->>'plate'), '')),
      'photo_url', NULLIF(BTRIM(p_payload->>'photo_url'), '')
    );

    IF v_payload->>'category' IS NULL
       OR v_payload->>'brand' IS NULL
       OR v_payload->>'model' IS NULL
       OR v_payload->>'year' IS NULL
       OR v_payload->>'color' IS NULL
       OR v_payload->>'plate' IS NULL THEN
      RAISE EXCEPTION 'Completa los datos del vehículo';
    END IF;

    -- Valida la categoria contra el enum
    PERFORM (v_payload->>'category')::vehicle_category;

    IF EXISTS (
      SELECT 1 FROM vehicles
      WHERE plate = v_payload->>'plate' AND id <> v_vehicle_id
    ) THEN
      RAISE EXCEPTION 'La placa ya está registrada';
    END IF;

  ELSE
    RAISE EXCEPTION 'Tipo de corrección no válido';
  END IF;

  IF EXISTS (
    SELECT 1 FROM driver_change_requests
    WHERE driver_id = v_uid AND status = 'pendiente'
  ) THEN
    RAISE EXCEPTION 'Ya tienes una solicitud pendiente. Espera la revisión.';
  END IF;

  INSERT INTO driver_change_requests (driver_id, kind, payload)
  VALUES (v_uid, p_kind, v_payload);

  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT id,
         'Solicitud de corrección',
         COALESCE(v_profile.full_name, 'Un conductor') || ' solicita corregir sus datos (' || p_kind::text || ').',
         'driver_change_request',
         jsonb_build_object('driver_id', v_uid, 'kind', p_kind::text, 'url', '/admin/conductores')
  FROM profiles
  WHERE role = 'super_admin'
     OR (role = 'encargado' AND (v_profile.zone_id IS NULL OR zone_id = v_profile.zone_id));

  RETURN jsonb_build_object('success', TRUE);
END;
$function$;

-- ------------------------------------------------------------
-- Revisar solicitud (admin/encargado de la zona)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.review_driver_change(
  p_request_id uuid,
  p_approve boolean,
  p_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_reviewer RECORD;
  v_req RECORD;
  v_driver_zone uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('review_driver_change', 30);

  SELECT * INTO v_reviewer FROM profiles WHERE id = v_uid;
  IF v_reviewer.role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado para revisar correcciones';
  END IF;

  SELECT * INTO v_req
  FROM driver_change_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF v_req.id IS NULL THEN
    RAISE EXCEPTION 'Solicitud no encontrada';
  END IF;
  IF v_req.status <> 'pendiente' THEN
    RAISE EXCEPTION 'Esta solicitud ya fue revisada';
  END IF;

  IF v_reviewer.role = 'encargado' THEN
    SELECT zone_id INTO v_driver_zone FROM profiles WHERE id = v_req.driver_id;
    IF public.caller_zone_id() IS NULL
       OR COALESCE(v_driver_zone, '00000000-0000-0000-0000-000000000000') <> public.caller_zone_id() THEN
      RAISE EXCEPTION 'No autorizado para revisar conductores de otra ciudad';
    END IF;
  END IF;

  IF p_approve THEN
    IF v_req.kind = 'phone' THEN
      UPDATE profiles
      SET phone = v_req.payload->>'phone',
          updated_at = NOW()
      WHERE id = v_req.driver_id;

    ELSIF v_req.kind = 'documents' THEN
      INSERT INTO driver_documents (
        driver_id, cedula_number, cedula_photo_url,
        license_number, license_photo_url, license_expiry_date
      ) VALUES (
        v_req.driver_id,
        v_req.payload->>'cedula_number',
        v_req.payload->>'cedula_photo_url',
        v_req.payload->>'license_number',
        v_req.payload->>'license_photo_url',
        (v_req.payload->>'license_expiry_date')::date
      )
      ON CONFLICT (driver_id) DO UPDATE SET
        cedula_number = EXCLUDED.cedula_number,
        cedula_photo_url = EXCLUDED.cedula_photo_url,
        license_number = EXCLUDED.license_number,
        license_photo_url = EXCLUDED.license_photo_url,
        license_expiry_date = EXCLUDED.license_expiry_date,
        updated_at = NOW();

    ELSIF v_req.kind = 'vehicle' THEN
      UPDATE vehicles SET
        category = COALESCE(NULLIF(v_req.payload->>'category', ''), category::text)::vehicle_category,
        brand = COALESCE(NULLIF(v_req.payload->>'brand', ''), brand),
        model = COALESCE(NULLIF(v_req.payload->>'model', ''), model),
        year = COALESCE(NULLIF(v_req.payload->>'year', '')::integer, year),
        color = COALESCE(NULLIF(v_req.payload->>'color', ''), color),
        plate = COALESCE(NULLIF(v_req.payload->>'plate', ''), plate),
        photo_url = COALESCE(NULLIF(v_req.payload->>'photo_url', ''), photo_url),
        updated_at = NOW()
      WHERE id = (v_req.payload->>'vehicle_id')::uuid
        AND driver_id = v_req.driver_id;
    END IF;
  END IF;

  UPDATE driver_change_requests
  SET status = (CASE WHEN p_approve THEN 'aprobado' ELSE 'rechazado' END)::driver_change_status,
      reviewed_by = v_uid,
      reviewed_at = NOW(),
      rejection_reason = CASE WHEN p_approve THEN NULL ELSE NULLIF(BTRIM(p_reason), '') END
  WHERE id = p_request_id;

  PERFORM public.notify_user(
    v_req.driver_id,
    CASE WHEN p_approve THEN 'Corrección aprobada' ELSE 'Corrección rechazada' END,
    CASE WHEN p_approve
         THEN 'Tus datos fueron actualizados.'
         ELSE COALESCE(NULLIF(BTRIM(p_reason), ''), 'Tu solicitud de corrección no fue aprobada.')
    END,
    'driver_change_review',
    jsonb_build_object('approved', p_approve, 'url', '/conductor/perfil')
  );

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (
    v_uid, 'REVIEW_DRIVER_CHANGE', 'profile', v_req.driver_id,
    jsonb_build_object('approved', p_approve, 'kind', v_req.kind::text, 'request_id', p_request_id)
  );

  RETURN jsonb_build_object('success', TRUE, 'approved', p_approve);
END;
$function$;

REVOKE ALL ON FUNCTION public.request_driver_change(public.driver_change_kind, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_driver_change(public.driver_change_kind, jsonb) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.review_driver_change(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.review_driver_change(uuid, boolean, text) TO authenticated, service_role;
