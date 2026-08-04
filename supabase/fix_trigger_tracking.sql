-- ============================================================
-- RIDESOCOPÓ - FIX: TRIGGER TRACKING_CODE (operador % inválido)
-- ============================================================
-- El trigger assign_tracking_code() usaba 26^x % 26 que genera
-- "operator does not exist: double precision % integer".
-- Esto rompía el INSERT de rides → 404 al solicitar viaje.
--
-- Fix: generar tracking con secuencia + LPAD (simple y robusto).
-- ============================================================

CREATE OR REPLACE FUNCTION public.assign_tracking_code()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_num INTEGER;
BEGIN
  IF NEW.tracking_code IS NOT NULL THEN
    RETURN NEW;
  END IF;

  SELECT nextval('public.tracking_code_seq') INTO v_num;

  NEW.tracking_code := 'RS-' || UPPER(LPAD(v_num::text, 6, '0'));
  RETURN NEW;
END;
$$;

-- Verificar que la secuencia existe (si no, crearla)
CREATE SEQUENCE IF NOT EXISTS public.tracking_code_seq START 1;

-- Recrear el trigger por si no está
DROP TRIGGER IF EXISTS trg_assign_tracking_code ON public.rides;
CREATE TRIGGER trg_assign_tracking_code
  BEFORE INSERT ON public.rides
  FOR EACH ROW EXECUTE FUNCTION public.assign_tracking_code();

SELECT '✅ Trigger tracking_code reparado (RS + secuencia)' AS estado;