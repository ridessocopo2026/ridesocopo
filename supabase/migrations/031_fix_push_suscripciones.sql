-- ============================================================
-- RIDESOCOPÓ - Migración: FIX SUSCRIPCIONES PUSH POR USUARIO
-- ============================================================
-- Problema: al cerrar sesión como conductor y abrir como cliente,
-- el dispositivo seguía recibiendo notificaciones del conductor.
--
-- Causa: get_or_create_push_subscription NO actualizaba user_id
-- en el ON CONFLICT(endpoint) DO UPDATE. La suscripción quedaba
-- asociada al usuario anterior.
--
-- Fix: actualizar user_id junto con las claves de la suscripción.
-- ============================================================

-- ============================================================
-- 1. CORREGIR GET_OR_CREATE_PUSH_SUBSCRIPTION
--    Al haber conflicto por endpoint (mismo dispositivo),
--    MOVER la suscripción al usuario que está iniciando sesión
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_or_create_push_subscription(
  p_endpoint TEXT,
  p_p256dh TEXT,
  p_auth TEXT,
  p_user_agent TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_sub_id UUID;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  IF p_endpoint IS NULL OR p_endpoint = '' OR p_p256dh IS NULL OR p_auth IS NULL THEN
    RAISE EXCEPTION 'Datos de suscripción incompletos';
  END IF;

  -- Upsert: EN CASO DE CONFLICTO, MOVER la suscripción al usuario actual
  INSERT INTO push_subscriptions (user_id, endpoint, p256dh, auth, user_agent)
  VALUES (v_user_id, p_endpoint, p_p256dh, p_auth, p_user_agent)
  ON CONFLICT (endpoint) DO UPDATE
  SET user_id = EXCLUDED.user_id,          -- 🔴 FIX: mover al usuario actual
      p256dh = EXCLUDED.p256dh,
      auth = EXCLUDED.auth,
      user_agent = EXCLUDED.user_agent,
      updated_at = NOW()
  RETURNING id INTO v_sub_id;

  RETURN v_sub_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_or_create_push_subscription TO anon, authenticated, service_role;

-- ============================================================
-- 2. LIMPIAR SUSCRIPCIONES HUÉRFANAS
--    Eliminar suscripciones que ya no deberían existir (opcional)
-- ============================================================

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'Fix suscripciones push por usuario completado' AS estado;