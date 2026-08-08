-- ============================================================
-- RIDERFLASSHI - Migracion 042: BLOQUEAR VIAJES DUPLICADOS
-- ------------------------------------------------------------
-- Un cliente NO puede tener más de un viaje activo
-- ('buscando', 'aceptada', 'en_ruta', 'incidente') a la vez.
--
-- 1. Trigger BEFORE INSERT en rides: cubre request_ride y
--    request_ride_with_proof (y cualquier INSERT futuro).
-- 2. get_client_active_ride() incluye 'incidente' para que el
--    aviso de viaje en curso del inicio sea consistente.
-- ============================================================

-- ============================================================
-- 1. TRIGGER: bloquear segundo viaje activo
-- ============================================================
CREATE OR REPLACE FUNCTION public.guard_single_active_ride()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM rides
    WHERE client_id = NEW.client_id
      AND status IN ('buscando', 'aceptada', 'en_ruta', 'incidente')
  ) THEN
    RAISE EXCEPTION 'Ya tienes un viaje en curso. Finaliza o cancela el actual antes de pedir otro.';
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_guard_single_active_ride ON rides;
CREATE TRIGGER trg_guard_single_active_ride
  BEFORE INSERT ON rides
  FOR EACH ROW
  EXECUTE FUNCTION public.guard_single_active_ride();

-- ============================================================
-- 2. GET_CLIENT_ACTIVE_RIDE: incluir 'incidente'
--    (el cliente debe ver el viaje congelado en revisión)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_client_active_ride()
RETURNS SETOF rides
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_client_id UUID := auth.uid();
BEGIN
  RETURN QUERY
  SELECT r.* FROM rides r
  WHERE r.client_id = v_client_id
    AND r.status IN ('buscando', 'aceptada', 'en_ruta', 'incidente')
  ORDER BY r.created_at DESC
  LIMIT 1;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_client_active_ride TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_client_active_ride TO service_role;

-- ============================================================
-- VERIFICACION
-- ============================================================
SELECT 'Migracion 042: viajes duplicados bloqueados' AS estado;
