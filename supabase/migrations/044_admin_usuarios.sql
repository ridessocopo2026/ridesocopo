-- ============================================================
-- RIDERFLASSHI - Migración 044: ADMIN USUARIOS + WHATSAPP
-- ------------------------------------------------------------
-- 1. RPC get_admin_users: listado paginado y filtrable de TODOS
--    los usuarios (pasajeros, conductores, admins) para el panel
--    de administración. SECURITY DEFINER + chequeo de rol.
-- 2. driver_documents.license_number pasa a ser NULLABLE: ya no
--    se pide el número de licencia en el registro de conductor.
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_admin_users(
  p_search TEXT DEFAULT NULL,
  p_role TEXT DEFAULT NULL,
  p_driver_status TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 25,
  p_offset INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_search TEXT := NULLIF(TRIM(COALESCE(p_search, '')), '');
  v_total INTEGER := 0;
  v_items JSONB;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- Limitar tamaño de página
  IF p_limit > 100 THEN p_limit := 100; END IF;
  IF p_limit < 1 THEN p_limit := 25; END IF;
  IF p_offset < 0 THEN p_offset := 0; END IF;

  -- Contar total (para paginación)
  SELECT COUNT(*) INTO v_total
  FROM public.profiles pr
  WHERE (v_search IS NULL
         OR pr.full_name ILIKE '%' || v_search || '%'
         OR pr.email ILIKE '%' || v_search || '%'
         OR pr.phone ILIKE '%' || v_search || '%')
    AND (p_role IS NULL
         OR (p_role = 'cliente' AND pr.role = 'cliente')
         OR (p_role = 'conductor' AND pr.role = 'conductor')
         OR (p_role = 'admin' AND pr.role IN ('super_admin', 'encargado')))
    AND (p_driver_status IS NULL OR COALESCE(pr.driver_status::text, '') = p_driver_status);

  -- Obtener items paginados
  SELECT COALESCE(jsonb_agg(t ORDER BY t.created_at DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT
      pr.id::text AS id,
      pr.full_name,
      pr.email,
      pr.phone,
      pr.role::text AS role,
      pr.driver_status::text AS driver_status,
      pr.is_online,
      pr.onboarding_completed,
      pr.created_at,
      COALESCE(w.balance_usd, 0) AS balance_usd
    FROM public.profiles pr
    LEFT JOIN public.wallets w ON w.user_id = pr.id
    WHERE (v_search IS NULL
           OR pr.full_name ILIKE '%' || v_search || '%'
           OR pr.email ILIKE '%' || v_search || '%'
           OR pr.phone ILIKE '%' || v_search || '%')
      AND (p_role IS NULL
           OR (p_role = 'cliente' AND pr.role = 'cliente')
           OR (p_role = 'conductor' AND pr.role = 'conductor')
           OR (p_role = 'admin' AND pr.role IN ('super_admin', 'encargado')))
      AND (p_driver_status IS NULL OR COALESCE(pr.driver_status::text, '') = p_driver_status)
  ) t
  LIMIT p_limit OFFSET p_offset;

  RETURN jsonb_build_object('total', v_total, 'items', v_items);
END;
$$;

-- Permisos: solo usuarios autenticados (y la RPC valida el rol)
REVOKE ALL ON FUNCTION public.get_admin_users FROM anon;
GRANT EXECUTE ON FUNCTION public.get_admin_users TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_users TO service_role;

-- ============================================================
-- Número de licencia ya no es obligatorio
-- ============================================================
ALTER TABLE public.driver_documents ALTER COLUMN license_number DROP NOT NULL;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'OK: migración 044 aplicada' AS estado;
