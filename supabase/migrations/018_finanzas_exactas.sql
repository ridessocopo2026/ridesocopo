-- ============================================================
-- RIDESOCOPÓ - Migración: FINANZAS EXACTAS
-- 1. Tabla driver_earnings (historial desglosado por viaje)
-- 2. Corregir comisión sobre final_fare_usd (no total_fare_usd)
-- 3. Corregir settle_ride_earnings: efectivo NO acredita en app
-- 4. Reescribir complete_ride para insertar driver_earnings
-- 5. Actualizar approve_ride_proof para acreditar al conductor
-- 6. RPC get_driver_earnings
-- 7. Reconciliación: resetear wallets y reconstruir desde cero
-- ============================================================

-- ============================================================
-- 1. TABLA: DRIVER_EARNINGS (historial exacto por viaje)
-- ============================================================
CREATE TABLE IF NOT EXISTS driver_earnings (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  ride_id UUID NOT NULL REFERENCES rides(id) ON DELETE CASCADE UNIQUE,
  driver_id UUID NOT NULL REFERENCES profiles(id),
  fare_usd NUMERIC(10,2) NOT NULL DEFAULT 0.00,
  commission_usd NUMERIC(10,2) NOT NULL DEFAULT 0.00,
  cash_received_usd NUMERIC(10,2) NOT NULL DEFAULT 0.00,
  app_credit_usd NUMERIC(10,2) NOT NULL DEFAULT 0.00,
  payment_method TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'completado' CHECK (status IN ('completado', 'cancelado', 'ajustado')),
  created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Índices para búsquedas rápidas
CREATE INDEX IF NOT EXISTS idx_driver_earnings_driver ON driver_earnings(driver_id);
CREATE INDEX IF NOT EXISTS idx_driver_earnings_created ON driver_earnings(created_at DESC);

GRANT ALL ON public.driver_earnings TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;

-- RLS: conductor ve sus propias ganancias
ALTER TABLE driver_earnings ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "driver_view_own_earnings" ON public.driver_earnings;
CREATE POLICY "driver_view_own_earnings" ON public.driver_earnings
  FOR SELECT USING (auth.uid() = driver_id);

DROP POLICY IF EXISTS "admin_view_all_earnings" ON public.driver_earnings;
CREATE POLICY "admin_view_all_earnings" ON public.driver_earnings
  FOR SELECT USING (public.get_user_role(auth.uid()) IN ('super_admin', 'encargado'));

-- ============================================================
-- 2. CORREGIR ACCEPT_RIDE: comisión sobre final_fare_usd
--    (era total_fare_usd, que no incluye descuentos)
-- ============================================================
DROP FUNCTION IF EXISTS public.accept_ride(UUID);

CREATE OR REPLACE FUNCTION public.accept_ride(p_ride_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_ride RECORD;
  v_wallet RECORD;
  v_commission NUMERIC;
  v_vehicle RECORD;
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT driver_status INTO v_ride FROM profiles WHERE id = v_driver_id;
  IF v_ride.driver_status != 'aprobado' THEN
    RAISE EXCEPTION 'Conductor no aprobado';
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id AND status = 'buscando';
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no disponible';
  END IF;

  SELECT * INTO v_vehicle FROM vehicles
  WHERE driver_id = v_driver_id AND category = v_ride.category AND is_active = TRUE
  LIMIT 1;

  IF v_vehicle.id IS NULL THEN
    RAISE EXCEPTION 'No tiene un vehículo activo de la categoría requerida';
  END IF;

  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_driver_id;

  -- Comisión CORRECTA: sobre final_fare_usd (lo que el cliente REALMENTE paga)
  v_commission := ROUND(COALESCE(v_ride.final_fare_usd, 0) * v_ride.commission_rate / 100, 2);

  IF v_wallet.balance_usd < -v_wallet.debt_limit_usd THEN
    RETURN jsonb_build_object(
      'success', FALSE,
      'error', 'DEUDA_EXCEDIDA',
      'message', 'Tienes una deuda pendiente que supera el límite permitido. Contacta al administrador para regularizar tu situación.',
      'deuda_actual', v_wallet.balance_usd,
      'limite_deuda', v_wallet.debt_limit_usd
    );
  END IF;

  UPDATE wallets
  SET balance_usd = balance_usd - v_commission,
      updated_at = NOW()
  WHERE user_id = v_driver_id;

  INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
  VALUES (v_wallet.id, v_driver_id, 'comision', v_commission, 'completado',
          'Comisión por viaje', p_ride_id);

  UPDATE rides
  SET driver_id = v_driver_id,
      vehicle_id = v_vehicle.id,
      commission_usd = v_commission,
      status = 'aceptada',
      started_at = NOW()
  WHERE id = p_ride_id;

  PERFORM public.notify_user(
    v_ride.client_id,
    'Conductor asignado',
    'Un conductor ha aceptado tu viaje',
    'ride_accepted',
    jsonb_build_object('ride_id', p_ride_id, 'url', '/cliente/viaje/' || p_ride_id)
  );

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_driver_id, 'ACCEPT_RIDE', 'ride', p_ride_id,
          jsonb_build_object('commission', v_commission, 'final_fare', v_ride.final_fare_usd));

  RETURN jsonb_build_object(
    'success', TRUE,
    'ride_id', p_ride_id,
    'commission', v_commission
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.accept_ride TO anon, authenticated, service_role;

-- ============================================================
-- 3. REESCRIBIR SETTLE_RIDE_EARNINGS: lógica exacta por método
--    - Efectivo: el conductor ya cobró → NO acreditar en app
--    - Billetera: la app le debe → acreditar final - comisión
--    - Pago Móvil: acreditar SOLO si comprobante aprobado
-- ============================================================
CREATE OR REPLACE FUNCTION public.settle_ride_earnings(p_ride_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ride RECORD;
  v_wallet RECORD;
  v_commission NUMERIC := 0.00;
  v_cash NUMERIC := 0.00;
  v_app_credit NUMERIC := 0.00;
  v_payment_method TEXT;
BEGIN
  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF v_ride.status != 'completada' THEN
    RAISE EXCEPTION 'El viaje debe estar completado';
  END IF;

  IF v_ride.driver_id IS NULL THEN
    RETURN jsonb_build_object('success', TRUE, 'driver_earned', 0, 'note', 'Sin conductor asignado');
  END IF;

  -- Idempotente: si ya se liquidó, no acreditar de nuevo
  IF EXISTS (SELECT 1 FROM driver_earnings WHERE ride_id = p_ride_id) THEN
    RETURN jsonb_build_object('success', TRUE, 'already_settled', TRUE);
  END IF;

  v_commission := COALESCE(v_ride.commission_usd, 0);
  v_payment_method := v_ride.payment_method;

  -- ============================================================
  -- DETERMINAR FLUJO DE DINERO SEGÚN MÉTODO DE PAGO
  -- ============================================================
  IF v_payment_method = 'Efectivo' THEN
    -- El conductor YA cobró al cliente en efectivo.
    -- La app NO le debe nada. Solo la comisión queda como deuda.
    v_cash := v_ride.final_fare_usd;
    v_app_credit := 0.00;
  ELSIF v_payment_method = 'Billetera' THEN
    -- El cliente pagó a la app. La app le debe al conductor.
    v_cash := 0.00;
    v_app_credit := GREATEST(v_ride.final_fare_usd - v_commission, 0);
  ELSE
    -- Pago Móvil u otro método con comprobante:
    -- Solo acreditar si el admin aprobó el comprobante
    IF v_ride.proof_status = 'aprobado' THEN
      v_cash := 0.00;
      v_app_credit := GREATEST(v_ride.final_fare_usd - v_commission, 0);
    ELSE
      -- Comprobante pendiente/rechazado: no acreditar aún
      v_cash := 0.00;
      v_app_credit := 0.00;
    END IF;
  END IF;

  -- Insertar historial exacto
  INSERT INTO driver_earnings (
    ride_id, driver_id, fare_usd, commission_usd,
    cash_received_usd, app_credit_usd, payment_method, status
  ) VALUES (
    p_ride_id, v_ride.driver_id, v_ride.final_fare_usd, v_commission,
    v_cash, v_app_credit, v_payment_method, 'completado'
  )
  ON CONFLICT (ride_id) DO NOTHING;

  -- Acreditar en la wallet SOLO lo que la app realmente le debe
  IF v_app_credit > 0 THEN
    SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.driver_id;
    IF v_wallet.id IS NOT NULL THEN
      UPDATE wallets
      SET balance_usd = balance_usd + v_app_credit,
          updated_at = NOW()
      WHERE user_id = v_ride.driver_id;

      INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
      VALUES (v_wallet.id, v_ride.driver_id, 'credito', v_app_credit, 'completado',
              CONCAT('Ganancia del viaje por ', v_payment_method), p_ride_id);
    END IF;
  END IF;

  -- Auditoría del rendimiento exacto
  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (
    COALESCE(v_ride.driver_id, auth.uid()),
    'SETTLE_RIDE_EARNINGS', 'ride', p_ride_id,
    jsonb_build_object(
      'fare', v_ride.final_fare_usd,
      'commission', v_commission,
      'cash_received', v_cash,
      'app_credit', v_app_credit,
      'payment_method', v_payment_method
    )
  );

  RETURN jsonb_build_object(
    'success', TRUE,
    'ride_id', p_ride_id,
    'cash_received_usd', v_cash,
    'app_credit_usd', v_app_credit,
    'commission_usd', v_commission,
    'payment_method', v_payment_method
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.settle_ride_earnings TO anon, authenticated, service_role;

-- ============================================================
-- 4. REESCRIBIR COMPLETE_RIDE: llama a settle + notifica
-- ============================================================
CREATE OR REPLACE FUNCTION public.complete_ride(
  p_ride_id UUID,
  p_rating INTEGER DEFAULT NULL,
  p_review TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_ride RECORD;
  v_settlement JSONB;
BEGIN
  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF v_ride.driver_id != v_user_id AND v_ride.client_id != v_user_id THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF v_ride.status NOT IN ('aceptada', 'en_ruta') THEN
    RAISE EXCEPTION 'Estado inválido';
  END IF;

  UPDATE rides
  SET status = 'completada',
      completed_at = NOW(),
      rating = COALESCE(p_rating, rating),
      review = COALESCE(p_review, review)
  WHERE id = p_ride_id;

  -- Liquidar ganancias exactas (inserta en driver_earnings)
  IF v_ride.driver_id IS NOT NULL THEN
    v_settlement := public.settle_ride_earnings(p_ride_id);
  END IF;

  -- Notificar
  IF v_user_id = v_ride.driver_id THEN
    PERFORM public.notify_user(
      v_ride.client_id, 'Viaje completado', 'Tu viaje ha finalizado',
      'ride_completed', jsonb_build_object('ride_id', p_ride_id, 'url', '/cliente/viaje/' || p_ride_id)
    );
  ELSE
    PERFORM public.notify_user(
      v_ride.driver_id, 'Viaje completado', 'El viaje ha finalizado',
      'ride_completed', jsonb_build_object('ride_id', p_ride_id, 'url', '/conductor/viaje/' || p_ride_id)
    );
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'ride_id', p_ride_id, 'settlement', v_settlement);
END;
$$;

GRANT EXECUTE ON FUNCTION public.complete_ride TO anon, authenticated, service_role;

-- ============================================================
-- 5. ACTUALIZAR APPROVE_RIDE_PROOF: si el viaje ya se completó,
--    acreditar al conductor las ganancias pendientes (Pago Móvil)
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
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id FOR UPDATE;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF v_ride.proof_status != 'pendiente' THEN
    RAISE EXCEPTION 'El comprobante ya fue procesado';
  END IF;

  v_status := CASE WHEN p_approve THEN 'aprobado' ELSE 'rechazado' END;

  UPDATE rides SET proof_status = v_status WHERE id = p_ride_id;

  -- Si el viaje ya se completó y el comprobante se aprueba AHORA,
  -- hay que acreditar al conductor las ganancias que quedaron pendientes
  IF p_approve AND v_ride.status = 'completada' AND v_ride.driver_id IS NOT NULL THEN
    v_commission := COALESCE(v_ride.commission_usd, 0);
    v_app_credit := GREATEST(v_ride.final_fare_usd - v_commission, 0);

    -- Actualizar/crear driver_earnings (si existe, pasar cash=0 a app_credit)
    SELECT * INTO v_earning FROM driver_earnings WHERE ride_id = p_ride_id;

    IF v_earning.id IS NOT NULL THEN
      UPDATE driver_earnings
      SET cash_received_usd = 0,
          app_credit_usd = v_app_credit,
          status = CASE WHEN p_approve THEN 'completado' ELSE 'ajustado' END
      WHERE ride_id = p_ride_id;
    ELSE
      INSERT INTO driver_earnings (
        ride_id, driver_id, fare_usd, commission_usd,
        cash_received_usd, app_credit_usd, payment_method, status
      ) VALUES (
        p_ride_id, v_ride.driver_id, v_ride.final_fare_usd, v_commission,
        0, v_app_credit, v_ride.payment_method, 'completado'
      );
    END IF;

    -- Acreditar en la wallet (si no fue acreditado antes)
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

  -- Notificar cliente
  INSERT INTO notifications (user_id, title, body, type, data)
  VALUES (
    v_ride.client_id,
    CASE WHEN p_approve THEN 'Comprobante aprobado' ELSE 'Comprobante rechazado' END,
    CASE WHEN p_approve THEN 'Tu pago fue aprobado. El viaje puede continuar.'
         ELSE 'Tu comprobante fue rechazado. Sube uno válido.' END,
    'proof_reviewed',
    jsonb_build_object('ride_id', p_ride_id, 'approved', p_approve)
  );

  RETURN jsonb_build_object('success', TRUE, 'proof_status', v_status);
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_ride_proof TO anon, authenticated, service_role;

-- ============================================================
-- 6. RPC: OBTENER GANANCIAS DEL CONDUCTOR (historial desglosado)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_driver_earnings()
RETURNS TABLE (
  ride_id UUID,
  fare_usd NUMERIC,
  commission_usd NUMERIC,
  cash_received_usd NUMERIC,
  app_credit_usd NUMERIC,
  payment_method TEXT,
  destination TEXT,
  created_at TIMESTAMPTZ
)
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT de.ride_id,
         de.fare_usd,
         de.commission_usd,
         de.cash_received_usd,
         de.app_credit_usd,
         de.payment_method,
         r.destination_address,
         de.created_at
  FROM driver_earnings de
  LEFT JOIN rides r ON r.id = de.ride_id
  WHERE de.driver_id = auth.uid()
  ORDER BY de.created_at DESC
  LIMIT 50;
$$;

GRANT EXECUTE ON FUNCTION public.get_driver_earnings TO anon, authenticated, service_role;

-- ============================================================
-- 7. RECONCILIACIÓN: resetear wallets de conductores y
--    reconstruir saldo desde cero (datos actuales son de prueba)
-- ============================================================
DO $$
DECLARE
  v_ride RECORD;
  v_wallet RECORD;
  v_net NUMERIC;
  v_app_credit NUMERIC;
  v_cash NUMERIC;
  v_commission NUMERIC;
  v_recon_cursor CURSOR FOR
    SELECT r.* FROM rides r
    WHERE r.status = 'completada'
      AND r.driver_id IS NOT NULL;
BEGIN
  -- 1. Resetear billeteras de conductores a $0
  UPDATE wallets w
  SET balance_usd = 0, updated_at = NOW()
  FROM profiles p
  WHERE p.id = w.user_id AND p.role = 'conductor';

  -- 2. Borrar transacciones históricas de conductores (se reconstruirán)
  DELETE FROM transactions t
  USING profiles p
  WHERE p.id = t.user_id AND p.role = 'conductor';

  -- 3. Limpiar driver_earnings existentes (reconstrucción total)
  TRUNCATE driver_earnings;

  -- 4. Reconstruir earnings y saldos por cada viaje completado
  FOR v_ride IN v_recon_cursor LOOP
    v_commission := COALESCE(v_ride.commission_usd, 0);
    v_cash := 0;
    v_app_credit := 0;

    -- Lógica exacta por método
    IF v_ride.payment_method = 'Efectivo' THEN
      v_cash := v_ride.final_fare_usd;
    ELSIF v_ride.payment_method = 'Billetera' THEN
      v_app_credit := GREATEST(v_ride.final_fare_usd - v_commission, 0);
    ELSE
      -- Pago Móvil: solo acreditar si comprobante aprobado
      IF v_ride.proof_status = 'aprobado' THEN
        v_app_credit := GREATEST(v_ride.final_fare_usd - v_commission, 0);
      END IF;
    END IF;

    -- Insertar historial exacto
    INSERT INTO driver_earnings (
      ride_id, driver_id, fare_usd, commission_usd,
      cash_received_usd, app_credit_usd, payment_method, status
    ) VALUES (
      v_ride.id, v_ride.driver_id, v_ride.final_fare_usd, v_commission,
      v_cash, v_app_credit, v_ride.payment_method, 'completado'
    );

    -- Ajustar saldo de la wallet del conductor
    v_net := v_app_credit - v_commission;

    SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.driver_id;
    IF v_wallet.id IS NOT NULL THEN
      UPDATE wallets
      SET balance_usd = balance_usd + v_net,
          updated_at = NOW()
      WHERE user_id = v_ride.driver_id;

      -- Registrar transacción de comisión (siempre que exista)
      IF v_commission > 0 THEN
        INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
        VALUES (v_wallet.id, v_ride.driver_id, 'comision', v_commission, 'completado',
                'Comisión por viaje', v_ride.id);
      END IF;

      -- Registrar crédito si la app le debe al conductor
      IF v_app_credit > 0 THEN
        INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
        VALUES (v_wallet.id, v_ride.driver_id, 'credito', v_app_credit, 'completado',
                CONCAT('Ganancia del viaje por ', v_ride.payment_method), v_ride.id);
      END IF;
    END IF;
  END LOOP;

  -- Auditoría de la reconciliación
  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (auth.uid(), 'RECONCILE_WALLETS', 'wallet', NULL,
          jsonb_build_object('rebuilt_from', 'rides_completadas', 'total', 
            (SELECT COUNT(*) FROM driver_earnings)));
END;
$$;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'Migración de finanzas exactas completada' AS estado;