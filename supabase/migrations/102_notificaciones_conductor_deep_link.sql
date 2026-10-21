-- ============================================================
-- 102 - NOTIFICACIONES DE VEHICULO CON DRIVER_ID
-- Permite que el admin abra al conductor exacto desde la notificacion.
-- ============================================================

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
  v_driver_zone UUID;
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT * INTO v_driver_profiles FROM public.profiles WHERE id = v_driver_id;
  IF v_driver_profiles.role != 'conductor' THEN
    RAISE EXCEPTION 'No es conductor';
  END IF;

  v_driver_zone := v_driver_profiles.zone_id;

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

  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT id, 'Nuevo vehículo por aprobar',
         CONCAT('El conductor ', v_driver_profiles.full_name, ' registró un ', p_category, ' (', p_brand, ' ', p_model, ' ', p_color, ') placa ', UPPER(p_plate), '. Revisar.'),
         'vehicle_pending',
         jsonb_build_object('vehicle_id', v_vehicle_id, 'driver_id', v_driver_id, 'url', '/admin/conductores')
  FROM profiles
  WHERE role = 'super_admin'
     OR (role = 'encargado' AND (v_driver_zone IS NULL OR zone_id = v_driver_zone));

  RETURN v_vehicle_id;
END;
$$;

REVOKE ALL ON FUNCTION public.add_vehicle(vehicle_category, text, text, integer, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.add_vehicle(vehicle_category, text, text, integer, text, text, text) TO authenticated, service_role;

-- Backfill de notificaciones de vehiculo existentes
UPDATE public.notifications n
SET data = n.data || jsonb_build_object('driver_id', v.driver_id)
FROM public.vehicles v
WHERE n.type = 'vehicle_pending'
  AND n.data ? 'vehicle_id'
  AND (n.data->>'vehicle_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  AND (n.data->>'vehicle_id')::uuid = v.id
  AND n.data->>'driver_id' IS NULL;
