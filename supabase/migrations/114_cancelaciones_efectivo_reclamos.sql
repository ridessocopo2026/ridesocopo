-- ============================================================
-- 114 - CANCELACIONES: RECLAMO DEL CLIENTE
-- ------------------------------------------------------------
-- report_ride_incident: permite al cliente reclamar una
-- cancelación (7 días). Si ya existe el incidente automático
-- de cancelación, el reclamo se adjunta a ese incidente.
-- ============================================================

-- ============================================================
-- 4. REPORT_RIDE_INCIDENT
--    · El cliente puede reclamar una cancelación (7 días).
--    · Si ya existe el incidente automático de cancelación, el
--      reclamo se adjunta a ese incidente (no se duplica).
-- ============================================================
CREATE OR REPLACE FUNCTION public.report_ride_incident(
  p_ride_id UUID,
  p_incident_type TEXT,
  p_description TEXT DEFAULT NULL,
  p_photo_urls JSONB DEFAULT '[]'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_ride RECORD;
  v_incident_id UUID;
  v_existing RECORD;
  v_is_dispute BOOLEAN;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('report_ride_incident', 5);

  IF p_incident_type NOT IN ('accidente', 'falla_mecanica', 'urgencia_medica', 'clima', 'otro',
                             'viaje_no_realizado', 'disputa_cobro') THEN
    RAISE EXCEPTION 'Tipo de incidente no válido';
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id FOR UPDATE;

  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF v_ride.client_id != v_user_id AND v_ride.driver_id != v_user_id THEN
    RAISE EXCEPTION 'No autorizado para este viaje';
  END IF;

  -- ----------------------------------------------------------
  -- 4.1 CANCELACIÓN: reclamo del cliente sobre el cargo
  -- ----------------------------------------------------------
  IF v_ride.status = 'cancelada' THEN
    IF v_user_id != v_ride.client_id THEN
      RAISE EXCEPTION 'Solo el cliente puede reportar inconformidad con una cancelación';
    END IF;

    IF v_ride.updated_at < NOW() - INTERVAL '7 days' THEN
      RAISE EXCEPTION 'El plazo para reportar esta cancelación venció';
    END IF;

    IF p_incident_type NOT IN ('viaje_no_realizado', 'disputa_cobro', 'otro') THEN
      RAISE EXCEPTION 'Tipo de reporte no válido para una cancelación';
    END IF;

    SELECT * INTO v_existing
    FROM ride_incidents
    WHERE ride_id = p_ride_id
      AND incident_type = 'cancelacion_cliente'
      AND status IN ('abierto', 'en_revision')
    ORDER BY created_at DESC
    LIMIT 1
    FOR UPDATE;

    IF v_existing.id IS NOT NULL THEN
      UPDATE ride_incidents
      SET description = COALESCE(description, '') || E'\n\n[Reclamo del cliente] ' || COALESCE(p_description, 'Sin detalle'),
          photo_urls = COALESCE(photo_urls, '[]'::jsonb) || COALESCE(p_photo_urls, '[]'::jsonb),
          status = 'en_revision',
          updated_at = NOW()
      WHERE id = v_existing.id;

      INSERT INTO notifications (user_id, title, body, type, data)
      SELECT p.id,
             '🚨 Reclamo de cancelación',
             CONCAT('El cliente reclamó el cargo del viaje ', substring(p_ride_id::text, 1, 8), '. Revisa y resuelve.'),
             'incident_reported',
             jsonb_build_object(
               'incident_id', v_existing.id, 'ride_id', p_ride_id,
               'url', CASE WHEN p.role = 'encargado' THEN '/encargado/incidentes' ELSE '/admin/incidentes' END
             )
      FROM profiles p
      WHERE p.role = 'super_admin'
         OR (p.role = 'encargado' AND p.zone_id = v_ride.origin_zone_id);

      INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
      VALUES (v_user_id, 'DISPUTE_CANCELLATION', 'incident', v_existing.id,
              jsonb_build_object('ride_id', p_ride_id, 'type', p_incident_type, 'attached', TRUE));

      RETURN jsonb_build_object(
        'success', TRUE, 'incident_id', v_existing.id, 'ride_id', p_ride_id,
        'status', 'cancelada', 'dispute', TRUE, 'attached', TRUE
      );
    END IF;

    INSERT INTO ride_incidents (ride_id, reported_by, incident_type, description, photo_urls, status)
    VALUES (p_ride_id, v_user_id, p_incident_type, p_description,
            COALESCE(p_photo_urls, '[]'::jsonb), 'abierto')
    RETURNING id INTO v_incident_id;

    UPDATE rides SET incident_id = v_incident_id, updated_at = NOW() WHERE id = p_ride_id;

    INSERT INTO notifications (user_id, title, body, type, data)
    SELECT p.id,
           '🚨 Disputa: ' || p_incident_type,
           CONCAT('El cliente disputó el viaje ', substring(p_ride_id::text, 1, 8), '. Revisa y resuelve.'),
           'incident_reported',
           jsonb_build_object(
             'incident_id', v_incident_id, 'ride_id', p_ride_id,
             'url', CASE WHEN p.role = 'encargado' THEN '/encargado/incidentes' ELSE '/admin/incidentes' END
           )
    FROM profiles p
    WHERE p.role = 'super_admin'
       OR (p.role = 'encargado' AND p.zone_id = v_ride.origin_zone_id);

    IF v_ride.driver_id IS NOT NULL THEN
      PERFORM public.notify_user(
        v_ride.driver_id, 'Disputa de viaje',
        'El cliente reportó un problema con la cancelación. La plataforma lo está revisando.',
        'ride_incident', jsonb_build_object('ride_id', p_ride_id, 'incident_id', v_incident_id)
      );
    END IF;

    INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
    VALUES (v_user_id, 'REPORT_INCIDENT', 'incident', v_incident_id,
            jsonb_build_object('ride_id', p_ride_id, 'type', p_incident_type, 'dispute', TRUE, 'attached', FALSE));

    RETURN jsonb_build_object(
      'success', TRUE, 'incident_id', v_incident_id, 'ride_id', p_ride_id,
      'status', 'cancelada', 'dispute', TRUE, 'attached', FALSE
    );
  END IF;

  -- ----------------------------------------------------------
  -- 4.2 RESTO: viaje activo (incidente) o completado (disputa)
  -- ----------------------------------------------------------
  v_is_dispute := (v_ride.status = 'completada');

  IF NOT v_is_dispute AND v_ride.status NOT IN ('aceptada', 'en_ruta') THEN
    RAISE EXCEPTION 'Solo se puede reportar un incidente durante un viaje activo';
  END IF;

  IF v_is_dispute AND v_user_id != v_ride.client_id THEN
    RAISE EXCEPTION 'Solo el cliente puede disputar un viaje completado';
  END IF;

  IF v_is_dispute AND p_incident_type NOT IN ('viaje_no_realizado', 'disputa_cobro', 'otro') THEN
    RAISE EXCEPTION 'Tipo de reporte no válido para un viaje completado';
  END IF;

  IF EXISTS (
    SELECT 1 FROM ride_incidents
    WHERE ride_id = p_ride_id AND status IN ('abierto', 'en_revision')
  ) THEN
    RAISE EXCEPTION 'Este viaje ya tiene un reporte en revisión';
  END IF;

  INSERT INTO ride_incidents (ride_id, reported_by, incident_type, description, photo_urls, status)
  VALUES (p_ride_id, v_user_id, p_incident_type, p_description,
          COALESCE(p_photo_urls, '[]'::jsonb), 'abierto')
  RETURNING id INTO v_incident_id;

  IF v_is_dispute THEN
    UPDATE rides
    SET incident_id = v_incident_id,
        updated_at = NOW()
    WHERE id = p_ride_id;
  ELSE
    UPDATE rides
    SET status = 'incidente',
        incident_id = v_incident_id,
        updated_at = NOW()
    WHERE id = p_ride_id;
  END IF;

  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT p.id,
         CONCAT('🚨 ', CASE WHEN v_is_dispute THEN 'Disputa: ' ELSE 'Incidente: ' END, p_incident_type),
         CONCAT('Reportado en el viaje ', substring(p_ride_id::text, 1, 8), '. Revisa y resuelve.'),
         'incident_reported',
         jsonb_build_object(
           'incident_id', v_incident_id, 'ride_id', p_ride_id,
           'url', CASE WHEN p.role = 'encargado' THEN '/encargado/incidentes' ELSE '/admin/incidentes' END
         )
  FROM profiles p
  WHERE p.role = 'super_admin'
     OR (p.role = 'encargado' AND p.zone_id = v_ride.origin_zone_id);

  IF v_ride.client_id IS NOT NULL AND v_ride.driver_id IS NOT NULL THEN
    PERFORM public.notify_user(
      CASE WHEN v_user_id = v_ride.client_id THEN v_ride.driver_id ELSE v_ride.client_id END,
      CASE WHEN v_is_dispute THEN 'Disputa de viaje' ELSE 'Incidente reportado' END,
      'Se reportó un problema en tu viaje. La plataforma lo está revisando.',
      'ride_incident',
      jsonb_build_object('ride_id', p_ride_id, 'incident_id', v_incident_id)
    );
  END IF;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_user_id, 'REPORT_INCIDENT', 'incident', v_incident_id,
          jsonb_build_object('ride_id', p_ride_id, 'type', p_incident_type, 'dispute', v_is_dispute));

  RETURN jsonb_build_object(
    'success', TRUE,
    'incident_id', v_incident_id,
    'ride_id', p_ride_id,
    'status', CASE WHEN v_is_dispute THEN v_ride.status ELSE 'incidente' END,
    'dispute', v_is_dispute
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.report_ride_incident TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.report_ride_incident FROM anon;
