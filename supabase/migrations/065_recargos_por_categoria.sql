-- ============================================================
-- BUNRIDER - Migración 065: RECARGOS POR BARRIO Y POR CATEGORÍA
-- ------------------------------------------------------------
-- REQUISITO: aplicar antes la migración 064 (agrega las etiquetas
-- del enum vehicle_category en su propia transacción).
-- Objetivo: que CADA tipo de vehículo del catálogo dinámico
-- (Moto Básica, Moto de Lujo, Trimoto, Moto de Carga, Carro,
-- Camioneta, Camión de Mudanza y los que el admin cree luego)
-- pueda tener su PROPIO recargo por barrio. Hasta ahora solo
-- existían columnas fijas moto/carro/camioneta y todo lo demás
-- caía en el recargo "general".
--
-- Diseño sin romper nada:
--  1. Tabla nueva barrio_surcharges(barrio_id, category, monto):
--     recargos EXPLÍCITOS por barrio × categoría.
--  2. Vista v_barrio_surcharges = barrios × categorías activas
--     que resuelve el recargo EFECTIVO así:
--       fila explícita  -> columna histórica (moto/carro/camioneta)
--       -> recargo general del barrio.
--     Con las filas vacías el resultado es IDÉNTICO al actual.
--  3. calculate_fare y la app leen SIEMPRE la vista.
--  4. Se garantiza que 'moto_carga' y 'camion_mudanza' existan
--     en el identificador interno vehicle_category + catálogo.
-- ============================================================

-- ============================================================
-- 1. CATÁLOGO: MOTO DE CARGA + CAMIÓN DE MUDANZA (y las otras
--    motos por si algún entorno no las tuviera). No pisa
--    tarifas base ya editadas por el admin (solo icono/etiqueta).
-- ============================================================
INSERT INTO public.vehicle_categories
  (name, display_name, base_fare_usd, max_passengers, description, icon, is_active)
VALUES
  ('moto_basica', 'Moto Básica', 1.00, 1, 'Económica, 1 pasajero', '🛵', TRUE),
  ('moto_lujo', 'Moto de Lujo', 1.60, 1, 'Cómoda y rápida', '🏍️', TRUE),
  ('trimoto', 'Trimoto', 2.00, 3, 'Trimoto, hasta 3 pasajeros', '🛺', TRUE),
  ('moto_carga', 'Moto de Carga', 1.30, 1, 'Transporte de mercancías para negocios', '📦', TRUE),
  ('camion_mudanza', 'Camión de Mudanza', 5.00, 2, 'Camión para mudanzas y cargas grandes', '🚛', TRUE)
ON CONFLICT (name) DO UPDATE SET
  display_name = EXCLUDED.display_name,
  description = EXCLUDED.description,
  icon = EXCLUDED.icon,
  is_active = TRUE;

-- ============================================================
-- 2. TABLA barrio_surcharges: recargo extra por barrio y tipo
-- ============================================================
CREATE TABLE IF NOT EXISTS public.barrio_surcharges (
  barrio_id     UUID           NOT NULL REFERENCES public.barrios(id) ON DELETE CASCADE,
  category      public.vehicle_category NOT NULL,
  surcharge_usd NUMERIC(10, 2) NOT NULL DEFAULT 0.00 CHECK (surcharge_usd >= 0),
  updated_at    TIMESTAMPTZ     NOT NULL DEFAULT NOW(),
  PRIMARY KEY (barrio_id, category)
);

CREATE INDEX IF NOT EXISTS barrio_surcharges_barrio_idx
  ON public.barrio_surcharges (barrio_id);

COMMENT ON TABLE public.barrio_surcharges IS
  'Recargos explícitos por barrio × categoría. Si no hay fila se usa la columna histórica del barrio (moto/carro/camioneta) o el recargo general.';

-- ============================================================
-- 3. VISTA v_barrio_surcharges: recargo efectivo por barrio y
--    categoría activa (fuente única para app y calculate_fare)
-- ============================================================
CREATE OR REPLACE VIEW public.v_barrio_surcharges AS
SELECT
  b.id            AS barrio_id,
  b.zone_id       AS zone_id,
  c.name          AS category,
  c.display_name  AS display_name,
  c.icon          AS icon,
  COALESCE(
    x.surcharge_usd,
    CASE c.name
      WHEN 'moto'      THEN b.surcharge_moto_usd
      WHEN 'carro'     THEN b.surcharge_carro_usd
      WHEN 'camioneta' THEN b.surcharge_camioneta_usd
    END,
    b.surcharge_usd,
    0.00
  )               AS surcharge_usd
FROM public.barrios b
JOIN public.vehicle_categories c ON c.is_active = TRUE
LEFT JOIN public.barrio_surcharges x
  ON x.barrio_id = b.id AND x.category = c.name
WHERE b.is_active = TRUE;

REVOKE ALL ON public.barrio_surcharges FROM anon, authenticated;
GRANT SELECT ON public.barrio_surcharges TO anon, authenticated, service_role;

REVOKE ALL ON public.v_barrio_surcharges FROM anon, authenticated;
GRANT SELECT ON public.v_barrio_surcharges TO anon, authenticated, service_role;

-- ============================================================
-- 4. CALCULATE_FARE: el recargo del barrio sale de la vista
--    (misma firma y mismo JSON de salida que antes)
-- ============================================================
CREATE OR REPLACE FUNCTION public.calculate_fare(
  p_origin_lat NUMERIC,
  p_origin_lng NUMERIC,
  p_dest_lat NUMERIC,
  p_dest_lng NUMERIC,
  p_category vehicle_category,
  p_coupon_code TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_base_fare NUMERIC;
  v_dest_surcharge NUMERIC := 0.00;
  v_dest_barrio_id UUID;
  v_dest_barrio_name TEXT;
  v_total NUMERIC;
  v_discount NUMERIC := 0.00;
  v_final NUMERIC;
  v_coupon_result JSONB;
  v_coupon_id UUID;
  v_zone RECORD;
BEGIN
  SELECT base_fare_usd INTO v_base_fare
  FROM vehicle_categories WHERE name = p_category;

  IF v_base_fare IS NULL THEN
    RAISE EXCEPTION 'Categoría de vehículo no válida';
  END IF;

  -- Detectar la ciudad (zona cobertura_general) que contiene el origen
  SELECT z.id, z.name INTO v_zone
  FROM zones z
  WHERE z.zone_type = 'cobertura_general'
    AND z.is_active = TRUE
    AND ST_Contains(z.polygon, ST_SetSRID(ST_MakePoint(p_origin_lng, p_origin_lat), 4326))
  LIMIT 1;

  IF v_zone.id IS NULL THEN
    RAISE EXCEPTION 'Tu ubicación está fuera del área de cobertura de la app';
  END IF;

  -- Barrio de destino por cercanía DENTRO de la misma ciudad
  SELECT b.id, b.name
  INTO v_dest_barrio_id, v_dest_barrio_name
  FROM barrios b
  WHERE b.is_active = TRUE
    AND b.zone_id = v_zone.id
    AND b.lat IS NOT NULL
    AND b.lng IS NOT NULL
  ORDER BY ST_Distance(
    ST_SetSRID(ST_MakePoint(b.lng, b.lat), 4326)::geography,
    ST_SetSRID(ST_MakePoint(p_dest_lng, p_dest_lat), 4326)::geography
  )
  LIMIT 1;

  -- Recargo efectivo del barrio para ESTA categoría (vista única).
  -- Fila explícita -> columna histórica -> recargo general del barrio.
  IF v_dest_barrio_id IS NOT NULL THEN
    SELECT v.surcharge_usd INTO v_dest_surcharge
    FROM public.v_barrio_surcharges v
    WHERE v.barrio_id = v_dest_barrio_id
      AND v.category = p_category;

    v_dest_surcharge := COALESCE(v_dest_surcharge, 0.00);
  ELSE
    v_dest_surcharge := 0.00;
    v_dest_barrio_name := 'No especificado';
  END IF;

  v_total := v_base_fare + v_dest_surcharge;

  -- Cupón: validación completa server-side (activo, fechas, usos, límite
  -- por usuario, primer viaje, monto mínimo). NO consume aquí.
  IF p_coupon_code IS NOT NULL THEN
    v_coupon_result := public.apply_coupon(p_coupon_code, v_total);
    IF COALESCE((v_coupon_result->>'valid')::boolean, FALSE) THEN
      v_discount := COALESCE((v_coupon_result->>'discount')::NUMERIC, 0.00);
      v_coupon_id := (v_coupon_result->>'coupon_id')::UUID;
    END IF;
  END IF;

  v_final := GREATEST(v_total - v_discount, 0.00);

  RETURN jsonb_build_object(
    'base_fare', v_base_fare,
    'origin_surcharge', 0.00,
    'destination_surcharge', v_dest_surcharge,
    'total_fare', v_total,
    'discount', v_discount,
    'final_fare', v_final,
    'destination_barrio_id', v_dest_barrio_id,
    'destination_barrio_name', v_dest_barrio_name,
    'in_coverage', TRUE,
    'origin_zone_id', v_zone.id,
    'origin_zone_name', v_zone.name,
    'destination_zone_id', v_zone.id,
    'destination_zone_name', v_zone.name,
    'coupon_id', v_coupon_id,
    'coupon_code', CASE WHEN v_coupon_id IS NOT NULL THEN UPPER(p_coupon_code) ELSE NULL END
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.calculate_fare TO anon, authenticated, service_role;

-- ============================================================
-- 5. UPSERT_BARRIO: guarda también los recargos por categoría
--    (lista JSONB [{category, surcharge_usd}]). Si viene NULL no
--    toca la tabla (compatibilidad con clientes antiguos); si
--    viene como array, reemplaza el conjunto de filas del barrio.
-- ============================================================
DROP FUNCTION IF EXISTS public.upsert_barrio(text, numeric, uuid, numeric, numeric, text, uuid, numeric, numeric, numeric);

CREATE OR REPLACE FUNCTION public.upsert_barrio(
  p_name TEXT,
  p_surcharge_usd NUMERIC,
  p_zone_id UUID,
  p_lat NUMERIC DEFAULT NULL,
  p_lng NUMERIC DEFAULT NULL,
  p_description TEXT DEFAULT NULL,
  p_barrio_id UUID DEFAULT NULL,
  p_surcharge_moto_usd NUMERIC DEFAULT NULL,
  p_surcharge_carro_usd NUMERIC DEFAULT NULL,
  p_surcharge_camioneta_usd NUMERIC DEFAULT NULL,
  p_surcharges JSONB DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_barrio_id UUID;
  v_zone_ok BOOLEAN;
  v_item JSONB;
  v_cat TEXT;
  v_amount NUMERIC;
BEGIN
  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;
  IF public.get_user_role(v_admin_id) != 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM zones WHERE id = p_zone_id AND zone_type = 'cobertura_general' AND is_active = TRUE
  ) INTO v_zone_ok;
  IF NOT v_zone_ok THEN
    RAISE EXCEPTION 'Ciudad no válida';
  END IF;

  IF p_surcharge_moto_usd IS NULL THEN p_surcharge_moto_usd := p_surcharge_usd; END IF;
  IF p_surcharge_carro_usd IS NULL THEN p_surcharge_carro_usd := p_surcharge_usd; END IF;
  IF p_surcharge_camioneta_usd IS NULL THEN p_surcharge_camioneta_usd := p_surcharge_usd; END IF;

  IF p_barrio_id IS NULL THEN
    INSERT INTO barrios (name, zone_id, surcharge_usd, surcharge_moto_usd, surcharge_carro_usd, surcharge_camioneta_usd, lat, lng, description)
    VALUES (p_name, p_zone_id, p_surcharge_usd, p_surcharge_moto_usd, p_surcharge_carro_usd, p_surcharge_camioneta_usd, p_lat, p_lng, p_description)
    RETURNING id INTO v_barrio_id;
  ELSE
    UPDATE barrios
    SET name = p_name,
        zone_id = p_zone_id,
        surcharge_usd = p_surcharge_usd,
        surcharge_moto_usd = p_surcharge_moto_usd,
        surcharge_carro_usd = p_surcharge_carro_usd,
        surcharge_camioneta_usd = p_surcharge_camioneta_usd,
        lat = p_lat,
        lng = p_lng,
        description = p_description,
        updated_at = NOW()
    WHERE id = p_barrio_id
    RETURNING id INTO v_barrio_id;
  END IF;

  -- Recargos explícitos por barrio × categoría.
  -- p_surcharges = [{category, surcharge_usd}] con TODAS las filas que
  -- debe tener el barrio: se reemplaza el conjunto. NULL = no tocar
  -- (compatibilidad con clientes antiguos). '' en la app no se envía,
  -- por lo que esa categoría vuelve a heredar (columna o general).
  IF p_surcharges IS NOT NULL THEN
    DELETE FROM public.barrio_surcharges WHERE barrio_id = v_barrio_id;

    IF jsonb_typeof(p_surcharges) = 'array' THEN
      FOR v_item IN SELECT * FROM jsonb_array_elements(p_surcharges)
      LOOP
        v_cat := NULLIF(BTRIM(COALESCE(v_item->>'category', '')), '');
        v_amount := v_item->>'surcharge_usd';
        CONTINUE WHEN v_cat IS NULL OR v_amount IS NULL;

        INSERT INTO public.barrio_surcharges (barrio_id, category, surcharge_usd)
        VALUES (v_barrio_id, v_cat::public.vehicle_category, GREATEST(v_amount::NUMERIC, 0.00))
        ON CONFLICT (barrio_id, category) DO UPDATE
          SET surcharge_usd = EXCLUDED.surcharge_usd, updated_at = NOW();
      END LOOP;
    END IF;
  END IF;

  RETURN v_barrio_id;
END;
$$;

REVOKE ALL ON FUNCTION public.upsert_barrio FROM anon;
GRANT EXECUTE ON FUNCTION public.upsert_barrio TO authenticated, service_role;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 064: recargos por barrio y categoría lista' AS estado;

SELECT c.name, c.display_name, c.icon, c.is_active
FROM public.vehicle_categories c
WHERE c.name IN ('moto_basica', 'moto_lujo', 'trimoto', 'moto_carga', 'camion_mudanza')
ORDER BY c.base_fare_usd;
