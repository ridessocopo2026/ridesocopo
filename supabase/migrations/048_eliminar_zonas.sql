-- ============================================================
-- RIDERFLASSHI - Migración 048: ELIMINAR ZONAS (seguro)
-- ------------------------------------------------------------
-- Permite eliminar zonas/ciudades desde el admin con validaciones:
--   - Solo super_admin.
--   - No se puede eliminar la ÚNICA ciudad activa.
--   - No se puede eliminar una zona con viajes registrados (historia).
--   - Se eliminan sus barrios y se desasignan los usuarios de esa zona.
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

  -- No permitir eliminar la única ciudad activa (rompería la cobertura)
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

  -- No eliminar si hay viajes registrados en la zona (historia)
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

  -- Desasignar usuarios de la zona (zone_id es un UUID simple, sin FK)
  UPDATE profiles SET zone_id = NULL, updated_at = NOW() WHERE zone_id = p_zone_id;

  -- Eliminar los barrios de la zona y la zona (misma transacción)
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
SELECT 'OK: migración 048 aplicada' AS estado;
