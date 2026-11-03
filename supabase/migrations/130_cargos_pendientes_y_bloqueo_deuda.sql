-- ============================================================
-- 130 - CARGOS POR VERIFICAR + BLOQUEO DEL CLIENTE CON DEUDA
-- ------------------------------------------------------------
-- 1) get_pending_charges(): lista los cargos por cancelación en
--    efectivo que quedaron "pendiente" y que hasta ahora solo se
--    podían resolver dentro del incidente.
-- 2) admin_process_charge(): aprobar (con monto editable, cobro
--    parcial) o eximir el cargo, debitando la billetera del
--    cliente y respetando su límite de deuda.
-- 3) Trigger: un cliente con saldo negativo NO puede pedir más
--    viajes hasta recargar. Antes request_ride no lo validaba.
--
-- Costo:
--   · 1 consulta pequeña para listar (índice transactions.ride_id).
--   · 1 trigger de 10 líneas en cada INSERT de rides (1 lectura por PK).
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_pending_charges()
RETURNS JSONB
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin UUID := auth.uid();
  v_role TEXT;
  v_zone UUID;
  v_items JSONB;
BEGIN
  v_role := public.get_user_role(v_admin)::text;
  IF v_role IS NULL OR v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  v_zone := public.caller_zone_id();
  IF v_role = 'super_admin' THEN
    v_zone := NULL;
  END IF;

  SELECT COALESCE(jsonb_agg(to_jsonb(x) ORDER BY x.created_at), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT
      t.id,
      t.user_id,
      t.amount_usd,
      t.created_at,
      t.description,
      p.full_name AS client_name,
      p.phone     AS client_phone,
      r.id AS ride_id,
      r.tracking_code,
      r.incident_id,
      (SELECT i.status::text FROM ride_incidents i WHERE i.id = r.incident_id) AS incident_status,
      ROUND(COALESCE(w.balance_usd, 0), 2) AS client_balance,
      ROUND(COALESCE(w.debt_limit_usd, 5.00), 2) AS debt_limit_usd,
      -- Cuánto se puede cobrar ahora sin pasar el límite de deuda
      ROUND(GREATEST(COALESCE(w.balance_usd, 0) + COALESCE(w.debt_limit_usd, 5.00), 0), 2) AS max_chargeable_usd
    FROM transactions t
    JOIN profiles p ON p.id = t.user_id
    LEFT JOIN rides r ON r.id = t.ride_id
    LEFT JOIN wallets w ON w.user_id = t.user_id
    WHERE t.type = 'debito'
      AND t.status = 'pendiente'
      AND t.description LIKE 'Cargo por cancelación%'
      AND (v_zone IS NULL OR r.origin_zone_id = v_zone)
  ) x;

  RETURN jsonb_build_object(
    'total', jsonb_array_length(v_items),
    'items', v_items
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_pending_charges() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_pending_charges() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_pending_charges() FROM anon;

-- ============================================================
-- 2. APROBAR / EXIMIR UN CARGO PENDIENTE
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_process_charge(
  p_transaction_id UUID,
  p_approve BOOLEAN,
  p_note TEXT DEFAULT NULL,
  p_amount NUMERIC DEFAULT NULL
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
  v_ride RECORD;
  v_wallet RECORD;
  v_amount NUMERIC := 0;
  v_max NUMERIC := 0;
  v_note TEXT;
BEGIN
  v_role := public.get_user_role(v_admin)::text;
  IF v_role IS NULL OR v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  v_zone := public.caller_zone_id();
  IF v_role = 'super_admin' THEN
    v_zone := NULL;
  END IF;

  SELECT * INTO v_txn FROM transactions WHERE id = p_transaction_id FOR UPDATE;

  IF v_txn.id IS NULL THEN
    RAISE EXCEPTION 'Cargo no encontrado';
  END IF;

  IF v_txn.type <> 'debito'
     OR v_txn.status <> 'pendiente'
     OR COALESCE(v_txn.description, '') NOT LIKE 'Cargo por cancelación%' THEN
    RAISE EXCEPTION 'Este cargo ya fue procesado o no es un cargo por cancelación';
  END IF;

  -- Si no hay viaje, SELECT INTO deja v_ride con NULLs (no rompe)
  SELECT * INTO v_ride FROM rides WHERE id = v_txn.ride_id;

  IF v_txn.ride_id IS NOT NULL
     AND v_zone IS NOT NULL
     AND v_ride.origin_zone_id IS DISTINCT FROM v_zone THEN
    RAISE EXCEPTION 'No autorizado para cargos de otra ciudad';
  END IF;

  v_note := NULLIF(BTRIM(COALESCE(p_note, '')), '');

  IF p_approve THEN
    v_amount := ROUND(COALESCE(p_amount, v_txn.amount_usd), 2);

    IF v_amount IS NULL OR v_amount <= 0 OR v_amount > 999999.99 THEN
      RAISE EXCEPTION 'Monto del cargo inválido (debe ser mayor que 0)';
    END IF;

    SELECT * INTO v_wallet FROM wallets WHERE user_id = v_txn.user_id FOR UPDATE;
    IF v_wallet.id IS NULL THEN
      RAISE EXCEPTION 'Billetera del cliente no encontrada';
    END IF;

    v_max := ROUND(GREATEST(v_wallet.balance_usd + COALESCE(v_wallet.debt_limit_usd, 5.00), 0), 2);

    IF v_wallet.balance_usd - v_amount < -COALESCE(v_wallet.debt_limit_usd, 5.00) THEN
      RAISE EXCEPTION USING MESSAGE = format(
        'El cargo supera el límite de deuda del cliente. Máximo cobrable ahora: $%s',
        v_max);
    END IF;

    UPDATE wallets
    SET balance_usd = balance_usd - v_amount,
        updated_at = NOW()
    WHERE id = v_wallet.id;

    UPDATE transactions
    SET amount_usd = v_amount,
        status = 'completado',
        reviewed_by = v_admin,
        reviewed_at = NOW(),
        description = 'Cargo por cancelación en curso (efectivo) — aprobado'
                      || CASE WHEN v_note IS NOT NULL THEN ' — ' || v_note ELSE '' END
    WHERE id = v_txn.id;

    IF v_ride.id IS NOT NULL THEN
      UPDATE rides
      SET cancellation_fee_usd = v_amount,
          updated_at = NOW()
      WHERE id = v_ride.id;
    END IF;

    PERFORM public.notify_user(
      v_txn.user_id,
      'Cargo por cancelación aprobado',
      format('Se cobraron $%s de tu billetera por cancelar un viaje en curso. Saldo: $%s.',
             v_amount,
             ROUND(v_wallet.balance_usd - v_amount, 2)),
      'cancellation_charge_approved',
      jsonb_build_object(
        'transaction_id', v_txn.id,
        'ride_id', v_txn.ride_id,
        'amount', v_amount,
        'url', '/cliente/billetera'
      )
    );

    INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
    VALUES (v_admin, 'APPROVE_CANCELLATION_CHARGE', 'transaction', v_txn.id,
            jsonb_build_object(
              'ride_id', v_txn.ride_id,
              'client_id', v_txn.user_id,
              'amount', v_amount,
              'original_amount', v_txn.amount_usd,
              'note', v_note
            ));
  ELSE
    UPDATE transactions
    SET status = 'rechazado',
        reviewed_by = v_admin,
        reviewed_at = NOW(),
        description = 'Cargo por cancelación en curso (efectivo) — eximido'
                      || CASE WHEN v_note IS NOT NULL THEN ' — ' || v_note ELSE '' END
    WHERE id = v_txn.id;

    PERFORM public.notify_user(
      v_txn.user_id,
      'Cargo por cancelación eximido',
      'Un administrador revisó la cancelación y no se te cobrará el cargo pendiente.',
      'cancellation_charge_waived',
      jsonb_build_object('transaction_id', v_txn.id, 'ride_id', v_txn.ride_id)
    );

    INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
    VALUES (v_admin, 'WAIVE_CANCELLATION_CHARGE', 'transaction', v_txn.id,
            jsonb_build_object(
              'ride_id', v_txn.ride_id,
              'client_id', v_txn.user_id,
              'amount', v_txn.amount_usd,
              'note', v_note
            ));
  END IF;

  RETURN jsonb_build_object(
    'success', TRUE,
    'transaction_id', v_txn.id,
    'approved', p_approve,
    'amount', CASE WHEN p_approve THEN v_amount ELSE 0 END
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_process_charge(uuid, boolean, text, numeric) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_process_charge(uuid, boolean, text, numeric)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.admin_process_charge(uuid, boolean, text, numeric) FROM anon;

-- ============================================================
-- 3. BLOQUEO: CLIENTE CON SALDO NEGATIVO NO PIDE MÁS VIAJES
--    Regla: balance_usd < 0  →  debe recargar hasta quedar en 0.
--    Solo aplica a los viajes que pide el propio cliente.
-- ============================================================
CREATE OR REPLACE FUNCTION public.block_ride_with_client_debt()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_balance NUMERIC;
BEGIN
  -- Los viajes creados por un admin/sistema no se bloquean
  IF NEW.client_id IS DISTINCT FROM auth.uid() THEN
    RETURN NEW;
  END IF;

  SELECT w.balance_usd INTO v_balance
  FROM public.wallets w
  WHERE w.user_id = NEW.client_id;

  IF NOT FOUND THEN
    RETURN NEW;
  END IF;

  IF v_balance < 0 THEN
    RAISE EXCEPTION USING MESSAGE = format(
      'Tienes un saldo pendiente de $%s. Recarga tu billetera para pedir otro viaje.',
      ROUND(ABS(v_balance), 2));
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_block_ride_with_client_debt ON public.rides;

CREATE TRIGGER trg_block_ride_with_client_debt
  BEFORE INSERT ON public.rides
  FOR EACH ROW
  EXECUTE FUNCTION public.block_ride_with_client_debt();

-- Helper para que la app muestre el mismo mensaje sin duplicar la regla
CREATE OR REPLACE FUNCTION public.get_my_ride_block()
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'blocked', COALESCE(w.balance_usd < 0, FALSE),
    'balance', ROUND(COALESCE(w.balance_usd, 0), 2),
    'owed', ROUND(GREATEST(-COALESCE(w.balance_usd, 0), 0), 2),
    'message', CASE
      WHEN w.balance_usd < 0 THEN format(
        'Tienes un saldo pendiente de $%s. Recarga tu billetera para pedir otro viaje.',
        ROUND(ABS(w.balance_usd), 2))
      ELSE NULL
    END
  )
  FROM (SELECT 1) AS one
  LEFT JOIN public.wallets w ON w.user_id = auth.uid();
$$;

REVOKE ALL ON FUNCTION public.get_my_ride_block() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_my_ride_block() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_my_ride_block() FROM anon;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'Migración 130 aplicada: cargos por verificar + bloqueo por deuda' AS estado;

SELECT count(*) AS cargos_pendientes
FROM public.transactions
WHERE type = 'debito' AND status = 'pendiente'
  AND description LIKE 'Cargo por cancelación%';
