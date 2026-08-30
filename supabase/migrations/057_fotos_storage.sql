-- ============================================================
-- BUNRIDER - Migración 057: FOTOS DE CONDUCTOR Y VEHÍCULO
-- ------------------------------------------------------------
-- 1) El bucket 'avatars' pasa a ser PÚBLICO (las fotos de perfil
--    se ven con URL pública, igual que 'vehicles').
-- 2) Se normalizan los datos existentes: las rutas de storage
--    guardadas en vehicles.photo_url y profiles.avatar_url se
--    convierten a URLs públicas completas (algunas fotos se
--    guardaron como ruta y se veían "corrompidas").
-- 3) get_ride_driver_info incluye avatar_url del conductor
--    (para la tarjeta del pasajero).
-- ============================================================

-- 1. Bucket avatars público (fotos de perfil visibles)
UPDATE storage.buckets SET public = TRUE WHERE id = 'avatars';

-- 2. Normalizar URLs de fotos de vehículos (rutas → URL pública)
UPDATE public.vehicles
SET photo_url = 'https://inxxhkwybjkcaeyahami.supabase.co/storage/v1/object/public/vehicles/' || photo_url
WHERE photo_url IS NOT NULL
  AND photo_url NOT LIKE 'http%'
  AND photo_url NOT LIKE 'data:%'
  AND photo_url NOT LIKE 'blob:%'
  AND photo_url NOT LIKE '/%'
  AND photo_url NOT LIKE 'vehicles/%';

-- 3. Normalizar URLs de avatares (rutas → URL pública)
UPDATE public.profiles
SET avatar_url = 'https://inxxhkwybjkcaeyahami.supabase.co/storage/v1/object/public/avatars/' || avatar_url
WHERE avatar_url IS NOT NULL
  AND avatar_url NOT LIKE 'http%'
  AND avatar_url NOT LIKE 'data:%'
  AND avatar_url NOT LIKE 'avatars/%';

-- 4. get_ride_driver_info: incluir avatar_url del conductor
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

  IF v_ride.client_id != v_user_id
     AND public.get_user_role(v_user_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF v_ride.driver_id IS NULL THEN
    RETURN jsonb_build_object('driver', NULL, 'vehicle', NULL);
  END IF;

  SELECT p.id, p.full_name, p.phone, p.avatar_url
  INTO v_driver
  FROM profiles p
  WHERE p.id = v_ride.driver_id;

  SELECT ROUND(AVG(r.rating)::numeric, 1) AS avg,
         COUNT(r.rating) AS n_rating,
         COUNT(*) AS n_rides
  INTO v_rating_avg, v_rating_count, v_rides_count
  FROM rides r
  WHERE r.driver_id = v_ride.driver_id;

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
      'avatar_url', v_driver.avatar_url,
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

GRANT EXECUTE ON FUNCTION public.get_ride_driver_info(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_ride_driver_info FROM anon;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 057: fotos de conductor y vehículo listas' AS estado;

SELECT p.email, p.avatar_url, v.photo_url
FROM profiles p LEFT JOIN vehicles v ON v.driver_id = p.id
WHERE p.email IN ('carro5@gmail.com', 'leonardymoto1@gmail.com')
ORDER BY p.email;
