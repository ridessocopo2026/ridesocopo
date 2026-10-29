-- ============================================================
-- 116 - ESTIMACION DE CANCELACION SEGUN METODO DE PAGO
-- ------------------------------------------------------------
-- Efectivo: informa el cargo, no el reembolso.
-- ============================================================

-- ============================================================
-- 6. ESTIMATE_CANCELLATION_FEE (consciente del método de pago)
--    · Efectivo: no hay reembolso; se informa el cargo.
--    · Billetera / Pago Móvil: reembolso = tarifa - fee.
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
  v_charge NUMERIC := 0.00;
  v_method TEXT;
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

  -- El conductor no paga tarifa de cancelación
  IF v_ride.driver_id = v_user_id THEN
    RETURN jsonb_build_object(
      'fee', 0.00,
      'compensation', 0.00,
      'refund', 0.00,
      'charge', 0.00,
      'payment_method', v_ride.payment_method,
      'commission_refunded', FALSE,
      'note', 'El conductor no paga tarifa de cancelación'
    );
  END IF;

  SELECT * INTO v_policy
  FROM cancellation_policies
  WHERE ride_status = v_ride.status::text
    AND at_fault = 'cliente'
    AND is_active = TRUE;

  IF v_policy.id IS NOT NULL THEN
    v_fee := ROUND((v_ride.final_fare_usd * v_policy.fee_rate / 100), 2);
    IF v_fee < v_policy.min_fee THEN v_fee := v_policy.min_fee; END IF;
    IF v_policy.max_fee IS NOT NULL AND v_fee > v_policy.max_fee THEN v_fee := v_policy.max_fee; END IF;
    v_compensation := ROUND((v_fee * v_policy.driver_compensation_rate / 100), 2);
  END IF;

  v_method := LOWER(COALESCE(v_ride.payment_method, 'efectivo'));

  IF v_method = 'efectivo' THEN
    v_charge := v_fee;
    v_refund := 0.00;
  ELSIF v_method = 'billetera' THEN
    v_refund := GREATEST(v_ride.final_fare_usd - v_fee, 0);
  ELSE
    -- Pago Móvil u otros: solo hay reembolso si el pago fue aprobado
    IF v_ride.proof_status = 'aprobado' THEN
      v_refund := GREATEST(v_ride.final_fare_usd - v_fee, 0);
    ELSE
      v_refund := 0.00;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'fee', v_fee,
    'compensation', v_compensation,
    'refund', v_refund,
    'charge', v_charge,
    'payment_method', v_ride.payment_method,
    'commission_refunded', FALSE
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.estimate_cancellation_fee TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.estimate_cancellation_fee FROM anon;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'Migración 116 aplicada: estimación de cancelación por método' AS estado;
