-- ============================================================
-- RIDESOCOPÓ - Migración: DISPUTAS DE VIAJES COMPLETADOS
-- Permite al cliente disputar un viaje que fue marcado como
-- 'completada' pero que realmente no se realizó (o el cobro
-- no corresponde). Reutiliza el sistema de incidentes existente.
-- ============================================================

-- ============================================================
-- 1. AMPLIAR TIPOS DE INCIDENTE
--    Se agregan 'viaje_no_realizado' y 'disputa_cobro'
-- ============================================================
ALTER TABLE ride_incidents
  DROP CONSTRAINT IF EXISTS ride_incidents_incident_type_check;

ALTER TABLE ride_incidents
  ADD CONSTRAINT ride_incidents_incident_type_check
  CHECK (incident_type IN (
    'accidente', 'falla_mecanica', 'urgencia_medica', 'clima', 'otro',
    'viaje_no_realizado', 'disputa_cobro'
  ));

-- ============================================================
-- 2. REESCRIBIR REPORT_RIDE_INCIDENT
--    - Soporta reportes en viajes 'completada' (disputas)
--    - Solo el CLIENTE puede disputar un viaje completado
--    - En disputas NO se cambia el status del viaje (se mantiene
--      'completada' para no corromper métricas) pero se enlaza
--      el incidente en rides.incident_id
--    - Evita reportes duplicados (mismo viaje con reporte abierto)
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
  v_is_dispute BOOLEAN;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  -- Validar tipo
  IF p_incident_type NOT IN ('accidente', 'falla_mecanica', 'urgencia_medica', 'clima', 'otro',
                             'viaje_no_realizado', 'disputa_cobro') THEN
    RAISE EXCEPTION 'Tipo de incidente no válido';
  END IF;

  -- Obtener viaje con bloqueo
  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id FOR UPDATE;

  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  -- Solo participantes del viaje pueden reportar
  IF v_ride.client_id != v_user_id AND v_ride.driver_id != v_user_id THEN
    RAISE EXCEPTION 'No autorizado para este viaje';
  END IF;

  -- Determinar si es disputa post-viaje
  v_is_dispute := (v_ride.status = 'completada');

  IF NOT v_is_dispute AND v_ride.status NOT IN ('aceptada', 'en_ruta') THEN
    RAISE EXCEPTION 'Solo se puede reportar un incidente durante un viaje activo';
  END IF;

  -- En viajes completados, solo el CLIENTE puede disputar
  -- (el conductor es quien marcó el viaje como completado)
  IF v_is_dispute AND v_user_id != v_ride.client_id THEN
    RAISE EXCEPTION 'Solo el cliente puede disputar un viaje completado';
  END IF;

  -- En disputas solo se permiten tipos de disputa
  IF v_is_dispute AND p_incident_type NOT IN ('viaje_no_realizado', 'disputa_cobro', 'otro') THEN
    RAISE EXCEPTION 'Tipo de reporte no válido para un viaje completado';
  END IF;

  -- Evitar duplicados: no permitir otro reporte si ya hay uno abierto/en_revision
  IF EXISTS (
    SELECT 1 FROM ride_incidents
    WHERE ride_id = p_ride_id AND status IN ('abierto', 'en_revision')
  ) THEN
    RAISE EXCEPTION 'Este viaje ya tiene un reporte en revisión';
  END IF;

  -- Crear incidente
  INSERT INTO ride_incidents (ride_id, reported_by, incident_type, description, photo_urls, status)
  VALUES (p_ride_id, v_user_id, p_incident_type, p_description, COALESCE(p_photo_urls, '[]'::jsonb), 'abierto')
  RETURNING id INTO v_incident_id;

  -- Actualizar el viaje
  IF v_is_dispute THEN
    -- Disputa post-viaje: NO cambiar el status (mantener 'completada'),
    -- solo enlazar el incidente para rastreo
    UPDATE rides
    SET incident_id = v_incident_id,
        updated_at = NOW()
    WHERE id = p_ride_id;
  ELSE
    -- Incidente durante el viaje: congelar el proceso
    UPDATE rides
    SET status = 'incidente',
        incident_id = v_incident_id,
        updated_at = NOW()
    WHERE id = p_ride_id;
  END IF;

  -- Notificar a admins con prioridad
  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT id,
         CONCAT('🚨 ', CASE WHEN v_is_dispute THEN 'Disputa: ' ELSE 'Incidente: ' END, p_incident_type),
         CONCAT('Reportado en el viaje ', substring(p_ride_id::text, 1, 8), '. Revisa y resuelve.'),
         'incident_reported',
         jsonb_build_object('incident_id', v_incident_id, 'ride_id', p_ride_id, 'url', '/admin/incidentes')
  FROM profiles WHERE role IN ('super_admin', 'encargado');

  -- Notificar al otro participante
  IF v_ride.client_id IS NOT NULL AND v_ride.driver_id IS NOT NULL THEN
    PERFORM public.notify_user(
      CASE WHEN v_user_id = v_ride.client_id THEN v_ride.driver_id ELSE v_ride.client_id END,
      CASE WHEN v_is_dispute THEN 'Disputa de viaje' ELSE 'Incidente reportado' END,
      'Se reportó un problema en tu viaje. La plataforma lo está revisando.',
      'ride_incident',
      jsonb_build_object('ride_id', p_ride_id, 'incident_id', v_incident_id)
    );
  END IF;

  -- Auditoría
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

GRANT EXECUTE ON FUNCTION public.report_ride_incident TO anon, authenticated, service_role;

-- ============================================================
-- 3. ACTUALIZAR RLS: permitir INSERT en viajes 'completada'
--    (solo el cliente del viaje)
-- ============================================================
DROP POLICY IF EXISTS "ride_participants_insert_incidents" ON public.ride_incidents;
CREATE POLICY "ride_participants_insert_incidents" ON public.ride_incidents
  FOR INSERT WITH CHECK (
    auth.uid() = reported_by
    AND EXISTS (
      SELECT 1 FROM rides r
      WHERE r.id = ride_incidents.ride_id
        AND (
          (r.status IN ('aceptada', 'en_ruta', 'incidente')
            AND (r.client_id = auth.uid() OR r.driver_id = auth.uid()))
          OR
          (r.status = 'completada' AND r.client_id = auth.uid())
        )
    )
  );

-- ============================================================
-- Verificación
-- ============================================================
SELECT 'Migración de disputas de viajes completados aplicada' AS estado;
