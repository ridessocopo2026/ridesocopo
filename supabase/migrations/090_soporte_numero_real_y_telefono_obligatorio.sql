-- ============================================================
-- BUNRIDER - Migracion 090
-- 1) Soporte: numero de respaldo real (+58 416 260 8950).
--    Las ciudades ya tienen su numero; este solo aplica cuando el
--    usuario no tiene ciudad o la ciudad no tiene numero.
-- 2) Aprobacion de conductor: exigir TELEFONO, documentos y vehiculo.
--    Sin telefono no hay forma de contactar al conductor.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_my_support()
RETURNS jsonb
LANGUAGE sql
STABLE SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT jsonb_build_object(
    'phone', COALESCE(z.support_whatsapp, '+584162608950')
  )
  FROM profiles p
  LEFT JOIN zones z ON z.id = p.zone_id
  WHERE p.id = auth.uid();
$function$;

CREATE OR REPLACE FUNCTION public.review_driver(p_driver_id uuid, p_approve boolean, p_reason text DEFAULT NULL::text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_reviewer_id UUID := auth.uid();
  v_reviewer RECORD;
  v_driver_zone UUID;
  v_new_status driver_status;
BEGIN
  IF v_reviewer_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT * INTO v_reviewer FROM profiles WHERE id = v_reviewer_id;
  IF v_reviewer.role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado para revisar conductores';
  END IF;

  IF v_reviewer.role = 'encargado' THEN
    SELECT zone_id INTO v_driver_zone FROM profiles WHERE id = p_driver_id;
    IF public.caller_zone_id() IS NULL OR COALESCE(v_driver_zone, '00000000-0000-0000-0000-000000000000') != public.caller_zone_id() THEN
      RAISE EXCEPTION 'No autorizado para revisar conductores de otra ciudad';
    END IF;
  END IF;

  -- GUARDIA: telefono + documentos + vehiculo
  IF p_approve THEN
    IF NOT EXISTS (SELECT 1 FROM driver_documents WHERE driver_id = p_driver_id)
       OR NOT EXISTS (SELECT 1 FROM vehicles WHERE driver_id = p_driver_id)
       OR NOT EXISTS (SELECT 1 FROM profiles WHERE id = p_driver_id AND phone IS NOT NULL AND TRIM(phone) <> '') THEN
      RAISE EXCEPTION 'El conductor no completo sus datos (telefono, documentos y vehiculo). No se puede aprobar.';
    END IF;
  END IF;

  v_new_status := CASE WHEN p_approve THEN 'aprobado' ELSE 'rechazado' END;

  UPDATE profiles SET driver_status = v_new_status WHERE id = p_driver_id;

  PERFORM public.notify_user(
    p_driver_id,
    CASE WHEN p_approve THEN 'Cuenta aprobada!' ELSE 'Cuenta rechazada' END,
    CASE WHEN p_approve THEN 'Ya puedes comenzar a trabajar. Bienvenido!'
         ELSE COALESCE(p_reason, 'Tu solicitud fue rechazada. Contacta al administrador.') END,
    'driver_review',
    jsonb_build_object('approved', p_approve, 'url', '/conductor')
  );

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_reviewer_id, 'REVIEW_DRIVER', 'profile', p_driver_id,
          jsonb_build_object('approved', p_approve, 'reason', p_reason));

  RETURN jsonb_build_object('success', TRUE, 'driver_id', p_driver_id, 'status', v_new_status);
END;
$function$;