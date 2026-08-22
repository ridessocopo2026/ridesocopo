-- ============================================================
-- RIDERFLASSHI - Migración 050: ROL ENCARGADO POR CIUDAD + SOPORTE
-- ------------------------------------------------------------
-- 1. zones.support_whatsapp: número de soporte por ciudad.
-- 2. caller_zone_id(): zona del encargado (NULL = ve todo).
-- 3. set_user_role: crear encargados (solo super_admin, con ciudad).
-- 4. set_zone_support: admin (cualquier zona) o encargado (su zona).
-- 5. get_my_support: número de soporte de la zona del usuario.
-- ============================================================

ALTER TABLE public.zones ADD COLUMN IF NOT EXISTS support_whatsapp TEXT;

-- ============================================================
-- 1. CALLER_ZONE_ID: zona del encargado; NULL para otros roles
-- ============================================================
CREATE OR REPLACE FUNCTION public.caller_zone_id()
RETURNS UUID
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE WHEN role = 'encargado' THEN zone_id ELSE NULL END
  FROM profiles WHERE id = auth.uid();
$$;

GRANT EXECUTE ON FUNCTION public.caller_zone_id() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.caller_zone_id FROM anon;

-- ============================================================
-- 2. SET_USER_ROLE: crear/degradar encargados (solo super_admin)
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_user_role(
  p_user_id UUID,
  p_role TEXT,
  p_zone_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin UUID := auth.uid();
BEGIN
  IF public.get_user_role(v_admin) != 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF p_user_id = v_admin THEN
    RAISE EXCEPTION 'No puedes cambiar tu propio rol';
  END IF;

  IF p_role NOT IN ('cliente', 'conductor', 'encargado') THEN
    RAISE EXCEPTION 'Rol no válido';
  END IF;

  IF p_role = 'encargado' AND p_zone_id IS NULL THEN
    RAISE EXCEPTION 'Un encargado debe tener una ciudad asignada';
  END IF;

  UPDATE profiles
  SET role = p_role::public.user_role,
      zone_id = p_zone_id,
      driver_status = NULL,
      updated_at = NOW()
  WHERE id = p_user_id;

  RETURN jsonb_build_object('success', TRUE, 'user_id', p_user_id, 'role', p_role, 'zone_id', p_zone_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_user_role(uuid, text, uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.set_user_role FROM anon;

-- ============================================================
-- 3. SET_ZONE_SUPPORT: admin (cualquier zona) o encargado (su zona)
-- ============================================================
CREATE OR REPLACE FUNCTION public.set_zone_support(
  p_zone_id UUID,
  p_phone TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_role TEXT;
  v_zone UUID;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT role::text, zone_id INTO v_role, v_zone FROM profiles WHERE id = v_user_id;

  IF v_role = 'super_admin' THEN
    NULL; -- puede asignar a cualquier zona
  ELSIF v_role = 'encargado' AND v_zone = p_zone_id THEN
    NULL; -- solo su propia zona
  ELSE
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM zones WHERE id = p_zone_id) THEN
    RAISE EXCEPTION 'Zona no encontrada';
  END IF;

  UPDATE zones SET support_whatsapp = NULLIF(TRIM(p_phone), ''), updated_at = NOW()
  WHERE id = p_zone_id;

  RETURN jsonb_build_object('success', TRUE, 'zone_id', p_zone_id);
END;
$$;

GRANT EXECUTE ON FUNCTION public.set_zone_support(uuid, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.set_zone_support FROM anon;

-- ============================================================
-- 4. GET_MY_SUPPORT: número de soporte de la zona del usuario
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_my_support()
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'phone', z.support_whatsapp
  )
  FROM profiles p
  LEFT JOIN zones z ON z.id = p.zone_id
  WHERE p.id = auth.uid();
$$;

GRANT EXECUTE ON FUNCTION public.get_my_support() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_my_support FROM anon;

-- ============================================================
-- 5. GET_PENDING_PROOFS: encargado ve solo su ciudad
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_pending_proofs()
RETURNS SETOF rides
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_zone UUID := public.caller_zone_id();
BEGIN
  RETURN QUERY SELECT * FROM rides
  WHERE proof_status = 'pendiente'
    AND (v_zone IS NULL OR origin_zone_id = v_zone)
  ORDER BY created_at ASC;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_pending_proofs TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_pending_proofs FROM anon;

-- ============================================================
-- 6. GET_RIDE_INCIDENTS: encargado ve solo incidentes de su ciudad
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_ride_incidents(p_status TEXT DEFAULT NULL)
RETURNS SETOF ride_incidents
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_role TEXT;
  v_zone UUID;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT role::text, public.caller_zone_id() INTO v_role, v_zone FROM profiles WHERE id = v_user_id;

  IF v_role IN ('super_admin', 'encargado') THEN
    IF v_zone IS NOT NULL THEN
      -- Encargado: solo incidentes de viajes de su zona
      RETURN QUERY SELECT i.* FROM ride_incidents i
      INNER JOIN rides r ON r.id = i.ride_id
      WHERE (p_status IS NULL OR i.status = p_status)
        AND r.origin_zone_id = v_zone
      ORDER BY i.created_at DESC LIMIT 100;
    ELSIF p_status IS NOT NULL THEN
      RETURN QUERY SELECT * FROM ride_incidents
      WHERE status = p_status
      ORDER BY created_at DESC LIMIT 100;
    ELSE
      RETURN QUERY SELECT * FROM ride_incidents
      ORDER BY created_at DESC LIMIT 100;
    END IF;
  ELSE
    -- Participantes solo ven incidentes de sus viajes
    RETURN QUERY SELECT i.* FROM ride_incidents i
    INNER JOIN rides r ON r.id = i.ride_id
    WHERE (r.client_id = v_user_id OR r.driver_id = v_user_id)
    ORDER BY i.created_at DESC LIMIT 50;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_ride_incidents TO anon, authenticated, service_role;

-- ============================================================
-- 7. REVIEW_DRIVER: encargado solo revisa conductores de su ciudad
-- ============================================================
CREATE OR REPLACE FUNCTION public.review_driver(
  p_driver_id UUID,
  p_approve BOOLEAN,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reviewer_id UUID := auth.uid();
  v_reviewer RECORD;
  v_driver_zone UUID;
  v_new_status driver_status;
BEGIN
  SELECT * INTO v_reviewer FROM profiles WHERE id = v_reviewer_id;
  IF v_reviewer.role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado para revisar conductores';
  END IF;

  -- Encargado: el conductor debe pertenecer a su ciudad
  IF v_reviewer.role = 'encargado' THEN
    SELECT zone_id INTO v_driver_zone FROM profiles WHERE id = p_driver_id;
    IF public.caller_zone_id() IS NULL OR COALESCE(v_driver_zone, '00000000-0000-0000-0000-000000000000') != public.caller_zone_id() THEN
      RAISE EXCEPTION 'No autorizado para revisar conductores de otra ciudad';
    END IF;
  END IF;

  v_new_status := CASE WHEN p_approve THEN 'aprobado' ELSE 'rechazado' END;

  UPDATE profiles
  SET driver_status = v_new_status
  WHERE id = p_driver_id;

  PERFORM public.notify_user(
    p_driver_id,
    CASE WHEN p_approve THEN '¡Cuenta aprobada!' ELSE 'Cuenta rechazada' END,
    CASE WHEN p_approve THEN 'Ya puedes comenzar a trabajar. ¡Bienvenido!'
         ELSE COALESCE(p_reason, 'Tu solicitud fue rechazada. Contacta al administrador.') END,
    'driver_review',
    jsonb_build_object('approved', p_approve, 'url', '/conductor')
  );

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_reviewer_id, 'REVIEW_DRIVER', 'profile', p_driver_id,
          jsonb_build_object('approved', p_approve, 'reason', p_reason));

  RETURN jsonb_build_object('success', TRUE, 'driver_id', p_driver_id, 'status', v_new_status);
END;
$$;

GRANT EXECUTE ON FUNCTION public.review_driver TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.review_driver FROM anon;

-- ============================================================
-- 8. APPROVE_RIDE_PROOF: encargado solo de su ciudad
-- ============================================================
CREATE OR REPLACE FUNCTION public.approve_ride_proof(
  p_ride_id UUID,
  p_approve BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_ride RECORD;
  v_status TEXT;
  v_wallet RECORD;
  v_app_credit NUMERIC := 0.00;
  v_commission NUMERIC := 0.00;
  v_earning RECORD;
  v_fare NUMERIC;
  v_category vehicle_category;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id FOR UPDATE;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  -- Encargado: el viaje debe ser de su ciudad
  IF public.get_user_role(v_admin_id) = 'encargado'
     AND COALESCE(v_ride.origin_zone_id, '00000000-0000-0000-0000-000000000000') != public.caller_zone_id() THEN
    RAISE EXCEPTION 'No autorizado para viajes de otra ciudad';
  END IF;

  IF v_ride.proof_status != 'pendiente' THEN
    RAISE EXCEPTION 'El comprobante ya fue procesado';
  END IF;

  v_status := CASE WHEN p_approve THEN 'aprobado' ELSE 'rechazado' END;
  v_fare := v_ride.final_fare_usd;
  v_category := v_ride.category;

  UPDATE rides SET proof_status = v_status WHERE id = p_ride_id;

  IF p_approve THEN
    IF v_ride.status = 'buscando' THEN
      INSERT INTO notifications (user_id, title, body, type, data)
      SELECT p.id, 'Nuevo viaje disponible',
             CONCAT('Viaje de ', v_fare, '$ en ', v_category, '. ¿Lo aceptas?'),
             'ride_available',
             jsonb_build_object('ride_id', p_ride_id, 'category', v_category,
                                'fare', v_fare, 'url', '/conductor')
      FROM profiles p
      WHERE p.role = 'conductor'
        AND p.driver_status = 'aprobado'
        AND public.driver_has_vehicle_for_category(v_category) = TRUE;
    END IF;

    IF v_ride.status = 'completada' AND v_ride.driver_id IS NOT NULL THEN
      v_commission := COALESCE(v_ride.commission_usd, 0);
      v_app_credit := GREATEST(COALESCE(v_ride.total_fare_usd, v_ride.final_fare_usd, 0) - v_commission, 0);

      SELECT * INTO v_earning FROM driver_earnings WHERE ride_id = p_ride_id;

      IF v_earning.id IS NOT NULL THEN
        UPDATE driver_earnings
        SET cash_received_usd = 0,
            app_credit_usd = v_app_credit,
            status = 'completado'
        WHERE ride_id = p_ride_id;
      ELSE
        INSERT INTO driver_earnings (
          ride_id, driver_id, fare_usd, commission_usd,
          cash_received_usd, app_credit_usd, payment_method, status
        ) VALUES (
          p_ride_id, v_ride.driver_id, COALESCE(v_ride.total_fare_usd, v_ride.final_fare_usd, 0), v_commission,
          0, v_app_credit, v_ride.payment_method, 'completado'
        );
      END IF;

      IF v_app_credit > 0 AND NOT EXISTS (
        SELECT 1 FROM transactions t
        WHERE t.ride_id = p_ride_id AND t.type = 'credito' AND t.user_id = v_ride.driver_id
      ) THEN
        SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.driver_id;
        IF v_wallet.id IS NOT NULL THEN
          UPDATE wallets
          SET balance_usd = balance_usd + v_app_credit,
              updated_at = NOW()
          WHERE user_id = v_ride.driver_id;

          INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
          VALUES (v_wallet.id, v_ride.driver_id, 'credito', v_app_credit, 'completado',
                  'Ganancia del viaje por Pago Móvil (comprobante aprobado)', p_ride_id);
        END IF;
      END IF;
    END IF;
  END IF;

  INSERT INTO notifications (user_id, title, body, type, data)
  VALUES (
    v_ride.client_id,
    CASE WHEN p_approve THEN 'Comprobante aprobado' ELSE 'Comprobante rechazado' END,
    CASE WHEN p_approve THEN 'Tu pago fue aprobado. El viaje ya está disponible para conductores.'
         ELSE 'Tu comprobante fue rechazado. Sube uno válido.' END,
    'proof_reviewed',
    jsonb_build_object('ride_id', p_ride_id, 'approved', p_approve)
  );

  IF NOT p_approve AND v_ride.status = 'buscando' THEN
    UPDATE rides SET status = 'cancelada',
                     cancelled_by = v_admin_id,
                     cancel_reason = 'Comprobante rechazado',
                     updated_at = NOW()
    WHERE id = p_ride_id;

    IF v_ride.coupon_id IS NOT NULL THEN
      DELETE FROM coupon_redemptions WHERE ride_id = p_ride_id;
      UPDATE coupons SET used_count = GREATEST(used_count - 1, 0), updated_at = NOW()
      WHERE id = v_ride.coupon_id;
    END IF;

    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (v_ride.client_id, 'Viaje cancelado',
            'Tu viaje fue cancelado porque el comprobante fue rechazado. Solicita de nuevo con un pago válido.',
            'ride_cancelled', jsonb_build_object('ride_id', p_ride_id));
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'proof_status', v_status);
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_ride_proof TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.approve_ride_proof FROM anon;

-- ============================================================
-- 9. RESOLVE_RIDE_INCIDENT: encargado solo de su ciudad
-- ============================================================
CREATE OR REPLACE FUNCTION public.resolve_ride_incident(
  p_incident_id UUID,
  p_resolution TEXT,
  p_at_fault TEXT DEFAULT 'accidente',
  p_refund_client NUMERIC DEFAULT 0,
  p_penalize_culpable NUMERIC DEFAULT 0,
  p_compensate_driver NUMERIC DEFAULT 0,
  p_cancel_ride BOOLEAN DEFAULT TRUE
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_incident RECORD;
  v_ride RECORD;
  v_client_wallet RECORD;
  v_driver_wallet RECORD;
  v_culpable_wallet RECORD;
  v_culpable_id UUID;
  v_final_fare NUMERIC;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT * INTO v_incident FROM ride_incidents WHERE id = p_incident_id FOR UPDATE;
  IF v_incident.id IS NULL THEN
    RAISE EXCEPTION 'Incidente no encontrado';
  END IF;

  IF v_incident.status NOT IN ('abierto', 'en_revision') THEN
    RAISE EXCEPTION 'El incidente ya fue procesado';
  END IF;

  IF p_at_fault NOT IN ('cliente', 'conductor', 'accidente') THEN
    RAISE EXCEPTION 'Culpable no válido';
  END IF;

  IF p_refund_client < 0 OR p_refund_client > 999999.99 THEN
    RAISE EXCEPTION 'Reembolso al cliente inválido (0 - 999999.99)';
  END IF;
  IF p_penalize_culpable < 0 OR p_penalize_culpable > 999999.99 THEN
    RAISE EXCEPTION 'Penalización inválida (0 - 999999.99)';
  END IF;
  IF p_compensate_driver < 0 OR p_compensate_driver > 999999.99 THEN
    RAISE EXCEPTION 'Compensación al conductor inválida (0 - 999999.99)';
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = v_incident.ride_id FOR UPDATE;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  -- Encargado: el incidente debe ser de su ciudad
  IF public.get_user_role(v_admin_id) = 'encargado'
     AND COALESCE(v_ride.origin_zone_id, '00000000-0000-0000-0000-000000000000') != public.caller_zone_id() THEN
    RAISE EXCEPTION 'No autorizado para incidentes de otra ciudad';
  END IF;

  v_final_fare := COALESCE(v_ride.final_fare_usd, 0);

  IF v_ride.payment_method = 'Efectivo' THEN
    IF p_refund_client > 0 THEN
      RAISE EXCEPTION 'El cliente pagó en efectivo (al conductor). No se puede reembolsar desde la app.';
    END IF;
  ELSIF p_refund_client > v_final_fare THEN
    RAISE EXCEPTION 'El reembolso ($%s) excede la tarifa pagada ($%s)', p_refund_client, v_final_fare;
  END IF;

  IF p_at_fault = 'accidente' AND p_penalize_culpable > 0 THEN
    RAISE EXCEPTION 'No se puede penalizar a nadie en un accidente (no hay culpable)';
  END IF;

  IF p_at_fault = 'cliente' THEN
    v_culpable_id := v_ride.client_id;
  ELSIF p_at_fault = 'conductor' THEN
    v_culpable_id := v_ride.driver_id;
  END IF;

  IF p_refund_client > 0 AND v_ride.client_id IS NOT NULL THEN
    SELECT * INTO v_client_wallet FROM wallets WHERE user_id = v_ride.client_id;
    IF v_client_wallet.id IS NULL THEN
      RAISE EXCEPTION 'Billetera del cliente no encontrada';
    END IF;
    UPDATE wallets
    SET balance_usd = balance_usd + p_refund_client, updated_at = NOW()
    WHERE user_id = v_ride.client_id;
    INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
    VALUES (v_client_wallet.id, v_ride.client_id, 'credito', p_refund_client, 'completado',
            CONCAT('Reembolso por incidente (culpable: ', p_at_fault, ')'), v_ride.id);
  END IF;

  IF p_compensate_driver > 0 AND v_ride.driver_id IS NOT NULL THEN
    SELECT * INTO v_driver_wallet FROM wallets WHERE user_id = v_ride.driver_id;
    IF v_driver_wallet.id IS NULL THEN
      RAISE EXCEPTION 'Billetera del conductor no encontrada';
    END IF;
    UPDATE wallets
    SET balance_usd = balance_usd + p_compensate_driver, updated_at = NOW()
    WHERE user_id = v_ride.driver_id;
    INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
    VALUES (v_driver_wallet.id, v_ride.driver_id, 'credito', p_compensate_driver, 'completado',
            'Compensación por incidente del viaje', v_ride.id);
  END IF;

  IF p_penalize_culpable > 0 AND v_culpable_id IS NOT NULL THEN
    SELECT * INTO v_culpable_wallet FROM wallets WHERE user_id = v_culpable_id;
    IF v_culpable_wallet.id IS NULL THEN
      RAISE EXCEPTION 'Billetera del culpable no encontrada';
    END IF;
    IF v_culpable_wallet.balance_usd - p_penalize_culpable < -COALESCE(v_culpable_wallet.debt_limit_usd, 5.00) THEN
      RAISE EXCEPTION 'La penalización excede el límite de deuda del culpable';
    END IF;
    UPDATE wallets
    SET balance_usd = balance_usd - p_penalize_culpable, updated_at = NOW()
    WHERE user_id = v_culpable_id;
    INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
    VALUES (v_culpable_wallet.id, v_culpable_id, 'debito', p_penalize_culpable, 'completado',
            CONCAT('Penalización por incidente (culpable: ', p_at_fault, ')'), v_ride.id);
  END IF;

  IF p_cancel_ride AND v_ride.status != 'cancelada' THEN
    UPDATE rides
    SET status = 'cancelada',
        cancelled_by = v_admin_id,
        cancel_reason = 'Resolución de incidente',
        cancellation_fee_usd = p_penalize_culpable,
        driver_compensation_usd = p_compensate_driver,
        reimbursement_status = CASE WHEN v_ride.payment_method = 'Billetera' THEN 'auto_completado'
                                    WHEN v_ride.payment_method = 'Efectivo' THEN 'no_aplica'
                                    ELSE 'pendiente_manual' END,
        updated_at = NOW()
    WHERE id = v_ride.id;
  ELSIF NOT p_cancel_ride AND v_ride.status = 'incidente' THEN
    UPDATE rides SET status = 'en_ruta', updated_at = NOW() WHERE id = v_ride.id;
  END IF;

  UPDATE ride_incidents
  SET status = 'resuelto',
      resolution = p_resolution,
      resolution_details = jsonb_build_object(
        'at_fault', p_at_fault,
        'fare', v_final_fare,
        'refund_client', p_refund_client,
        'penalty', p_penalize_culpable,
        'compensate_driver', p_compensate_driver,
        'ride_cancelled', p_cancel_ride,
        'payment_method', v_ride.payment_method
      ),
      resolved_by = v_admin_id,
      resolved_at = NOW(),
      updated_at = NOW()
  WHERE id = p_incident_id;

  INSERT INTO notifications (user_id, title, body, type, data)
  VALUES
    (v_ride.client_id, 'Incidente resuelto', CONCAT('Tu incidente fue resuelto. ', p_resolution), 'incident_resolved',
     jsonb_build_object('incident_id', p_incident_id, 'ride_id', v_ride.id));
  IF v_ride.driver_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (v_ride.driver_id, 'Incidente resuelto', CONCAT('El incidente del viaje fue resuelto. ', p_resolution), 'incident_resolved',
            jsonb_build_object('incident_id', p_incident_id, 'ride_id', v_ride.id));
  END IF;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_admin_id, 'RESOLVE_INCIDENT', 'incident', p_incident_id,
          jsonb_build_object('ride_id', v_ride.id, 'at_fault', p_at_fault,
                             'refund_client', p_refund_client,
                             'penalty', p_penalize_culpable,
                             'compensate_driver', p_compensate_driver,
                             'cancelled', p_cancel_ride));

  RETURN jsonb_build_object(
    'success', TRUE,
    'incident_id', p_incident_id,
    'ride_id', v_ride.id,
    'status', 'resuelto',
    'refund_client', p_refund_client,
    'penalty', p_penalize_culpable,
    'compensate_driver', p_compensate_driver,
    'ride_status', (SELECT status FROM rides WHERE id = v_ride.id)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.resolve_ride_incident TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.resolve_ride_incident FROM anon;

-- ============================================================
-- 10. GET_ADMIN_RIDES: encargado ve solo viajes de su ciudad
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_admin_rides(
  p_search TEXT DEFAULT NULL,
  p_fecha_inicio TIMESTAMPTZ DEFAULT NOW() - INTERVAL '90 days',
  p_fecha_fin TIMESTAMPTZ DEFAULT NOW(),
  p_status TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 25,
  p_offset INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_caller_zone UUID;
  v_total INTEGER := 0;
  v_items JSONB;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;
  v_caller_zone := public.caller_zone_id();

  IF p_limit > 50 THEN p_limit := 50; END IF;
  IF p_limit < 1 THEN p_limit := 25; END IF;
  IF p_offset < 0 THEN p_offset := 0; END IF;

  IF p_search IS NOT NULL AND TRIM(p_search) = '' THEN
    p_search := NULL;
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM rides r
  LEFT JOIN profiles cl ON cl.id = r.client_id
  LEFT JOIN profiles dr ON dr.id = r.driver_id
  WHERE (p_search IS NOT NULL OR (r.created_at >= p_fecha_inicio AND r.created_at <= p_fecha_fin))
    AND (p_status IS NULL OR r.status::text = p_status)
    AND (v_caller_zone IS NULL OR r.origin_zone_id = v_caller_zone)
    AND (
      p_search IS NULL
      OR UPPER(r.tracking_code) LIKE UPPER('%' || p_search || '%')
      OR UPPER(cl.full_name) LIKE UPPER('%' || p_search || '%')
      OR UPPER(dr.full_name) LIKE UPPER('%' || p_search || '%')
      OR UPPER(cl.email) LIKE UPPER('%' || p_search || '%')
    );

  SELECT COALESCE(jsonb_agg(t ORDER BY t.fecha DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT
      r.id AS ride_id,
      r.tracking_code,
      r.status::text AS status,
      r.payment_method,
      r.final_fare_usd,
      r.commission_usd,
      r.created_at AS fecha,
      r.origin_address,
      r.destination_address,
      r.destination_barrio_name,
      r.proof_status,
      r.cancellation_fee_usd,
      r.driver_compensation_usd,
      cl.full_name AS cliente,
      dr.full_name AS conductor,
      COALESCE(de.cash_received_usd, 0) AS cash_received,
      COALESCE(de.app_credit_usd, 0) AS app_credit
    FROM rides r
    LEFT JOIN profiles cl ON cl.id = r.client_id
    LEFT JOIN profiles dr ON dr.id = r.driver_id
    LEFT JOIN driver_earnings de ON de.ride_id = r.id
    WHERE (p_search IS NOT NULL OR (r.created_at >= p_fecha_inicio AND r.created_at <= p_fecha_fin))
      AND (p_status IS NULL OR r.status::text = p_status)
      AND (v_caller_zone IS NULL OR r.origin_zone_id = v_caller_zone)
      AND (
        p_search IS NULL
        OR UPPER(r.tracking_code) LIKE UPPER('%' || p_search || '%')
        OR UPPER(cl.full_name) LIKE UPPER('%' || p_search || '%')
        OR UPPER(dr.full_name) LIKE UPPER('%' || p_search || '%')
        OR UPPER(cl.email) LIKE UPPER('%' || p_search || '%')
      )
  ) t
  LIMIT p_limit OFFSET p_offset;

  RETURN jsonb_build_object('total', v_total, 'items', v_items);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_admin_rides TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_admin_rides FROM anon;

-- ============================================================
-- 11. GET_ADMIN_USERS: encargado ve solo usuarios de su ciudad
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_admin_users(
  p_search TEXT DEFAULT NULL,
  p_role TEXT DEFAULT NULL,
  p_driver_status TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 25,
  p_offset INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_caller_zone UUID;
  v_search TEXT := NULLIF(TRIM(COALESCE(p_search, '')), '');
  v_total INTEGER := 0;
  v_items JSONB;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;
  v_caller_zone := public.caller_zone_id();

  IF p_limit > 100 THEN p_limit := 100; END IF;
  IF p_limit < 1 THEN p_limit := 25; END IF;
  IF p_offset < 0 THEN p_offset := 0; END IF;

  SELECT COUNT(*) INTO v_total
  FROM public.profiles pr
  WHERE (v_search IS NULL
         OR pr.full_name ILIKE '%' || v_search || '%'
         OR pr.email ILIKE '%' || v_search || '%'
         OR pr.phone ILIKE '%' || v_search || '%')
    AND (v_caller_zone IS NULL OR pr.zone_id = v_caller_zone)
    AND (p_role IS NULL
         OR (p_role = 'cliente' AND pr.role = 'cliente')
         OR (p_role = 'conductor' AND pr.role = 'conductor')
         OR (p_role = 'admin' AND pr.role IN ('super_admin', 'encargado')))
    AND (p_driver_status IS NULL OR COALESCE(pr.driver_status::text, '') = p_driver_status);

  SELECT COALESCE(jsonb_agg(t ORDER BY t.created_at DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT
      pr.id::text AS id,
      pr.full_name,
      pr.email,
      pr.phone,
      pr.role::text AS role,
      pr.driver_status::text AS driver_status,
      pr.is_online,
      pr.onboarding_completed,
      pr.created_at,
      COALESCE(w.balance_usd, 0) AS balance_usd
    FROM public.profiles pr
    LEFT JOIN public.wallets w ON w.user_id = pr.id
    WHERE (v_search IS NULL
           OR pr.full_name ILIKE '%' || v_search || '%'
           OR pr.email ILIKE '%' || v_search || '%'
           OR pr.phone ILIKE '%' || v_search || '%')
      AND (v_caller_zone IS NULL OR pr.zone_id = v_caller_zone)
      AND (p_role IS NULL
           OR (p_role = 'cliente' AND pr.role = 'cliente')
           OR (p_role = 'conductor' AND pr.role = 'conductor')
           OR (p_role = 'admin' AND pr.role IN ('super_admin', 'encargado')))
      AND (p_driver_status IS NULL OR COALESCE(pr.driver_status::text, '') = p_driver_status)
  ) t
  LIMIT p_limit OFFSET p_offset;

  RETURN jsonb_build_object('total', v_total, 'items', v_items);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_admin_users TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_admin_users FROM anon;

-- ============================================================
-- 12. GET_ADMIN_TRANSACTIONS: encargado ve solo su ciudad
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_admin_transactions(
  p_fecha_inicio TIMESTAMPTZ DEFAULT NOW() - INTERVAL '30 days',
  p_fecha_fin TIMESTAMPTZ DEFAULT NOW(),
  p_tipo TEXT DEFAULT NULL,
  p_rol TEXT DEFAULT NULL,
  p_usuario_id UUID DEFAULT NULL,
  p_busqueda TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_caller_zone UUID;
  v_total INTEGER := 0;
  v_items JSONB;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;
  v_caller_zone := public.caller_zone_id();

  IF p_limit > 100 THEN p_limit := 100; END IF;
  IF p_limit < 1 THEN p_limit := 50; END IF;
  IF p_offset < 0 THEN p_offset := 0; END IF;

  IF p_busqueda IS NOT NULL AND TRIM(p_busqueda) = '' THEN
    p_busqueda := NULL;
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM (
    SELECT id
    FROM (
      SELECT t.id AS id
      FROM transactions t
      LEFT JOIN profiles pr ON pr.id = t.user_id
      WHERE t.created_at >= p_fecha_inicio
        AND t.created_at <= p_fecha_fin
        AND (p_tipo IS NULL OR t.type::text = p_tipo)
        AND (p_usuario_id IS NULL OR t.user_id = p_usuario_id)
        AND (v_caller_zone IS NULL OR pr.zone_id = v_caller_zone)
        AND (p_busqueda IS NULL
             OR pr.full_name ILIKE '%' || p_busqueda || '%'
             OR pr.email ILIKE '%' || p_busqueda || '%'
             OR pr.phone ILIKE '%' || p_busqueda || '%'
             OR t.reference ILIKE '%' || p_busqueda || '%'
             OR t.ride_id IN (SELECT r.id FROM rides r WHERE UPPER(r.tracking_code) LIKE UPPER('%' || p_busqueda || '%')))
        AND (
          p_rol IS NULL
          OR (p_rol = 'cliente' AND pr.role = 'cliente')
          OR (p_rol = 'conductor' AND pr.role = 'conductor')
          OR (p_rol = 'admin' AND pr.role IN ('super_admin', 'encargado'))
        )
      UNION ALL
      SELECT po.id AS id
      FROM payouts po
      LEFT JOIN profiles pr ON pr.id = po.driver_id
      WHERE po.created_at >= p_fecha_inicio
        AND po.created_at <= p_fecha_fin
        AND (p_tipo IS NULL OR po.type::text = p_tipo)
        AND (p_usuario_id IS NULL OR po.driver_id = p_usuario_id)
        AND (v_caller_zone IS NULL OR pr.zone_id = v_caller_zone)
        AND (p_busqueda IS NULL
             OR pr.full_name ILIKE '%' || p_busqueda || '%'
             OR pr.email ILIKE '%' || p_busqueda || '%'
             OR pr.phone ILIKE '%' || p_busqueda || '%'
             OR po.description ILIKE '%' || p_busqueda || '%'
             OR po.ride_id IN (SELECT r.id FROM rides r WHERE UPPER(r.tracking_code) LIKE UPPER('%' || p_busqueda || '%')))
        AND (
          p_rol IS NULL
          OR (p_rol = 'conductor' AND pr.role = 'conductor')
          OR (p_rol = 'admin' AND pr.role IN ('super_admin', 'encargado'))
        )
    ) sub
  ) sub2;

  SELECT COALESCE(jsonb_agg(t ORDER BY t.fecha DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT
      t.id::text AS id,
      'transaction' AS origen,
      t.created_at AS fecha,
      pr.full_name AS usuario,
      pr.role AS rol,
      t.user_id AS usuario_id,
      t.type::text AS tipo,
      t.amount_usd AS monto,
      t.status::text AS estado,
      t.description AS descripcion,
      t.reference AS referencia,
      t.ride_id AS viaje_id,
      NULL::text AS comprobante,
      COALESCE((SELECT balance_usd FROM wallets w WHERE w.id = t.wallet_id), 0) AS saldo_resultante
    FROM transactions t
    LEFT JOIN profiles pr ON pr.id = t.user_id
    WHERE t.created_at >= p_fecha_inicio
      AND t.created_at <= p_fecha_fin
      AND (p_tipo IS NULL OR t.type::text = p_tipo)
      AND (p_usuario_id IS NULL OR t.user_id = p_usuario_id)
      AND (v_caller_zone IS NULL OR pr.zone_id = v_caller_zone)
      AND (p_busqueda IS NULL
           OR pr.full_name ILIKE '%' || p_busqueda || '%'
           OR pr.email ILIKE '%' || p_busqueda || '%'
           OR pr.phone ILIKE '%' || p_busqueda || '%'
           OR t.reference ILIKE '%' || p_busqueda || '%'
           OR t.ride_id IN (SELECT r.id FROM rides r WHERE UPPER(r.tracking_code) LIKE UPPER('%' || p_busqueda || '%')))
      AND (
        p_rol IS NULL
        OR (p_rol = 'cliente' AND pr.role = 'cliente')
        OR (p_rol = 'conductor' AND pr.role = 'conductor')
        OR (p_rol = 'admin' AND pr.role IN ('super_admin', 'encargado'))
      )

    UNION ALL

    SELECT
      po.id::text AS id,
      'payout' AS origen,
      po.created_at AS fecha,
      pr.full_name AS usuario,
      pr.role AS rol,
      po.driver_id AS usuario_id,
      po.type AS tipo,
      po.amount_usd AS monto,
      po.status AS estado,
      po.description AS descripcion,
      NULL::text AS referencia,
      po.ride_id AS viaje_id,
      po.proof_url AS comprobante,
      0 AS saldo_resultante
    FROM payouts po
    LEFT JOIN profiles pr ON pr.id = po.driver_id
    WHERE po.created_at >= p_fecha_inicio
      AND po.created_at <= p_fecha_fin
      AND (p_tipo IS NULL OR po.type::text = p_tipo)
      AND (p_usuario_id IS NULL OR po.driver_id = p_usuario_id)
      AND (v_caller_zone IS NULL OR pr.zone_id = v_caller_zone)
      AND (p_busqueda IS NULL
           OR pr.full_name ILIKE '%' || p_busqueda || '%'
           OR pr.email ILIKE '%' || p_busqueda || '%'
           OR pr.phone ILIKE '%' || p_busqueda || '%'
           OR po.description ILIKE '%' || p_busqueda || '%'
           OR po.ride_id IN (SELECT r.id FROM rides r WHERE UPPER(r.tracking_code) LIKE UPPER('%' || p_busqueda || '%')))
      AND (
        p_rol IS NULL
        OR (p_rol = 'conductor' AND pr.role = 'conductor')
        OR (p_rol = 'admin' AND pr.role IN ('super_admin', 'encargado'))
      )
  ) t
  LIMIT p_limit OFFSET p_offset;

  RETURN jsonb_build_object('total', v_total, 'items', v_items);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_admin_transactions TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_admin_transactions FROM anon;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'OK: migración 050 aplicada' AS estado;
