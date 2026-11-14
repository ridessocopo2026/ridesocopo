-- 140 - Un vehiculo aprobado queda ACTIVO automaticamente
--
-- Antes: approve_vehicle solo ponia is_approved = TRUE y el conductor tenia que
-- entrar a su perfil y pulsar "Hacer activo". Sin eso, el trigger
-- sync_driver_active_vehicle_plate le bloquea el boton de conectarse
-- ("Selecciona y activa un vehiculo aprobado antes de conectarte"), asi que un
-- conductor aprobado con vehiculo aprobado no podia recibir viajes.
--
-- Ahora: al aprobar, si el conductor no tiene ya un vehiculo activo, ese queda
-- activo (el trigger enforce_single_active_vehicle deja siempre uno solo).
-- Si ya tenia otro activo, se respeta su eleccion.
--
-- Incluye correccion unica de los conductores que ya estaban aprobados con
-- vehiculo aprobado pero sin ninguno activo.

CREATE OR REPLACE FUNCTION public.approve_vehicle(
  p_vehicle_id uuid,
  p_approve boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id uuid := auth.uid();
  v_vehicle RECORD;
  v_primary RECORD;
  v_secondary RECORD;
  v_driver_name text;
  v_has_other_active boolean := FALSE;
  v_is_active boolean := FALSE;
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

    -- Si el conductor ya tiene otro vehiculo activo, no se lo cambiamos
    SELECT EXISTS (
      SELECT 1 FROM public.vehicles v
      WHERE v.driver_id = v_vehicle.driver_id
        AND v.id <> p_vehicle_id
        AND v.is_active_vehicle = TRUE
    ) INTO v_has_other_active;

    -- Aprobar y, si no habia uno activo, dejarlo activo de una vez
    UPDATE public.vehicles
    SET is_approved = TRUE,
        is_active_vehicle = CASE WHEN v_has_other_active THEN is_active_vehicle ELSE TRUE END,
        updated_at = NOW()
    WHERE id = p_vehicle_id;

    SELECT is_active_vehicle INTO v_is_active
    FROM public.vehicles
    WHERE id = p_vehicle_id;

    PERFORM public.notify_user(
      v_vehicle.driver_id,
      'Vehiculo aprobado',
      CASE
        WHEN v_is_active
          THEN CONCAT('Tu vehiculo ', v_vehicle.brand, ' ', v_vehicle.model,
                      ' fue aprobado y quedo activo. Ya puedes conectarte.')
        ELSE CONCAT('Tu vehiculo ', v_vehicle.brand, ' ', v_vehicle.model,
                    ' fue aprobado. Puedes activarlo o cambiarlo desde tu perfil.')
      END,
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

  RETURN jsonb_build_object(
    'success', TRUE,
    'vehicle_id', p_vehicle_id,
    'approved', p_approve,
    'is_active_vehicle', v_is_active
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_vehicle(uuid, boolean) TO authenticated;
REVOKE ALL ON FUNCTION public.approve_vehicle(uuid, boolean) FROM anon;

-- ------------------------------------------------------------
-- Correccion unica: conductores aprobados con vehiculo aprobado y ninguno activo
-- (activa el aprobado mas reciente de cada conductor)
-- ------------------------------------------------------------
WITH candidatos AS (
  SELECT v.id,
         ROW_NUMBER() OVER (
           PARTITION BY v.driver_id
           ORDER BY v.updated_at DESC NULLS LAST, v.created_at DESC
         ) AS rn
  FROM public.vehicles v
  JOIN public.profiles p
    ON p.id = v.driver_id
   AND p.role = 'conductor'
   AND p.driver_status = 'aprobado'
  WHERE v.is_approved = TRUE
    AND NOT EXISTS (
      SELECT 1 FROM public.vehicles x
      WHERE x.driver_id = v.driver_id
        AND x.is_active_vehicle = TRUE
    )
)
UPDATE public.vehicles v
SET is_active_vehicle = TRUE,
    updated_at = NOW()
FROM candidatos c
WHERE c.id = v.id
  AND c.rn = 1;
