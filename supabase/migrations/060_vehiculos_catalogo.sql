-- ============================================================
-- BUNRIDER - Migración 060: CATÁLOGO DE VEHÍCULOS DINÁMICO
-- ------------------------------------------------------------
-- Permite al admin crear/editar/eliminar "tipos" de vehículo
-- (Moto, Moto de Lujo, Carro...) sin romper el modelo existente:
--  - El enum vehicle_category se amplía en caliente (ALTER TYPE
--    ADD VALUE en su PROPIA transacción vía RPC) → las columnas
--    rides.category/vehicles.category y funciones existentes
--    siguen funcionando intactas.
--  - CRUD de vehicle_categories por RPC (la tabla solo tiene
--    permiso SELECT desde security_hardening).
--  - Eliminar exige reasignar los vehículos de conductores a
--    otro tipo (con aviso de cuántos hay) y se bloquea si hay
--    viajes activos en esa categoría.
-- ============================================================

-- 1. GARANTIZAR ETIQUETA EN EL ENUM (DDL en su propia transacción).
--    Se llama ANTES de crear la fila en vehicle_categories.
CREATE OR REPLACE FUNCTION public.ensure_vehicle_category_enum(p_name TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_label TEXT;
BEGIN
  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  IF public.get_user_role(v_admin_id) != 'super_admin' THEN
    RAISE EXCEPTION 'Solo el administrador puede crear tipos de vehículo';
  END IF;

  v_label := NULLIF(BTRIM(p_name), '');
  IF v_label IS NULL THEN
    RAISE EXCEPTION 'El nombre no puede estar vacío';
  END IF;
  IF LENGTH(v_label) > 40 THEN
    RAISE EXCEPTION 'El nombre es muy largo (máx. 40 caracteres)';
  END IF;

  EXECUTE format('ALTER TYPE public.vehicle_category ADD VALUE IF NOT EXISTS %L', v_label);
  RETURN TRUE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.ensure_vehicle_category_enum(text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.ensure_vehicle_category_enum FROM anon;

-- ============================================================
-- 2. CREAR TIPO DE VEHÍCULO (la etiqueta ya debe existir en el enum)
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

  IF EXISTS (SELECT 1 FROM vehicle_categories WHERE name = v_name) THEN
    RAISE EXCEPTION 'Ya existe un tipo con ese nombre';
  END IF;

  INSERT INTO vehicle_categories (name, display_name, base_fare_usd, max_passengers, description, icon, is_active)
  VALUES (v_name,
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
-- 3. EDITAR TIPO (precio, nombre a mostrar, pasajeros, icono, activo)
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_update_vehicle_category(
  p_id UUID,
  p_display_name TEXT DEFAULT NULL,
  p_base_fare_usd NUMERIC DEFAULT NULL,
  p_max_passengers INTEGER DEFAULT NULL,
  p_description TEXT DEFAULT NULL,
  p_icon TEXT DEFAULT NULL,
  p_is_active BOOLEAN DEFAULT NULL
)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_row RECORD;
BEGIN
  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;
  IF public.get_user_role(v_admin_id) != 'super_admin' THEN
    RAISE EXCEPTION 'Solo el administrador puede editar tipos de vehículo';
  END IF;

  SELECT * INTO v_row FROM vehicle_categories WHERE id = p_id;
  IF v_row.id IS NULL THEN
    RAISE EXCEPTION 'Tipo de vehículo no encontrado';
  END IF;

  UPDATE vehicle_categories
  SET display_name   = COALESCE(NULLIF(BTRIM(p_display_name), ''), v_row.display_name),
      base_fare_usd  = COALESCE(p_base_fare_usd, v_row.base_fare_usd),
      max_passengers = COALESCE(p_max_passengers, v_row.max_passengers),
      description    = COALESCE(p_description, v_row.description),
      icon           = COALESCE(p_icon, v_row.icon),
      is_active      = COALESCE(p_is_active, v_row.is_active)
  WHERE id = p_id;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_admin_id, 'CATEGORY_UPDATE', 'vehicle_category', p_id,
          jsonb_build_object('display_name', COALESCE(p_display_name, v_row.display_name),
                             'base_fare_usd', COALESCE(p_base_fare_usd, v_row.base_fare_usd),
                             'is_active', COALESCE(p_is_active, v_row.is_active)));

  RETURN TRUE;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_update_vehicle_category(uuid, text, numeric, integer, text, text, boolean)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.admin_update_vehicle_category FROM anon;

-- ============================================================
-- 4. USO DE UN TIPO (para el aviso de vehículos asociados)
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

  SELECT COUNT(*) INTO v_vehicles FROM vehicles WHERE category = v_name;
  SELECT COUNT(DISTINCT driver_id) INTO v_drivers FROM vehicles WHERE category = v_name;
  SELECT COUNT(*) INTO v_active_rides
  FROM rides
  WHERE category = v_name
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
-- 5. ELIMINAR TIPO: aviso + reasignación de vehículos asociados
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
  WHERE category = v_name
    AND status IN ('buscando', 'aceptada', 'en_ruta', 'incidente');

  IF v_active_rides > 0 THEN
    RAISE EXCEPTION 'No se puede eliminar: hay % viaje(s) activo(s) en esta categoría', v_active_rides;
  END IF;

  SELECT COUNT(*) INTO v_vehicles FROM vehicles WHERE category = v_name;

  IF v_vehicles > 0 THEN
    v_target := NULLIF(BTRIM(p_reassign_to), '');
    IF v_target IS NULL THEN
      RAISE EXCEPTION 'Hay % vehículo(s) registrados. Debes elegir a qué tipo se mueven antes de eliminar', v_vehicles;
    END IF;
    IF v_target = v_name THEN
      RAISE EXCEPTION 'El tipo destino debe ser distinto del que estás eliminando';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM vehicle_categories WHERE name = v_target AND is_active = TRUE) THEN
      RAISE EXCEPTION 'El tipo destino no existe o está inactivo';
    END IF;

    UPDATE vehicles SET category = v_target WHERE category = v_name;
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
SELECT '✅ Migración 060: catálogo de vehículos dinámico lista' AS estado;

SELECT p.proname, pg_get_function_identity_arguments(p.oid) AS args
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('ensure_vehicle_category_enum', 'admin_create_vehicle_category',
                    'admin_update_vehicle_category', 'admin_get_category_usage',
                    'admin_delete_vehicle_category')
ORDER BY p.proname;

