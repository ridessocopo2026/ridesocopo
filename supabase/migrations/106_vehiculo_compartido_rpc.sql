-- ============================================================
-- 106 - VEHICULO COMPARTIDO (RPC)
-- ============================================================

-- ------------------------------------------------------------
-- 1) Vehiculos del conductor + datos de la pareja
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.get_driver_vehicles();

CREATE OR REPLACE FUNCTION public.get_driver_vehicles()
RETURNS TABLE (
  id uuid,
  driver_id uuid,
  max_passengers integer,
  category public.vehicle_category,
  brand text,
  model text,
  year integer,
  color text,
  plate text,
  photo_url text,
  is_active boolean,
  is_approved boolean,
  is_active_vehicle boolean,
  shared_with_vehicle_id uuid,
  is_shared boolean,
  shared_with_name text,
  created_at timestamptz,
  updated_at timestamptz
)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
  SELECT
    v.id,
    v.driver_id,
    v.max_passengers,
    v.category,
    v.brand,
    v.model,
    v.year,
    v.color,
    v.plate,
    v.photo_url,
    v.is_active,
    COALESCE(v.is_approved, FALSE) AS is_approved,
    COALESCE(v.is_active_vehicle, FALSE) AS is_active_vehicle,
    v.shared_with_vehicle_id,
    (
      v.shared_with_vehicle_id IS NOT NULL
      OR EXISTS (
        SELECT 1 FROM public.vehicles s
        WHERE s.shared_with_vehicle_id = v.id
      )
    ) AS is_shared,
    COALESCE(
      (
        SELECT p.full_name
        FROM public.vehicles s
        JOIN public.profiles p ON p.id = s.driver_id
        WHERE s.shared_with_vehicle_id = v.id
        LIMIT 1
      ),
      (
        SELECT p.full_name
        FROM public.vehicles pv
        JOIN public.profiles p ON p.id = pv.driver_id
        WHERE pv.id = v.shared_with_vehicle_id
        LIMIT 1
      )
    ) AS shared_with_name,
    v.created_at,
    v.updated_at
  FROM public.vehicles v
  WHERE v.driver_id = auth.uid()
  ORDER BY v.is_active_vehicle DESC, v.created_at DESC;
$function$;

REVOKE ALL ON FUNCTION public.get_driver_vehicles() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_driver_vehicles() TO authenticated, service_role;

-- ------------------------------------------------------------
-- 2) Registrar vehiculo (normal o solicitud compartida)
-- ------------------------------------------------------------
DROP FUNCTION IF EXISTS public.add_vehicle(public.vehicle_category, text, text, integer, text, text, text);

CREATE OR REPLACE FUNCTION public.add_vehicle(
  p_category public.vehicle_category,
  p_brand text,
  p_model text,
  p_year integer,
  p_color text,
  p_plate text,
  p_photo_url text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_driver_id uuid := auth.uid();
  v_driver_profiles RECORD;
  v_driver_zone uuid;
  v_plate text;
  v_existing RECORD;
  v_primary RECORD;
  v_primary_name text;
  v_shared_count integer;
  v_vehicle_id uuid;
  v_is_shared boolean := FALSE;
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT * INTO v_driver_profiles FROM public.profiles WHERE id = v_driver_id;
  IF v_driver_profiles.role != 'conductor' THEN
    RAISE EXCEPTION 'No es conductor';
  END IF;

  v_driver_zone := v_driver_profiles.zone_id;

  IF p_plate IS NULL OR btrim(p_plate) = '' THEN
    RAISE EXCEPTION 'La placa del vehiculo es obligatoria';
  END IF;

  v_plate := upper(btrim(p_plate));
  PERFORM pg_advisory_xact_lock(hashtextextended('vehicle_plate:' || v_plate, 0));

  SELECT * INTO v_existing
  FROM public.vehicles
  WHERE driver_id = v_driver_id
    AND upper(btrim(plate)) = v_plate
  LIMIT 1;

  IF v_existing.id IS NOT NULL THEN
    RAISE EXCEPTION 'Ya tienes este vehiculo registrado';
  END IF;

  SELECT * INTO v_primary
  FROM public.vehicles
  WHERE upper(btrim(plate)) = v_plate
    AND shared_with_vehicle_id IS NULL
  LIMIT 1;

  IF v_primary.id IS NULL THEN
    IF NULLIF(TRIM(p_brand), '') IS NULL
       OR NULLIF(TRIM(p_model), '') IS NULL
       OR p_year IS NULL
       OR NULLIF(TRIM(p_color), '') IS NULL THEN
      RAISE EXCEPTION 'Completa los datos del vehiculo';
    END IF;

    INSERT INTO public.vehicles (
      driver_id, category, brand, model, year, color, plate, photo_url
    ) VALUES (
      v_driver_id, p_category, TRIM(p_brand), TRIM(p_model), p_year, TRIM(p_color),
      v_plate, NULLIF(TRIM(p_photo_url), '')
    ) RETURNING id INTO v_vehicle_id;
  ELSE
    SELECT count(*) INTO v_shared_count
    FROM public.vehicles
    WHERE shared_with_vehicle_id = v_primary.id;

    IF v_shared_count >= 1 THEN
      RAISE EXCEPTION 'Este vehiculo ya esta compartido con otro conductor (maximo 2)';
    END IF;

    INSERT INTO public.vehicles (
      driver_id, category, brand, model, year, color, plate, photo_url,
      max_passengers, shared_with_vehicle_id, is_approved, is_active_vehicle
    ) VALUES (
      v_driver_id, v_primary.category, v_primary.brand, v_primary.model,
      v_primary.year, v_primary.color, v_primary.plate, v_primary.photo_url,
      v_primary.max_passengers, v_primary.id, FALSE, FALSE
    ) RETURNING id INTO v_vehicle_id;

    v_is_shared := TRUE;
  END IF;

  IF v_is_shared THEN
    SELECT p.full_name INTO v_primary_name
    FROM public.profiles p
    WHERE p.id = v_primary.driver_id;

    INSERT INTO public.notifications (user_id, title, body, type, data)
    SELECT p.id,
           'Solicitud de vehiculo compartido',
           CONCAT('El conductor ', v_driver_profiles.full_name, ' quiere usar el vehiculo ',
                  v_primary.brand, ' ', v_primary.model, ' placa ', v_primary.plate,
                  ', ya registrado por ', COALESCE(v_primary_name, 'otro conductor'), '. Revisar.'),
           'vehicle_pending',
           jsonb_build_object(
             'vehicle_id', v_vehicle_id,
             'driver_id', v_driver_id,
             'shared_with_driver_id', v_primary.driver_id,
             'url', '/admin/conductores'
           )
    FROM public.profiles p
    WHERE p.role = 'super_admin'
       OR (p.role = 'encargado' AND (v_driver_zone IS NULL OR p.zone_id = v_driver_zone));

    PERFORM public.notify_user(
      v_primary.driver_id,
      'Solicitud de vehiculo compartido',
      CONCAT('El conductor ', v_driver_profiles.full_name,
             ' solicito usar tu vehiculo placa ', v_primary.plate,
             '. El administrador lo revisara.'),
      'vehicle_share_request',
      jsonb_build_object(
        'vehicle_id', v_vehicle_id,
        'driver_id', v_driver_id,
        'url', '/conductor/perfil'
      )
    );
  ELSE
    INSERT INTO public.notifications (user_id, title, body, type, data)
    SELECT p.id,
           'Nuevo vehiculo por aprobar',
           CONCAT('El conductor ', v_driver_profiles.full_name, ' registro un ',
                  p_category, ' (', p_brand, ' ', p_model, ' ', p_color, ') placa ',
                  v_plate, '. Revisar.'),
           'vehicle_pending',
           jsonb_build_object('vehicle_id', v_vehicle_id, 'driver_id', v_driver_id, 'url', '/admin/conductores')
    FROM public.profiles p
    WHERE p.role = 'super_admin'
       OR (p.role = 'encargado' AND (v_driver_zone IS NULL OR p.zone_id = v_driver_zone));
  END IF;

  RETURN jsonb_build_object(
    'success', TRUE,
    'vehicle_id', v_vehicle_id,
    'shared', v_is_shared,
    'message', CASE
      WHEN v_is_shared THEN 'Solicitud de vehiculo compartido enviada. El administrador debe aprobarla.'
      ELSE 'Vehiculo registrado. Queda pendiente de aprobacion.'
    END
  );
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'La placa % ya esta registrada', v_plate;
END;
$function$;

REVOKE ALL ON FUNCTION public.add_vehicle(public.vehicle_category, text, text, integer, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_vehicle(public.vehicle_category, text, text, integer, text, text, text) TO authenticated, service_role;

-- ------------------------------------------------------------
-- 3) Onboarding: si la placa ya existe, crea solicitud compartida
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.register_driver_onboarding(
  p_full_name text,
  p_phone text,
  p_cedula_number text,
  p_cedula_photo_url text,
  p_license_number text,
  p_license_photo_url text,
  p_license_expiry_date date,
  p_profile_photo_url text,
  p_vehicle_category public.vehicle_category,
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
  v_user_id uuid := auth.uid();
  v_vehicle_id uuid;
  v_status public.driver_status;
  v_plate text;
  v_existing RECORD;
  v_primary RECORD;
  v_primary_name text;
  v_shared_count integer;
  v_is_shared boolean := FALSE;
  v_user_zone uuid;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  IF NOT public.is_account_active(v_user_id) THEN
    RAISE EXCEPTION 'Tu cuenta no esta activa. Contacta a soporte.';
  END IF;

  IF p_vehicle_plate IS NULL OR btrim(p_vehicle_plate) = '' THEN
    RAISE EXCEPTION 'La placa del vehiculo es obligatoria';
  END IF;

  UPDATE public.profiles
  SET full_name = COALESCE(NULLIF(TRIM(p_full_name), ''), full_name),
      phone = COALESCE(NULLIF(TRIM(p_phone), ''), phone),
      role = 'conductor',
      driver_status = (CASE WHEN driver_status = 'aprobado' THEN 'aprobado' ELSE 'pendiente' END)::public.driver_status,
      onboarding_completed = TRUE
  WHERE id = v_user_id;

  SELECT zone_id INTO v_user_zone FROM public.profiles WHERE id = v_user_id;

  IF EXISTS (SELECT 1 FROM public.driver_documents WHERE driver_id = v_user_id) THEN
    UPDATE public.driver_documents SET
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
      RAISE EXCEPTION 'Falta el numero de cedula';
    END IF;
    IF NULLIF(TRIM(p_cedula_photo_url), '') IS NULL THEN
      RAISE EXCEPTION 'Falta la foto de la cedula';
    END IF;
    IF NULLIF(TRIM(p_license_photo_url), '') IS NULL THEN
      RAISE EXCEPTION 'Falta la foto de la licencia';
    END IF;
    IF p_license_expiry_date IS NULL THEN
      RAISE EXCEPTION 'Falta el vencimiento de la licencia';
    END IF;

    INSERT INTO public.driver_documents (
      driver_id, cedula_number, cedula_photo_url,
      license_number, license_photo_url, license_expiry_date, profile_photo_url
    ) VALUES (
      v_user_id, TRIM(p_cedula_number), TRIM(p_cedula_photo_url),
      NULLIF(TRIM(p_license_number), ''), TRIM(p_license_photo_url),
      p_license_expiry_date, NULLIF(TRIM(p_profile_photo_url), '')
    );
  END IF;

  v_plate := upper(btrim(p_vehicle_plate));
  PERFORM pg_advisory_xact_lock(hashtextextended('vehicle_plate:' || v_plate, 0));

  SELECT * INTO v_existing
  FROM public.vehicles
  WHERE driver_id = v_user_id
    AND upper(btrim(plate)) = v_plate
  LIMIT 1;

  IF v_existing.id IS NOT NULL THEN
    UPDATE public.vehicles SET
      category = p_vehicle_category,
      brand = COALESCE(NULLIF(TRIM(p_vehicle_brand), ''), brand),
      model = COALESCE(NULLIF(TRIM(p_vehicle_model), ''), model),
      year = COALESCE(p_vehicle_year, year),
      color = COALESCE(NULLIF(TRIM(p_vehicle_color), ''), color),
      photo_url = COALESCE(NULLIF(TRIM(p_vehicle_photo_url), ''), photo_url),
      updated_at = NOW()
    WHERE id = v_existing.id;

    v_vehicle_id := v_existing.id;
    v_is_shared := v_existing.shared_with_vehicle_id IS NOT NULL;

    IF v_is_shared THEN
      SELECT * INTO v_primary
      FROM public.vehicles
      WHERE id = v_existing.shared_with_vehicle_id;
    END IF;
  ELSE
    SELECT * INTO v_primary
    FROM public.vehicles
    WHERE upper(btrim(plate)) = v_plate
      AND shared_with_vehicle_id IS NULL
    LIMIT 1;

    IF v_primary.id IS NULL THEN
      IF NULLIF(TRIM(p_vehicle_brand), '') IS NULL
         OR NULLIF(TRIM(p_vehicle_model), '') IS NULL
         OR p_vehicle_year IS NULL
         OR NULLIF(TRIM(p_vehicle_color), '') IS NULL THEN
        RAISE EXCEPTION 'Completa los datos del vehiculo';
      END IF;

      INSERT INTO public.vehicles (
        driver_id, category, brand, model, year, color, plate, photo_url
      ) VALUES (
        v_user_id, p_vehicle_category, TRIM(p_vehicle_brand),
        TRIM(p_vehicle_model), p_vehicle_year, TRIM(p_vehicle_color),
        v_plate, NULLIF(TRIM(p_vehicle_photo_url), '')
      ) RETURNING id INTO v_vehicle_id;
    ELSE
      SELECT count(*) INTO v_shared_count
      FROM public.vehicles
      WHERE shared_with_vehicle_id = v_primary.id;

      IF v_shared_count >= 1 THEN
        RAISE EXCEPTION 'Este vehiculo ya esta compartido con otro conductor (maximo 2)';
      END IF;

      INSERT INTO public.vehicles (
        driver_id, category, brand, model, year, color, plate, photo_url,
        max_passengers, shared_with_vehicle_id, is_approved, is_active_vehicle
      ) VALUES (
        v_user_id, v_primary.category, v_primary.brand, v_primary.model,
        v_primary.year, v_primary.color, v_primary.plate, v_primary.photo_url,
        v_primary.max_passengers, v_primary.id, FALSE, FALSE
      ) RETURNING id INTO v_vehicle_id;

      v_is_shared := TRUE;
    END IF;
  END IF;

  SELECT driver_status INTO v_status FROM public.profiles WHERE id = v_user_id;

  IF v_is_shared THEN
    SELECT p.full_name INTO v_primary_name
    FROM public.profiles p
    WHERE p.id = v_primary.driver_id;

    INSERT INTO public.notifications (user_id, title, body, type, data)
    SELECT p.id,
           'Solicitud de vehiculo compartido',
           CONCAT('El conductor ', COALESCE(p_full_name, 'Un conductor'),
                  ' quiere usar el vehiculo ', v_primary.brand, ' ', v_primary.model,
                  ' placa ', v_primary.plate, ', ya registrado por ',
                  COALESCE(v_primary_name, 'otro conductor'), '. Revisar.'),
           'vehicle_pending',
           jsonb_build_object(
             'vehicle_id', v_vehicle_id,
             'driver_id', v_user_id,
             'shared_with_driver_id', v_primary.driver_id,
             'url', '/admin/conductores'
           )
    FROM public.profiles p
    WHERE p.role = 'super_admin'
       OR (p.role = 'encargado' AND (v_user_zone IS NULL OR p.zone_id = v_user_zone));

    PERFORM public.notify_user(
      v_primary.driver_id,
      'Solicitud de vehiculo compartido',
      CONCAT('El conductor ', COALESCE(p_full_name, 'Un conductor'),
             ' solicito usar tu vehiculo placa ', v_primary.plate,
             '. El administrador lo revisara.'),
      'vehicle_share_request',
      jsonb_build_object(
        'vehicle_id', v_vehicle_id,
        'driver_id', v_user_id,
        'url', '/conductor/perfil'
      )
    );
  END IF;

  IF v_status <> 'aprobado' THEN
    INSERT INTO public.notifications (user_id, title, body, type, data)
    SELECT id, 'Nuevo conductor pendiente',
           COALESCE(p_full_name, 'Un conductor') || ' ha solicitado ser conductor',
           'driver_pending',
           jsonb_build_object('driver_id', v_user_id, 'url', '/admin/conductores')
    FROM public.profiles WHERE role IN ('super_admin', 'encargado');
  END IF;

  RETURN jsonb_build_object(
    'success', TRUE,
    'status', v_status,
    'vehicle_id', v_vehicle_id,
    'shared_vehicle', v_is_shared,
    'message', CASE
      WHEN v_is_shared THEN 'Solicitud de vehiculo compartido enviada. El administrador debe aprobarla.'
      ELSE 'Solicitud enviada. Queda pendiente de aprobacion.'
    END
  );
EXCEPTION WHEN unique_violation THEN
  RAISE EXCEPTION 'La placa % ya esta registrada', v_plate;
END;
$function$;

-- ------------------------------------------------------------
-- 4) Aprobacion de vehiculos (principal / compartida)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.approve_vehicle(
  p_vehicle_id uuid,
  p_approve boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_admin_id uuid := auth.uid();
  v_vehicle RECORD;
  v_primary RECORD;
  v_secondary RECORD;
  v_driver_name text;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT * INTO v_vehicle FROM public.vehicles WHERE id = p_vehicle_id;
  IF v_vehicle.id IS NULL THEN
    RAISE EXCEPTION 'Vehiculo no encontrado';
  END IF;

  IF p_approve THEN
    IF v_vehicle.shared_with_vehicle_id IS NOT NULL THEN
      SELECT * INTO v_primary
      FROM public.vehicles
      WHERE id = v_vehicle.shared_with_vehicle_id;

      IF v_primary.id IS NULL OR COALESCE(v_primary.is_approved, FALSE) = FALSE THEN
        RAISE EXCEPTION 'El vehiculo principal aun no esta aprobado';
      END IF;
    END IF;

    UPDATE public.vehicles
    SET is_approved = TRUE,
        updated_at = NOW()
    WHERE id = p_vehicle_id;

    PERFORM public.notify_user(
      v_vehicle.driver_id,
      'Vehiculo aprobado',
      CONCAT('Tu vehiculo ', v_vehicle.brand, ' ', v_vehicle.model, ' fue aprobado. Ya puedes activarlo.'),
      'vehicle_approved',
      jsonb_build_object('vehicle_id', p_vehicle_id, 'url', '/conductor/perfil')
    );

    IF v_vehicle.shared_with_vehicle_id IS NOT NULL THEN
      SELECT full_name INTO v_driver_name FROM public.profiles WHERE id = v_vehicle.driver_id;
      PERFORM public.notify_user(
        v_primary.driver_id,
        'Vehiculo compartido aprobado',
        CONCAT('El conductor ', COALESCE(v_driver_name, 'tu companero'),
               ' tambien usara tu vehiculo placa ', v_vehicle.plate, '.'),
        'vehicle_share_approved',
        jsonb_build_object('vehicle_id', p_vehicle_id, 'url', '/conductor/perfil')
      );
    END IF;
  ELSE
    UPDATE public.vehicles
    SET is_approved = FALSE,
        is_active_vehicle = FALSE,
        updated_at = NOW()
    WHERE id = p_vehicle_id;

    UPDATE public.profiles
    SET is_online = FALSE
    WHERE id = v_vehicle.driver_id
      AND is_online = TRUE;

    PERFORM public.notify_user(
      v_vehicle.driver_id,
      'Vehiculo rechazado',
      CONCAT('Tu vehiculo ', v_vehicle.brand, ' ', v_vehicle.model, ' fue rechazado. Verifica los datos y vuelve a intentar.'),
      'vehicle_rejected',
      jsonb_build_object('vehicle_id', p_vehicle_id, 'url', '/conductor/perfil')
    );

    IF v_vehicle.shared_with_vehicle_id IS NULL THEN
      FOR v_secondary IN
        SELECT * FROM public.vehicles
        WHERE shared_with_vehicle_id = v_vehicle.id
      LOOP
        UPDATE public.vehicles
        SET is_approved = FALSE,
            is_active_vehicle = FALSE,
            updated_at = NOW()
        WHERE id = v_secondary.id;

        UPDATE public.profiles
        SET is_online = FALSE
        WHERE id = v_secondary.driver_id
          AND is_online = TRUE;

        PERFORM public.notify_user(
          v_secondary.driver_id,
          'Vehiculo compartido rechazado',
          CONCAT('El vehiculo compartido placa ', v_secondary.plate,
                 ' fue rechazado porque el vehiculo principal no esta aprobado.'),
          'vehicle_rejected',
          jsonb_build_object('vehicle_id', v_secondary.id, 'url', '/conductor/perfil')
        );
      END LOOP;
    END IF;
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'vehicle_id', p_vehicle_id, 'approved', p_approve);
END;
$function$;

-- ------------------------------------------------------------
-- 5) Activar vehiculo (sin cambios en linea)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_active_vehicle(p_vehicle_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_driver_id uuid := auth.uid();
  v_vehicle RECORD;
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT * INTO v_vehicle FROM public.vehicles WHERE id = p_vehicle_id;
  IF v_vehicle.id IS NULL THEN
    RAISE EXCEPTION 'Vehiculo no encontrado';
  END IF;

  IF v_vehicle.driver_id != v_driver_id THEN
    RAISE EXCEPTION 'No es tu vehiculo';
  END IF;

  IF NOT COALESCE(v_vehicle.is_approved, FALSE) THEN
    RAISE EXCEPTION 'El vehiculo no esta aprobado por el administrador';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.rides r
    WHERE r.driver_id = v_driver_id
      AND r.status IN ('aceptada', 'en_ruta', 'incidente')
  ) THEN
    RAISE EXCEPTION 'No puedes cambiar de vehiculo mientras tienes un viaje en curso';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.profiles p
    WHERE p.id = v_driver_id AND p.is_online = TRUE
  ) THEN
    RAISE EXCEPTION 'Desconectate para cambiar de vehiculo';
  END IF;

  UPDATE public.vehicles
  SET is_active_vehicle = TRUE,
      updated_at = NOW()
  WHERE id = p_vehicle_id;

  RETURN jsonb_build_object('success', TRUE, 'vehicle_id', p_vehicle_id, 'is_active', TRUE);
END;
$function$;

-- ------------------------------------------------------------
-- 6) Eliminar vehiculo (con proteccion de la pareja)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_driver_vehicle(p_vehicle_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_driver_id uuid := auth.uid();
  v_row RECORD;
  v_used integer;
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('delete_driver_vehicle', 20);

  SELECT * INTO v_row FROM public.vehicles WHERE id = p_vehicle_id;
  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'Vehiculo no encontrado';
  END IF;

  IF v_row.driver_id != v_driver_id THEN
    RAISE EXCEPTION 'No puedes eliminar un vehiculo que no te pertenece';
  END IF;

  IF v_row.shared_with_vehicle_id IS NULL
     AND EXISTS (
       SELECT 1 FROM public.vehicles s
       WHERE s.shared_with_vehicle_id = v_row.id
     ) THEN
    RAISE EXCEPTION 'Este vehiculo esta compartido. Pide al administrador que desvincule al otro conductor antes de eliminarlo.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.rides
    WHERE vehicle_id = p_vehicle_id
      AND status IN ('buscando', 'aceptada', 'en_ruta', 'incidente')
  ) THEN
    RAISE EXCEPTION 'No puedes eliminar un vehiculo que esta en un viaje activo';
  END IF;

  SELECT COUNT(*) INTO v_used FROM public.rides WHERE vehicle_id = p_vehicle_id;
  IF v_used > 0 THEN
    RAISE EXCEPTION 'Este vehiculo ya fue usado en viajes y no se puede eliminar (queda en tu historial)';
  END IF;

  IF COALESCE(v_row.is_active_vehicle, FALSE) THEN
    UPDATE public.profiles
    SET is_online = FALSE
    WHERE id = v_driver_id AND is_online = TRUE;
  END IF;

  DELETE FROM public.vehicles WHERE id = p_vehicle_id;

  RETURN jsonb_build_object('success', TRUE, 'vehicle_id', p_vehicle_id);
END;
$function$;

-- ------------------------------------------------------------
-- 7) Conexion / disponibilidad (mensaje claro si el carro esta ocupado)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.toggle_driver_online(p_online boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_driver_id uuid := auth.uid();
  v_profile RECORD;
  v_wallet RECORD;
BEGIN
  SELECT * INTO v_profile FROM public.profiles WHERE id = v_driver_id;

  IF v_profile.role != 'conductor' THEN
    RAISE EXCEPTION 'No es conductor';
  END IF;

  IF NOT public.is_account_active(v_driver_id) THEN
    RAISE EXCEPTION 'Tu cuenta no esta activa. Contacta a soporte.';
  END IF;

  IF v_profile.driver_status != 'aprobado' THEN
    RAISE EXCEPTION 'Conductor no aprobado';
  END IF;

  SELECT * INTO v_wallet FROM public.wallets WHERE user_id = v_driver_id;
  IF v_wallet.balance_usd < -v_wallet.debt_limit_usd THEN
    RETURN jsonb_build_object(
      'success', FALSE,
      'error', 'DEUDA_EXCEDIDA',
      'message', 'Tienes una deuda pendiente que supera el limite permitido. Recarga tu billetera o contacta al administrador.',
      'deuda_actual', v_wallet.balance_usd,
      'limite_deuda', v_wallet.debt_limit_usd
    );
  END IF;

  BEGIN
    UPDATE public.profiles SET is_online = p_online WHERE id = v_driver_id;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Ese vehiculo esta en uso por tu companero. Solo uno de los dos puede estar en linea.';
  END;

  RETURN jsonb_build_object('success', TRUE, 'is_online', p_online);
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_my_availability(
  p_online boolean,
  p_auto boolean,
  p_from time DEFAULT NULL,
  p_to time DEFAULT NULL,
  p_days smallint[] DEFAULT NULL,
  p_push boolean DEFAULT TRUE
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_profile RECORD;
  v_wallet RECORD;
  v_day smallint;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT * INTO v_profile FROM public.profiles WHERE id = v_uid;
  IF v_profile.role != 'conductor' THEN
    RAISE EXCEPTION 'No es conductor';
  END IF;
  IF v_profile.driver_status != 'aprobado' THEN
    RAISE EXCEPTION 'Conductor no aprobado';
  END IF;

  IF p_auto IS TRUE AND (p_from IS NULL OR p_to IS NULL) THEN
    RAISE EXCEPTION 'Define la hora de inicio y de cierre del horario';
  END IF;

  IF p_days IS NOT NULL THEN
    FOREACH v_day IN ARRAY p_days LOOP
      IF v_day < 1 OR v_day > 7 THEN
        RAISE EXCEPTION 'Dia invalido en el horario (usa 1=lunes ... 7=domingo)';
      END IF;
    END LOOP;
  END IF;

  IF p_online IS TRUE THEN
    SELECT * INTO v_wallet FROM public.wallets WHERE user_id = v_uid;
    IF FOUND AND v_wallet.balance_usd < -v_wallet.debt_limit_usd THEN
      RAISE EXCEPTION 'Limite de deuda excedido. Recargue su saldo.';
    END IF;
  END IF;

  BEGIN
    UPDATE public.profiles
    SET is_online = p_online,
        availability_auto = COALESCE(p_auto, FALSE),
        available_from = p_from,
        available_to = p_to,
        available_days = p_days,
        availability_push = COALESCE(p_push, TRUE),
        available_override_until = CASE WHEN p_online IS TRUE THEN available_override_until ELSE NULL END
    WHERE id = v_uid;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Ese vehiculo esta en uso por tu companero. Solo uno de los dos puede estar en linea.';
  END;

  RETURN jsonb_build_object(
    'success', TRUE,
    'is_online', p_online,
    'auto', COALESCE(p_auto, FALSE),
    'in_schedule', public.driver_in_schedule_now(v_uid)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION public.set_my_availability_override(p_minutes integer DEFAULT 60)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_uid uuid := auth.uid();
  v_profile RECORD;
  v_wallet RECORD;
  v_until timestamptz;
  v_local_date date;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT * INTO v_profile FROM public.profiles WHERE id = v_uid;
  IF v_profile.role != 'conductor' OR v_profile.driver_status != 'aprobado' THEN
    RAISE EXCEPTION 'Conductor no aprobado';
  END IF;

  SELECT * INTO v_wallet FROM public.wallets WHERE user_id = v_uid;
  IF FOUND AND v_wallet.balance_usd < -v_wallet.debt_limit_usd THEN
    RAISE EXCEPTION 'Limite de deuda excedido. Recargue su saldo.';
  END IF;

  IF p_minutes IS NOT NULL AND p_minutes > 0 THEN
    v_until := NOW() + (p_minutes || ' minutes')::interval;
  ELSE
    v_local_date := (NOW() AT TIME ZONE 'America/Caracas')::date;
    v_until := ((v_local_date + 1)::timestamp AT TIME ZONE 'America/Caracas');
  END IF;

  BEGIN
    UPDATE public.profiles
    SET is_online = TRUE,
        available_override_until = v_until
    WHERE id = v_uid;
  EXCEPTION WHEN unique_violation THEN
    RAISE EXCEPTION 'Ese vehiculo esta en uso por tu companero. Solo uno de los dos puede estar en linea.';
  END;

  RETURN jsonb_build_object('success', TRUE, 'is_online', TRUE, 'override_until', v_until);
END;
$function$;

-- ------------------------------------------------------------
-- 8) Aceptar viaje: en linea, vehiculo aprobado y no ocupado por la pareja
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.accept_ride(p_ride_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_driver_id uuid := auth.uid();
  v_profile RECORD;
  v_ride RECORD;
  v_commission numeric;
  v_vehicle RECORD;
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('accept_ride', 30);

  SELECT * INTO v_profile FROM public.profiles WHERE id = v_driver_id;
  IF v_profile.id IS NULL THEN
    RAISE EXCEPTION 'Perfil no encontrado';
  END IF;

  IF v_profile.role != 'conductor' OR v_profile.driver_status != 'aprobado' THEN
    RAISE EXCEPTION 'Conductor no aprobado';
  END IF;

  IF NOT public.is_account_active(v_driver_id) THEN
    RAISE EXCEPTION 'Tu cuenta no esta activa. Contacta a soporte.';
  END IF;

  IF v_profile.is_online IS NOT TRUE THEN
    RAISE EXCEPTION 'No estas en linea. Activa tu disponibilidad para aceptar viajes.';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.rides r
    WHERE r.driver_id = v_driver_id
      AND r.status IN ('aceptada', 'en_ruta', 'incidente')
  ) THEN
    RAISE EXCEPTION 'Ya tienes un viaje en curso. Finalizalo antes de aceptar otro.';
  END IF;

  SELECT * INTO v_ride FROM public.rides WHERE id = p_ride_id AND status = 'buscando';
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no disponible';
  END IF;

  IF v_ride.proof_status = 'pendiente' THEN
    RAISE EXCEPTION 'Este viaje aun no esta disponible. Esperando aprobacion del pago.';
  END IF;

  SELECT * INTO v_vehicle
  FROM public.vehicles
  WHERE driver_id = v_driver_id
    AND category = v_ride.category
    AND is_approved = TRUE
    AND is_active_vehicle = TRUE
  LIMIT 1;

  IF v_vehicle.id IS NULL THEN
    RAISE EXCEPTION 'No tiene un vehiculo aprobado y activo de la categoria requerida';
  END IF;

  -- El companero tiene un viaje activo con el mismo vehiculo fisico
  IF EXISTS (
    SELECT 1
    FROM public.rides r
    JOIN public.vehicles rv ON rv.id = r.vehicle_id
    WHERE r.status IN ('aceptada', 'en_ruta', 'incidente')
      AND r.driver_id <> v_driver_id
      AND upper(btrim(rv.plate)) = upper(btrim(v_vehicle.plate))
  ) THEN
    RAISE EXCEPTION 'Ese vehiculo esta en uso por tu companero. Espera a que termine el viaje.';
  END IF;

  v_commission := ROUND(COALESCE(v_ride.total_fare_usd, v_ride.final_fare_usd, 0) * v_ride.commission_rate / 100, 2);

  UPDATE public.rides
  SET driver_id = v_driver_id,
      vehicle_id = v_vehicle.id,
      commission_usd = v_commission,
      status = 'aceptada',
      started_at = NOW()
  WHERE id = p_ride_id;

  PERFORM public.notify_user(
    v_ride.client_id,
    'Conductor asignado',
    'Un conductor ha aceptado tu viaje',
    'ride_accepted',
    jsonb_build_object('ride_id', p_ride_id, 'url', '/cliente/viaje/' || p_ride_id)
  );

  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_driver_id, 'ACCEPT_RIDE', 'ride', p_ride_id,
          jsonb_build_object('commission', v_commission, 'final_fare', v_ride.final_fare_usd));

  RETURN jsonb_build_object(
    'success', TRUE,
    'ride_id', p_ride_id,
    'commission', v_commission
  );
END;
$function$;

-- ------------------------------------------------------------
-- 9) Viajes disponibles segun vehiculo aprobado y activo
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_available_rides()
RETURNS SETOF public.rides
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_driver_id uuid := auth.uid();
  v_profile RECORD;
BEGIN
  SELECT * INTO v_profile FROM public.profiles WHERE id = v_driver_id;

  IF v_profile.role != 'conductor'
     OR v_profile.driver_status != 'aprobado'
     OR NOT v_profile.is_online THEN
    RAISE EXCEPTION 'No autorizado o no en linea';
  END IF;

  RETURN QUERY
  SELECT r.*
  FROM public.rides r
  WHERE r.status = 'buscando'
    AND r.category IN (
      SELECT v.category
      FROM public.vehicles v
      WHERE v.driver_id = v_driver_id
        AND v.is_approved = TRUE
        AND v.is_active_vehicle = TRUE
    )
  ORDER BY r.created_at DESC
  LIMIT 20;
END;
$function$;

-- ------------------------------------------------------------
-- 10) Correcciones de datos: permitir la placa de la propia pareja
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

  SELECT * INTO v_profile FROM public.profiles WHERE id = v_uid;
  IF v_profile.id IS NULL THEN
    RAISE EXCEPTION 'Perfil no encontrado';
  END IF;
  IF v_profile.role <> 'conductor' THEN
    RAISE EXCEPTION 'Solo los conductores pueden solicitar correcciones';
  END IF;
  IF v_profile.driver_status <> 'aprobado' THEN
    RAISE EXCEPTION 'Tu cuenta aun no esta aprobada';
  END IF;

  IF p_kind = 'phone' THEN
    v_payload := jsonb_build_object('phone', NULLIF(BTRIM(p_payload->>'phone'), ''));
    IF v_payload->>'phone' IS NULL OR LENGTH(v_payload->>'phone') < 7 THEN
      RAISE EXCEPTION 'Telefono invalido';
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
        RAISE EXCEPTION 'La licencia esta vencida';
      END IF;
    EXCEPTION WHEN invalid_datetime_format THEN
      RAISE EXCEPTION 'Fecha de vencimiento invalida';
    END;

  ELSIF p_kind = 'vehicle' THEN
    IF NULLIF(BTRIM(p_payload->>'vehicle_id'), '') IS NULL THEN
      RAISE EXCEPTION 'Vehiculo no indicado';
    END IF;

    v_vehicle_id := (p_payload->>'vehicle_id')::uuid;
    IF NOT EXISTS (
      SELECT 1 FROM public.vehicles
      WHERE id = v_vehicle_id AND driver_id = v_uid
    ) THEN
      RAISE EXCEPTION 'Ese vehiculo no es tuyo';
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
      RAISE EXCEPTION 'Completa los datos del vehiculo';
    END IF;

    PERFORM (v_payload->>'category')::public.vehicle_category;

    -- Se permite la placa de la propia pareja (principal <-> compartida),
    -- pero no la de otro vehiculo distinto.
    IF EXISTS (
      SELECT 1
      FROM public.vehicles x
      WHERE upper(btrim(x.plate)) = v_payload->>'plate'
        AND NOT EXISTS (
          SELECT 1
          FROM (
            SELECT id FROM public.vehicles WHERE id = v_vehicle_id
            UNION
            SELECT shared_with_vehicle_id FROM public.vehicles
            WHERE id = v_vehicle_id AND shared_with_vehicle_id IS NOT NULL
            UNION
            SELECT id FROM public.vehicles WHERE shared_with_vehicle_id = v_vehicle_id
          ) pair
          WHERE pair.id = x.id
        )
    ) THEN
      RAISE EXCEPTION 'La placa ya esta registrada';
    END IF;

  ELSE
    RAISE EXCEPTION 'Tipo de correccion no valido';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.driver_change_requests
    WHERE driver_id = v_uid AND status = 'pendiente'
  ) THEN
    RAISE EXCEPTION 'Ya tienes una solicitud pendiente. Espera la revision.';
  END IF;

  INSERT INTO public.driver_change_requests (driver_id, kind, payload)
  VALUES (v_uid, p_kind, v_payload);

  INSERT INTO public.notifications (user_id, title, body, type, data)
  SELECT id,
         'Solicitud de correccion',
         COALESCE(v_profile.full_name, 'Un conductor') || ' solicita corregir sus datos (' || p_kind::text || ').',
         'driver_change_request',
         jsonb_build_object('driver_id', v_uid, 'kind', p_kind::text, 'url', '/admin/conductores')
  FROM public.profiles
  WHERE role = 'super_admin'
     OR (role = 'encargado' AND (v_profile.zone_id IS NULL OR zone_id = v_profile.zone_id));

  RETURN jsonb_build_object('success', TRUE);
END;
$function$;

-- ------------------------------------------------------------
-- 11) Revisar correccion: actualizar las dos filas de la pareja
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
  v_vehicle RECORD;
  v_primary_id uuid;
  v_other_driver uuid;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('review_driver_change', 30);

  SELECT * INTO v_reviewer FROM public.profiles WHERE id = v_uid;
  IF v_reviewer.role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado para revisar correcciones';
  END IF;

  SELECT * INTO v_req
  FROM public.driver_change_requests
  WHERE id = p_request_id
  FOR UPDATE;

  IF v_req.id IS NULL THEN
    RAISE EXCEPTION 'Solicitud no encontrada';
  END IF;
  IF v_req.status <> 'pendiente' THEN
    RAISE EXCEPTION 'Esta solicitud ya fue revisada';
  END IF;

  IF v_reviewer.role = 'encargado' THEN
    SELECT zone_id INTO v_driver_zone FROM public.profiles WHERE id = v_req.driver_id;
    IF public.caller_zone_id() IS NULL
       OR COALESCE(v_driver_zone, '00000000-0000-0000-0000-000000000000') <> public.caller_zone_id() THEN
      RAISE EXCEPTION 'No autorizado para revisar conductores de otra ciudad';
    END IF;
  END IF;

  IF p_approve THEN
    IF v_req.kind = 'phone' THEN
      UPDATE public.profiles
      SET phone = v_req.payload->>'phone',
          updated_at = NOW()
      WHERE id = v_req.driver_id;

    ELSIF v_req.kind = 'documents' THEN
      INSERT INTO public.driver_documents (
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
      SELECT * INTO v_vehicle
      FROM public.vehicles
      WHERE id = (v_req.payload->>'vehicle_id')::uuid
        AND driver_id = v_req.driver_id;

      IF v_vehicle.id IS NULL THEN
        RAISE EXCEPTION 'Vehiculo no encontrado';
      END IF;

      v_primary_id := COALESCE(v_vehicle.shared_with_vehicle_id, v_vehicle.id);

      -- Desconectar a ambos antes de cambiar datos/placa
      UPDATE public.profiles
      SET is_online = FALSE
      WHERE id IN (
        SELECT driver_id FROM public.vehicles
        WHERE id = v_primary_id OR shared_with_vehicle_id = v_primary_id
      );

      UPDATE public.vehicles SET
        category = COALESCE(NULLIF(v_req.payload->>'category', ''), category::text)::public.vehicle_category,
        brand = COALESCE(NULLIF(v_req.payload->>'brand', ''), brand),
        model = COALESCE(NULLIF(v_req.payload->>'model', ''), model),
        year = COALESCE(NULLIF(v_req.payload->>'year', '')::integer, year),
        color = COALESCE(NULLIF(v_req.payload->>'color', ''), color),
        plate = COALESCE(NULLIF(v_req.payload->>'plate', ''), plate),
        photo_url = COALESCE(NULLIF(v_req.payload->>'photo_url', ''), photo_url),
        updated_at = NOW()
      WHERE id = v_primary_id;

      UPDATE public.vehicles SET
        category = COALESCE(NULLIF(v_req.payload->>'category', ''), category::text)::public.vehicle_category,
        brand = COALESCE(NULLIF(v_req.payload->>'brand', ''), brand),
        model = COALESCE(NULLIF(v_req.payload->>'model', ''), model),
        year = COALESCE(NULLIF(v_req.payload->>'year', '')::integer, year),
        color = COALESCE(NULLIF(v_req.payload->>'color', ''), color),
        plate = COALESCE(NULLIF(v_req.payload->>'plate', ''), plate),
        photo_url = COALESCE(NULLIF(v_req.payload->>'photo_url', ''), photo_url),
        updated_at = NOW()
      WHERE shared_with_vehicle_id = v_primary_id;

      SELECT driver_id INTO v_other_driver
      FROM public.vehicles
      WHERE (id = v_primary_id OR shared_with_vehicle_id = v_primary_id)
        AND driver_id <> v_req.driver_id
      LIMIT 1;

      IF v_other_driver IS NOT NULL THEN
        PERFORM public.notify_user(
          v_other_driver,
          'Vehiculo compartido actualizado',
          'El administrador actualizo los datos del vehiculo compartido.',
          'vehicle_share_updated',
          jsonb_build_object('vehicle_id', v_primary_id, 'url', '/conductor/perfil')
        );
      END IF;
    END IF;
  END IF;

  UPDATE public.driver_change_requests
  SET status = (CASE WHEN p_approve THEN 'aprobado' ELSE 'rechazado' END)::public.driver_change_status,
      reviewed_by = v_uid,
      reviewed_at = NOW(),
      rejection_reason = CASE WHEN p_approve THEN NULL ELSE NULLIF(BTRIM(p_reason), '') END
  WHERE id = p_request_id;

  PERFORM public.notify_user(
    v_req.driver_id,
    CASE WHEN p_approve THEN 'Correccion aprobada' ELSE 'Correccion rechazada' END,
    CASE WHEN p_approve
         THEN 'Tus datos fueron actualizados.'
         ELSE COALESCE(NULLIF(BTRIM(p_reason), ''), 'Tu solicitud de correccion no fue aprobada.')
    END,
    'driver_change_review',
    jsonb_build_object('approved', p_approve, 'url', '/conductor/perfil')
  );

  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (
    v_uid, 'REVIEW_DRIVER_CHANGE', 'profile', v_req.driver_id,
    jsonb_build_object('approved', p_approve, 'kind', v_req.kind::text, 'request_id', p_request_id)
  );

  RETURN jsonb_build_object('success', TRUE, 'approved', p_approve);
END;
$function$;

-- ------------------------------------------------------------
-- Permisos
-- ------------------------------------------------------------
REVOKE ALL ON FUNCTION public.approve_vehicle(uuid, boolean) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.approve_vehicle(uuid, boolean) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.set_active_vehicle(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_active_vehicle(uuid) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.delete_driver_vehicle(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.delete_driver_vehicle(uuid) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.register_driver_onboarding(text, text, text, text, text, text, date, text, public.vehicle_category, text, text, integer, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_driver_onboarding(text, text, text, text, text, text, date, text, public.vehicle_category, text, text, integer, text, text, text) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.request_driver_change(public.driver_change_kind, jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.request_driver_change(public.driver_change_kind, jsonb) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.review_driver_change(uuid, boolean, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.review_driver_change(uuid, boolean, text) TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
