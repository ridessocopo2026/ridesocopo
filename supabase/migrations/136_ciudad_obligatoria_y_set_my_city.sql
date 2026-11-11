-- 136 - Ciudad obligatoria:
--   1) Nueva RPC set_my_city para que el usuario elija/cambie su ciudad.
--   2) complete_onboarding valida la ciudad (antes aceptaba NULL y dejaba
--      perfiles sin zone_id, lo que ademas los excluia de las difusiones).
--   3) Correccion unica: clientes sin ciudad -> Socopo (Merida no tiene
--      usuarios ni viajes; toda la operacion es Socopo).

-- ------------------------------------------------------------
-- 1) ELEGIR / CAMBIAR MI CIUDAD
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.set_my_city(p_zone_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_uid UUID := auth.uid();
  v_id UUID;
  v_name TEXT;
BEGIN
  IF v_uid IS NULL THEN
    RAISE EXCEPTION ''No autenticado'';
  END IF;

  IF NOT public.is_account_active(v_uid) THEN
    RAISE EXCEPTION ''Tu cuenta no esta activa. Contacta a soporte.'';
  END IF;

  IF p_zone_id IS NULL THEN
    RAISE EXCEPTION ''Selecciona tu ciudad'';
  END IF;

  SELECT id, name INTO v_id, v_name
  FROM public.zones
  WHERE id = p_zone_id
    AND is_active = TRUE
    AND zone_type = ''cobertura_general'';

  IF v_id IS NULL THEN
    RAISE EXCEPTION ''Ciudad no disponible'';
  END IF;

  UPDATE public.profiles
  SET zone_id = v_id, updated_at = NOW()
  WHERE id = v_uid;

  RETURN jsonb_build_object(''success'', TRUE, ''zone_id'', v_id, ''zone_name'', v_name);
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_my_city(UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.set_my_city(UUID) FROM anon;

-- ------------------------------------------------------------
-- 2) ONBOARDING: la ciudad es obligatoria y debe estar activa
-- ------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.complete_onboarding(
  p_role public.user_role,
  p_zone_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_profile RECORD;
  v_zone_id UUID;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION ''No autenticado'';
  END IF;

  IF NOT public.is_account_active(v_user_id) THEN
    RAISE EXCEPTION ''Tu cuenta no esta activa. Contacta a soporte.'';
  END IF;

  IF p_role NOT IN (''cliente'', ''conductor'') THEN
    RAISE EXCEPTION ''Rol no permitido'';
  END IF;

  -- La ciudad es obligatoria: sin ciudad no se puede completar el registro
  SELECT id INTO v_zone_id
  FROM public.zones
  WHERE id = p_zone_id
    AND is_active = TRUE
    AND zone_type = ''cobertura_general'';

  IF v_zone_id IS NULL THEN
    RAISE EXCEPTION ''Selecciona tu ciudad para continuar'';
  END IF;

  SELECT * INTO v_profile FROM public.profiles WHERE id = v_user_id;
  IF v_profile.id IS NULL THEN
    RAISE EXCEPTION ''Perfil no encontrado'';
  END IF;

  IF v_profile.role = ''conductor''
     AND v_profile.driver_status IS NOT NULL
     AND v_profile.driver_status != ''pendiente'' THEN
    RAISE EXCEPTION ''Tu cuenta ya tiene un estado como conductor. Contacta al administrador.'';
  END IF;

  UPDATE public.profiles
  SET role = p_role,
      zone_id = v_zone_id,
      driver_status = CASE WHEN p_role = ''conductor'' THEN ''pendiente'' ELSE driver_status END,
      onboarding_completed = TRUE,
      updated_at = NOW()
  WHERE id = v_user_id;

  RETURN jsonb_build_object(''success'', TRUE, ''role'', p_role::text, ''zone_id'', v_zone_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.complete_onboarding(public.user_role, UUID) TO authenticated;
REVOKE ALL ON FUNCTION public.complete_onboarding(public.user_role, UUID) FROM anon;

-- ------------------------------------------------------------
-- 3) Correccion unica: clientes sin ciudad -> Socopo
-- ------------------------------------------------------------
WITH ciudad AS (
  SELECT id
  FROM public.zones
  WHERE zone_type = ''cobertura_general''
    AND is_active = TRUE
    AND name ILIKE ''Socop%''
  ORDER BY name
  LIMIT 1
)
UPDATE public.profiles p
SET zone_id = ciudad.id,
    updated_at = NOW()
FROM ciudad
WHERE p.zone_id IS NULL
  AND p.role = ''cliente'';
