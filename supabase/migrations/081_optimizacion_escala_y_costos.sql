-- ============================================================
-- BUNRIDER - Migración 081: OPTIMIZACIÓN DE ESCALA Y COSTOS
-- ------------------------------------------------------------
-- Fase 1 del plan de escalabilidad (objetivo: 500 viajes/día
-- sin sobresaltos de costo ni lentitud).
--
-- 1) TRACKING GPS (update_driver_location): el throttle anterior
--    escribía en `rides` cada vez que el vehículo se movía >8 m
--    (es decir, casi en cada lectura GPS en movimiento) y cada
--    UPDATE se publica por Realtime a 2 suscriptores (cliente y
--    conductor) => millones de mensajes/mes. El nuevo throttle:
--      · NUNCA escribe con menos de 12 s desde la última escritura
--      · si NO se movió >= 25 m, solo escribe un "latido" cada 60 s
--    Resultado: <= 5 escrituras/min (antes potencialmente ~1/s).
--    Misma firma y mismo retorno: el cliente no cambia nada.
--
-- 2) RLS initplan: 46 políticas reevaluaban auth.uid()/auth.jwt()
--    por fila. Se reescriben envolviéndolas en (select ...) que
--    PostgreSQL evalúa UNA vez por consulta. Semánticamente
--    idéntico (mismo valor); solo mejora el plan.
--
-- NO se toca: firmas de funciones, permisos ni lógica de negocio.
-- ============================================================

-- ============================================================
-- 1. TRACKING GPS CON THROTTLE ESTRICTO (costo Realtime)
-- ============================================================
CREATE OR REPLACE FUNCTION public.update_driver_location(p_ride_id uuid, p_lat numeric, p_lng numeric)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_ride RECORD;
  v_distance NUMERIC;
  v_elapsed INTERVAL;
  v_moved BOOLEAN;
BEGIN
  IF NOT public.is_account_active(v_driver_id) THEN
    RETURN FALSE;
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;

  IF v_ride.id IS NULL OR v_ride.driver_id != v_driver_id THEN
    RETURN FALSE;
  END IF;

  -- Si ya hay una posición previa, aplicamos throttling
  IF v_ride.driver_location_lat IS NOT NULL THEN
    v_elapsed := NOW() - v_ride.driver_last_update;

    -- 1) Nunca escribir con menos de 12 s de separación
    IF v_elapsed < INTERVAL '12 seconds' THEN
      RETURN FALSE;
    END IF;

    -- 2) ¿Se movió de verdad (>= 25 m)?
    v_distance := ST_Distance(
      ST_SetSRID(ST_MakePoint(v_ride.driver_location_lng, v_ride.driver_location_lat), 4326)::geography,
      ST_SetSRID(ST_MakePoint(p_lng, p_lat), 4326)::geography
    );
    v_moved := v_distance >= 25;

    -- 3) Si el vehículo no se movió, solo un "latido" cada 60 s
    IF NOT v_moved AND v_elapsed < INTERVAL '60 seconds' THEN
      RETURN FALSE;
    END IF;
  END IF;

  UPDATE rides
  SET driver_location_lat = p_lat,
      driver_location_lng = p_lng,
      driver_last_update = NOW()
  WHERE id = p_ride_id;

  RETURN TRUE;
END;
$$;

-- ============================================================
-- 2. RLS: auth.uid() / auth.jwt() / auth.role() -> (select ...)
-- ------------------------------------------------------------
-- Reescribe TODA política (public y storage) que use esas
-- funciones, sin duplicar el envoltorio si ya lo tiene.
-- ============================================================
DO $$
DECLARE
  rec RECORD;
  v_using TEXT;
  v_check TEXT;
  v_sql TEXT;
  v_token TEXT;
BEGIN
  FOR rec IN
    SELECT schemaname, tablename, policyname, cmd, qual, with_check
    FROM pg_policies
    WHERE schemaname IN ('public', 'storage')
      AND (
        COALESCE(qual, '') ~ 'auth\.(uid|jwt|role)\(\)'
        OR COALESCE(with_check, '') ~ 'auth\.(uid|jwt|role)\(\)'
      )
  LOOP
    v_using := rec.qual;
    v_check := rec.with_check;

    FOREACH v_token IN ARRAY ARRAY['auth.uid()', 'auth.jwt()', 'auth.role()'] LOOP
      IF v_using IS NOT NULL THEN
        v_using := replace(v_using, '(select ' || v_token || ')', '__SEL__');
        v_using := replace(v_using, v_token, '(select ' || v_token || ')');
        v_using := replace(v_using, '__SEL__', '(select ' || v_token || ')');
      END IF;
      IF v_check IS NOT NULL THEN
        v_check := replace(v_check, '(select ' || v_token || ')', '__SEL__');
        v_check := replace(v_check, v_token, '(select ' || v_token || ')');
        v_check := replace(v_check, '__SEL__', '(select ' || v_token || ')');
      END IF;
    END LOOP;

    v_sql := format('ALTER POLICY %I ON %I.%I', rec.policyname, rec.schemaname, rec.tablename);

    IF rec.cmd IN ('SELECT', 'UPDATE', 'DELETE', 'ALL') AND v_using IS NOT NULL THEN
      v_sql := v_sql || format(' USING (%s)', v_using);
    END IF;
    IF rec.cmd IN ('INSERT', 'UPDATE', 'ALL') AND v_check IS NOT NULL THEN
      v_sql := v_sql || format(' WITH CHECK (%s)', v_check);
    END IF;

    EXECUTE v_sql;
  END LOOP;
END $$;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'update_driver_location throttle 12s/25m' AS comprobacion,
       (pg_get_functiondef(oid) LIKE '%12 seconds%')::text AS ok
FROM pg_proc WHERE proname = 'update_driver_location' AND pronamespace = 'public'::regnamespace;

SELECT 'politicas public/storage con auth.* SIN (select ...) (esperado 0)' AS comprobacion,
       (SELECT COUNT(*)::text FROM pg_policies
         WHERE schemaname IN ('public','storage')
           AND (COALESCE(qual,'') ~ 'auth\.(uid|jwt|role)\(\)' AND COALESCE(qual,'') NOT LIKE '%(select auth.%'
             OR COALESCE(with_check,'') ~ 'auth\.(uid|jwt|role)\(\)' AND COALESCE(with_check,'') NOT LIKE '%(select auth.%'));

SELECT '✅ Migración 081: escala y costos (tracking + RLS initplan) aplicada' AS estado;
