-- ============================================================
-- RIDESOCOPÓ - Migración: CALIFICACIONES MUTUAS
-- El cliente califica al conductor y el conductor califica al cliente.
-- ============================================================

-- 1. AGREGAR COLUMNAS DE CALIFICACIÓN DEL CLIENTE (el conductor califica al cliente)
ALTER TABLE rides ADD COLUMN IF NOT EXISTS client_rating INTEGER CHECK (client_rating >= 1 AND client_rating <= 5);
ALTER TABLE rides ADD COLUMN IF NOT EXISTS client_review TEXT;

-- 2. FUNCIÓN: CALIFICAR AL CONDUCTOR (por el cliente)
CREATE OR REPLACE FUNCTION public.rate_driver(
  p_ride_id UUID,
  p_rating INTEGER,
  p_review TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_client_id UUID := auth.uid();
  v_ride RECORD;
BEGIN
  IF v_client_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  IF p_rating < 1 OR p_rating > 5 THEN
    RAISE EXCEPTION 'Calificación inválida (1-5)';
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF v_ride.client_id != v_client_id THEN
    RAISE EXCEPTION 'No autorizado para calificar este viaje';
  END IF;

  IF v_ride.status != 'completada' THEN
    RAISE EXCEPTION 'Solo puedes calificar viajes completados';
  END IF;

  UPDATE rides
  SET rating = p_rating,
      review = COALESCE(p_review, review)
  WHERE id = p_ride_id;

  RETURN jsonb_build_object('success', TRUE, 'ride_id', p_ride_id);
END;
$$;

-- 3. FUNCIÓN: CALIFICAR AL CLIENTE (por el conductor)
CREATE OR REPLACE FUNCTION public.rate_client(
  p_ride_id UUID,
  p_rating INTEGER,
  p_review TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_ride RECORD;
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  IF p_rating < 1 OR p_rating > 5 THEN
    RAISE EXCEPTION 'Calificación inválida (1-5)';
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF v_ride.driver_id != v_driver_id THEN
    RAISE EXCEPTION 'No autorizado para calificar este viaje';
  END IF;

  IF v_ride.status != 'completada' THEN
    RAISE EXCEPTION 'Solo puedes calificar viajes completados';
  END IF;

  UPDATE rides
  SET client_rating = p_rating,
      client_review = COALESCE(p_review, client_review)
  WHERE id = p_ride_id;

  RETURN jsonb_build_object('success', TRUE, 'ride_id', p_ride_id);
END;
$$;

-- 4. PERMISOS
GRANT EXECUTE ON FUNCTION public.rate_driver TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rate_client TO anon, authenticated, service_role;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'Migración de calificaciones completada' AS estado;