-- ============================================================
-- BUNRIDER - Migración 083: RETENCIÓN DE VIAJES (ARCHIVADO)
-- ------------------------------------------------------------
-- `rides` crece sin tope (cleanup_old_data NO la toca). A ~500
-- viajes/día son ~270 MB/año, y el plan Free tiene 500 MB.
--
-- Esta migración:
--   1) Crea `rides_archive` (snapshot JSONB del viaje + sus filas
--      hijas: driver_earnings, coupon_redemptions, ride_incidents).
--   2) Crea archive_old_rides(p_months, p_delete): archiva viajes
--      CERRADOS más antiguos que N meses (por defecto 18). Solo
--      borra de `rides` (p_delete=true) si NO hay un payout que lo
--      referencie (FK NO ACTION). Por defecto NO borra (archiva).
--
-- SEGURIDAD: no se programa automáticamente. Es una decisión del
-- operador cuándo/pausar el borrado. El archivado es idempotente.
-- Para habilitar borrado automático, ver ESCALABILIDAD_Y_COSTOS.md.
-- ============================================================

-- ============================================================
-- 1. TABLA DE ARCHIVO
-- ============================================================
CREATE TABLE IF NOT EXISTS public.rides_archive (
  id            uuid PRIMARY KEY,
  tracking_code text,
  status        text,
  created_at    timestamptz,
  completed_at  timestamptz,
  archived_at   timestamptz NOT NULL DEFAULT now(),
  data          jsonb NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_rides_archive_archived_at ON public.rides_archive(archived_at DESC);
CREATE INDEX IF NOT EXISTS idx_rides_archive_created_at  ON public.rides_archive(created_at DESC);

ALTER TABLE public.rides_archive ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "super_admin_view_rides_archive" ON public.rides_archive;
CREATE POLICY "super_admin_view_rides_archive" ON public.rides_archive
  FOR SELECT USING (public.get_user_role((SELECT auth.uid())) = 'super_admin');

REVOKE ALL ON public.rides_archive FROM anon;
GRANT SELECT ON public.rides_archive TO authenticated;

-- ============================================================
-- 2. FUNCIÓN DE ARCHIVADO / RETENCIÓN
-- ============================================================
CREATE OR REPLACE FUNCTION public.archive_old_rides(p_months INTEGER DEFAULT 18, p_delete BOOLEAN DEFAULT false)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_corte TIMESTAMPTZ := NOW() - (GREATEST(COALESCE(p_months, 18), 6) || ' months')::INTERVAL;
  v_archivados INTEGER := 0;
  v_borrados   INTEGER := 0;
  v_protegidos INTEGER := 0;
  rec RECORD;
BEGIN
  -- Solo super_admin (usuario) o el sistema (cron/service_role: auth.uid() NULL)
  IF auth.uid() IS NOT NULL AND public.get_user_role(auth.uid()) <> 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  FOR rec IN
    SELECT r.id
    FROM public.rides r
    WHERE r.status::text IN ('completada', 'cancelada')
      AND COALESCE(r.completed_at, r.created_at) < v_corte
      AND NOT EXISTS (SELECT 1 FROM public.rides_archive a WHERE a.id = r.id)
  LOOP
    INSERT INTO public.rides_archive (id, tracking_code, status, created_at, completed_at, data)
    SELECT r.id, r.tracking_code, r.status::text, r.created_at, r.completed_at,
           jsonb_build_object(
             'ride', to_jsonb(r),
             'driver_earnings',    COALESCE((SELECT jsonb_agg(to_jsonb(de)) FROM public.driver_earnings de WHERE de.ride_id = r.id), '[]'::jsonb),
             'coupon_redemptions', COALESCE((SELECT jsonb_agg(to_jsonb(cr)) FROM public.coupon_redemptions cr WHERE cr.ride_id = r.id), '[]'::jsonb),
             'ride_incidents',     COALESCE((SELECT jsonb_agg(to_jsonb(ri)) FROM public.ride_incidents ri WHERE ri.ride_id = r.id), '[]'::jsonb)
           )
    FROM public.rides r
    WHERE r.id = rec.id
    ON CONFLICT (id) DO UPDATE SET data = EXCLUDED.data, archived_at = NOW();

    v_archivados := v_archivados + 1;

    IF p_delete THEN
      -- No borrar si hay una liquidación (payout) que lo referencia (FK NO ACTION)
      IF EXISTS (SELECT 1 FROM public.payouts p WHERE p.ride_id = rec.id) THEN
        v_protegidos := v_protegidos + 1;
      ELSE
        DELETE FROM public.rides WHERE id = rec.id;
        v_borrados := v_borrados + 1;
      END IF;
    END IF;
  END LOOP;

  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (auth.uid(), 'ARCHIVE_OLD_RIDES', 'system', NULL,
          jsonb_build_object('months', p_months, 'delete', p_delete,
                             'archivados', v_archivados, 'borrados', v_borrados, 'protegidos', v_protegidos));

  RETURN jsonb_build_object('corte', v_corte, 'archivados', v_archivados,
                            'borrados', v_borrados, 'protegidos', v_protegidos);
END;
$$;

GRANT EXECUTE ON FUNCTION public.archive_old_rides(integer, boolean) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.archive_old_rides(integer, boolean) FROM anon;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'rides_archive existe + RLS' AS comprobacion,
       (SELECT (relrowsecurity)::text FROM pg_class WHERE oid = 'public.rides_archive'::regclass) AS rls_on;

SELECT 'archive_old_rides disponible' AS comprobacion,
       (SELECT COUNT(*)::text FROM pg_proc WHERE proname = 'archive_old_rides' AND pronamespace = 'public'::regnamespace) AS existe;

SELECT '✅ Migración 083: archivado de viajes listo' AS estado;
