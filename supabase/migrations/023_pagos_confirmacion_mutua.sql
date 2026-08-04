-- ============================================================
-- RIDESOCOPÓ - Migración: PAGOS CON CONFIRMACIÓN MUTUA
-- 1. Conductor puede solicitar retiro de su saldo
-- 2. Admin aprueba/rechaza la solicitud
-- 3. Conductor confirma que recibió el pago (doble confirmación)
-- 4. Admin puede pagar directamente a un conductor
-- ============================================================

-- ============================================================
-- 1. FUNCIÓN: CONDUCTOR SOLICITA RETIRO
-- El conductor con saldo positivo puede solicitar que le paguen.
-- El admin debe aprobar y luego el conductor confirmar recepción.
-- ============================================================
CREATE OR REPLACE FUNCTION public.driver_request_payout(
  p_amount_usd NUMERIC,
  p_description TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_wallet RECORD;
  v_profile RECORD;
  v_payout_id UUID;
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT * INTO v_profile FROM profiles WHERE id = v_driver_id;
  IF v_profile.role != 'conductor' OR v_profile.driver_status != 'aprobado' THEN
    RAISE EXCEPTION 'No autorizado o conductor no aprobado';
  END IF;

  IF p_amount_usd <= 0 THEN
    RAISE EXCEPTION 'Monto inválido';
  END IF;

  -- Validar saldo disponible
  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_driver_id;
  IF v_wallet.id IS NULL THEN
    RAISE EXCEPTION 'Billetera no encontrada';
  END IF;

  IF v_wallet.balance_usd < p_amount_usd THEN
    RAISE EXCEPTION USING MESSAGE = format('Saldo insuficiente. Disponible: $%s, solicitado: $%s', v_wallet.balance_usd, p_amount_usd);
  END IF;

  -- Crear payout (la app paga al conductor)
  INSERT INTO payouts (driver_id, amount_usd, type, status, description, created_by)
  VALUES (v_driver_id, p_amount_usd, 'platform_pay_driver', 'pendiente',
          COALESCE(p_description, 'Retiro solicitado por el conductor'), v_driver_id)
  RETURNING id INTO v_payout_id;

  -- Notificar a admins
  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT id, 'Solicitud de retiro',
         CONCAT(v_profile.full_name, ' solicita retiro de $', p_amount_usd),
         'payout_request',
         jsonb_build_object('payout_id', v_payout_id, 'url', '/admin/liquidaciones')
  FROM profiles WHERE role IN ('super_admin', 'encargado');

  RETURN v_payout_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.driver_request_payout TO anon, authenticated, service_role;

-- ============================================================
-- 2. FUNCIÓN: ADMIN PAGA DIRECTAMENTE A UN CONDUCTOR
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_pay_driver_manual(
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
  v_wallet RECORD;
  v_payout_id UUID;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF p_amount_usd <= 0 THEN
    RAISE EXCEPTION 'Monto inválido';
  END IF;

  -- Validar saldo disponible del conductor
  SELECT * INTO v_wallet FROM wallets WHERE user_id = p_driver_id;
  IF v_wallet.id IS NULL THEN
    RAISE EXCEPTION 'Billetera del conductor no encontrada';
  END IF;

  IF v_wallet.balance_usd < p_amount_usd THEN
    RAISE EXCEPTION USING MESSAGE = format('El conductor solo tiene disponible: $%s', v_wallet.balance_usd);
  END IF;

  -- Crear payout (la app paga al conductor)
  INSERT INTO payouts (driver_id, amount_usd, type, status, description, created_by)
  VALUES (p_driver_id, p_amount_usd, 'platform_pay_driver', 'pendiente',
          COALESCE(p_description, 'Pago de la plataforma al conductor'), v_admin_id)
  RETURNING id INTO v_payout_id;

  -- Notificar al conductor
  INSERT INTO notifications (user_id, title, body, type, data)
  VALUES (p_driver_id, 'Pago disponible',
          CONCAT('La plataforma te pagará $', p_amount_usd, '. Confirma cuando lo recibas.'),
          'payout_platform_pay',
          jsonb_build_object('payout_id', v_payout_id, 'url', '/conductor/billetera'));

  RETURN v_payout_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_pay_driver_manual TO anon, authenticated, service_role;

-- ============================================================
-- 3. MEJORAR APPROVE_PAYOUT: para retiros de conductores,
--    aprobar NO descuenta aún — solo marca aprobado y
--    notifica al conductor para que confirme recepción.
-- ============================================================
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

  SELECT * INTO v_payout FROM payouts WHERE id = p_payout_id FOR UPDATE;
  IF v_payout.id IS NULL THEN
    RAISE EXCEPTION 'Pago no encontrado';
  END IF;

  IF v_payout.status != 'pendiente' THEN
    RAISE EXCEPTION 'El pago ya fue procesado';
  END IF;

  IF v_payout.type = 'driver_pay_platform' AND p_approve THEN
    -- El conductor pagó a la plataforma → acreditar a su balance (reduce deuda)
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

  ELSIF v_payout.type = 'platform_pay_driver' AND p_approve THEN
    -- La app paga al conductor: aprobar NO descuenta aún.
    -- El conductor debe confirmar recepción (segunda confirmación).
    UPDATE payouts SET status = 'aprobado', reviewed_by = v_admin_id, updated_at = NOW()
    WHERE id = p_payout_id;

    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (v_payout.driver_id, 'Pago aprobado — Confirma recibo',
            CONCAT('La plataforma te pagó $', v_payout.amount_usd, '. Confirma que lo recibiste.'),
            'payout_approved_confirm',
            jsonb_build_object('payout_id', p_payout_id, 'url', '/conductor/billetera'));

  ELSIF v_payout.type = 'platform_pay_driver' AND NOT p_approve THEN
    -- Admin rechazó la solicitud de retiro del conductor
    UPDATE payouts SET status = 'rechazado', reviewed_by = v_admin_id, updated_at = NOW()
    WHERE id = p_payout_id;

    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (v_payout.driver_id, 'Solicitud de retiro rechazada',
            CONCAT('Tu solicitud de retiro de $', v_payout.amount_usd, ' fue rechazada. Contacta a la plataforma.'),
            'payout_rejected', jsonb_build_object('payout_id', p_payout_id));
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'payout_id', p_payout_id, 'status',
    (SELECT status FROM payouts WHERE id = p_payout_id));
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_payout TO anon, authenticated, service_role;

-- ============================================================
-- 4. MEJORAR DRIVER_CONFIRM_PAYOUT: el conductor confirma que
--    recibió el pago de la plataforma → recién ahí se descuenta
--    de su saldo virtual (doble confirmación).
-- ============================================================
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
  v_new_balance NUMERIC;
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT * INTO v_payout FROM payouts WHERE id = p_payout_id FOR UPDATE;
  IF v_payout.id IS NULL THEN
    RAISE EXCEPTION 'Pago no encontrado';
  END IF;

  IF v_payout.driver_id != v_driver_id THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF v_payout.type != 'platform_pay_driver' OR v_payout.status != 'aprobado' THEN
    RAISE EXCEPTION 'El pago no está listo para confirmar. Debe estar aprobado por la plataforma.';
  END IF;

  -- Validar saldo disponible
  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_driver_id;
  IF v_wallet.balance_usd < v_payout.amount_usd THEN
    RAISE EXCEPTION USING MESSAGE = format('Saldo insuficiente para confirmar este pago. Disponible: $%s', v_wallet.balance_usd);
  END IF;

  -- Descontar saldo (la app le pagó externamente, ahora se descuenta del virtual)
  UPDATE wallets
  SET balance_usd = balance_usd - v_payout.amount_usd,
      updated_at = NOW()
  WHERE user_id = v_driver_id;

  SELECT balance_usd INTO v_new_balance FROM wallets WHERE user_id = v_driver_id;

  UPDATE payouts SET status = 'confirmado', updated_at = NOW() WHERE id = p_payout_id;

  INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, reviewed_by)
  VALUES (v_wallet.id, v_driver_id, 'debito', v_payout.amount_usd, 'completado',
          'Pago recibido de la plataforma (confirmado)', v_driver_id);

  RETURN jsonb_build_object('success', TRUE, 'new_balance', v_new_balance);
END;
$$;

GRANT EXECUTE ON FUNCTION public.driver_confirm_payout TO anon, authenticated, service_role;

-- ============================================================
-- Verificación
-- ============================================================
SELECT 'Migración de pagos con confirmación mutua completada' AS estado;