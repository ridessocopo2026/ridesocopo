-- ============================================================
-- 118 - PROCESADOR DE REEMBOLSOS MANUALES
-- ------------------------------------------------------------
-- Cubre los reembolsos pendientes que NO tienen incidente
-- (cancelaciones en estado 'buscando' con Pago Móvil) y los
-- reembolsos heredados.
--
--   get_pending_refunds()  -> lista filtrada por ciudad
--   admin_process_refund() -> aprueba (acredita wallet) o
--                             rechaza, con auditoría
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_pending_refunds()
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_role TEXT;
  v_zone UUID;
  v_items JSONB;
  v_total BIGINT;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  v_role := public.get_user_role(v_user_id)::text;
  IF v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  v_zone := public.caller_zone_id();
  IF v_role = 'encargado' AND v_zone IS NULL THEN
    RAISE EXCEPTION 'Tu cuenta no tiene una ciudad asignada';
  END IF;

  WITH pendientes AS (
    SELECT
      t.id AS transaction_id,
      t.user_id AS cliente_id,
      p.full_name AS cliente,
      p.phone AS telefono,
      t.amount_usd,
      t.created_at,
      t.ride_id,
      r.tracking_code,
      r.payment_method,
      r.status::text AS ride_status,
      r.final_fare_usd,
      EXISTS (
        SELECT 1
        FROM ride_incidents i
        WHERE i.ride_id = t.ride_id
          AND i.incident_type = 'cancelacion_cliente'
          AND i.status IN ('abierto', 'en_revision')
      ) AS tiene_incidente_abierto
    FROM transactions t
    JOIN profiles p ON p.id = t.user_id
    LEFT JOIN rides r ON r.id = t.ride_id
    WHERE t.type = 'credito'
      AND t.status = 'pendiente'
      AND t.description LIKE 'Reembolso%'
      AND (v_role = 'super_admin' OR p.zone_id = v_zone)
  )
  SELECT
    COALESCE(
      jsonb_agg(
        jsonb_build_object(
          'transaction_id', transaction_id,
          'cliente_id', cliente_id,
          'cliente', cliente,
          'telefono', telefono,
          'amount_usd', amount_usd,
          'created_at', created_at,
          'ride_id', ride_id,
          'tracking_code', tracking_code,
          'payment_method', payment_method,
          'ride_status', ride_status,
          'final_fare_usd', final_fare_usd,
          'tiene_incidente_abierto', tiene_incidente_abierto,
          'puede_procesar', (NOT tiene_incidente_abierto)
                            AND LOWER(COALESCE(payment_method, '')) <> 'efectivo',
          'motivo_bloqueo', CASE
            WHEN tiene_incidente_abierto THEN
              'Tiene un incidente abierto: resuélvelo desde Incidentes.'
            WHEN LOWER(COALESCE(payment_method, '')) = 'efectivo' THEN
              'Pago en efectivo: no hubo retención que reembolsar.'
            ELSE NULL
          END
        )
        ORDER BY created_at
      ),
      '[]'::jsonb
    ),
    COUNT(*)
  INTO v_items, v_total
  FROM pendientes;

  RETURN jsonb_build_object('total', v_total, 'items', v_items);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_pending_refunds() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_pending_refunds() FROM anon;

CREATE OR REPLACE FUNCTION public.admin_process_refund(
  p_transaction_id UUID,
  p_approve BOOLEAN,
  p_note TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin UUID := auth.uid();
  v_role TEXT;
  v_zone UUID;
  v_txn RECORD;
  v_wallet RECORD;
  v_ride RECORD;
  v_incident RECORD;
  v_note TEXT := NULLIF(LEFT(TRIM(COALESCE(p_note, '')), 500), '');
BEGIN
  IF v_admin IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  v_role := public.get_user_role(v_admin)::text;
  IF v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF p_approve IS NULL THEN
    RAISE EXCEPTION 'Debes indicar si apruebas o rechazas el reembolso';
  END IF;

  v_zone := public.caller_zone_id();
  IF v_role = 'encargado' AND v_zone IS NULL THEN
    RAISE EXCEPTION 'Tu cuenta no tiene una ciudad asignada';
  END IF;

  SELECT * INTO v_txn FROM transactions WHERE id = p_transaction_id FOR UPDATE;
  IF v_txn.id IS NULL THEN
    RAISE EXCEPTION 'Transacción no encontrada';
  END IF;

  IF v_txn.type <> 'credito' OR v_txn.description NOT LIKE 'Reembolso%' THEN
    RAISE EXCEPTION 'La transacción no es un reembolso';
  END IF;

  IF v_role = 'encargado' THEN
    IF NOT EXISTS (
      SELECT 1 FROM profiles p WHERE p.id = v_txn.user_id AND p.zone_id = v_zone
    ) THEN
      RAISE EXCEPTION 'No autorizado para reembolsos de otra ciudad';
    END IF;
  END IF;

  IF v_txn.status <> 'pendiente' THEN
    RETURN jsonb_build_object(
      'success', TRUE,
      'already_processed', TRUE,
      'transaction_id', v_txn.id,
      'status', v_txn.status
    );
  END IF;

  IF v_txn.amount_usd <= 0 THEN
    RAISE EXCEPTION 'Monto de reembolso inválido';
  END IF;

  IF v_txn.ride_id IS NOT NULL THEN
    SELECT * INTO v_ride FROM rides WHERE id = v_txn.ride_id;

    IF v_ride.id IS NOT NULL THEN
      IF v_txn.amount_usd > COALESCE(v_ride.final_fare_usd, 0) THEN
        RAISE EXCEPTION 'El reembolso ($%) excede la tarifa pagada ($%)',
          v_txn.amount_usd, v_ride.final_fare_usd;
      END IF;

      IF p_approve AND LOWER(COALESCE(v_ride.payment_method, '')) = 'efectivo' THEN
        RAISE EXCEPTION 'No se puede reembolsar un viaje pagado en efectivo (no hubo retención)';
      END IF;

      SELECT * INTO v_incident
      FROM ride_incidents
      WHERE ride_id = v_ride.id
        AND incident_type = 'cancelacion_cliente'
        AND status IN ('abierto', 'en_revision')
      LIMIT 1;

      IF v_incident.id IS NOT NULL THEN
        RAISE EXCEPTION 'Este reembolso pertenece a un incidente abierto. Resuélvelo desde Incidentes.';
      END IF;
    END IF;
  END IF;

  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_txn.user_id FOR UPDATE;
  IF v_wallet.id IS NULL THEN
    RAISE EXCEPTION 'Billetera del cliente no encontrada';
  END IF;

  IF p_approve THEN
    UPDATE wallets
    SET balance_usd = balance_usd + v_txn.amount_usd, updated_at = NOW()
    WHERE user_id = v_txn.user_id;

    UPDATE transactions
    SET status = 'completado',
        reviewed_by = v_admin,
        reviewed_at = NOW(),
        description = COALESCE(description, '') ||
                      CASE WHEN v_note IS NOT NULL THEN ' — ' || v_note ELSE '' END
    WHERE id = v_txn.id;

    IF v_txn.ride_id IS NOT NULL THEN
      UPDATE rides
      SET reimbursement_status = 'auto_completado', updated_at = NOW()
      WHERE id = v_txn.ride_id AND reimbursement_status = 'pendiente_manual';
    END IF;

    PERFORM public.notify_user(
      v_txn.user_id,
      'Reembolso completado',
      CONCAT('Se reembolsaron $', v_txn.amount_usd, ' a tu billetera.'),
      'refund_completed',
      jsonb_build_object('transaction_id', v_txn.id, 'ride_id', v_txn.ride_id,
                         'amount', v_txn.amount_usd, 'url', '/cliente/billetera')
    );
  ELSE
    UPDATE transactions
    SET status = 'rechazado',
        reviewed_by = v_admin,
        reviewed_at = NOW(),
        description = COALESCE(description, '') ||
                      CASE WHEN v_note IS NOT NULL THEN ' — ' || v_note ELSE '' END
    WHERE id = v_txn.id;

    IF v_txn.ride_id IS NOT NULL THEN
      UPDATE rides
      SET reimbursement_status = 'no_aplica', updated_at = NOW()
      WHERE id = v_txn.ride_id AND reimbursement_status = 'pendiente_manual';
    END IF;

    PERFORM public.notify_user(
      v_txn.user_id,
      'Reembolso rechazado',
      CONCAT('El reembolso de $', v_txn.amount_usd, ' fue rechazado.',
             CASE WHEN v_note IS NOT NULL THEN ' ' || v_note ELSE '' END),
      'refund_rejected',
      jsonb_build_object('transaction_id', v_txn.id, 'ride_id', v_txn.ride_id,
                         'amount', v_txn.amount_usd, 'url', '/cliente/billetera')
    );
  END IF;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_admin, 'PROCESS_REFUND', 'transaction', v_txn.id,
          jsonb_build_object('ride_id', v_txn.ride_id, 'client_id', v_txn.user_id,
                             'amount_usd', v_txn.amount_usd, 'approved', p_approve,
                             'note', v_note));

  RETURN jsonb_build_object(
    'success', TRUE,
    'transaction_id', v_txn.id,
    'approved', p_approve,
    'amount_usd', v_txn.amount_usd,
    'client_id', v_txn.user_id,
    'ride_id', v_txn.ride_id
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_process_refund(UUID, BOOLEAN, TEXT) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.admin_process_refund(UUID, BOOLEAN, TEXT) FROM anon;

SELECT 'Migración 118 aplicada: procesador de reembolsos manuales' AS estado;

