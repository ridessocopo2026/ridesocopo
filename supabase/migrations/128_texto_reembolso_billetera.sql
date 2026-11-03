-- ============================================================
-- 128 - TEXTO CLARO EN LOS REEMBOLSOS ACREDITADOS EN BILLETERA
-- ------------------------------------------------------------
-- Problema:
--   cancel_ride deja el reembolso como PENDIENTE
--   ("Reembolso pendiente por cancelación (Pago Móvil)...") y
--   procesar_reembolsos_manuales lo acredita en la billetera del
--   cliente cambiando el estado a 'completado', pero NO cambiaba
--   la descripción. En el historial seguía diciendo "pendiente",
--   lo que hacía pensar que el dinero aún estaba por devolver
--   cuando en realidad ya estaba en la billetera del cliente.
--
-- Solución (sin tocar la lógica de dinero):
--   1. Trigger BEFORE UPDATE en transactions: cuando el estado pasa
--      a 'completado' (o 'rechazado') reescribe SOLO el encabezado
--      de la descripción, conservando método, fee y notas.
--   2. Corrige el histórico que ya quedó con el texto viejo.
--
-- Costo: comprobación de texto solo al actualizar un movimiento
--        (no afecta inserts ni lecturas).
-- ============================================================
CREATE OR REPLACE FUNCTION public.sync_refund_transaction_text()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = public
AS $$
DECLARE
  v_pending CONSTANT TEXT := 'Reembolso pendiente por cancelación';
BEGIN
  IF COALESCE(NEW.description, '') LIKE v_pending || '%'
     AND NEW.status IS DISTINCT FROM OLD.status
     AND NEW.status IN ('completado', 'rechazado') THEN
    NEW.description :=
      CASE WHEN NEW.status = 'completado'
           THEN 'Reembolso acreditado en billetera'
           ELSE 'Reembolso rechazado'
      END
      || SUBSTR(NEW.description, LENGTH(v_pending) + 1);
  END IF;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_sync_refund_transaction_text ON public.transactions;

CREATE TRIGGER trg_sync_refund_transaction_text
  BEFORE UPDATE OF status ON public.transactions
  FOR EACH ROW
  EXECUTE FUNCTION public.sync_refund_transaction_text();

-- ============================================================
-- HISTÓRICO: reembolsos ya acreditados/rechazados
-- ============================================================
UPDATE public.transactions
SET description = 'Reembolso acreditado en billetera'
                  || SUBSTR(description, LENGTH('Reembolso pendiente por cancelación') + 1)
WHERE status = 'completado'
  AND description LIKE 'Reembolso pendiente por cancelación%';

UPDATE public.transactions
SET description = 'Reembolso rechazado'
                  || SUBSTR(description, LENGTH('Reembolso pendiente por cancelación') + 1)
WHERE status = 'rechazado'
  AND description LIKE 'Reembolso pendiente por cancelación%';

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'Migración 128 aplicada: reembolsos acreditados se muestran como billetera' AS estado;

SELECT t.status, t.description
FROM public.transactions t
WHERE t.description LIKE 'Reembolso%'
ORDER BY t.created_at DESC
LIMIT 5;
