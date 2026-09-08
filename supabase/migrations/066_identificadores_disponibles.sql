-- ============================================================
-- BUNRIDER - Migración 066: IDENTIFICADORES INTERNOS
-- DISPONIBLES PARA AGREGAR TIPOS DE VEHÍCULO
-- ------------------------------------------------------------
-- El identificador interno (vehicle_category) ahora se ELIGE al
-- crear un tipo de vehículo en vez de escribirse a mano.
--  - Se siembran aquí algunas etiquetas del enum SIN crear fila
--    en vehicle_categories: quedan "disponibles" para activarse
--    como tipo cuando el admin quiera (con su tarifa/icono).
--  - RPC get_available_vehicle_category_identifiers: devuelve las
--    etiquetas del enum que aún no tienen fila en el catálogo.
-- Separado en archivo propio porque Supabase no permite usar en
-- el mismo script un valor de enum recién agregado (55P04) y
-- estas etiquetas tampoco se "usan" aquí (solo se agregan).
-- ============================================================

ALTER TYPE public.vehicle_category ADD VALUE IF NOT EXISTS 'furgoneta';
ALTER TYPE public.vehicle_category ADD VALUE IF NOT EXISTS 'camion';
ALTER TYPE public.vehicle_category ADD VALUE IF NOT EXISTS 'bus';

-- ============================================================
-- 1. RPC: identificadores internos aún sin tipo activo
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_available_vehicle_category_identifiers()
RETURNS TABLE (identifier TEXT)
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
BEGIN
  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  IF public.get_user_role(v_admin_id) != 'super_admin' THEN
    RAISE EXCEPTION 'Solo el administrador puede ver los identificadores internos';
  END IF;

  RETURN QUERY
  SELECT e.enumlabel::TEXT
  FROM pg_enum e
  JOIN pg_type t ON t.oid = e.enumtypid
  WHERE t.typname = 'vehicle_category'
    AND t.typnamespace = 'public'::regnamespace
    AND NOT EXISTS (
      SELECT 1 FROM public.vehicle_categories c
      WHERE c.name::TEXT = e.enumlabel::TEXT
    )
  ORDER BY e.enumlabel::TEXT;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_available_vehicle_category_identifiers() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_available_vehicle_category_identifiers() FROM anon;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 066: pool de identificadores + RPC listos' AS estado;
