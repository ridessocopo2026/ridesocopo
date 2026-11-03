-- ============================================================
-- 129 - ESTADO DEL DINERO EN CADA INCIDENTE (para el modal)
-- ------------------------------------------------------------
-- Antes el admin veía "Cargo al cliente" y "Compensación" sin
-- saber qué dinero existía realmente:
--   · Efectivo: nunca se cobró nada (no hay reembolso posible).
--   · Pago Móvil/Billetera: el fee ya quedó retenido del dinero.
--   · Y no se veía si había un cargo pendiente de verificar.
--
-- Esta migración agrega a get_admin_incidents (misma llamada, sin
-- requests extra) el estado real del dinero del viaje.
--
-- También crea el índice que faltaba en transactions(ride_id): sin
-- él, cada consulta por viaje hacía un recorrido completo de la tabla.
-- ============================================================
CREATE INDEX IF NOT EXISTS idx_transactions_ride
  ON public.transactions(ride_id);

CREATE OR REPLACE FUNCTION public.get_admin_incidents(
  p_status TEXT DEFAULT NULL,
  p_limit INTEGER DEFAULT 20,
  p_offset INTEGER DEFAULT 0
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_role TEXT;
  v_zone UUID;
  v_total INTEGER := 0;
  v_items JSONB;
BEGIN
  v_role := public.get_user_role(v_admin_id)::text;

  IF v_role IS NULL OR v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  v_zone := public.caller_zone_id();
  IF v_role = 'super_admin' THEN
    v_zone := NULL;
  END IF;

  IF p_limit IS NULL OR p_limit < 1 THEN p_limit := 20; END IF;
  IF p_limit > 50 THEN p_limit := 50; END IF;
  IF p_offset IS NULL OR p_offset < 0 THEN p_offset := 0; END IF;

  IF p_status IS NOT NULL AND BTRIM(p_status) = '' THEN
    p_status := NULL;
  END IF;

  SELECT COUNT(*) INTO v_total
  FROM ride_incidents i
  INNER JOIN rides r ON r.id = i.ride_id
  WHERE (p_status IS NULL OR i.status = p_status)
    AND (v_zone IS NULL OR r.origin_zone_id = v_zone);

  SELECT COALESCE(jsonb_agg(t ORDER BY t.created_at DESC), '[]'::jsonb)
  INTO v_items
  FROM (
    SELECT
      -- Incidente
      i.id,
      i.ride_id,
      i.reported_by,
      i.incident_type,
      i.description,
      i.photo_urls,
      i.status,
      i.resolution,
      i.resolution_details,
      i.suggested_compensation_usd,
      i.resolved_by,
      i.resolved_at,
      i.created_at,
      i.updated_at,
      -- Viaje
      r.tracking_code,
      r.status::text AS ride_status,
      r.payment_method,
      r.final_fare_usd,
      r.commission_usd,
      r.cancellation_fee_usd,
      r.driver_compensation_usd,
      r.cancelled_by,
      r.reimbursement_status,
      r.proof_status,
      r.origin_address,
      r.destination_address,
      r.client_id,
      r.driver_id,
      -- Involucrados
      cl.full_name AS client_name,
      cl.phone     AS client_phone,
      dr.full_name AS driver_name,
      dr.phone     AS driver_phone,
      rp.full_name AS reporter_name,
      rp.phone     AS reporter_phone,
      rp.role::text AS reporter_role,
      -- Estado real del dinero (una sola búsqueda por ride_id)
      COALESCE(m.charge_pending_usd, 0)  AS charge_pending_usd,
      COALESCE(m.refund_pending_usd, 0)  AS refund_pending_usd,
      COALESCE(m.refund_credited_usd, 0) AS refund_credited_usd,
      COALESCE(m.charge_waived_usd, 0)   AS charge_waived_usd
    FROM ride_incidents i
    INNER JOIN rides r ON r.id = i.ride_id
    LEFT JOIN profiles cl ON cl.id = r.client_id
    LEFT JOIN profiles dr ON dr.id = r.driver_id
    LEFT JOIN profiles rp ON rp.id = i.reported_by
    LEFT JOIN LATERAL (
      SELECT
        SUM(t.amount_usd) FILTER (WHERE t.type = 'debito'  AND t.status = 'pendiente')  AS charge_pending_usd,
        SUM(t.amount_usd) FILTER (WHERE t.type = 'credito' AND t.status = 'pendiente')  AS refund_pending_usd,
        SUM(t.amount_usd) FILTER (WHERE t.type = 'credito' AND t.status = 'completado') AS refund_credited_usd,
        SUM(t.amount_usd) FILTER (WHERE t.type = 'debito'  AND t.status = 'rechazado')  AS charge_waived_usd
      FROM transactions t
      WHERE t.ride_id = r.id
        AND (t.description LIKE 'Cargo por cancelación%' OR t.description LIKE 'Reembolso%')
    ) m ON TRUE
    WHERE (p_status IS NULL OR i.status = p_status)
      AND (v_zone IS NULL OR r.origin_zone_id = v_zone)
    ORDER BY i.created_at DESC
    LIMIT p_limit OFFSET p_offset
  ) t;

  RETURN jsonb_build_object(
    'total', v_total,
    'limit', p_limit,
    'offset', p_offset,
    'items', v_items
  );
END;
$$;

REVOKE ALL ON FUNCTION public.get_admin_incidents(text, integer, integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_admin_incidents(text, integer, integer)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_admin_incidents(text, integer, integer) FROM anon;

SELECT 'Migración 129 aplicada: estado del dinero en incidentes' AS estado;
