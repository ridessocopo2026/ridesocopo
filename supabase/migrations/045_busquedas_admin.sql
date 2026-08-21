-- ============================================================
-- RIDERFLASSHI - Migración 045: BÚSQUEDAS ADMIN MEJORADAS
-- ------------------------------------------------------------
-- 1. get_admin_rides: cuando hay texto de búsqueda se IGNORA el
--    filtro de fechas → un viaje viejo se encuentra por su
--    código de seguimiento (RS-XXXXXX).
-- 2. get_admin_transactions: nuevo parámetro p_busqueda que busca
--    por nombre/email/teléfono del usuario, referencia o código
--    de seguimiento del viaje (transacciones y payouts).
-- ============================================================

-- ============================================================
-- 1. GET_ADMIN_RIDES (misma firma, cuerpo mejorado)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_admin_rides(
  p_search TEXT DEFAULT NULL,
  p_fecha_inicio TIMESTAMPTZ DEFAULT NOW() - INTERVAL '90 days',
  p_fecha_fin TIMESTAMPTZ DEFAULT NOW(),
  p_status TEXT DEFAULT NULL,
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
  v_total INTEGER := 0;
  v_items JSONB;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF p_limit > 50 THEN p_limit := 50; END IF;
  IF p_limit < 1 THEN p_limit := 25; END IF;
  IF p_offset < 0 THEN p_offset := 0; END IF;

  IF p_search IS NOT NULL AND TRIM(p_search) = '' THEN
    p_search := NULL;
  END IF;

  -- Contar total
  SELECT COUNT(*) INTO v_total
  FROM rides r
  LEFT JOIN profiles cl ON cl.id = r.client_id
  LEFT JOIN profiles dr ON dr.id = r.driver_id
  WHERE (p_search IS NOT NULL OR (r.created_at >= p_fecha_inicio AND r.created_at <= p_fecha_fin))
    AND (p_status IS NULL OR r.status::text = p_status)
    AND (
      p_search IS NULL
      OR UPPER(r.tracking_code) LIKE UPPER('%' || p_search || '%')
      OR UPPER(cl.full_name) LIKE UPPER('%' || p_search || '%')
      OR UPPER(dr.full_name) LIKE UPPER('%' || p_search || '%')
      OR UPPER(cl.email) LIKE UPPER('%' || p_search || '%')
    );

  -- Obtener items paginados
  SELECT COALESCE(jsonb_agg(t ORDER BY t.fecha DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT
      r.id AS ride_id,
      r.tracking_code,
      r.status::text AS status,
      r.payment_method,
      r.final_fare_usd,
      r.commission_usd,
      r.created_at AS fecha,
      r.origin_address,
      r.destination_address,
      r.destination_barrio_name,
      r.proof_status,
      r.cancellation_fee_usd,
      r.driver_compensation_usd,
      cl.full_name AS cliente,
      dr.full_name AS conductor,
      COALESCE(de.cash_received_usd, 0) AS cash_received,
      COALESCE(de.app_credit_usd, 0) AS app_credit
    FROM rides r
    LEFT JOIN profiles cl ON cl.id = r.client_id
    LEFT JOIN profiles dr ON dr.id = r.driver_id
    LEFT JOIN driver_earnings de ON de.ride_id = r.id
    WHERE (p_search IS NOT NULL OR (r.created_at >= p_fecha_inicio AND r.created_at <= p_fecha_fin))
      AND (p_status IS NULL OR r.status::text = p_status)
      AND (
        p_search IS NULL
        OR UPPER(r.tracking_code) LIKE UPPER('%' || p_search || '%')
        OR UPPER(cl.full_name) LIKE UPPER('%' || p_search || '%')
        OR UPPER(dr.full_name) LIKE UPPER('%' || p_search || '%')
        OR UPPER(cl.email) LIKE UPPER('%' || p_search || '%')
      )
  ) t
  LIMIT p_limit OFFSET p_offset;

  RETURN jsonb_build_object('total', v_total, 'items', v_items);
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_admin_rides TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_rides TO service_role;

-- ============================================================
-- 2. GET_ADMIN_TRANSACTIONS con p_busqueda
--    (DROP + CREATE porque cambia la firma)
-- ============================================================
DROP FUNCTION IF EXISTS public.get_admin_transactions(timestamptz, timestamptz, text, text, uuid, integer, integer);

CREATE OR REPLACE FUNCTION public.get_admin_transactions(
  p_fecha_inicio TIMESTAMPTZ DEFAULT NOW() - INTERVAL '30 days',
  p_fecha_fin TIMESTAMPTZ DEFAULT NOW(),
  p_tipo TEXT DEFAULT NULL,
  p_rol TEXT DEFAULT NULL,
  p_usuario_id UUID DEFAULT NULL,
  p_busqueda TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 50,
  p_offset INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_total INTEGER := 0;
  v_items JSONB;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- Limitar tamaño de página (máx 100)
  IF p_limit > 100 THEN p_limit := 100; END IF;
  IF p_limit < 1 THEN p_limit := 50; END IF;
  IF p_offset < 0 THEN p_offset := 0; END IF;

  -- Normalizar búsqueda (vacío = NULL)
  IF p_busqueda IS NOT NULL AND TRIM(p_busqueda) = '' THEN
    p_busqueda := NULL;
  END IF;

  -- Contar total (para paginación)
  SELECT COUNT(*) INTO v_total
  FROM (
    SELECT id
    FROM (
      SELECT t.id AS id
      FROM transactions t
      LEFT JOIN profiles pr ON pr.id = t.user_id
      WHERE t.created_at >= p_fecha_inicio
        AND t.created_at <= p_fecha_fin
        AND (p_tipo IS NULL OR t.type::text = p_tipo)
        AND (p_usuario_id IS NULL OR t.user_id = p_usuario_id)
        AND (p_busqueda IS NULL
             OR pr.full_name ILIKE '%' || p_busqueda || '%'
             OR pr.email ILIKE '%' || p_busqueda || '%'
             OR pr.phone ILIKE '%' || p_busqueda || '%'
             OR t.reference ILIKE '%' || p_busqueda || '%'
             OR t.ride_id IN (SELECT r.id FROM rides r WHERE UPPER(r.tracking_code) LIKE UPPER('%' || p_busqueda || '%')))
        AND (
          p_rol IS NULL
          OR (p_rol = 'cliente' AND pr.role = 'cliente')
          OR (p_rol = 'conductor' AND pr.role = 'conductor')
          OR (p_rol = 'admin' AND pr.role IN ('super_admin', 'encargado'))
        )
      UNION ALL
      SELECT po.id AS id
      FROM payouts po
      LEFT JOIN profiles pr ON pr.id = po.driver_id
      WHERE po.created_at >= p_fecha_inicio
        AND po.created_at <= p_fecha_fin
        AND (p_tipo IS NULL OR po.type::text = p_tipo)
        AND (p_usuario_id IS NULL OR po.driver_id = p_usuario_id)
        AND (p_busqueda IS NULL
             OR pr.full_name ILIKE '%' || p_busqueda || '%'
             OR pr.email ILIKE '%' || p_busqueda || '%'
             OR pr.phone ILIKE '%' || p_busqueda || '%'
             OR po.description ILIKE '%' || p_busqueda || '%'
             OR po.ride_id IN (SELECT r.id FROM rides r WHERE UPPER(r.tracking_code) LIKE UPPER('%' || p_busqueda || '%')))
        AND (
          p_rol IS NULL
          OR (p_rol = 'conductor' AND pr.role = 'conductor')
          OR (p_rol = 'admin' AND pr.role IN ('super_admin', 'encargado'))
        )
    ) sub
  ) sub2;

  -- Obtener items paginados
  SELECT COALESCE(jsonb_agg(t ORDER BY t.fecha DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    -- Transacciones de wallets (clientes y conductores)
    SELECT
      t.id::text AS id,
      'transaction' AS origen,
      t.created_at AS fecha,
      pr.full_name AS usuario,
      pr.role AS rol,
      t.user_id AS usuario_id,
      t.type::text AS tipo,
      t.amount_usd AS monto,
      t.status::text AS estado,
      t.description AS descripcion,
      t.reference AS referencia,
      t.ride_id AS viaje_id,
      NULL::text AS comprobante,
      COALESCE((SELECT balance_usd FROM wallets w WHERE w.id = t.wallet_id), 0) AS saldo_resultante
    FROM transactions t
    LEFT JOIN profiles pr ON pr.id = t.user_id
    WHERE t.created_at >= p_fecha_inicio
      AND t.created_at <= p_fecha_fin
      AND (p_tipo IS NULL OR t.type::text = p_tipo)
      AND (p_usuario_id IS NULL OR t.user_id = p_usuario_id)
      AND (p_busqueda IS NULL
           OR pr.full_name ILIKE '%' || p_busqueda || '%'
           OR pr.email ILIKE '%' || p_busqueda || '%'
           OR pr.phone ILIKE '%' || p_busqueda || '%'
           OR t.reference ILIKE '%' || p_busqueda || '%'
           OR t.ride_id IN (SELECT r.id FROM rides r WHERE UPPER(r.tracking_code) LIKE UPPER('%' || p_busqueda || '%')))
      AND (
        p_rol IS NULL
        OR (p_rol = 'cliente' AND pr.role = 'cliente')
        OR (p_rol = 'conductor' AND pr.role = 'conductor')
        OR (p_rol = 'admin' AND pr.role IN ('super_admin', 'encargado'))
      )

    UNION ALL

    -- Payouts (liquidaciones entre plataforma y conductores)
    SELECT
      po.id::text AS id,
      'payout' AS origen,
      po.created_at AS fecha,
      pr.full_name AS usuario,
      pr.role AS rol,
      po.driver_id AS usuario_id,
      po.type AS tipo,
      po.amount_usd AS monto,
      po.status AS estado,
      po.description AS descripcion,
      NULL::text AS referencia,
      po.ride_id AS viaje_id,
      po.proof_url AS comprobante,
      0 AS saldo_resultante
    FROM payouts po
    LEFT JOIN profiles pr ON pr.id = po.driver_id
    WHERE po.created_at >= p_fecha_inicio
      AND po.created_at <= p_fecha_fin
      AND (p_tipo IS NULL OR po.type::text = p_tipo)
      AND (p_usuario_id IS NULL OR po.driver_id = p_usuario_id)
      AND (p_busqueda IS NULL
           OR pr.full_name ILIKE '%' || p_busqueda || '%'
           OR pr.email ILIKE '%' || p_busqueda || '%'
           OR pr.phone ILIKE '%' || p_busqueda || '%'
           OR po.description ILIKE '%' || p_busqueda || '%'
           OR po.ride_id IN (SELECT r.id FROM rides r WHERE UPPER(r.tracking_code) LIKE UPPER('%' || p_busqueda || '%')))
      AND (
        p_rol IS NULL
        OR (p_rol = 'conductor' AND pr.role = 'conductor')
        OR (p_rol = 'admin' AND pr.role IN ('super_admin', 'encargado'))
      )
  ) t
  LIMIT p_limit OFFSET p_offset;

  RETURN jsonb_build_object(
    'total', v_total,
    'items', v_items
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_admin_transactions TO authenticated;
GRANT EXECUTE ON FUNCTION public.get_admin_transactions TO service_role;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'OK: migración 045 aplicada' AS estado;
