-- ============================================================
-- RIDESOCOPÓ - Migración: COMISIÓN CON CRÉDITO (SIN SALDO PREVIO)
-- El conductor NO necesita saldo positivo para aceptar viajes.
-- La comisión se descuenta de la billetera (puede quedar negativa).
-- El bloqueo ocurre solo si la deuda supera el límite definido por el Admin.
-- ============================================================

-- 1. ACTUALIZAR FUNCIÓN ACCEPT_RIDE
--    - Elimina la verificación de saldo positivo para la comisión
--    - Solo bloquea si la deuda supera el límite
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

  -- Verificar que el conductor está aprobado
  SELECT driver_status INTO v_ride FROM profiles WHERE id = v_driver_id;
  IF v_ride.driver_status != 'aprobado' THEN
    RAISE EXCEPTION 'Conductor no aprobado';
  END IF;

  -- Obtener viaje
  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id AND status = 'buscando';
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no disponible';
  END IF;

  -- Obtener vehículo del conductor
  SELECT * INTO v_vehicle FROM vehicles
  WHERE driver_id = v_driver_id AND category = v_ride.category AND is_active = TRUE
  LIMIT 1;

  IF v_vehicle.id IS NULL THEN
    RAISE EXCEPTION 'No tiene un vehículo activo de la categoría requerida';
  END IF;

  -- Obtener billetera del conductor
  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_driver_id;

  -- Calcular comisión (10% del total)
  v_commission := ROUND(v_ride.total_fare_usd * v_ride.commission_rate / 100, 2);

  -- BLOQUEO POR MOROSIDAD:
  -- Solo se bloquea si la deuda acumulada supera el límite permitido por el Admin
  IF v_wallet.balance_usd < -v_wallet.debt_limit_usd THEN
    RETURN jsonb_build_object(
      'success', FALSE,
      'error', 'DEUDA_EXCEDIDA',
      'message', 'Tienes una deuda pendiente que supera el límite permitido. Contacta al administrador para regularizar tu situación.',
      'deuda_actual', v_wallet.balance_usd,
      'limite_deuda', v_wallet.debt_limit_usd
    );
  END IF;

  -- Descontar comisión (con crédito: puede quedar saldo negativo)
  UPDATE wallets
  SET balance_usd = balance_usd - v_commission,
      updated_at = NOW()
  WHERE user_id = v_driver_id;

  -- Registrar transacción de comisión
  INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
  VALUES (v_wallet.id, v_driver_id, 'comision', v_commission, 'completado',
          'Comisión por viaje', p_ride_id);

  -- Actualizar viaje
  UPDATE rides
  SET driver_id = v_driver_id,
      vehicle_id = v_vehicle.id,
      commission_usd = v_commission,
      status = 'aceptada',
      started_at = NOW()
  WHERE id = p_ride_id;

  -- Notificar al cliente
  INSERT INTO notifications (user_id, title, body, type, data)
  VALUES (
    v_ride.client_id,
    'Conductor asignado',
    'Un conductor ha aceptado tu viaje',
    'ride_accepted',
    jsonb_build_object('ride_id', p_ride_id)
  );

  -- Auditoría
  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_driver_id, 'ACCEPT_RIDE', 'ride', p_ride_id,
          jsonb_build_object('commission', v_commission));

  RETURN jsonb_build_object(
    'success', TRUE,
    'ride_id', p_ride_id,
    'commission', v_commission
  );
END;
$$;

-- 2. ACTUALIZAR FUNCIÓN TOGGLE_DRIVER_ONLINE
--    - Mantiene el bloqueo por deuda superada (morosidad)
--    - Mensaje más claro
CREATE OR REPLACE FUNCTION public.toggle_driver_online(p_online BOOLEAN)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_profile RECORD;
  v_wallet RECORD;
BEGIN
  SELECT * INTO v_profile FROM profiles WHERE id = v_driver_id;

  IF v_profile.role != 'conductor' THEN
    RAISE EXCEPTION 'No es conductor';
  END IF;

  IF v_profile.driver_status != 'aprobado' THEN
    RAISE EXCEPTION 'Conductor no aprobado';
  END IF;

  -- Verificar límite de deuda (morosidad)
  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_driver_id;
  IF v_wallet.balance_usd < -v_wallet.debt_limit_usd THEN
    RETURN jsonb_build_object(
      'success', FALSE,
      'error', 'DEUDA_EXCEDIDA',
      'message', 'Tienes una deuda pendiente que supera el límite permitido. Recarga tu billetera o contacta al administrador.',
      'deuda_actual', v_wallet.balance_usd,
      'limite_deuda', v_wallet.debt_limit_usd
    );
  END IF;

  UPDATE profiles SET is_online = p_online WHERE id = v_driver_id;

  RETURN jsonb_build_object('success', TRUE, 'is_online', p_online);
END;
$$;

-- 3. FUNCIÓN NUEVA: EL ADMIN PUEDE AJUSTAR LA DEUDA DE UN CONDUCTOR
--    (para cobrar/saldar cuando el conductor pague en efectivo o por pago móvil)
CREATE OR REPLACE FUNCTION public.adjust_driver_debt(
  p_driver_id UUID,
  p_amount_usd NUMERIC, -- positivo = pago/abono, negativo = ajuste manual
  p_description TEXT DEFAULT 'Ajuste de deuda'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_wallet RECORD;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT * INTO v_wallet FROM wallets WHERE user_id = p_driver_id;

  UPDATE wallets
  SET balance_usd = balance_usd + p_amount_usd,
      updated_at = NOW()
  WHERE user_id = p_driver_id;

  INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, reviewed_by)
  VALUES (v_wallet.id, p_driver_id, 'ajuste', p_amount_usd, 'completado', p_description, v_admin_id);

  RETURN jsonb_build_object(
    'success', TRUE,
    'driver_id', p_driver_id,
    'nuevo_balance', v_wallet.balance_usd + p_amount_usd
  );
END;
$$;

-- 4. PERMISOS
GRANT EXECUTE ON FUNCTION public.accept_ride TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.toggle_driver_online TO authenticated, anon;
GRANT EXECUTE ON FUNCTION public.adjust_driver_debt TO authenticated;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'Migración de comisión con crédito completada' AS estado;