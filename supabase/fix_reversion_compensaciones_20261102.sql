-- ============================================================
-- Reversión de compensaciones automáticas del 2026-11-02
-- ------------------------------------------------------------
-- Los viajes RS-511011, RS-052634 y RS-976513 se cancelaron
-- antes de la migración 124, que pagaba automáticamente el
-- 50% del fee ($0.25) al conductor. El admin decidió que no
-- corresponde compensación: se revierten los $0.75.
--
-- Idempotente: si ya existe la transacción de reversión para el
-- viaje, no vuelve a descontar. Se puede ejecutar varias veces.
-- ============================================================
DO $$
DECLARE
  v_ride RECORD;
  v_credit RECORD;
  v_wallet RECORD;
  v_amount NUMERIC;
  v_admin UUID;
  v_total NUMERIC := 0.00;
BEGIN
  SELECT id INTO v_admin
  FROM profiles
  WHERE role = 'super_admin'
  ORDER BY created_at
  LIMIT 1;

  FOR v_ride IN
    SELECT DISTINCT
      r.id,
      r.tracking_code,
      r.driver_id,
      r.driver_compensation_usd,
      i.id AS incident_id,
      i.resolved_by
    FROM rides r
    JOIN ride_incidents i
      ON i.ride_id = r.id
     AND i.incident_type = 'cancelacion_cliente'
    WHERE r.tracking_code IN ('RS-511011', 'RS-052634', 'RS-976513')
      AND r.driver_id IS NOT NULL
      AND COALESCE(r.driver_compensation_usd, 0) > 0
  LOOP
    -- Ya revertido: no duplicar
    IF EXISTS (
      SELECT 1 FROM transactions t
      WHERE t.ride_id = v_ride.id
        AND t.type = 'debito'
        AND t.description LIKE 'Reversión de compensación%'
    ) THEN
      CONTINUE;
    END IF;

    SELECT * INTO v_credit
    FROM transactions
    WHERE ride_id = v_ride.id
      AND type = 'credito'
      AND status = 'completado'
      AND description = 'Compensación por cancelación'
    ORDER BY created_at
    LIMIT 1;

    IF v_credit.id IS NULL THEN
      CONTINUE;
    END IF;

    v_amount := LEAST(v_credit.amount_usd, COALESCE(v_ride.driver_compensation_usd, 0));
    IF v_amount <= 0 THEN
      CONTINUE;
    END IF;

    SELECT * INTO v_wallet
    FROM wallets
    WHERE user_id = v_ride.driver_id
    FOR UPDATE;

    IF v_wallet.id IS NULL THEN
      RAISE EXCEPTION 'Billetera no encontrada para el conductor del viaje %', v_ride.tracking_code;
    END IF;

    IF v_wallet.balance_usd - v_amount < -COALESCE(v_wallet.debt_limit_usd, 5.00) THEN
      RAISE EXCEPTION 'Saldo insuficiente para revertir $% del viaje %', v_amount, v_ride.tracking_code;
    END IF;

    UPDATE wallets
    SET balance_usd = balance_usd - v_amount,
        updated_at = NOW()
    WHERE id = v_wallet.id;

    INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
    VALUES (v_wallet.id, v_ride.driver_id, 'debito', v_amount, 'completado',
            'Reversión de compensación por cancelación — ajuste administrativo',
            v_ride.id);

    UPDATE rides
    SET driver_compensation_usd = GREATEST(COALESCE(driver_compensation_usd, 0) - v_amount, 0),
        updated_at = NOW()
    WHERE id = v_ride.id;

    UPDATE ride_incidents
    SET resolution_details = COALESCE(resolution_details, '{}'::jsonb)
          || jsonb_build_object(
               'compensate_driver',
               GREATEST(COALESCE((resolution_details ->> 'compensate_driver')::numeric, 0) - v_amount, 0),
               'compensation_reversed',
               COALESCE((resolution_details ->> 'compensation_reversed')::numeric, 0) + v_amount,
               'compensation_reversal_reason',
               'Ajuste administrativo 2026-11-02: el admin no aprobó compensación'
             ),
        updated_at = NOW()
    WHERE id = v_ride.incident_id;

    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (
      v_ride.driver_id,
      'Ajuste de compensación',
      CONCAT('Se descontaron $', v_amount,
             ' de tu billetera: el administrador no aprobó la compensación por la cancelación del viaje ',
             v_ride.tracking_code, '.'),
      'driver_compensation_reversed',
      jsonb_build_object('ride_id', v_ride.id, 'amount', v_amount, 'incident_id', v_ride.incident_id)
    );

    INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
    VALUES (
      COALESCE(v_ride.resolved_by, v_admin),
      'REVERSE_DRIVER_COMPENSATION',
      'ride',
      v_ride.id,
      jsonb_build_object(
        'ride_id', v_ride.id,
        'incident_id', v_ride.incident_id,
        'tracking_code', v_ride.tracking_code,
        'amount_reversed', v_amount,
        'reason', 'Ajuste administrativo: el admin no aprobó compensación'
      )
    );

    v_total := v_total + v_amount;
    RAISE NOTICE 'Reversión aplicada: % -> $%', v_ride.tracking_code, v_amount;
  END LOOP;

  RAISE NOTICE 'Total revertido: $%', v_total;
END $$;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT jsonb_build_object(
  'viajes', (
    SELECT jsonb_agg(jsonb_build_object(
      'tracking_code', r.tracking_code,
      'driver_compensation_usd', r.driver_compensation_usd,
      'suggested', i.suggested_compensation_usd,
      'compensate_driver', (i.resolution_details ->> 'compensate_driver')::numeric,
      'compensation_reversed', (i.resolution_details ->> 'compensation_reversed')::numeric,
      'saldo_billetera', w.balance_usd
    ) ORDER BY r.tracking_code)
    FROM rides r
    JOIN ride_incidents i ON i.ride_id = r.id
    JOIN wallets w ON w.user_id = r.driver_id
    WHERE r.tracking_code IN ('RS-511011', 'RS-052634', 'RS-976513')
  ),
  'reversos', (
    SELECT jsonb_build_object(
      'cantidad', count(*),
      'total', COALESCE(sum(amount_usd), 0)
    )
    FROM transactions
    WHERE type = 'debito'
      AND description LIKE 'Reversión de compensación%'
  ),
  'wallet_conductor', (
    SELECT jsonb_build_object('balance_usd', w.balance_usd, 'debt_limit_usd', w.debt_limit_usd)
    FROM wallets w
    WHERE w.user_id = '2fa7ed12-04ab-4070-ae26-0866c2f75d7d'
  )
) AS resultado;
