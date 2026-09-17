-- ============================================================
-- BUNRIDER - VERIFICACIÓN DE DISPONIBILIDAD (solo lectura)
-- Pegar en el SQL Editor de Supabase y ejecutar TODO.
-- Sirve para comprobar que el conteo que ve el cliente coincide
-- con la realidad (regla: is_approved + is_active_vehicle).
-- ============================================================

-- ============================================================
-- 1) COMPARACIÓN: RPC del cliente vs consulta canónica
--    (deben coincidir exactamente: estado = ✅ OK)
-- ============================================================
WITH canon AS (
  SELECT c.name::TEXT AS category, COUNT(p.id)::INTEGER AS canon_count
  FROM public.vehicle_categories c
  LEFT JOIN public.profiles p
    ON p.role = 'conductor'
   AND p.driver_status = 'aprobado'
   AND public.driver_available_now(p.id)
   AND EXISTS (
     SELECT 1 FROM public.vehicles v
     WHERE v.driver_id = p.id AND v.category = c.name
       AND v.is_approved = TRUE AND v.is_active_vehicle = TRUE
   )
   AND NOT EXISTS (
     SELECT 1 FROM public.rides r
     WHERE r.driver_id = p.id AND r.status IN ('aceptada','en_ruta','incidente')
   )
  WHERE c.is_active = TRUE
  GROUP BY c.name
)
SELECT
  f.category,
  f.available                       AS rpc_count,
  COALESCE(canon.canon_count, 0)    AS canon_count,
  CASE WHEN f.available = COALESCE(canon.canon_count, 0)
       THEN '✅ OK' ELSE '❌ DIFERENCIA' END AS estado
FROM public.get_available_driver_counts(NULL) f
LEFT JOIN canon ON canon.category = f.category
ORDER BY f.category;

-- ============================================================
-- 2) CONDUCTOR POR CONDUCTOR (por qué está o no disponible)
--    eligible = lo que cuenta el cliente
-- ============================================================
SELECT
  p.full_name,
  COALESCE(p.is_online, FALSE)            AS conectado,
  public.driver_in_schedule_now(p.id)     AS dentro_horario,
  v.category::TEXT                        AS vehiculo_activo,
  v.plate                                 AS placa,
  COALESCE(v.is_approved, FALSE)          AS aprobado,
  COALESCE(v.is_active_vehicle, FALSE)    AS es_su_activo,
  EXISTS (
    SELECT 1 FROM public.rides r
    WHERE r.driver_id = p.id AND r.status IN ('aceptada','en_ruta','incidente')
  )                                       AS ocupado,
  (
    COALESCE(p.is_online, FALSE)
    AND public.driver_in_schedule_now(p.id)
    AND COALESCE(v.is_approved, FALSE)
    AND COALESCE(v.is_active_vehicle, FALSE)
    AND NOT EXISTS (
      SELECT 1 FROM public.rides r
      WHERE r.driver_id = p.id AND r.status IN ('aceptada','en_ruta','incidente')
    )
  )                                       AS disponible_para_cliente
FROM public.profiles p
LEFT JOIN public.vehicles v
  ON v.driver_id = p.id AND v.is_approved = TRUE AND v.is_active_vehicle = TRUE
WHERE p.role = 'conductor' AND p.driver_status = 'aprobado'
ORDER BY p.full_name;

-- ============================================================
-- 3) VEHÍCULOS QUE NO CUENTAN (pendientes o no activos)
--    Deben aparecer aquí los que antes contaminaban el conteo.
-- ============================================================
SELECT
  p.full_name,
  v.category::TEXT,
  v.plate,
  v.is_approved,
  v.is_active_vehicle,
  v.is_active AS is_active_legacy,
  CASE
    WHEN NOT v.is_approved AND NOT v.is_active_vehicle THEN 'Pendiente y no activo'
    WHEN NOT v.is_approved THEN 'Pendiente de aprobación'
    WHEN NOT v.is_active_vehicle THEN 'No es su vehículo activo'
    ELSE 'Cuenta correctamente'
  END AS motivo
FROM public.vehicles v
JOIN public.profiles p ON p.id = v.driver_id
WHERE p.role = 'conductor' AND p.driver_status = 'aprobado'
  AND NOT (v.is_approved = TRUE AND v.is_active_vehicle = TRUE)
ORDER BY p.full_name, v.category::TEXT;
