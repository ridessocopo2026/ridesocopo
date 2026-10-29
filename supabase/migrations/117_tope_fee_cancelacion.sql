-- ============================================================
-- 117 - TOPE DEL FEE DE CANCELACIÓN
-- ------------------------------------------------------------
-- Evita cargos desproporcionados en efectivo (y en cualquier
-- método) cuando la tarifa es alta:
--   · en_ruta  (cliente culpable): fee máximo $3.00
--   · aceptada (cliente culpable): fee máximo $1.50
-- La compensación al conductor sigue siendo el 50% del fee.
-- Idempotente: solo aplica si max_fee aún es NULL.
-- ============================================================

UPDATE public.cancellation_policies
SET max_fee = 3.00,
    updated_at = NOW()
WHERE ride_status = 'en_ruta'
  AND at_fault = 'cliente'
  AND max_fee IS NULL;

UPDATE public.cancellation_policies
SET max_fee = 1.50,
    updated_at = NOW()
WHERE ride_status = 'aceptada'
  AND at_fault = 'cliente'
  AND max_fee IS NULL;

SELECT 'Migración 117 aplicada: topes de fee de cancelación' AS estado;
