-- ============================================================
-- RIDESOCOPÓ - Migración: CONFIRMACIÓN MUTUA DE INICIO DE VIAJE
-- El conductor recoge al cliente → AMBOS deben confirmar el inicio.
-- El viaje pasa a 'en_ruta' solo cuando ambos confirman.
-- ============================================================

-- 1. AGREGAR COLUMNAS DE CONFIRMACIÓN A RIDES
ALTER TABLE rides ADD COLUMN IF NOT EXISTS driver_start_confirmed BOOLEAN DEFAULT FALSE;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS client_start_confirmed BOOLEAN DEFAULT FALSE;

-- 2. FUNCIÓN: CONFIRMAR INICIO DE VIAJE
CREATE OR REPLACE FUNCTION public.confirm_ride_start(p_ride_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_ride RECORD;
  v_is_driver BOOLEAN;
  v_is_client BOOLEAN;
  v_both_confirmed BOOLEAN := FALSE;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  -- Obtener viaje
  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  -- Verificar que el usuario es conductor o cliente de este viaje
  v_is_driver := (v_ride.driver_id = v_user_id);
  v_is_client := (v_ride.client_id = v_user_id);

  IF NOT v_is_driver AND NOT v_is_client THEN
    RAISE EXCEPTION 'No autorizado para este viaje';
  END IF;

  -- El viaje debe estar en estado 'aceptada' para poder iniciar
  IF v_ride.status != 'aceptada' THEN
    RAISE EXCEPTION 'El viaje debe estar aceptado para poder iniciarse';
  END IF;

  -- Marcar confirmación según el rol
  IF v_is_driver THEN
    UPDATE rides SET driver_start_confirmed = TRUE WHERE id = p_ride_id;
  ELSE
    UPDATE rides SET client_start_confirmed = TRUE WHERE id = p_ride_id;
  END IF;

  -- Verificar si ambos confirmaron
  SELECT (driver_start_confirmed AND client_start_confirmed) INTO v_both_confirmed
  FROM rides WHERE id = p_ride_id;

  -- Si ambos confirmaron, pasar a 'en_ruta'
  IF v_both_confirmed THEN
    UPDATE rides SET status = 'en_ruta' WHERE id = p_ride_id;

    -- Notificar a ambos
    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES
      (v_ride.driver_id, '¡Viaje iniciado!', 'Ambos confirmaron. Buen viaje.', 'ride_started',
       jsonb_build_object('ride_id', p_ride_id)),
      (v_ride.client_id, '¡Viaje iniciado!', 'Ambos confirmaron. Buen viaje.', 'ride_started',
       jsonb_build_object('ride_id', p_ride_id));

    -- Auditoría
    INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
    VALUES (v_user_id, 'RIDE_STARTED', 'ride', p_ride_id,
            jsonb_build_object('both_confirmed', TRUE));
  END IF;

  RETURN jsonb_build_object(
    'success', TRUE,
    'ride_id', p_ride_id,
    'both_confirmed', v_both_confirmed,
    'driver_confirmed', (SELECT driver_start_confirmed FROM rides WHERE id = p_ride_id),
    'client_confirmed', (SELECT client_start_confirmed FROM rides WHERE id = p_ride_id),
    'status', (SELECT status FROM rides WHERE id = p_ride_id)
  );
END;
$$;

-- 3. PERMISOS
GRANT EXECUTE ON FUNCTION public.confirm_ride_start TO anon, authenticated, service_role;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'Migración de confirmación de inicio completada' AS estado;