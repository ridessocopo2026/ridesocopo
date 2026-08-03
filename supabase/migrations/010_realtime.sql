-- ============================================================
-- RIDESOCOPÓ - Migración: REALTIME PARA RIDES
-- Publica la tabla rides en Realtime para que los cambios
-- (aceptar, iniciar, completar) lleguen al instante a
-- cliente y conductor sin recargar la página.
-- ============================================================

-- Publicar rides en Realtime
ALTER PUBLICATION supabase_realtime ADD TABLE public.rides;

-- ============================================================
SELECT 'Realtime de rides habilitado' AS estado;