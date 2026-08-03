-- ============================================================
-- RIDESOCOPÓ - Migración: SISTEMA DE LIQUIDACIÓN FINANCIERA
-- Modelo correcto: plataforma cobra 10%, conductor recibe 90%.
-- ============================================================

-- 1. TABLA: PAYOUTS (liquidaciones entre conductor y plataforma)
CREATE TABLE IF NOT EXISTS payouts (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  driver_id UUID NOT NULL REFERENCES profiles(id),
  amount_usd NUMERIC(12,2) NOT NULL,
  type TEXT NOT NULL CHECK (type IN ('driver_pay_platform', 'platform_pay_driver')),
  status TEXT NOT NULL DEFAULT 'pendiente' CHECK (status IN ('pendiente', 'aprobado', 'rechazado', 'confirmado')),
  proof_url TEXT,
  created_by UUID REFERENCES profiles(id),
  reviewed_by UUID REFERENCES profiles(id),
  ride_id UUID REFERENCES rides(id),
  description TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

GRANT ALL ON public.payouts TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;

-- RLS
ALTER TABLE payouts ENABLE ROW LEVEL SECURITY;

-- Conductor ve sus payouts
DROP POLICY IF EXISTS "driver_view_own_payouts" ON public.payouts;
CREATE POLICY "driver_view_own_payouts" ON public.payouts
  FOR SELECT USING (auth.uid() = driver_id);

-- Conductor crea payouts (pagar plataforma)
DROP POLICY IF EXISTS "driver_create_payouts" ON public.payouts;
CREATE POLICY "driver_create_payouts" ON public.payouts
  FOR INSERT WITH CHECK (auth.uid() = driver_id AND type = 'driver_pay_platform');

-- Admin ve todos
DROP POLICY IF EXISTS "admin_view_payouts" ON public.payouts;
CREATE POLICY "admin_view_payouts" ON public.payouts
  FOR SELECT USING (public.get_user_role(auth.uid()) IN ('super_admin', 'encargado'));

-- Admin crea pagos a conductores
DROP POLICY IF EXISTS "admin_create_payouts" ON public.payouts;
CREATE POLICY "admin_create_payouts" ON public.payouts
  FOR INSERT WITH CHECK (
    public.get_user_role(auth.uid()) IN ('super_admin', 'encargado')
    AND type = 'platform_pay_driver'
  );

-- ============================================================
-- 2. FUNCIONES DE LIQUIDACIÓN
-- ============================================================

-- 2.1 LIQUIDAR GANANCIAS DEL CONDUCTOR AL COMPLETAR VIAJE
-- Si el pago fue a la plataforma → acreditar Total - Comisión al conductor
-- Si el pago fue efectivo → solo registrar (conductor ya cobró en efectivo)
CREATE OR REPLACE FUNCTION public.settle_ride_earnings(p_ride_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ride RECORD;
  v_wallet RECORD;
  v_driver_earn NUMERIC;
  v_paid_to_platform BOOLEAN;
BEGIN
  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  -- Solo liquidar una vez
  IF v_ride.status != 'completada' THEN
    RAISE EXCEPTION 'El viaje debe estar completado';
  END IF;

  -- ¿El pago fue a la plataforma? (billetera, pago móvil u otro digital)
  v_paid_to_platform := (
    SELECT NOT COALESCE((SELECT proof_required FROM payment_methods WHERE name = v_ride.payment_method), FALSE)
    OR v_ride.proof_status = 'aprobado'
  );

  -- Ganancias del conductor = Total - Comisión
  v_driver_earn := v_ride.final_fare_usd - COALESCE(v_ride.commission_usd, 0);

  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.driver_id;

  IF v_paid_to_platform THEN
    -- El cliente pagó a la plataforma → la plataforma le debe al conductor
    UPDATE wallets
    SET balance_usd = balance_usd + v_driver_earn,
        updated_at = NOW()
    WHERE user_id = v_ride.driver_id;

    INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
    VALUES (v_wallet.id, v_ride.driver_id, 'credito', v_driver_earn, 'completado',
            CONCAT('Ganancia del viaje (90%) - ', v_ride.final_fare_usd, '$ - comisión ', v_ride.commission_usd, '$'),
            p_ride_id);

    RETURN jsonb_build_object('success', TRUE, 'driver_earned', v_driver_earn, 'credited', TRUE);
  ELSE
    -- El cliente pagó en efectivo → el conductor ya cobró, solo queda la comisión pendiente
    -- (la comisión ya se descontó al aceptar; esto registra el flujo)
    RETURN jsonb_build_object('success', TRUE, 'driver_earned', v_driver_earn, 'credited', FALSE,
                              'note', 'Pago en efectivo: el conductor ya recibió su parte');
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.settle_ride_earnings TO anon, authenticated, service_role;

-- 2.2 CONDUCTOR PAGA A LA PLATAFORMA (sube comprobante)
CREATE OR REPLACE FUNCTION public.driver_pay_to_platform(
  p_amount_usd NUMERIC,
  p_proof_url TEXT,
  p_description TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_payout_id UUID;
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  IF p_amount_usd <= 0 THEN
    RAISE EXCEPTION 'Monto inválido';
  END IF;

  IF p_proof_url IS NULL OR p_proof_url = '' THEN
    RAISE EXCEPTION 'Debes subir un comprobante';
  END IF;

  INSERT INTO payouts (driver_id, amount_usd, type, status, proof_url, description, created_by)
  VALUES (v_driver_id, p_amount_usd, 'driver_pay_platform', 'pendiente', p_proof_url,
          COALESCE(p_description, 'Pago del conductor a la plataforma'), v_driver_id)
  RETURNING id INTO v_payout_id;

  -- Notificar admin/encargado
  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT id, 'Pago de conductor por aprobar',
         'Un conductor pagó ' || p_amount_usd || '$ a la plataforma. Revisar.',
         'payout_driver_pay',
         jsonb_build_object('payout_id', v_payout_id)
  FROM profiles WHERE role IN ('super_admin', 'encargado');

  RETURN v_payout_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.driver_pay_to_platform TO anon, authenticated, service_role;

-- 2.3 ADMIN PAGA AL CONDUCTOR (payout)
CREATE OR REPLACE FUNCTION public.admin_pay_driver(
  p_driver_id UUID,
  p_amount_usd NUMERIC,
  p_description TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_payout_id UUID;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF p_amount_usd <= 0 THEN
    RAISE EXCEPTION 'Monto inválido';
  END IF;

  INSERT INTO payouts (driver_id, amount_usd, type, status, description, created_by)
  VALUES (p_driver_id, p_amount_usd, 'platform_pay_driver', 'pendiente',
          COALESCE(p_description, 'Pago de la plataforma al conductor'), v_admin_id)
  RETURNING id INTO v_payout_id;

  -- Notificar conductor
  INSERT INTO notifications (user_id, title, body, type, data)
  VALUES (p_driver_id, 'Pago disponible',
          'La plataforma te pagará ' || p_amount_usd || '$. Confirma cuando lo recibas.',
          'payout_platform_pay',
          jsonb_build_object('payout_id', v_payout_id));

  RETURN v_payout_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_pay_driver TO anon, authenticated, service_role;

-- 2.4 CONDUCTOR CONFIRMA QUE RECIBIÓ EL PAGO DE LA PLATAFORMA
CREATE OR REPLACE FUNCTION public.driver_confirm_payout(p_payout_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_payout RECORD;
  v_wallet RECORD;
BEGIN
  SELECT * INTO v_payout FROM payouts WHERE id = p_payout_id;
  IF v_payout.id IS NULL THEN
    RAISE EXCEPTION 'Pago no encontrado';
  END IF;

  IF v_payout.driver_id != v_driver_id THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF v_payout.type != 'platform_pay_driver' OR v_payout.status != 'pendiente' THEN
    RAISE EXCEPTION 'Pago no válido para confirmar';
  END IF;

  -- Descontar del saldo del conductor (la plataforma le pagó en efectivo/transferencia)
  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_driver_id;
  UPDATE wallets
  SET balance_usd = balance_usd - v_payout.amount_usd,
      updated_at = NOW()
  WHERE user_id = v_driver_id;

  UPDATE payouts SET status = 'confirmado', updated_at = NOW() WHERE id = p_payout_id;

  INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description)
  VALUES (v_wallet.id, v_driver_id, 'debito', v_payout.amount_usd, 'completado',
          'Pago recibido de la plataforma');

  RETURN jsonb_build_object('success', TRUE, 'new_balance', v_wallet.balance_usd - v_payout.amount_usd);
END;
$$;

GRANT EXECUTE ON FUNCTION public.driver_confirm_payout TO anon, authenticated, service_role;

-- 2.5 ADMIN APRUEBA/RECHAZA PAGO DEL CONDUCTOR A LA PLATAFORMA
CREATE OR REPLACE FUNCTION public.approve_payout(
  p_payout_id UUID,
  p_approve BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_payout RECORD;
  v_wallet RECORD;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT * INTO v_payout FROM payouts WHERE id = p_payout_id;
  IF v_payout.id IS NULL THEN
    RAISE EXCEPTION 'Pago no encontrado';
  END IF;

  IF v_payout.status != 'pendiente' THEN
    RAISE EXCEPTION 'El pago ya fue procesado';
  END IF;

  IF v_payout.type = 'driver_pay_platform' AND p_approve THEN
    -- El conductor pagó a la plataforma → reducir deuda (sumar al balance)
    SELECT * INTO v_wallet FROM wallets WHERE user_id = v_payout.driver_id;
    UPDATE wallets
    SET balance_usd = balance_usd + v_payout.amount_usd,
        updated_at = NOW()
    WHERE user_id = v_payout.driver_id;

    UPDATE payouts SET status = 'aprobado', reviewed_by = v_admin_id, updated_at = NOW()
    WHERE id = p_payout_id;

    INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description)
    VALUES (v_wallet.id, v_payout.driver_id, 'credito', v_payout.amount_usd, 'completado',
            'Pago del conductor a la plataforma (aprobado)');

    -- Notificar conductor
    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (v_payout.driver_id, 'Pago aprobado',
            'Tu pago de ' || v_payout.amount_usd || '$ fue aprobado. Tu deuda fue actualizada.',
            'payout_approved', jsonb_build_object('payout_id', p_payout_id));
  ELSIF v_payout.type = 'driver_pay_platform' AND NOT p_approve THEN
    UPDATE payouts SET status = 'rechazado', reviewed_by = v_admin_id, updated_at = NOW()
    WHERE id = p_payout_id;

    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (v_payout.driver_id, 'Pago rechazado',
            'Tu pago de ' || v_payout.amount_usd || '$ fue rechazado. Verifica el comprobante.',
            'payout_rejected', jsonb_build_object('payout_id', p_payout_id));
  ELSIF v_payout.type = 'platform_pay_driver' THEN
    -- Pago de plataforma a conductor: solo admin revisa, el conductor confirma
    UPDATE payouts SET reviewed_by = v_admin_id, updated_at = NOW() WHERE id = p_payout_id;
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'payout_id', p_payout_id, 'status',
    (SELECT status FROM payouts WHERE id = p_payout_id));
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_payout TO anon, authenticated, service_role;

-- 2.6 OBTENER PAYOUTS (filtrado por rol)
CREATE OR REPLACE FUNCTION public.get_payouts()
RETURNS SETOF payouts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_role TEXT;
BEGIN
  SELECT role::text INTO v_role FROM profiles WHERE id = v_user_id;
  IF v_role IN ('super_admin', 'encargado') THEN
    RETURN QUERY SELECT * FROM payouts ORDER BY created_at DESC LIMIT 50;
  ELSE
    RETURN QUERY SELECT * FROM payouts WHERE driver_id = v_user_id ORDER BY created_at DESC LIMIT 50;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_payouts TO anon, authenticated, service_role;

-- 2.7 ACTUALIZAR COMPLETE_RIDE para llamar a settle_ride_earnings
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

  -- Liquidar ganancias del conductor
  IF v_ride.driver_id IS NOT NULL THEN
    v_settlement := public.settle_ride_earnings(p_ride_id);
  END IF;

  -- Notificar
  IF v_user_id = v_ride.driver_id THEN
    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (v_ride.client_id, 'Viaje completado', 'Tu viaje ha finalizado', 'ride_completed',
            jsonb_build_object('ride_id', p_ride_id));
  ELSE
    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (v_ride.driver_id, 'Viaje completado', 'El viaje ha finalizado', 'ride_completed',
            jsonb_build_object('ride_id', p_ride_id));
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'ride_id', p_ride_id, 'settlement', v_settlement);
END;
$$;

GRANT EXECUTE ON FUNCTION public.complete_ride TO anon, authenticated, service_role;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'Migración de finanzas completada' AS estado;