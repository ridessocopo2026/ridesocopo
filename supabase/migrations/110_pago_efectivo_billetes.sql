-- ============================================================
-- BUNRIDER - Migración 110: PAGO EN EFECTIVO CON BILLETES
-- ------------------------------------------------------------
-- El pasajero que paga en efectivo indica con qué billete(s)
-- pagará, para que el conductor sepa ANTES de aceptar si debe
-- llevar vuelto.
--
--   1) rides.cash_bills (jsonb, nullable)
--        {"b":{"20":1,"5":1}}  -> billetes (denominación: cantidad)
--        {"x":true}            -> pago exacto (no requiere vuelto)
--        NULL                  -> no aplica (billetera / pago móvil)
--   2) request_ride acepta p_cash_bills (DEFAULT NULL):
--      100% retrocompatible — quien no lo envía no nota nada.
--   3) Validación en servidor (nunca se confía en el cliente) y
--      texto informativo en la notificación al conductor.
--
-- COSTO: ~50 bytes por viaje EN EFECTIVO. Sin tablas ni índices
-- nuevos y sin consultas adicionales: el dato viaja en la misma
-- llamada que el cliente ya hacía.
--
-- ROLLBACK:
--   ALTER TABLE public.rides DROP COLUMN IF EXISTS cash_bills;
--   y recrear request_ride con sus 9 argumentos anteriores.
-- ============================================================

-- ============================================================
-- 1. COLUMNA
-- ============================================================
ALTER TABLE public.rides ADD COLUMN IF NOT EXISTS cash_bills jsonb;

COMMENT ON COLUMN public.rides.cash_bills IS
'Pago en efectivo: {"b":{"20":1,"5":1}} billetes (denominación: cantidad) o {"x":true} pago exacto. NULL si no aplica.';

-- Tope de tamaño: corta payloads basura sin validar la forma en cada insert
ALTER TABLE public.rides DROP CONSTRAINT IF EXISTS rides_cash_bills_size;
ALTER TABLE public.rides
  ADD CONSTRAINT rides_cash_bills_size
  CHECK (cash_bills IS NULL OR pg_column_size(cash_bills) <= 256);

-- ============================================================
-- 2. REQUEST_RIDE con billetes de efectivo
-- ============================================================
-- Hay que soltar la versión de 9 argumentos: si se deja, Postgres
-- no sabría cuál elegir al llamar con 9 parámetros (ambigüedad).
DROP FUNCTION IF EXISTS public.request_ride(
  numeric, numeric, text, numeric, numeric, text, vehicle_category, text, text
);

CREATE FUNCTION public.request_ride(
  p_origin_lat numeric,
  p_origin_lng numeric,
  p_origin_address text,
  p_dest_lat numeric,
  p_dest_lng numeric,
  p_dest_address text,
  p_category vehicle_category,
  p_payment_method text DEFAULT 'efectivo'::text,
  p_coupon_code text DEFAULT NULL::text,
  p_cash_bills jsonb DEFAULT NULL::jsonb
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
DECLARE
  v_user_id UUID := auth.uid();
  v_fare JSONB;
  v_ride_id UUID;
  v_final_fare NUMERIC;
  v_wallet RECORD;
  v_is_wallet BOOLEAN;
  v_cash JSONB;
  v_cash_total NUMERIC;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('request_ride', 15);

  v_fare := public.calculate_fare(
    p_origin_lat, p_origin_lng,
    p_dest_lat, p_dest_lng,
    p_category, p_coupon_code
  );

  IF NOT EXISTS (SELECT 1 FROM payment_methods WHERE name = p_payment_method AND is_active = TRUE) THEN
    RAISE EXCEPTION 'Método de pago no disponible';
  END IF;

  -- ¿Hay algún conductor que pueda tomarlo AHORA?
  -- (mismo criterio que get_available_driver_counts). Si no hay,
  -- se rechaza ANTES de crear el viaje y de debitar la billetera.
  IF NOT EXISTS (
    SELECT 1
    FROM profiles p
    WHERE p.role = 'conductor'
      AND p.driver_status = 'aprobado'
      AND p.is_online = TRUE
      AND (p.zone_id IS NULL OR p.zone_id = (v_fare->>'origin_zone_id')::uuid)
      AND EXISTS (
        SELECT 1 FROM vehicles v
        WHERE v.driver_id = p.id
          AND v.category = p_category
          AND v.is_approved = TRUE
          AND v.is_active_vehicle = TRUE
      )
      AND NOT EXISTS (
        SELECT 1 FROM rides r
        WHERE r.driver_id = p.id
          AND r.status IN ('aceptada', 'en_ruta', 'incidente')
      )
  ) THEN
    RAISE EXCEPTION 'No hay vehículos disponibles ahora. Elige otro vehículo o intenta más tarde.';
  END IF;

  v_final_fare := (v_fare->>'final_fare')::NUMERIC;
  v_is_wallet := (p_payment_method = 'Billetera');

  -- ============================================================
  -- BILLETES DE EFECTIVO (solo Efectivo; cualquier otro método
  -- ignora el parámetro para no guardar datos sin sentido)
  -- ============================================================
  IF p_cash_bills IS NOT NULL AND p_payment_method = 'Efectivo' THEN
    IF jsonb_typeof(p_cash_bills) <> 'object' THEN
      RAISE EXCEPTION 'Datos de efectivo inválidos';
    END IF;

    IF p_cash_bills ? 'x' THEN
      -- Pago exacto: sin billetes, no requiere vuelto
      IF (p_cash_bills ? 'b') OR COALESCE((p_cash_bills->>'x')::BOOLEAN, FALSE) IS NOT TRUE THEN
        RAISE EXCEPTION 'Datos de efectivo inválidos';
      END IF;
      v_cash := jsonb_build_object('x', TRUE);

    ELSIF p_cash_bills ? 'b' THEN
      IF jsonb_typeof(p_cash_bills->'b') <> 'object' THEN
        RAISE EXCEPTION 'Billetes inválidos';
      END IF;

      -- Denominaciones 1..100000 y cantidades 1..20, sin claves raras
      IF EXISTS (
        SELECT 1
        FROM jsonb_each_text(p_cash_bills->'b') AS e(k, v)
        WHERE k !~ '^[0-9]{1,6}$'
           OR v !~ '^[0-9]{1,2}$'
           OR (k::NUMERIC < 1 OR k::NUMERIC > 100000)
           OR (v::INT < 1 OR v::INT > 20)
      ) THEN
        RAISE EXCEPTION 'Billetes inválidos';
      END IF;

      SELECT COALESCE(SUM(k::NUMERIC * v::NUMERIC), 0)
      INTO v_cash_total
      FROM jsonb_each_text(p_cash_bills->'b') AS e(k, v);

      IF v_cash_total <= 0 THEN
        RAISE EXCEPTION 'Billetes inválidos';
      END IF;

      IF v_cash_total < v_final_fare THEN
        RAISE EXCEPTION USING
          MESSAGE = format('El monto entregado ($%s) no cubre la tarifa ($%s)', v_cash_total, v_final_fare);
      END IF;

      v_cash := jsonb_build_object('b', p_cash_bills->'b');

    ELSE
      RAISE EXCEPTION 'Elige los billetes o marca pago exacto';
    END IF;
  END IF;

  -- ============================================================
  -- BILLETERA: validar saldo y DEBITAR (FOR UPDATE anti TOCTOU)
  -- ============================================================
  IF v_is_wallet THEN
    SELECT * INTO v_wallet
    FROM wallets
    WHERE user_id = v_user_id
    FOR UPDATE;

    IF v_wallet.id IS NULL THEN
      RAISE EXCEPTION 'Billetera no encontrada';
    END IF;

    IF v_wallet.balance_usd < v_final_fare THEN
      RAISE EXCEPTION USING MESSAGE = format('Saldo insuficiente en billetera. Necesitas $%s y tienes $%s', v_final_fare, v_wallet.balance_usd);
    END IF;

    UPDATE wallets
    SET balance_usd = balance_usd - v_final_fare,
        updated_at = NOW()
    WHERE user_id = v_user_id;

    INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description)
    VALUES (v_wallet.id, v_user_id, 'debito', v_final_fare, 'completado',
            'Pago de viaje con billetera');
  END IF;

  INSERT INTO rides (
    client_id, category,
    origin_lat, origin_lng, origin_address, origin_zone_id,
    destination_lat, destination_lng, destination_address, destination_zone_id,
    destination_barrio_id, destination_barrio_name,
    base_fare_usd, origin_surcharge_usd, destination_surcharge_usd,
    total_fare_usd, coupon_id, discount_usd, final_fare_usd,
    payment_method, status, cash_bills
  ) VALUES (
    v_user_id, p_category,
    p_origin_lat, p_origin_lng, p_origin_address, (v_fare->>'origin_zone_id')::UUID,
    p_dest_lat, p_dest_lng, p_dest_address, (v_fare->>'destination_zone_id')::UUID,
    (v_fare->>'destination_barrio_id')::UUID,
    v_fare->>'destination_barrio_name',
    (v_fare->>'base_fare')::NUMERIC,
    (v_fare->>'origin_surcharge')::NUMERIC,
    (v_fare->>'destination_surcharge')::NUMERIC,
    (v_fare->>'total_fare')::NUMERIC,
    (v_fare->>'coupon_id')::UUID,
    (v_fare->>'discount')::NUMERIC,
    v_final_fare,
    p_payment_method, 'buscando', v_cash
  ) RETURNING id INTO v_ride_id;

  IF (v_fare->>'coupon_id') IS NOT NULL THEN
    PERFORM public.redeem_coupon(
      (v_fare->>'coupon_id')::UUID,
      v_user_id,
      v_ride_id,
      (v_fare->>'discount')::NUMERIC
    );
  END IF;

  -- Notificar SOLO a conductores LIBRES y disponibles de la MISMA ciudad.
  -- El texto incluye el efectivo esperado (sin consultas extra).
  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT p.id, 'Nuevo viaje disponible',
         CONCAT(
           'Viaje de ', v_fare->>'final_fare', '$ en ', p_category, '. ¿Lo aceptas?',
           CASE
             WHEN v_cash IS NULL THEN ''
             WHEN v_cash ? 'x' THEN ' · pago exacto'
             ELSE ' · efectivo: ' || replace(to_char(v_cash_total, 'FM999999990.00'), '.', ',') || '$'
                  || CASE
                       WHEN v_cash_total > v_final_fare
                       THEN ' (vuelto ' || replace(to_char(v_cash_total - v_final_fare, 'FM999999990.00'), '.', ',') || '$)'
                       ELSE ''
                     END
           END
         ),
         'ride_available',
         jsonb_build_object('ride_id', v_ride_id, 'category', p_category,
                            'fare', (v_fare->>'final_fare')::NUMERIC,
                            'cash_total', v_cash_total,
                            'url', '/conductor')
  FROM profiles p
  WHERE p.role = 'conductor'
    AND p.driver_status = 'aprobado'
    AND p.is_online = TRUE
    AND (p.zone_id IS NULL OR p.zone_id = (v_fare->>'origin_zone_id')::uuid)
    AND p.id IN (
      SELECT v.driver_id FROM vehicles v
      WHERE v.is_approved = TRUE
        AND v.is_active_vehicle = TRUE
        AND v.category = p_category
    )
    AND NOT EXISTS (
      SELECT 1 FROM rides r
      WHERE r.driver_id = p.id
        AND r.status IN ('aceptada', 'en_ruta', 'incidente')
    )
  ORDER BY p.updated_at DESC
  LIMIT 25;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_user_id, 'REQUEST_RIDE', 'ride', v_ride_id,
          jsonb_build_object('fare', v_fare, 'wallet_debited', v_is_wallet, 'cash_bills', v_cash));

  RETURN v_ride_id;
END;
$function$;

-- ============================================================
-- 3. PERMISOS (el DROP los borra: hay que volver a darlos)
-- ============================================================
GRANT EXECUTE ON FUNCTION public.request_ride(
  numeric, numeric, text, numeric, numeric, text, vehicle_category, text, text, jsonb
) TO authenticated, service_role;

REVOKE ALL ON FUNCTION public.request_ride(
  numeric, numeric, text, numeric, numeric, text, vehicle_category, text, text, jsonb
) FROM anon, public;

-- ============================================================
-- 4. VERIFICACIÓN
-- ============================================================
SELECT 'columna cash_bills' AS comprobacion,
       (SELECT count(*) = 1 FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name = 'rides' AND column_name = 'cash_bills')::text AS valor
UNION ALL
SELECT 'request_ride con p_cash_bills',
       (SELECT count(*) = 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.proname = 'request_ride'
          AND pg_get_function_identity_arguments(p.oid) LIKE '%p_cash_bills%')::text
UNION ALL
SELECT 'authenticated puede ejecutarla',
       (SELECT has_function_privilege('authenticated',
          'public.request_ride(numeric, numeric, text, numeric, numeric, text, vehicle_category, text, text, jsonb)',
          'EXECUTE'))::text;
