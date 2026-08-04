-- ============================================================
-- RIDESOCOPÓ - Migración: VEHÍCULOS MÚLTIPLES CON APROBACIÓN
-- 1. columnas nuevas en vehicles (is_approved, is_active_vehicle)
-- 2. trigger: solo UN vehículo activo por conductor
-- 3. RPCs: add_vehicle, approve_vehicle, set_active_vehicle,
--          get_driver_vehicles
-- ============================================================

-- ============================================================
-- 1. COLUMNAS NUEVAS
-- ============================================================
ALTER TABLE vehicles
  ADD COLUMN IF NOT EXISTS is_approved BOOLEAN DEFAULT FALSE,
  ADD COLUMN IF NOT EXISTS is_active_vehicle BOOLEAN DEFAULT FALSE;

-- Los vehículos existentes se marcan como aprobados (los que ya estaban)
UPDATE vehicles SET is_approved = TRUE, is_active_vehicle = TRUE
WHERE is_approved = FALSE;

-- ============================================================
-- 2. TRIGGER: SOLO UN VEHÍCULO ACTIVO POR CONDUCTOR
-- ============================================================
CREATE OR REPLACE FUNCTION public.enforce_single_active_vehicle()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF NEW.is_active_vehicle = TRUE THEN
    UPDATE vehicles
    SET is_active_vehicle = FALSE, updated_at = NOW()
    WHERE driver_id = NEW.driver_id AND id <> NEW.id;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS single_active_vehicle ON public.vehicles;
CREATE TRIGGER single_active_vehicle
  AFTER INSERT OR UPDATE OF is_active_vehicle ON public.vehicles
  FOR EACH ROW EXECUTE FUNCTION public.enforce_single_active_vehicle();

-- ============================================================
-- 3. RPCs
-- ============================================================

-- 3.1 Conductor añade vehículo (queda pendiente de aprobación)
CREATE OR REPLACE FUNCTION public.add_vehicle(
  p_category vehicle_category,
  p_brand TEXT,
  p_model TEXT,
  p_year INTEGER,
  p_color TEXT,
  p_plate TEXT,
  p_photo_url TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_vehicle_id UUID;
  v_driver_profiles RECORD;
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  -- Verificar que el usuario es conductor aprobado
  SELECT * INTO v_driver_profiles FROM public.profiles WHERE id = v_driver_id;
  IF v_driver_profiles.role != 'conductor' THEN
    RAISE EXCEPTION 'No es conductor';
  END IF;

  -- Verificar placa única
  IF EXISTS (SELECT 1 FROM vehicles WHERE plate = UPPER(p_plate)) THEN
    RAISE EXCEPTION 'La placa ya está registrada';
  END IF;

  INSERT INTO vehicles (
    driver_id, category, brand, model, year, color, plate, photo_url,
    is_approved, is_active_vehicle
  ) VALUES (
    v_driver_id, p_category, p_brand, p_model, p_year, p_color, UPPER(p_plate), p_photo_url,
    FALSE, FALSE
  ) RETURNING id INTO v_vehicle_id;

  -- Notificar a admins/encargados
  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT id, 'Nuevo vehículo por aprobar',
         CONCAT('El conductor ', v_driver_profiles.full_name, ' registró un ', p_category, ' (', p_brand, ' ', p_model, ' ', p_color, ') placa ', UPPER(p_plate), '. Revisar.'),
         'vehicle_pending',
         jsonb_build_object('vehicle_id', v_vehicle_id, 'url', '/admin/conductores')
  FROM profiles WHERE role IN ('super_admin', 'encargado');

  RETURN v_vehicle_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.add_vehicle TO authenticated, anon;

-- 3.2 Admin aprueba/rechaza vehículo
CREATE OR REPLACE FUNCTION public.approve_vehicle(
  p_vehicle_id UUID,
  p_approve BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_vehicle RECORD;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT * INTO v_vehicle FROM vehicles WHERE id = p_vehicle_id;
  IF v_vehicle.id IS NULL THEN
    RAISE EXCEPTION 'Vehículo no encontrado';
  END IF;

  IF p_approve THEN
    UPDATE vehicles SET is_approved = TRUE, updated_at = NOW() WHERE id = p_vehicle_id;

    PERFORM public.notify_user(
      v_vehicle.driver_id,
      'Vehículo aprobado',
      CONCAT('Tu vehículo ', v_vehicle.brand, ' ', v_vehicle.model, ' fue aprobado. Ya puedes activarlo.'),
      'vehicle_approved',
      jsonb_build_object('vehicle_id', p_vehicle_id, 'url', '/conductor/perfil')
    );
  ELSE
    UPDATE vehicles SET is_approved = FALSE, updated_at = NOW() WHERE id = p_vehicle_id;

    PERFORM public.notify_user(
      v_vehicle.driver_id,
      'Vehículo rechazado',
      CONCAT('Tu vehículo ', v_vehicle.brand, ' ', v_vehicle.model, ' fue rechazado. Verifica los datos y vuelve a intentar.'),
      'vehicle_rejected',
      jsonb_build_object('vehicle_id', p_vehicle_id, 'url', '/conductor/perfil')
    );
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'vehicle_id', p_vehicle_id, 'approved', p_approve);
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_vehicle TO authenticated, anon;

-- 3.3 Conductor activa su vehículo activo (solo si está aprobado)
CREATE OR REPLACE FUNCTION public.set_active_vehicle(p_vehicle_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_vehicle RECORD;
BEGIN
  SELECT * INTO v_vehicle FROM vehicles WHERE id = p_vehicle_id;
  IF v_vehicle.id IS NULL THEN
    RAISE EXCEPTION 'Vehículo no encontrado';
  END IF;

  IF v_vehicle.driver_id != v_driver_id THEN
    RAISE EXCEPTION 'No es tu vehículo';
  END IF;

  IF NOT v_vehicle.is_approved THEN
    RAISE EXCEPTION 'El vehículo no está aprobado por el administrador';
  END IF;

  -- Actualizar: el trigger desactiva los demás
  UPDATE vehicles SET is_active_vehicle = TRUE, updated_at = NOW() WHERE id = p_vehicle_id;

  RETURN jsonb_build_object('success', TRUE, 'vehicle_id', p_vehicle_id, 'is_active', TRUE);
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_active_vehicle TO authenticated, anon;

-- 3.4 Obtener vehículos del conductor actual
CREATE OR REPLACE FUNCTION public.get_driver_vehicles()
RETURNS SETOF vehicles
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT * FROM vehicles WHERE driver_id = auth.uid() ORDER BY is_active_vehicle DESC, created_at DESC;
$$;

GRANT EXECUTE ON FUNCTION public.get_driver_vehicles TO authenticated, anon;

-- ============================================================
SELECT 'Migración de vehículos múltiples completada' AS estado;