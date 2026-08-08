-- ============================================================
-- RIDERFLASSHI - Migracion 041: CONFIRMACION DE VIAJE COMPLETADO
-- ------------------------------------------------------------
-- Cuando el CONDUCTOR marca el viaje como completado, el cliente
-- debe confirmar ("El conductor completo el viaje, confirmas?") o
-- reportar un incidente.
--
-- 1. rides.completed_by         -> quien llamo a complete_ride
-- 2. rides.client_confirmed_at  -> cuando confirmo el cliente
-- 3. complete_ride guarda completed_by
-- 4. RPC confirm_ride_completion (solo el cliente del viaje)
-- ============================================================

-- 1. COLUMNAS NUEVAS
ALTER TABLE rides ADD COLUMN IF NOT EXISTS completed_by UUID REFERENCES profiles(id);
ALTER TABLE rides ADD COLUMN IF NOT EXISTS client_confirmed_at TIMESTAMPTZ;

CREATE INDEX IF NOT EXISTS idx_rides_completed_by ON rides(completed_by);

-- ============================================================
-- 2. COMPLETE_RIDE: registrar quien lo completo
--    (misma logica que 037, + completed_by = v_user_id)
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
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('complete_ride', 30);

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF v_ride.driver_id != v_user_id AND v_ride.client_id != v_user_id THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF v_ride.status NOT IN ('aceptada', 'en_ruta') THEN
    RAISE EXCEPTION 'Estado invalido';
  END IF;

  UPDATE rides
  SET status = 'completada',
      completed_at = NOW(),
      completed_by = v_user_id,
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

GRANT EXECUTE ON FUNCTION public.complete_ride TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.complete_ride FROM anon;

-- ============================================================
-- 3. RPC: CONFIRMAR VIAJE COMPLETADO (solo el cliente)
-- ============================================================
CREATE OR REPLACE FUNCTION public.confirm_ride_completion(p_ride_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_client_id UUID := auth.uid();
  v_ride RECORD;
  v_confirmed_at TIMESTAMPTZ;
BEGIN
  IF v_client_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF v_ride.client_id != v_client_id THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF v_ride.status != 'completada' THEN
    RAISE EXCEPTION 'El viaje aun no esta completado';
  END IF;

  -- Idempotente: si ya confirmo, no cambiar
  IF v_ride.client_confirmed_at IS NULL THEN
    UPDATE rides
    SET client_confirmed_at = NOW(), updated_at = NOW()
    WHERE id = p_ride_id;
  END IF;

  SELECT client_confirmed_at INTO v_confirmed_at FROM rides WHERE id = p_ride_id;

  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_client_id, 'CONFIRM_RIDE_COMPLETION', 'ride', p_ride_id,
          jsonb_build_object('driver_id', v_ride.driver_id));

  RETURN jsonb_build_object('success', TRUE, 'ride_id', p_ride_id, 'client_confirmed_at', v_confirmed_at);
END;
$$;

REVOKE ALL ON FUNCTION public.confirm_ride_completion(UUID) FROM anon;
GRANT EXECUTE ON FUNCTION public.confirm_ride_completion(UUID) TO authenticated, service_role;

-- ============================================================
-- VERIFICACION
-- ============================================================
SELECT 'Migracion 041: confirmacion de viaje completado aplicada' AS estado;

SELECT column_name FROM information_schema.columns
WHERE table_schema = 'public' AND table_name = 'rides'
  AND column_name IN ('completed_by', 'client_confirmed_at')
ORDER BY column_name;