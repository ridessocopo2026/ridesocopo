-- ============================================================
-- FIX 113 - Corrección del viaje cancelado en efectivo (29/10/2026)
-- ------------------------------------------------------------
-- Viaje: de05e23a-e0f5-4504-9808-83a7dac22e64 (Efectivo, $2.00)
--
--   1) Compensación al conductor mal calculada: $0.01 -> $0.50
--      (regla: 50% del fee; el fee fue $1.00)
--   2) Reembolso fantasma de $1.00: en efectivo no hubo retención,
--      se anula (no se mueve dinero, solo cambia el estado).
--
-- Idempotente: se puede ejecutar varias veces sin duplicar.
-- ============================================================
DO $$
DECLARE
  v_ride_id UUID := 'de05e23a-e0f5-4504-9808-83a7dac22e64';
  v_txn_comp UUID := '9c84c415-5c22-41ce-8d11-92eaffb1e703';
  v_txn_refund UUID := 'a3cef13d-7a01-44a6-939b-3abde377e8dc';
  v_driver UUID := 'b2f6020b-2c13-433d-957f-730108b163aa';
  v_admin UUID := 'cbbd6371-d96b-44aa-8f32-460b8ade5594';
  v_comp RECORD;
  v_refund RECORD;
  v_ride RECORD;
  v_delta NUMERIC;
BEGIN
  SELECT * INTO v_ride FROM rides WHERE id = v_ride_id FOR UPDATE;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje % no encontrado', v_ride_id;
  END IF;

  SELECT * INTO v_comp FROM transactions WHERE id = v_txn_comp FOR UPDATE;
  SELECT * INTO v_refund FROM transactions WHERE id = v_txn_refund FOR UPDATE;

  -- 1) Compensación correcta (solo si sigue en 0.01)
  IF v_comp.id IS NOT NULL AND v_comp.status = 'completado' AND v_comp.amount_usd = 0.01 THEN
    IF NOT EXISTS (SELECT 1 FROM wallets WHERE user_id = v_driver) THEN
      RAISE EXCEPTION 'Billetera del conductor no encontrada';
    END IF;

    v_delta := 0.50 - v_comp.amount_usd;

    UPDATE wallets
    SET balance_usd = balance_usd + v_delta, updated_at = NOW()
    WHERE user_id = v_driver;

    UPDATE transactions
    SET amount_usd = 0.50,
        description = 'Compensación por cancelación (corregida)'
    WHERE id = v_txn_comp;

    UPDATE rides
    SET driver_compensation_usd = 0.50, updated_at = NOW()
    WHERE id = v_ride_id;

    INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
    VALUES (v_admin, 'FIX_CANCELLATION_COMPENSATION', 'ride', v_ride_id,
            jsonb_build_object('before_usd', 0.01, 'after_usd', 0.50, 'credited_usd', v_delta,
                               'driver_id', v_driver,
                               'reason', 'driver_compensation_rate 0.50 se interpretaba como 0.5%'));
  END IF;

  -- 2) Reembolso fantasma (solo si sigue pendiente)
  IF v_refund.id IS NOT NULL AND v_refund.status = 'pendiente' THEN
    UPDATE transactions
    SET status = 'rechazado',
        reviewed_by = v_admin,
        reviewed_at = NOW(),
        description = 'Reembolso anulado: pago en efectivo (no hubo retención)'
    WHERE id = v_txn_refund;

    UPDATE rides
    SET reimbursement_status = 'no_aplica', updated_at = NOW()
    WHERE id = v_ride_id AND reimbursement_status = 'pendiente_manual';

    INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
    VALUES (v_admin, 'VOID_PHANTOM_REFUND', 'transaction', v_txn_refund,
            jsonb_build_object('ride_id', v_ride_id, 'amount_usd', v_refund.amount_usd,
                               'reason', 'efectivo sin retención: el cliente nunca pagó a la plataforma'));
  END IF;
END $$;

-- 3) Barrido general: cualquier reembolso pendiente de un viaje
--    en EFECTIVO es inexistente (nunca hubo retención). Se anula.
DO $$
DECLARE
  v_admin UUID := 'cbbd6371-d96b-44aa-8f32-460b8ade5594';
  r RECORD;
  v_count INTEGER := 0;
BEGIN
  FOR r IN
    SELECT t.id, t.ride_id, t.amount_usd
    FROM transactions t
    JOIN rides rd ON rd.id = t.ride_id
    WHERE t.type = 'credito'
      AND t.status = 'pendiente'
      AND t.description LIKE 'Reembolso%'
      AND LOWER(rd.payment_method) = 'efectivo'
    FOR UPDATE
  LOOP
    UPDATE transactions
    SET status = 'rechazado',
        reviewed_by = v_admin,
        reviewed_at = NOW(),
        description = 'Reembolso anulado: pago en efectivo (no hubo retención)'
    WHERE id = r.id;

    UPDATE rides
    SET reimbursement_status = 'no_aplica', updated_at = NOW()
    WHERE id = r.ride_id AND reimbursement_status = 'pendiente_manual';

    INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
    VALUES (v_admin, 'VOID_PHANTOM_REFUND', 'transaction', r.id,
            jsonb_build_object('ride_id', r.ride_id, 'amount_usd', r.amount_usd,
                               'reason', 'efectivo sin retención: el cliente nunca pagó a la plataforma'));

    v_count := v_count + 1;
  END LOOP;

  RAISE NOTICE 'Reembolsos fantasma anulados: %', v_count;
END $$;

-- Verificación
SELECT r.id, r.payment_method, r.cancellation_fee_usd, r.driver_compensation_usd, r.reimbursement_status
FROM rides r WHERE r.id = 'de05e23a-e0f5-4504-9808-83a7dac22e64';
