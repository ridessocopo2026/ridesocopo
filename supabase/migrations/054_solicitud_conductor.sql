-- ============================================================
-- RIDESOCOPÓ - Migración 054: SOLICITUD DE CONDUCTOR DESDE EL
-- PERFIL DEL PASAJERO
-- ------------------------------------------------------------
-- Un pasajero (rol 'cliente') puede solicitar ser conductor
-- desde su perfil. La RPC become_driver():
--   - Solo actúa sobre el propio perfil (auth.uid()).
--   - Solo permite 'cliente' → 'conductor' (nunca encargado/
--     super_admin, sin escalada de privilegios).
--   - Fija driver_status='pendiente' (nunca auto-aprobación).
--   - Requiere ciudad asignada (necesaria para ver viajes).
--   - guard_rate_limit + auditoría (REQUEST_DRIVER_ROLE).
-- ============================================================

CREATE OR REPLACE FUNCTION public.become_driver()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_profile RECORD;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('become_driver', 5);

  SELECT * INTO v_profile FROM public.profiles WHERE id = v_user_id;
  IF v_profile.id IS NULL THEN
    RAISE EXCEPTION 'Perfil no encontrado';
  END IF;

  -- Solo un pasajero puede solicitar ser conductor
  IF v_profile.role != 'cliente' THEN
    RAISE EXCEPTION 'Esta opción solo está disponible para pasajeros';
  END IF;

  -- Debe tener una ciudad asignada (necesaria para ver viajes)
  IF v_profile.zone_id IS NULL THEN
    RAISE EXCEPTION 'Debes tener una ciudad asignada para ser conductor. Contacta al administrador.';
  END IF;

  UPDATE public.profiles
  SET role = 'conductor',
      driver_status = 'pendiente',
      onboarding_completed = TRUE,
      updated_at = NOW()
  WHERE id = v_user_id;

  -- 📝 Auditoría (el admin lo ve en Auditoría y en Conductores pendientes)
  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_user_id, 'REQUEST_DRIVER_ROLE', 'profile', v_user_id,
          jsonb_build_object('zone_id', v_profile.zone_id));

  RETURN jsonb_build_object('success', TRUE, 'role', 'conductor', 'driver_status', 'pendiente');
END;
$$;

-- Permisos: solo usuarios autenticados (la RPC valida el rol)
GRANT EXECUTE ON FUNCTION public.become_driver() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.become_driver() FROM anon;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 054: solicitud de conductor lista' AS estado;
