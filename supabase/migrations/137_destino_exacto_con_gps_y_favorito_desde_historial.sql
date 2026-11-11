-- 137 - Destino exacto con la ubicacion ACTUAL del cliente.
--
-- Antes, "Guardar destino" guardaba el centroide del sector (ride.destination_lat/lng),
-- no el punto donde el cliente se bajo. Ahora el cliente toma su GPS en ese momento
-- y ese punto queda en el favorito y en el viaje.
--
-- Tambien permite fijar el punto exacto de un viaje ya completado desde el historial
-- (con aviso de que se usara la ubicacion actual).

-- ------------------------------------------------------------
-- 1) Trazabilidad
-- ------------------------------------------------------------
ALTER TABLE public.favorite_places
  ADD COLUMN IF NOT EXISTS source_ride_id UUID REFERENCES public.rides(id) ON DELETE SET NULL,
  ADD COLUMN IF NOT EXISTS accuracy_m NUMERIC;

ALTER TABLE public.rides
  ADD COLUMN IF NOT EXISTS destination_exact_set_at TIMESTAMPTZ,
  ADD COLUMN IF NOT EXISTS destination_exact_source TEXT;

COMMENT ON COLUMN public.favorite_places.source_ride_id IS 'Viaje del que salio el punto guardado';
COMMENT ON COLUMN public.favorite_places.accuracy_m IS 'Precision GPS en metros al guardar';
COMMENT ON COLUMN public.rides.destination_exact_source IS 'recogida | historial: origen del punto exacto';

-- ------------------------------------------------------------
-- 2) Utilidades internas
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.assert_valid_point(p_lat NUMERIC, p_lng NUMERIC)
RETURNS VOID
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  IF p_lat IS NULL OR p_lng IS NULL THEN
    RAISE EXCEPTION 'Falta la ubicación';
  END IF;

  IF p_lat = 0 AND p_lng = 0 THEN
    RAISE EXCEPTION 'Ubicación inválida';
  END IF;

  IF p_lat NOT BETWEEN -90 AND 90 OR p_lng NOT BETWEEN -180 AND 180 THEN
    RAISE EXCEPTION 'Ubicación fuera de rango';
  END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.assert_valid_point(NUMERIC, NUMERIC) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.assert_valid_point(NUMERIC, NUMERIC) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.upsert_favorite_place(
  p_user_id UUID,
  p_name TEXT,
  p_address TEXT,
  p_lat NUMERIC,
  p_lng NUMERIC,
  p_source_ride_id UUID DEFAULT NULL,
  p_accuracy_m NUMERIC DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_place_id UUID;
  v_name TEXT := NULLIF(BTRIM(COALESCE(p_name, '')), '');
  v_address TEXT := NULLIF(BTRIM(COALESCE(p_address, '')), '');
BEGIN
  IF p_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Escribe un nombre para el lugar';
  END IF;

  PERFORM public.assert_valid_point(p_lat, p_lng);

  SELECT id INTO v_place_id
  FROM public.favorite_places
  WHERE user_id = p_user_id
    AND LOWER(BTRIM(name)) = LOWER(v_name)
  LIMIT 1;

  IF v_place_id IS NOT NULL THEN
    UPDATE public.favorite_places
    SET name = v_name,
        address = COALESCE(v_address, address),
        lat = p_lat,
        lng = p_lng,
        source_ride_id = COALESCE(p_source_ride_id, source_ride_id),
        accuracy_m = COALESCE(p_accuracy_m, accuracy_m)
    WHERE id = v_place_id;

    RETURN v_place_id;
  END IF;

  INSERT INTO public.favorite_places (user_id, name, address, lat, lng, source_ride_id, accuracy_m)
  VALUES (p_user_id, v_name, v_address, p_lat, p_lng, p_source_ride_id, p_accuracy_m)
  RETURNING id INTO v_place_id;

  RETURN v_place_id;
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_favorite_place(UUID, TEXT, TEXT, NUMERIC, NUMERIC, UUID, NUMERIC) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.upsert_favorite_place(UUID, TEXT, TEXT, NUMERIC, NUMERIC, UUID, NUMERIC) FROM anon, authenticated;
GRANT EXECUTE ON FUNCTION public.upsert_favorite_place(UUID, TEXT, TEXT, NUMERIC, NUMERIC, UUID, NUMERIC) TO service_role;

-- ------------------------------------------------------------
-- 3) save_favorite_place ahora delega (misma firma, sin romper llamadas)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_favorite_place(
  p_name text,
  p_address text,
  p_lat numeric,
  p_lng numeric
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  RETURN public.upsert_favorite_place(v_user_id, p_name, p_address, p_lat, p_lng);
END;
$$;

REVOKE ALL ON FUNCTION public.save_favorite_place(text, text, numeric, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_favorite_place(text, text, numeric, numeric) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.save_favorite_place(text, text, numeric, numeric) FROM anon;

-- ------------------------------------------------------------
-- 4) Fijar el destino exacto de un viaje completado (solo el punto)
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_ride_exact_destination(
  p_ride_id UUID,
  p_lat NUMERIC,
  p_lng NUMERIC
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_ride RECORD;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.assert_valid_point(p_lat, p_lng);

  SELECT r.id, r.status::text AS status
  INTO v_ride
  FROM public.rides r
  WHERE r.id = p_ride_id
    AND r.client_id = v_uid;

  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Este viaje no está en tu historial';
  END IF;

  IF v_ride.status <> 'completada' THEN
    RAISE EXCEPTION 'Solo puedes fijar el destino de un viaje completado';
  END IF;

  UPDATE public.rides
  SET destination_lat = p_lat,
      destination_lng = p_lng,
      destination_is_exact = TRUE,
      destination_exact_set_at = NOW(),
      destination_exact_source = 'historial',
      updated_at = NOW()
  WHERE id = p_ride_id;

  RETURN jsonb_build_object('success', TRUE, 'ride_id', p_ride_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_ride_exact_destination(UUID, NUMERIC, NUMERIC) TO authenticated;
REVOKE ALL ON FUNCTION public.set_ride_exact_destination(UUID, NUMERIC, NUMERIC) FROM anon;

-- ------------------------------------------------------------
-- 5) Guardar el destino del viaje como lugar favorito con el GPS actual
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.save_ride_place(
  p_ride_id UUID,
  p_name TEXT,
  p_lat NUMERIC,
  p_lng NUMERIC,
  p_accuracy_m NUMERIC DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_ride RECORD;
  v_place_id UUID;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.assert_valid_point(p_lat, p_lng);

  SELECT r.id, r.status::text AS status, r.destination_address
  INTO v_ride
  FROM public.rides r
  WHERE r.id = p_ride_id
    AND r.client_id = v_uid;

  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Este viaje no está en tu historial';
  END IF;

  IF v_ride.status <> 'completada' THEN
    RAISE EXCEPTION 'Solo puedes guardar el destino de un viaje completado';
  END IF;

  v_place_id := public.upsert_favorite_place(
    v_uid, p_name, v_ride.destination_address, p_lat, p_lng, p_ride_id, p_accuracy_m
  );

  UPDATE public.rides
  SET destination_lat = p_lat,
      destination_lng = p_lng,
      destination_is_exact = TRUE,
      destination_exact_set_at = NOW(),
      destination_exact_source = 'recogida',
      updated_at = NOW()
  WHERE id = p_ride_id;

  RETURN jsonb_build_object(
    'success', TRUE,
    'place_id', v_place_id,
    'ride_id', p_ride_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.save_ride_place(UUID, TEXT, NUMERIC, NUMERIC, NUMERIC) TO authenticated;
REVOKE ALL ON FUNCTION public.save_ride_place(UUID, TEXT, NUMERIC, NUMERIC, NUMERIC) FROM anon;
