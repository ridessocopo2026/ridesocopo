-- 123 - get_admin_rides incluye origin_barrio_name (sector real de recogida)
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
  v_caller_zone UUID;
  v_total INTEGER := 0;
  v_items JSONB;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;
  v_caller_zone := public.caller_zone_id();

  IF p_limit > 50 THEN p_limit := 50; END IF;
  IF p_limit < 1 THEN p_limit := 25; END IF;
  IF p_offset < 0 THEN p_offset := 0; END IF;

  IF p_search IS NOT NULL AND TRIM(p_search) = '' THEN
    p_search := NULL;
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM rides r
  LEFT JOIN profiles cl ON cl.id = r.client_id
  LEFT JOIN profiles dr ON dr.id = r.driver_id
  WHERE (p_search IS NOT NULL OR (r.created_at >= p_fecha_inicio AND r.created_at <= p_fecha_fin))
    AND (p_status IS NULL OR r.status::text = p_status)
    AND (v_caller_zone IS NULL OR r.origin_zone_id = v_caller_zone)
    AND (
      p_search IS NULL
      OR UPPER(r.tracking_code) LIKE UPPER('%' || p_search || '%')
      OR UPPER(cl.full_name) LIKE UPPER('%' || p_search || '%')
      OR UPPER(dr.full_name) LIKE UPPER('%' || p_search || '%')
      OR UPPER(cl.email) LIKE UPPER('%' || p_search || '%')
    );

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
      r.origin_barrio_name,
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
      AND (v_caller_zone IS NULL OR r.origin_zone_id = v_caller_zone)
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

GRANT EXECUTE ON FUNCTION public.get_admin_rides TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_admin_rides FROM anon;