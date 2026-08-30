-- ============================================================
-- BUNRIDER - Migración 055: INFO DEL CONDUCTOR PARA EL PASAJERO
-- ------------------------------------------------------------
-- El pasajero del viaje puede ver:
--   - Datos del conductor: nombre, teléfono, calificación
--     promedio (media de rides.driver_rating), nº de
--     calificaciones y nº de viajes.
--   - Su vehículo activo: categoría, marca, modelo, color,
--     placa y foto.
-- Costo: 1 llamada por viaje (guard_rate_limit 30/min) + 1
-- query indexada por driver_id. Sin tablas nuevas.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_ride_driver_info(p_ride_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_ride RECORD;
  v_driver RECORD;
  v_vehicle RECORD;
  v_rating_avg NUMERIC;
  v_rating_count INTEGER;
  v_rides_count INTEGER;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('get_ride_driver_info', 30);

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  -- Solo el cliente del viaje (o super_admin/encargado) puede ver los datos
  IF v_ride.client_id != v_user_id
     AND public.get_user_role(v_user_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF v_ride.driver_id IS NULL THEN
    RETURN jsonb_build_object('driver', NULL, 'vehicle', NULL);
  END IF;

  SELECT p.id, p.full_name, p.phone
  INTO v_driver
  FROM profiles p
  WHERE p.id = v_ride.driver_id;

  SELECT ROUND(AVG(r.rating)::numeric, 1) AS avg,
         COUNT(r.rating) AS n_rating,
         COUNT(*) AS n_rides
  INTO v_rating_avg, v_rating_count, v_rides_count
  FROM rides r
  WHERE r.driver_id = v_ride.driver_id;

  -- Vehículo activo actual del conductor (aprobado)
  SELECT v.id, v.category, v.brand, v.model, v.color, v.plate, v.photo_url
  INTO v_vehicle
  FROM vehicles v
  WHERE v.driver_id = v_ride.driver_id
    AND v.is_approved = TRUE
  ORDER BY v.is_active_vehicle DESC NULLS LAST, v.updated_at DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'driver', jsonb_build_object(
      'id', v_driver.id,
      'full_name', v_driver.full_name,
      'phone', v_driver.phone,
      'rating_avg', v_rating_avg,
      'rating_count', v_rating_count,
      'rides_count', v_rides_count
    ),
    'vehicle', CASE WHEN v_vehicle.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id', v_vehicle.id,
      'category', v_vehicle.category,
      'brand', v_vehicle.brand,
      'model', v_vehicle.model,
      'color', v_vehicle.color,
      'plate', v_vehicle.plate,
      'photo_url', v_vehicle.photo_url
    ) END
  );
END;
$$;

-- Permisos: solo autenticados (la RPC valida que sea el cliente del viaje)
GRANT EXECUTE ON FUNCTION public.get_ride_driver_info(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_ride_driver_info FROM anon;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 055: info del conductor lista' AS estado;
