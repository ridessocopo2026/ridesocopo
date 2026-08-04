-- ============================================================
-- RIDESOCOPÓ - Migración: CANCELACIONES CON POLÍTICA + INCIDENTES
-- 1. Políticas de cancelación configurables por Admin
-- 2. Sistema de reporte de incidentes/accidentes
-- 3. cancel_ride reescrito: atómico, idempotente, con reembolsos
--    y compensaciones según método de pago y culpable
-- ============================================================

-- ============================================================
-- 1. NOTA: El valor 'incidente' del enum ride_status se agrega
-- en 017a_ride_status_incidente.sql (transacción separada).
-- Postgres no permite usar un valor recién agregado en un enum
-- dentro de la misma transacción.
-- ============================================================

-- ============================================================
-- 2. TABLA: CANCELLATION_POLICIES (política de cancelación)
--    fee_rate:  % de la tarifa que paga el cliente como penalización
--    min_fee:   mínimo absoluto del fee
--    max_fee:   máximo absoluto del fee (NULL = sin tope)
--    driver_compensation_rate: % del fee que recibe el conductor
-- ============================================================
CREATE TABLE IF NOT EXISTS cancellation_policies (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ride_status TEXT NOT NULL CHECK (ride_status IN ('buscando', 'aceptada', 'en_ruta')),
  at_fault TEXT NOT NULL CHECK (at_fault IN ('cliente', 'conductor', 'accidente')),
  fee_rate NUMERIC(5,2) NOT NULL DEFAULT 0.00,
  min_fee NUMERIC(10,2) NOT NULL DEFAULT 0.00,
  max_fee NUMERIC(10,2),
  driver_compensation_rate NUMERIC(5,2) NOT NULL DEFAULT 0.00,
  refunds_commission BOOLEAN NOT NULL DEFAULT TRUE,
  is_active BOOLEAN NOT NULL DEFAULT TRUE,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  UNIQUE(ride_status, at_fault)
);

GRANT ALL ON public.cancellation_policies TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;

-- RLS: todos pueden ver políticas activas, solo admin gestiona
ALTER TABLE cancellation_policies ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "public_view_cancellation_policies" ON public.cancellation_policies;
CREATE POLICY "public_view_cancellation_policies" ON public.cancellation_policies
  FOR SELECT USING (is_active = TRUE);

DROP POLICY IF EXISTS "admin_manage_cancellation_policies" ON public.cancellation_policies;
CREATE POLICY "admin_manage_cancellation_policies" ON public.cancellation_policies
  FOR ALL USING (public.get_user_role(auth.uid()) IN ('super_admin', 'encargado'));

-- ============================================================
-- 2.1 SEEDS POR DEFECTO
-- ============================================================
INSERT INTO cancellation_policies (ride_status, at_fault, fee_rate, min_fee, max_fee, driver_compensation_rate, refunds_commission)
VALUES
  -- BUSCANDO: sin penalización
  ('buscando', 'cliente',      0.00, 0.00, NULL, 0.00, TRUE),
  ('buscando', 'conductor',    0.00, 0.00, NULL, 0.00, TRUE),
  ('buscando', 'accidente',    0.00, 0.00, NULL, 0.00, TRUE),

  -- ACEPTADA: cliente cancela → 15% (mín $0.50); conductor cancela → sin fee
  ('aceptada', 'cliente',     15.00, 0.50, NULL, 0.50, FALSE),
  ('aceptada', 'conductor',    0.00, 0.00, NULL, 0.00, TRUE),
  ('aceptada', 'accidente',    0.00, 0.00, NULL, 0.00, TRUE),

  -- EN_RUTA: cliente cancela → 50% (mín $1.00); conductor cancela → sin fee pero pierde comisión
  ('en_ruta', 'cliente',      50.00, 1.00, NULL, 0.50, FALSE),
  ('en_ruta', 'conductor',     0.00, 0.00, NULL, 0.00, FALSE),
  ('en_ruta', 'accidente',     0.00, 0.00, NULL, 0.00, TRUE)
ON CONFLICT (ride_status, at_fault) DO NOTHING;

-- ============================================================
-- 3. TABLA: RIDE_INCIDENTS (incidentes/accidentes)
-- ============================================================
CREATE TABLE IF NOT EXISTS ride_incidents (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ride_id UUID NOT NULL REFERENCES rides(id) ON DELETE CASCADE,
  reported_by UUID NOT NULL REFERENCES profiles(id),
  incident_type TEXT NOT NULL CHECK (incident_type IN ('accidente', 'falla_mecanica', 'urgencia_medica', 'clima', 'otro')),
  description TEXT,
  photo_urls JSONB DEFAULT '[]'::jsonb,
  status TEXT NOT NULL DEFAULT 'abierto' CHECK (status IN ('abierto', 'en_revision', 'resuelto', 'cerrado')),
  resolution TEXT,
  resolution_details JSONB,
  resolved_by UUID REFERENCES profiles(id),
  resolved_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Índices para búsquedas rápidas
CREATE INDEX IF NOT EXISTS idx_ride_incidents_ride ON ride_incidents(ride_id);
CREATE INDEX IF NOT EXISTS idx_ride_incidents_status ON ride_incidents(status);
CREATE INDEX IF NOT EXISTS idx_ride_incidents_created ON ride_incidents(created_at DESC);

GRANT ALL ON public.ride_incidents TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;

-- RLS
ALTER TABLE ride_incidents ENABLE ROW LEVEL SECURITY;

-- Cliente/conductor del viaje pueden ver el incidente
DROP POLICY IF EXISTS "ride_participants_view_incidents" ON public.ride_incidents;
CREATE POLICY "ride_participants_view_incidents" ON public.ride_incidents
  FOR SELECT USING (
    EXISTS (
      SELECT 1 FROM rides r
      WHERE r.id = ride_incidents.ride_id
        AND (r.client_id = auth.uid() OR r.driver_id = auth.uid())
    )
    OR public.get_user_role(auth.uid()) IN ('super_admin', 'encargado')
  );

-- Cliente/conductor pueden reportar incidentes en sus viajes
DROP POLICY IF EXISTS "ride_participants_insert_incidents" ON public.ride_incidents;
CREATE POLICY "ride_participants_insert_incidents" ON public.ride_incidents
  FOR INSERT WITH CHECK (
    auth.uid() = reported_by
    AND EXISTS (
      SELECT 1 FROM rides r
      WHERE r.id = ride_incidents.ride_id
        AND (r.client_id = auth.uid() OR r.driver_id = auth.uid())
        AND r.status IN ('aceptada', 'en_ruta', 'incidente')
    )
  );

-- Admin puede cerrar/resolver
DROP POLICY IF EXISTS "admin_update_incidents" ON public.ride_incidents;
CREATE POLICY "admin_update_incidents" ON public.ride_incidents
  FOR UPDATE USING (public.get_user_role(auth.uid()) IN ('super_admin', 'encargado'));

-- Admin ve todos
DROP POLICY IF EXISTS "admin_view_all_incidents" ON public.ride_incidents;
CREATE POLICY "admin_view_all_incidents" ON public.ride_incidents
  FOR SELECT USING (public.get_user_role(auth.uid()) IN ('super_admin', 'encargado'));

-- ============================================================
-- 4. COLUMNAS NUEVAS EN RIDES
-- ============================================================
ALTER TABLE rides ADD COLUMN IF NOT EXISTS cancellation_fee_usd NUMERIC(10,2) NOT NULL DEFAULT 0.00;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS driver_compensation_usd NUMERIC(10,2) NOT NULL DEFAULT 0.00;
ALTER TABLE rides ADD COLUMN IF NOT EXISTS incident_id UUID REFERENCES ride_incidents(id);
ALTER TABLE rides ADD COLUMN IF NOT EXISTS reimbursement_status TEXT DEFAULT NULL
  CHECK (reimbursement_status IN (NULL, 'auto_completado', 'pendiente_manual', 'no_aplica'));

-- Índice para reembolsos pendientes (Pago Móvil)
CREATE INDEX IF NOT EXISTS idx_rides_reimbursement_pending ON rides(reimbursement_status) WHERE reimbursement_status = 'pendiente_manual';

-- ============================================================
-- 5. FUNCIÓN HELPER: OBTENER POLÍTICA DE CANCELACIÓN
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_cancellation_policy(
  p_ride_status TEXT,
  p_at_fault TEXT
)
RETURNS JSONB
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'fee_rate', COALESCE(fee_rate, 0),
    'min_fee', COALESCE(min_fee, 0),
    'max_fee', max_fee,
    'driver_compensation_rate', COALESCE(driver_compensation_rate, 0),
    'refunds_commission', COALESCE(refunds_commission, TRUE)
  )
  FROM cancellation_policies
  WHERE ride_status = p_ride_status
    AND at_fault = p_at_fault
    AND is_active = TRUE
  LIMIT 1;
$$;

GRANT EXECUTE ON FUNCTION public.get_cancellation_policy TO anon, authenticated, service_role;

-- ============================================================
-- 6. REESCRITURA DE CANCEL_RIDE: ATÓMICO, IDEMPOTENTE, JUSTO
-- Primero se eliminan las firmas antiguas para evitar conflicto
-- de sobrecarga (Postgres no permite CREATE OR REPLACE con
-- diferente lista de argumentos)
-- ============================================================
DROP FUNCTION IF EXISTS public.cancel_ride(UUID, TEXT);
DROP FUNCTION IF EXISTS public.cancel_ride(UUID, TEXT, TEXT);

CREATE OR REPLACE FUNCTION public.cancel_ride(
  p_ride_id UUID,
  p_reason TEXT DEFAULT NULL,
  p_at_fault TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_ride RECORD;
  v_policy RECORD;
  v_wallet RECORD;
  v_other_user UUID;
  v_fee NUMERIC := 0.00;
  v_compensation NUMERIC := 0.00;
  v_refund NUMERIC := 0.00;
  v_refund_commission BOOLEAN := FALSE;
  v_effective_fault TEXT;
  v_is_driver BOOLEAN;
  v_error TEXT;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  -- ================================================================
  -- BLOQUEO DE FILA: evita doble reembolso por condición de carrera
  -- ================================================================
  SELECT * INTO v_ride
  FROM rides
  WHERE id = p_ride_id
  FOR UPDATE;

  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  -- ================================================================
  -- VALIDACIÓN DE AUTORIZACIÓN Y ESTADO
  -- ================================================================
  IF v_ride.client_id != v_user_id AND v_ride.driver_id != v_user_id THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- IDEMPOTENTE: si ya está cancelado o en incidente, NO reembolsar de nuevo
  IF v_ride.status IN ('cancelada', 'incidente') THEN
    RETURN jsonb_build_object(
      'success', TRUE,
      'ride_id', p_ride_id,
      'status', v_ride.status,
      'already_processed', TRUE,
      'note', 'El viaje ya fue procesado. No se reembolsó de nuevo.'
    );
  END IF;

  IF v_ride.status NOT IN ('buscando', 'aceptada', 'en_ruta') THEN
    RAISE EXCEPTION 'Estado del viaje no permite cancelación';
  END IF;

  -- ================================================================
  -- DETERMINAR CULPABLE (default = quien llama la función)
  -- ================================================================
  v_is_driver := (v_ride.driver_id = v_user_id);
  v_effective_fault := p_at_fault;
  IF v_effective_fault IS NULL THEN
    v_effective_fault := CASE WHEN v_is_driver THEN 'conductor' ELSE 'cliente' END;
  END IF;

  -- Validar que el valor es permitido
  IF v_effective_fault NOT IN ('cliente', 'conductor', 'accidente') THEN
    RAISE EXCEPTION 'Culpable no válido: debe ser cliente, conductor o accidente';
  END IF;

  -- Si reporta accidente, debe existir un incidente abierto vinculado
  IF v_effective_fault = 'accidente' THEN
    IF v_ride.incident_id IS NULL THEN
      RAISE EXCEPTION 'Debe reportar un incidente antes de cancelar por accidente';
    END IF;
  END IF;

  -- ================================================================
  -- OBTENER POLÍTICA y CALCULAR MONTOS
  -- ================================================================
  SELECT * INTO v_policy
  FROM cancellation_policies
  WHERE ride_status = v_ride.status::text
    AND at_fault = v_effective_fault
    AND is_active = TRUE;

  IF v_policy.id IS NULL THEN
    -- Fallback: sin penalización (nunca bloquear una cancelación)
    v_fee := 0.00;
    v_compensation := 0.00;
    v_refund_commission := TRUE;
  ELSE
    -- Fee = tarifa_final × fee_rate% (con mínimo y máximo)
    v_fee := ROUND((v_ride.final_fare_usd * v_policy.fee_rate / 100), 2);
    IF v_fee < v_policy.min_fee THEN
      v_fee := v_policy.min_fee;
    END IF;
    IF v_policy.max_fee IS NOT NULL AND v_fee > v_policy.max_fee THEN
      v_fee := v_policy.max_fee;
    END IF;

    -- Compensación al conductor = fee × driver_compensation_rate%
    v_compensation := ROUND((v_fee * v_policy.driver_compensation_rate / 100), 2);

    -- ¿Se devuelve la comisión descontada al conductor?
    v_refund_commission := v_policy.refunds_commission;
  END IF;

  -- ================================================================
  -- PROCESAR REEMBOLSOS SEGÚN MÉTODO DE PAGO
  -- ================================================================

  -- ------------------------------------------------------------------
  -- 6a. COMPENSACIÓN AL CONDUCTOR (si aplica)
  --     Solo si hay un conductor asignado y la compensación > 0
  -- ------------------------------------------------------------------
  IF v_compensation > 0 AND v_ride.driver_id IS NOT NULL THEN
    SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.driver_id;
    IF v_wallet.id IS NOT NULL THEN
      UPDATE wallets
      SET balance_usd = balance_usd + v_compensation,
          updated_at = NOW()
      WHERE user_id = v_ride.driver_id;

      INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
      VALUES (v_wallet.id, v_ride.driver_id, 'credito', v_compensation, 'completado',
              CONCAT('Compensación por cancelación del cliente (', v_effective_fault, ')'), p_ride_id);
    END IF;
  END IF;

  -- ------------------------------------------------------------------
  -- 6b. REEMBOLSO DE COMISIÓN AL CONDUCTOR (si la política lo permite)
  --     Aplicable cuando la cancelación NO es culpa del conductor
  -- ------------------------------------------------------------------
  IF v_refund_commission
     AND v_ride.commission_usd > 0
     AND v_ride.driver_id IS NOT NULL
     AND v_effective_fault != 'conductor' THEN

    SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.driver_id;
    IF v_wallet.id IS NOT NULL THEN
      UPDATE wallets
      SET balance_usd = balance_usd + v_ride.commission_usd,
          updated_at = NOW()
      WHERE user_id = v_ride.driver_id;

      INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
      VALUES (v_wallet.id, v_ride.driver_id, 'credito', v_ride.commission_usd, 'completado',
              'Reembolso de comisión por cancelación', p_ride_id);
    END IF;
  END IF;

  -- ------------------------------------------------------------------
  -- 6c. REEMBOLSO AL CLIENTE
  -- ------------------------------------------------------------------
  IF v_ride.payment_method = 'Billetera' AND v_ride.final_fare_usd > 0 THEN
    -- Refund = 100% − fee (el fee es la penalización si el cliente es culpable)
    v_refund := GREATEST(v_ride.final_fare_usd - v_fee, 0);

    IF v_refund > 0 THEN
      SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.client_id;
      IF v_wallet.id IS NOT NULL THEN
        UPDATE wallets
        SET balance_usd = balance_usd + v_refund,
            updated_at = NOW()
        WHERE user_id = v_ride.client_id;

        INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
        VALUES (v_wallet.id, v_ride.client_id, 'credito', v_refund, 'completado',
                CONCAT('Reembolso por cancelación (', v_effective_fault, '). Fee: $', v_fee), p_ride_id);
      END IF;
    END IF;

    v_ride.reimbursement_status := 'auto_completado';
  ELSIF v_ride.payment_method NOT IN ('Billetera', 'Efectivo') AND v_ride.final_fare_usd > 0 THEN
    -- Pago Móvil u otro método digital: el dinero está en la plataforma.
    -- Crear reembolso manual pendiente (admin lo procesa)
    v_refund := GREATEST(v_ride.final_fare_usd - v_fee, 0);

    IF v_refund > 0 THEN
      SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.client_id;
      IF v_wallet.id IS NOT NULL THEN
        INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
        VALUES (v_wallet.id, v_ride.client_id, 'credito', v_refund, 'pendiente',
                CONCAT('Reembolso pendiente por cancelación (Pago Móvil). Fee: $', v_fee), p_ride_id);

        -- Notificar a admins para procesar la devolución manual
        INSERT INTO notifications (user_id, title, body, type, data)
        SELECT id, 'Reembolso pendiente por cancelación',
               CONCAT('Reembolsar $', v_refund, ' al cliente por el viaje ', substring(p_ride_id::text, 1, 8)),
               'refund_pending',
               jsonb_build_object('ride_id', p_ride_id, 'amount', v_refund, 'url', '/admin/incidentes')
        FROM profiles WHERE role IN ('super_admin', 'encargado');
      END IF;
    END IF;

    v_ride.reimbursement_status := 'pendiente_manual';
  ELSE
    -- Efectivo: no hay dinero retenido; si el cliente es culpable,
    -- registrar el fee como deuda en su billetera (mismo modelo que conductores)
    IF v_fee > 0 AND v_effective_fault = 'cliente' THEN
      SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.client_id;
      IF v_wallet.id IS NOT NULL THEN
        UPDATE wallets
        SET balance_usd = balance_usd - v_fee,
            updated_at = NOW()
        WHERE user_id = v_ride.client_id;

        INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
        VALUES (v_wallet.id, v_ride.client_id, 'debito', v_fee, 'completado',
                'Tarifa de cancelación del viaje (pago en efectivo)', p_ride_id);
      END IF;
    END IF;

    v_ride.reimbursement_status := 'no_aplica';
  END IF;

  -- ================================================================
  -- ACTUALIZAR VIAJE
  -- ================================================================
  UPDATE rides
  SET status = 'cancelada',
      cancelled_by = v_user_id,
      cancel_reason = COALESCE(p_reason, 'Cancelado'),
      cancellation_fee_usd = v_fee,
      driver_compensation_usd = v_compensation,
      reimbursement_status = v_ride.reimbursement_status,
      updated_at = NOW()
  WHERE id = p_ride_id;

  -- ================================================================
  -- NOTIFICAR AL OTRO USUARIO
  -- ================================================================
  IF v_ride.client_id IS NOT NULL AND v_ride.driver_id IS NOT NULL THEN
    v_other_user := CASE WHEN v_user_id = v_ride.client_id THEN v_ride.driver_id ELSE v_ride.client_id END;

    PERFORM public.notify_user(
      v_other_user,
      'Viaje cancelado',
      CASE
        WHEN v_effective_fault = 'accidente' THEN 'Viaje cancelado por incidente reportado'
        WHEN v_fee > 0 THEN CONCAT('El viaje fue cancelado. Tarifa de cancelación: $', v_fee)
        ELSE 'El viaje fue cancelado'
      END,
      'ride_cancelled',
      jsonb_build_object('ride_id', p_ride_id, 'fee', v_fee, 'compensation', v_compensation)
    );

    -- Notificar al usuario que canceló también (confirmación)
    IF v_fee > 0 THEN
      PERFORM public.notify_user(
        v_user_id,
        'Viaje cancelado',
        CONCAT('Se aplicó una tarifa de cancelación de $', v_fee, '. ',
               CASE WHEN v_compensation > 0 THEN CONCAT('El conductor recibió $', v_compensation, ' de compensación.') ELSE '' END),
        'ride_cancelled_confirmation',
        jsonb_build_object('ride_id', p_ride_id, 'fee', v_fee)
      );
    END IF;
  END IF;

  -- ================================================================
  -- AUDITORÍA
  -- ================================================================
  BEGIN
    INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
    VALUES (v_user_id, 'CANCEL_RIDE', 'ride', p_ride_id,
            jsonb_build_object(
              'at_fault', v_effective_fault,
              'fee', v_fee,
              'compensation', v_compensation,
              'refunded_commission', v_refund_commission,
              'reimbursement_status', v_ride.reimbursement_status,
              'payment_method', v_ride.payment_method
            ));
  EXCEPTION WHEN OTHERS THEN
    NULL; -- La auditoría nunca debe romper el flujo
  END;

  RETURN jsonb_build_object(
    'success', TRUE,
    'ride_id', p_ride_id,
    'status', 'cancelada',
    'at_fault', v_effective_fault,
    'cancellation_fee_usd', v_fee,
    'driver_compensation_usd', v_compensation,
    'refunded_commission', v_refund_commission,
    'reimbursement_status', v_ride.reimbursement_status
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.cancel_ride TO anon, authenticated, service_role;

-- ============================================================
-- 7. FUNCIÓN: REPORTAR INCIDENTE
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
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  -- Validar tipo
  IF p_incident_type NOT IN ('accidente', 'falla_mecanica', 'urgencia_medica', 'clima', 'otro') THEN
    RAISE EXCEPTION 'Tipo de incidente no válido';
  END IF;

  -- Obtener viaje con bloqueo
  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id FOR UPDATE;

  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  -- Solo participantes del viaje activo pueden reportar
  IF v_ride.client_id != v_user_id AND v_ride.driver_id != v_user_id THEN
    RAISE EXCEPTION 'No autorizado para este viaje';
  END IF;

  IF v_ride.status NOT IN ('aceptada', 'en_ruta') THEN
    RAISE EXCEPTION 'Solo se puede reportar un incidente durante un viaje activo';
  END IF;

  -- Crear incidente
  INSERT INTO ride_incidents (ride_id, reported_by, incident_type, description, photo_urls, status)
  VALUES (p_ride_id, v_user_id, p_incident_type, p_description, COALESCE(p_photo_urls, '[]'::jsonb), 'abierto')
  RETURNING id INTO v_incident_id;

  -- Cambiar el viaje a estado 'incidente' para congelar el proceso
  UPDATE rides
  SET status = 'incidente',
      incident_id = v_incident_id,
      updated_at = NOW()
  WHERE id = p_ride_id;

  -- Notificar a admins con prioridad
  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT id,
         CONCAT('🚨 Incidente: ', p_incident_type),
         CONCAT('Reportado en el viaje ', substring(p_ride_id::text, 1, 8), '. Revisa y resuelve.'),
         'incident_reported',
         jsonb_build_object('incident_id', v_incident_id, 'ride_id', p_ride_id, 'url', '/admin/incidentes')
  FROM profiles WHERE role IN ('super_admin', 'encargado');

  -- Notificar al otro participante
  IF v_ride.client_id IS NOT NULL AND v_ride.driver_id IS NOT NULL THEN
    PERFORM public.notify_user(
      CASE WHEN v_user_id = v_ride.client_id THEN v_ride.driver_id ELSE v_ride.client_id END,
      'Incidente reportado',
      'Se reportó un incidente en tu viaje. La plataforma lo está revisando.',
      'ride_incident',
      jsonb_build_object('ride_id', p_ride_id, 'incident_id', v_incident_id)
    );
  END IF;

  -- Auditoría
  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_user_id, 'REPORT_INCIDENT', 'incident', v_incident_id,
          jsonb_build_object('ride_id', p_ride_id, 'type', p_incident_type));

  RETURN jsonb_build_object(
    'success', TRUE,
    'incident_id', v_incident_id,
    'ride_id', p_ride_id,
    'status', 'incidente'
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.report_ride_incident TO anon, authenticated, service_role;

-- ============================================================
-- 8. FUNCIÓN: OBTENER INCIDENTES (para admin y participantes)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_ride_incidents(p_status TEXT DEFAULT NULL)
RETURNS SETOF ride_incidents
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_role TEXT;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT role::text INTO v_role FROM profiles WHERE id = v_user_id;

  IF v_role IN ('super_admin', 'encargado') THEN
    IF p_status IS NOT NULL THEN
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
-- 9. FUNCIÓN: RESOLVER INCIDENTE (Admin/Encargado)
-- ============================================================
CREATE OR REPLACE FUNCTION public.resolve_ride_incident(
  p_incident_id UUID,
  p_resolution TEXT,
  p_at_fault TEXT DEFAULT 'accidente',
  p_refund_percent NUMERIC DEFAULT 100,
  p_compensate_driver BOOLEAN DEFAULT TRUE,
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
  v_refund NUMERIC := 0.00;
  v_ride_final NUMERIC := 0.00;
  v_wallet RECORD;
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

  SELECT * INTO v_ride FROM rides WHERE id = v_incident.ride_id FOR UPDATE;

  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  -- ================================================================
  -- SI SE DECIDE CANCELAR: reembolsar y cancelar manualmente
  -- (El viaje puede estar en estado 'incidente' si fue reportado)
  -- ================================================================
  IF p_cancel_ride AND v_ride.status != 'cancelada' THEN
    -- Nota: v_ride.status puede ser 'incidente' (reportado) o
    -- 'aceptada'/'en_ruta' (si el admin resuelve sin reporte previo)
    -- En todos los casos, se reembolsa según % y se cancela.
    -- La lógica es manual porque auth.uid() es del admin, no del cliente.

    -- Reembolso al cliente según % configurado
    IF v_ride.payment_method = 'Billetera' AND v_ride.final_fare_usd > 0 AND p_refund_percent > 0 THEN
      v_refund := ROUND((v_ride.final_fare_usd * p_refund_percent / 100), 2);

      SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.client_id;
      IF v_wallet.id IS NOT NULL AND v_refund > 0 THEN
        UPDATE wallets
        SET balance_usd = balance_usd + v_refund,
            updated_at = NOW()
        WHERE user_id = v_ride.client_id;

        INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
        VALUES (v_wallet.id, v_ride.client_id, 'credito', v_refund, 'completado',
                CONCAT('Reembolso por incidente resuelto (', p_refund_percent, '%)'), v_ride.id);
      END IF;
    ELSIF v_ride.payment_method NOT IN ('Billetera', 'Efectivo') AND v_ride.final_fare_usd > 0 AND p_refund_percent > 0 THEN
      v_refund := ROUND((v_ride.final_fare_usd * p_refund_percent / 100), 2);

      SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.client_id;
      IF v_wallet.id IS NOT NULL AND v_refund > 0 THEN
        INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
        VALUES (v_wallet.id, v_ride.client_id, 'credito', v_refund, 'pendiente',
                CONCAT('Reembolso pendiente por incidente (Pago Móvil). ', p_refund_percent, '%'), v_ride.id);
      END IF;
    END IF;

    -- Devolver comisión al conductor si se compensa
    IF p_compensate_driver AND v_ride.commission_usd > 0 AND v_ride.driver_id IS NOT NULL THEN
      SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.driver_id;
      IF v_wallet.id IS NOT NULL THEN
        UPDATE wallets
        SET balance_usd = balance_usd + v_ride.commission_usd,
            updated_at = NOW()
        WHERE user_id = v_ride.driver_id;

        INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
        VALUES (v_wallet.id, v_ride.driver_id, 'credito', v_ride.commission_usd, 'completado',
                'Reembolso de comisión por incidente', v_ride.id);
      END IF;
    END IF;

    -- Actualizar viaje
    UPDATE rides
    SET status = 'cancelada',
        cancelled_by = v_admin_id,
        cancel_reason = p_resolution,
        cancellation_fee_usd = 0,
        driver_compensation_usd = 0,
        reimbursement_status = CASE WHEN v_ride.payment_method = 'Billetera' THEN 'auto_completado'
                                    WHEN v_ride.payment_method = 'Efectivo' THEN 'no_aplica'
                                    ELSE 'pendiente_manual' END,
        updated_at = NOW()
    WHERE id = v_ride.id;
  END IF;

  -- ================================================================
  -- CERRAR INCIDENTE
  -- ================================================================
  UPDATE ride_incidents
  SET status = 'resuelto',
      resolution = p_resolution,
      resolution_details = jsonb_build_object(
        'at_fault', p_at_fault,
        'refund_percent', p_refund_percent,
        'refund_amount', v_refund,
        'compensated_driver', p_compensate_driver,
        'ride_cancelled', p_cancel_ride
      ),
      resolved_by = v_admin_id,
      resolved_at = NOW(),
      updated_at = NOW()
  WHERE id = p_incident_id;

  -- Notificar a los participantes
  INSERT INTO notifications (user_id, title, body, type, data)
  VALUES
    (v_ride.client_id, 'Incidente resuelto', CONCAT('Tu incidente fue resuelto. ', p_resolution), 'incident_resolved',
     jsonb_build_object('incident_id', p_incident_id, 'ride_id', v_ride.id));
  IF v_ride.driver_id IS NOT NULL THEN
    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (v_ride.driver_id, 'Incidente resuelto', CONCAT('El incidente del viaje fue resuelto. ', p_resolution), 'incident_resolved',
            jsonb_build_object('incident_id', p_incident_id, 'ride_id', v_ride.id));
  END IF;

  -- Auditoría
  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_admin_id, 'RESOLVE_INCIDENT', 'incident', p_incident_id,
          jsonb_build_object('ride_id', v_ride.id, 'at_fault', p_at_fault,
                             'refund_percent', p_refund_percent, 'refund_amount', v_refund,
                             'compensated_driver', p_compensate_driver,
                             'cancelled', p_cancel_ride));

  RETURN jsonb_build_object(
    'success', TRUE,
    'incident_id', p_incident_id,
    'ride_id', v_ride.id,
    'status', 'resuelto',
    'refund_amount', v_refund,
    'ride_status', (SELECT status FROM rides WHERE id = v_ride.id)
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.resolve_ride_incident TO anon, authenticated, service_role;

-- ============================================================
-- 10. ACTUALIZAR GET_ACTIVE_RIDE PARA INCLUIR ESTADO 'incidente'
--     Sin esto, el usuario no puede volver a la pantalla de viaje
--     si recarga la app mientras hay un incidente en revisión.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_driver_active_ride()
RETURNS SETOF rides
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
BEGIN
  RETURN QUERY
  SELECT r.* FROM rides r
  WHERE r.driver_id = v_driver_id
    AND r.status IN ('aceptada', 'en_ruta', 'incidente')
  ORDER BY r.created_at DESC
  LIMIT 1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_driver_active_ride TO anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.get_client_active_ride()
RETURNS SETOF rides
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_client_id UUID := auth.uid();
BEGIN
  RETURN QUERY
  SELECT r.* FROM rides r
  WHERE r.client_id = v_client_id
    AND r.status IN ('buscando', 'aceptada', 'en_ruta', 'incidente')
  ORDER BY r.created_at DESC
  LIMIT 1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_client_active_ride TO anon, authenticated, service_role;

-- ============================================================
-- 11. FUNCIÓN: ESTIMAR FEE DE CANCELACIÓN (para mostrar al cliente)
-- ============================================================
CREATE OR REPLACE FUNCTION public.estimate_cancellation_fee(
  p_ride_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_ride RECORD;
  v_policy RECORD;
  v_fee NUMERIC := 0.00;
  v_compensation NUMERIC := 0.00;
  v_refund NUMERIC := 0.00;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;

  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF v_ride.client_id != v_user_id AND v_ride.driver_id != v_user_id THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- Si el conductor cancela, no hay fee
  IF v_ride.driver_id = v_user_id THEN
    RETURN jsonb_build_object(
      'fee', 0.00,
      'refund', v_ride.final_fare_usd,
      'commission_refunded', TRUE,
      'note', 'El conductor no paga tarifa de cancelación'
    );
  END IF;

  -- Buscar política para cliente (o accidente)
  SELECT * INTO v_policy
  FROM cancellation_policies
  WHERE ride_status = v_ride.status::text
    AND at_fault = 'cliente'
    AND is_active = TRUE;

  IF v_policy.id IS NULL THEN
    v_fee := 0.00;
  ELSE
    v_fee := ROUND((v_ride.final_fare_usd * v_policy.fee_rate / 100), 2);
    IF v_fee < v_policy.min_fee THEN v_fee := v_policy.min_fee; END IF;
    IF v_policy.max_fee IS NOT NULL AND v_fee > v_policy.max_fee THEN v_fee := v_policy.max_fee; END IF;
    v_compensation := ROUND((v_fee * v_policy.driver_compensation_rate / 100), 2);
  END IF;

  v_refund := GREATEST(v_ride.final_fare_usd - v_fee, 0);

  RETURN jsonb_build_object(
    'fee', v_fee,
    'compensation', v_compensation,
    'refund', v_refund,
    'payment_method', v_ride.payment_method,
    'commission_refunded', FALSE
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.estimate_cancellation_fee TO anon, authenticated, service_role;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'Migración de cancelaciones e incidentes completada' AS estado;