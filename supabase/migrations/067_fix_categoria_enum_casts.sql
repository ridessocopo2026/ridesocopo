-- ============================================================
-- BUNRIDER - Migración 067: FIX CASTS ENUM EN CRUD DE
-- CATEGORÍAS (operator does not exist: vehicle_category = text)
-- ------------------------------------------------------------
-- Las funciones de 060 guardaban el identificador en variables
-- TEXT y lo comparaban/asignaban contra columnas del enum
-- vehicle_category (vehicle_categories.name, vehicles.category,
-- rides.category), lo que PostgreSQL no permite implícitamente.
-- Se reescriben con casts explícitos:
--   - v_name (viene del catálogo -> label válido): se castea a
--     vehicle_category para conservar el uso de índices.
--   - v_target (texto libre del admin): se valida comparando el
--     texto y solo se castea al mover los vehículos.
-- Bonus: ahora CREAR tipos desde la UI funciona de punta a punta
-- (el INSERT a columna enum también llevaba texto sin cast).
-- ============================================================

-- ============================================================
-- 1. ADMIN_CREATE_VEHICLE_CATEGORY (fix chequeo + INSERT)
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_create_vehicle_category(
  p_name TEXT,
  p_display_name TEXT DEFAULT NULL,
  p_base_fare_usd NUMERIC DEFAULT NULL,
  p_max_passengers INTEGER DEFAULT NULL,
  p_description TEXT DEFAULT NULL,
  p_icon TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_name TEXT;
  v_display TEXT;
  v_id UUID;
BEGIN
  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;
  IF public.get_user_role(v_admin_id) != 'super_admin' THEN
    RAISE EXCEPTION 'Solo el administrador puede crear tipos de vehículo';
  END IF;

  v_name := NULLIF(BTRIM(p_name), '');
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'El nombre es obligatorio';
  END IF;

  v_display := COALESCE(NULLIF(BTRIM(p_display_name), ''), v_name);

  IF EXISTS (SELECT 1 FROM vehicle_categories WHERE name::text = v_name) THEN
    RAISE EXCEPTION 'Ya existe un tipo con ese nombre';
  END IF;

  INSERT INTO vehicle_categories (name, display_name, base_fare_usd, max_passengers, description, icon, is_active)
  VALUES (v_name::public.vehicle_category,
          v_display,
          COALESCE(p_base_fare_usd, 1.00),
          COALESCE(p_max_passengers, 1),
          p_description,
          p_icon,
          TRUE)
  RETURNING id INTO v_id;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_admin_id, 'CATEGORY_CREATE', 'vehicle_category', v_id,
          jsonb_build_object('name', v_name, 'display_name', v_display,
                             'base_fare_usd', COALESCE(p_base_fare_usd, 1.00)));

  RETURN v_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_create_vehicle_category(text, text, numeric, integer, text, text)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.admin_create_vehicle_category FROM anon;

-- ============================================================
-- 2. ADMIN_GET_CATEGORY_USAGE (fix conteos de vehículos/viajes)
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_get_category_usage(p_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_name TEXT;
  v_vehicles INTEGER;
  v_drivers INTEGER;
  v_active_rides INTEGER;
BEGIN
  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT name INTO v_name FROM vehicle_categories WHERE id = p_id;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Tipo de vehículo no encontrado';
  END IF;

  SELECT COUNT(*) INTO v_vehicles FROM vehicles WHERE category = v_name::public.vehicle_category;
  SELECT COUNT(DISTINCT driver_id) INTO v_drivers FROM vehicles WHERE category = v_name::public.vehicle_category;
  SELECT COUNT(*) INTO v_active_rides
  FROM rides
  WHERE category = v_name::public.vehicle_category
    AND status IN ('buscando', 'aceptada', 'en_ruta', 'incidente');

  RETURN jsonb_build_object(
    'name', v_name,
    'vehicles', v_vehicles,
    'drivers', v_drivers,
    'active_rides', v_active_rides
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_get_category_usage(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.admin_get_category_usage FROM anon;

-- ============================================================
-- 3. ADMIN_DELETE_VEHICLE_CATEGORY (fix reasignación + borrado)
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_delete_vehicle_category(
  p_id UUID,
  p_reassign_to TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_name TEXT;
  v_target TEXT;
  v_vehicles INTEGER;
  v_active_rides INTEGER;
BEGIN
  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;
  IF public.get_user_role(v_admin_id) != 'super_admin' THEN
    RAISE EXCEPTION 'Solo el administrador puede eliminar tipos de vehículo';
  END IF;

  SELECT name INTO v_name FROM vehicle_categories WHERE id = p_id;
  IF v_name IS NULL THEN
    RAISE EXCEPTION 'Tipo de vehículo no encontrado';
  END IF;

  SELECT COUNT(*) INTO v_active_rides
  FROM rides
  WHERE category = v_name::public.vehicle_category
    AND status IN ('buscando', 'aceptada', 'en_ruta', 'incidente');

  IF v_active_rides > 0 THEN
    RAISE EXCEPTION 'No se puede eliminar: hay % viaje(s) activo(s) en esta categoría', v_active_rides;
  END IF;

  SELECT COUNT(*) INTO v_vehicles FROM vehicles WHERE category = v_name::public.vehicle_category;

  IF v_vehicles > 0 THEN
    v_target := NULLIF(BTRIM(p_reassign_to), '');
    IF v_target IS NULL THEN
      RAISE EXCEPTION 'Hay % vehículo(s) registrados. Debes elegir a qué tipo se mueven antes de eliminar', v_vehicles;
    END IF;
    IF v_target = v_name THEN
      RAISE EXCEPTION 'El tipo destino debe ser distinto del que estás eliminando';
    END IF;
    -- Validación amigable en texto (v_target puede ser cualquier cadena)
    IF NOT EXISTS (SELECT 1 FROM vehicle_categories WHERE name::text = v_target AND is_active = TRUE) THEN
      RAISE EXCEPTION 'El tipo destino no existe o está inactivo';
    END IF;

    UPDATE vehicles
    SET category = v_target::public.vehicle_category
    WHERE category = v_name::public.vehicle_category;
  END IF;

  DELETE FROM vehicle_categories WHERE id = p_id;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_admin_id, 'CATEGORY_DELETE', 'vehicle_category', p_id,
          jsonb_build_object('name', v_name, 'reassigned_to', v_target, 'vehicles_moved', v_vehicles));

  RETURN jsonb_build_object('success', TRUE, 'deleted', v_name,
                            'reassigned_to', v_target, 'vehicles_moved', v_vehicles);
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_delete_vehicle_category(uuid, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.admin_delete_vehicle_category FROM anon;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 067: casts enum corregidos en el CRUD de categorías' AS estado;
