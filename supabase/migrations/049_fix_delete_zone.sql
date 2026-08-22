-- ============================================================
-- RIDERFLASSHI - Migración 049: FIX DELETE_ZONE
-- ------------------------------------------------------------
-- Incluye en el bloqueo los viajes que usan barrios de la zona
-- (los viajes previos a 046 tienen zone_id NULL pero sí
-- referencian destination_barrio_id).
-- ============================================================

CREATE OR REPLACE FUNCTION public.delete_zone(p_zone_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_zone RECORD;
  v_barrios INTEGER;
  v_rides INTEGER;
  v_other_cities INTEGER;
BEGIN
  IF public.get_user_role(v_admin_id) != 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT * INTO v_zone FROM zones WHERE id = p_zone_id;
  IF v_zone.id IS NULL THEN
    RAISE EXCEPTION 'Zona no encontrada';
  END IF;

  -- No permitir eliminar la única ciudad activa
  IF v_zone.zone_type = 'cobertura_general' THEN
    SELECT COUNT(*) INTO v_other_cities FROM zones
    WHERE zone_type = 'cobertura_general' AND is_active = TRUE AND id <> p_zone_id;
    IF v_other_cities = 0 THEN
      RETURN jsonb_build_object(
        'success', FALSE, 'error', 'ULTIMA_CIUDAD',
        'message', 'No puedes eliminar la única ciudad de la plataforma.'
      );
    END IF;
  END IF;

  -- No eliminar si hay viajes registrados en la zona o que usan sus barrios
  SELECT COUNT(*) INTO v_rides FROM rides
  WHERE origin_zone_id = p_zone_id
     OR destination_zone_id = p_zone_id
     OR destination_barrio_id IN (SELECT id FROM barrios WHERE zone_id = p_zone_id);
  IF v_rides > 0 THEN
    RETURN jsonb_build_object(
      'success', FALSE, 'error', 'ZONA_CON_VIAJES',
      'message', format('No se puede eliminar: hay %s viaje(s) registrados en esta zona.', v_rides)
    );
  END IF;

  SELECT COUNT(*) INTO v_barrios FROM barrios WHERE zone_id = p_zone_id;

  UPDATE profiles SET zone_id = NULL, updated_at = NOW() WHERE zone_id = p_zone_id;

  DELETE FROM barrios WHERE zone_id = p_zone_id;
  DELETE FROM zones WHERE id = p_zone_id;

  RETURN jsonb_build_object('success', TRUE, 'deleted_barrios', v_barrios);
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_zone(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.delete_zone FROM anon;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'OK: migración 049 aplicada' AS estado;
