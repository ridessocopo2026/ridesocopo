-- ============================================================
-- BUNRIDER - Migración 069: FIX COLUMNA updated_at EN coupons
-- ------------------------------------------------------------
-- redeem_coupon (047) y las devoluciones de cupón al cancelar
-- hacen: UPDATE coupons SET ..., updated_at = NOW();
-- pero la tabla coupons (001) nunca tuvo esa columna, lo que
-- provocaba el error al pedir un viaje con cupón:
--   column "updated_at" of relation "coupons" does not exist
-- Se agrega la columna (+ trigger para mantenerla al día).
-- ============================================================

ALTER TABLE public.coupons
  ADD COLUMN IF NOT EXISTS updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW();

DROP TRIGGER IF EXISTS update_coupons_updated_at ON public.coupons;
CREATE TRIGGER update_coupons_updated_at
  BEFORE UPDATE ON public.coupons
  FOR EACH ROW EXECUTE FUNCTION public.update_updated_at();

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 069: coupons.updated_at listo' AS estado;
