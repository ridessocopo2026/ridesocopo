-- ============================================================
-- 133 - LUGARES GUARDADOS SIN DUPLICADOS
-- ------------------------------------------------------------
-- save_favorite_place siempre insertaba: guardar dos veces "Casa"
-- creaba dos filas y ensuciaba la lista de "Lugares guardados"
-- (que ahora se muestra dentro de la hoja de destino).
--
-- Ahora es un upsert por nombre (sin distinguir mayusculas): si el
-- usuario ya tiene un lugar con ese nombre, se actualizan direccion
-- y coordenadas. Tambien valida sesion y nombre vacio.
-- ============================================================
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
AS $function$
DECLARE
  v_user_id UUID := auth.uid();
  v_place_id UUID;
  v_name TEXT := NULLIF(BTRIM(COALESCE(p_name, '')), '');
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Escribe un nombre para el lugar';
  END IF;

  -- Si ya existe un lugar con ese nombre, se actualiza
  SELECT id INTO v_place_id
  FROM favorite_places
  WHERE user_id = v_user_id
    AND LOWER(BTRIM(name)) = LOWER(v_name)
  LIMIT 1;

  IF v_place_id IS NOT NULL THEN
    UPDATE favorite_places
    SET name = v_name,
        address = p_address,
        lat = p_lat,
        lng = p_lng
    WHERE id = v_place_id;

    RETURN v_place_id;
  END IF;

  INSERT INTO favorite_places (user_id, name, address, lat, lng)
  VALUES (v_user_id, v_name, p_address, p_lat, p_lng)
  RETURNING id INTO v_place_id;

  RETURN v_place_id;
END;
$function$;

REVOKE ALL ON FUNCTION public.save_favorite_place(text, text, numeric, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.save_favorite_place(text, text, numeric, numeric) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.save_favorite_place(text, text, numeric, numeric) FROM anon;