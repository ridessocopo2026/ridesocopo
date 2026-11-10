-- ============================================================
-- 131 - VIAJES DEL ENCARGADO: detalle limitado a su ciudad
-- ------------------------------------------------------------
-- Al habilitar el modulo "Viajes" para el encargado aparecio un hueco:
-- get_ride_full_detail permitia a CUALQUIER encargado abrir el detalle
-- de cualquier viaje solo con conocer el id (no filtraba por ciudad).
--
-- Ahora:
--   - super_admin  -> ve todo
--   - encargado    -> solo viajes con origin_zone_id = su ciudad
--   - cliente/conductor -> solo sus propios viajes (igual que antes)
--
-- Tambien se agrega 'origin_zone_id' a la respuesta.
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_ride_full_detail(p_ride_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id UUID := auth.uid();
  v_role TEXT;
  v_zone UUID;
  v_ride JSONB;
  v_transactions JSONB;
  v_incident JSONB;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT role::text INTO v_role FROM profiles WHERE id = v_user_id;
  v_zone := public.caller_zone_id();

  SELECT jsonb_build_object(
    'ride_id', r.id,
    'tracking_code', r.tracking_code,
    'status', r.status,
    'category', r.category,
    'payment_method', r.payment_method,
    'origin_address', r.origin_address,
    'destination_address', r.destination_address,
    'destination_barrio_name', r.destination_barrio_name,
    'origin_zone_id', r.origin_zone_id,
    'final_fare_usd', r.final_fare_usd,
    'commission_usd', r.commission_usd,
    'commission_rate', r.commission_rate,
    'cancellation_fee_usd', r.cancellation_fee_usd,
    'driver_compensation_usd', r.driver_compensation_usd,
    'created_at', r.created_at,
    'started_at', r.started_at,
    'completed_at', r.completed_at,
    'proof_status', r.proof_status,
    'client_id', r.client_id,
    'driver_id', r.driver_id
  ) INTO v_ride
  FROM rides r
  WHERE r.id = p_ride_id;

  IF v_ride IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF v_role = 'encargado' THEN
    IF v_zone IS NOT NULL
       AND (v_ride->>'origin_zone_id')::uuid IS DISTINCT FROM v_zone THEN
      RAISE EXCEPTION 'No autorizado para viajes de otra ciudad';
    END IF;
  ELSIF v_role IS DISTINCT FROM 'super_admin' THEN
    IF NOT (v_ride->>'client_id')::uuid = v_user_id
       AND NOT (v_ride->>'driver_id')::uuid = v_user_id THEN
      RAISE EXCEPTION 'No autorizado';
    END IF;
  END IF;

  SELECT COALESCE(jsonb_agg(t), '[]'::jsonb)
  INTO v_transactions
  FROM (
    SELECT
      t.id,
      t.type::text AS tipo,
      t.amount_usd AS monto,
      t.status::text AS estado,
      t.description AS descripcion,
      t.created_at AS fecha,
      pr.full_name AS usuario,
      pr.role AS rol
    FROM transactions t
    LEFT JOIN profiles pr ON pr.id = t.user_id
    WHERE t.ride_id = p_ride_id
    ORDER BY t.created_at ASC
  ) t;

  SELECT jsonb_build_object(
    'incident_id', ri.id,
    'incident_type', ri.incident_type,
    'description', ri.description,
    'status', ri.status,
    'resolution', ri.resolution,
    'resolution_details', ri.resolution_details,
    'created_at', ri.created_at
  ) INTO v_incident
  FROM ride_incidents ri
  WHERE ri.ride_id = p_ride_id
  ORDER BY ri.created_at DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'ride', v_ride,
    'transacciones', v_transactions,
    'incidente', COALESCE(v_incident, NULL)
  );
END;
$function$;

REVOKE ALL ON FUNCTION public.get_ride_full_detail(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_ride_full_detail(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_ride_full_detail(uuid) FROM anon;

SELECT 'Migracion 131 aplicada: detalle de viaje limitado a la ciudad del encargado' AS estado;