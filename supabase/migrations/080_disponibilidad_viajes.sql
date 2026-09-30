-- ============================================================
-- BUNRIDER - Migración 080: DISPONIBILIDAD DE CONDUCTORES
-- ------------------------------------------------------------
-- QUÉ ARREGLA
--   1) Un conductor CON VIAJE ACTIVO ya no recibe ofertas ni
--      puede aceptar otro viaje (antes podía terminar con dos
--      viajes activos a la vez).
--   2) La oferta se envía EXACTAMENTE al mismo conjunto que el
--      cliente ve en el conteo (vehículo aprobado + activo, y
--      sin viaje en curso). Antes el conteo exigía
--      is_approved + is_active_vehicle y la oferta solo is_active
--      → el cliente veía "0 disponibles" y aun así salían ofertas.
--   3) request_ride / request_ride_with_proof comprueban que haya
--      algún conductor que pueda tomarlo ANTES de crear el viaje
--      y de debitar la billetera → nunca queda un viaje huérfano
--      ni dinero retenido sin conductor.
--   4) BUG GRAVE en approve_ride_proof: filtraba con
--      driver_has_vehicle_for_category(v_category), un helper que
--      mira auth.uid() (¡el ADMIN!), así que la condición era
--      SIEMPRE FALSE y NO se notificaba a ningún conductor al
--      aprobar un comprobante de Pago Móvil.
--   5) expire_unassigned_rides(): los viajes en 'buscando' sin
--      conductor se cancelan solos a los 10 minutos. Si pagó con
--      Billetera SE LE DEVUELVE EL DINERO AL INSTANTE (el débito
--      ocurre al crear el viaje y nunca hubo conductor). Se libera
--      el cupón y se borran las ofertas pendientes.
--      El cron de 5 minutos que YA existe (bunrider-availability-
--      reminders) pasa a llamar también a esta función: coste 0.
--
-- NO SE TOCA
--   · cancel_ride ni su flujo de reembolso manual.
--   · El débito de la billetera al crear el viaje.
--   · Cupones, pruebas de pago, confirmaciones ni comisiones.
-- ============================================================

-- ============================================================
-- 1. ACCEPT_RIDE: un conductor ocupado no puede aceptar otro viaje
-- ============================================================
CREATE OR REPLACE FUNCTION public.accept_ride(p_ride_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_ride RECORD;
  v_wallet RECORD;
  v_commission NUMERIC;
  v_vehicle RECORD;
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('accept_ride', 30);

  SELECT driver_status INTO v_ride FROM profiles WHERE id = v_driver_id;
  IF v_ride.driver_status != 'aprobado' THEN
    RAISE EXCEPTION 'Conductor no aprobado';
  END IF;

  -- 🔒 Ya está en un viaje: no puede tomar otro (mismo criterio
  --    de "ocupado" que el conteo de disponibles)
  IF EXISTS (
    SELECT 1 FROM rides r
    WHERE r.driver_id = v_driver_id
      AND r.status IN ('aceptada', 'en_ruta', 'incidente')
  ) THEN
    RAISE EXCEPTION 'Ya tienes un viaje en curso. Finalízalo antes de aceptar otro.';
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id AND status = 'buscando';
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no disponible';
  END IF;

  IF v_ride.proof_status = 'pendiente' THEN
    RAISE EXCEPTION 'Este viaje aún no está disponible. Esperando aprobación del pago.';
  END IF;

  SELECT * INTO v_vehicle FROM vehicles
  WHERE driver_id = v_driver_id AND category = v_ride.category AND is_active = TRUE
  LIMIT 1;

  IF v_vehicle.id IS NULL THEN
    RAISE EXCEPTION 'No tiene un vehículo activo de la categoría requerida';
  END IF;

  -- Comisión sobre el TOTAL del viaje (sin descontar cupones)
  v_commission := ROUND(COALESCE(v_ride.total_fare_usd, v_ride.final_fare_usd, 0) * v_ride.commission_rate / 100, 2);

  UPDATE rides
  SET driver_id = v_driver_id,
      vehicle_id = v_vehicle.id,
      commission_usd = v_commission,
      status = 'aceptada',
      started_at = NOW()
  WHERE id = p_ride_id;

  PERFORM public.notify_user(
    v_ride.client_id,
    'Conductor asignado',
    'Un conductor ha aceptado tu viaje',
    'ride_accepted',
    jsonb_build_object('ride_id', p_ride_id, 'url', '/cliente/viaje/' || p_ride_id)
  );

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_driver_id, 'ACCEPT_RIDE', 'ride', p_ride_id,
          jsonb_build_object('commission', v_commission, 'final_fare', v_ride.final_fare_usd));

  RETURN jsonb_build_object(
    'success', TRUE,
    'ride_id', p_ride_id,
    'commission', v_commission
  );
END;
$$;

-- ============================================================
-- 2. GET_AVAILABLE_DRIVER_COUNTS: además de los disponibles,
--    cuántos están OCUPADOS (para poder decir "todos en viaje")
-- ============================================================
DROP FUNCTION IF EXISTS public.get_available_driver_counts(uuid);

CREATE OR REPLACE FUNCTION public.get_available_driver_counts(p_zone_id uuid DEFAULT NULL)
RETURNS TABLE(category text, available integer, busy integer)
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT c.name::TEXT AS category,
         (
           SELECT COUNT(*)::INTEGER
           FROM public.profiles p
           WHERE p.role = 'conductor'
             AND p.driver_status = 'aprobado'
             AND (p_zone_id IS NULL OR p.zone_id IS NULL OR p.zone_id = p_zone_id)
             AND public.driver_available_now(p.id)
             AND EXISTS (
               SELECT 1 FROM public.vehicles v
               WHERE v.driver_id = p.id
                 AND v.category = c.name
                 AND v.is_approved = TRUE
                 AND v.is_active_vehicle = TRUE
             )
             AND NOT EXISTS (
               SELECT 1 FROM public.rides r
               WHERE r.driver_id = p.id
                 AND r.status IN ('aceptada', 'en_ruta', 'incidente')
             )
         ) AS available,
         (
           SELECT COUNT(*)::INTEGER
           FROM public.profiles b
           WHERE b.role = 'conductor'
             AND b.driver_status = 'aprobado'
             AND (p_zone_id IS NULL OR b.zone_id IS NULL OR b.zone_id = p_zone_id)
             AND EXISTS (
               SELECT 1 FROM public.vehicles v
               WHERE v.driver_id = b.id
                 AND v.category = c.name
                 AND v.is_approved = TRUE
                 AND v.is_active_vehicle = TRUE
             )
             AND EXISTS (
               SELECT 1 FROM public.rides r
               WHERE r.driver_id = b.id
                 AND r.status IN ('aceptada', 'en_ruta', 'incidente')
             )
         ) AS busy
  FROM public.vehicle_categories c
  WHERE c.is_active = TRUE
  ORDER BY c.base_fare_usd;
$$;

GRANT EXECUTE ON FUNCTION public.get_available_driver_counts(uuid) TO anon, authenticated, service_role;

-- ============================================================
-- 3. REQUEST_RIDE: comprobar que hay conductor ANTES de crear el
--    viaje y de debitar la billetera + ofertas al conjunto correcto
-- ============================================================
CREATE OR REPLACE FUNCTION public.request_ride(
  p_origin_lat numeric,
  p_origin_lng numeric,
  p_origin_address text,
  p_dest_lat numeric,
  p_dest_lng numeric,
  p_dest_address text,
  p_category vehicle_category,
  p_payment_method text DEFAULT 'efectivo'::text,
  p_coupon_code text DEFAULT NULL::text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_fare JSONB;
  v_ride_id UUID;
  v_final_fare NUMERIC;
  v_wallet RECORD;
  v_is_wallet BOOLEAN;
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

  -- 🔒 ¿Hay algún conductor que pueda tomarlo AHORA?
  --    (mismo criterio que get_available_driver_counts). Si no hay,
  --    se rechaza ANTES de crear el viaje y de debitar la billetera.
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

  -- Billetera: validar saldo y DEBITAR (FOR UPDATE anti TOCTOU)
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
    payment_method, status
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
    p_payment_method, 'buscando'
  ) RETURNING id INTO v_ride_id;

  -- Canjear el cupón de forma atómica (si falla, todo el viaje se revierte)
  IF (v_fare->>'coupon_id') IS NOT NULL THEN
    PERFORM public.redeem_coupon(
      (v_fare->>'coupon_id')::UUID,
      v_user_id,
      v_ride_id,
      (v_fare->>'discount')::NUMERIC
    );
  END IF;

  -- Notificar SOLO a conductores LIBRES y disponibles de la MISMA ciudad
  -- (vehículo aprobado y activo; sin viaje en curso: mismo criterio que el conteo)
  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT p.id, 'Nuevo viaje disponible',
         CONCAT('Viaje de ', v_fare->>'final_fare', '$ en ', p_category, '. ¿Lo aceptas?'),
         'ride_available',
         jsonb_build_object('ride_id', v_ride_id, 'category', p_category,
                            'fare', (v_fare->>'final_fare')::NUMERIC,
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
          jsonb_build_object('fare', v_fare, 'wallet_debited', v_is_wallet));

  RETURN v_ride_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_ride(numeric, numeric, text, numeric, numeric, text, vehicle_category, text, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.request_ride(numeric, numeric, text, numeric, numeric, text, vehicle_category, text, text) FROM anon;

-- ============================================================
-- 4. REQUEST_RIDE_WITH_PROOF
--    - Con comprobante (Pago Móvil): el viaje espera la aprobación
--      del admin, así que NO se exige conductor en ese momento.
--    - Sin comprobante: se exige conductor igual que request_ride.
--    - Ofertas al mismo conjunto que el conteo (libres y con
--      vehículo aprobado/activo).
-- ============================================================
CREATE OR REPLACE FUNCTION public.request_ride_with_proof(
  p_origin_lat numeric,
  p_origin_lng numeric,
  p_origin_address text,
  p_dest_lat numeric,
  p_dest_lng numeric,
  p_dest_address text,
  p_category vehicle_category,
  p_payment_method text,
  p_proof_url text,
  p_coupon_code text DEFAULT NULL::text
)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_fare JSONB;
  v_ride_id UUID;
  v_proof_required BOOLEAN;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  PERFORM public.guard_rate_limit('request_ride_with_proof', 15);

  SELECT proof_required INTO v_proof_required
  FROM payment_methods WHERE name = p_payment_method AND is_active = TRUE;

  IF v_proof_required IS NULL THEN
    RAISE EXCEPTION 'Método de pago no disponible';
  END IF;

  IF v_proof_required AND (p_proof_url IS NULL OR p_proof_url = '') THEN
    RAISE EXCEPTION 'Debes subir el comprobante del pago';
  END IF;

  v_fare := public.calculate_fare(
    p_origin_lat, p_origin_lng,
    p_dest_lat, p_dest_lng,
    p_category, p_coupon_code
  );

  -- 🔒 Solo cuando el viaje sale a buscar conductor de inmediato
  --    (si requiere comprobante, primero lo revisa el admin)
  IF NOT v_proof_required AND NOT EXISTS (
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

  INSERT INTO rides (
    client_id, category,
    origin_lat, origin_lng, origin_address, origin_zone_id,
    destination_lat, destination_lng, destination_address, destination_zone_id,
    destination_barrio_id, destination_barrio_name,
    base_fare_usd, origin_surcharge_usd, destination_surcharge_usd,
    total_fare_usd, coupon_id, discount_usd, final_fare_usd,
    payment_method, status, proof_url, proof_status
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
    (v_fare->>'final_fare')::NUMERIC,
    p_payment_method, 'buscando',
    CASE WHEN v_proof_required THEN p_proof_url ELSE NULL END,
    CASE WHEN v_proof_required THEN 'pendiente' ELSE 'aprobado' END
  ) RETURNING id INTO v_ride_id;

  -- Canjear el cupón de forma atómica
  IF (v_fare->>'coupon_id') IS NOT NULL THEN
    PERFORM public.redeem_coupon(
      (v_fare->>'coupon_id')::UUID,
      v_user_id,
      v_ride_id,
      (v_fare->>'discount')::NUMERIC
    );
  END IF;

  IF v_proof_required THEN
    INSERT INTO notifications (user_id, title, body, type, data)
    SELECT id, 'Comprobante por aprobar',
           'Nuevo comprobante de pago pendiente de revisión para un viaje',
           'proof_pending',
           jsonb_build_object('ride_id', v_ride_id, 'url', '/admin/comprobantes')
    FROM profiles WHERE role IN ('super_admin', 'encargado');
  ELSE
    INSERT INTO notifications (user_id, title, body, type, data)
    SELECT p.id, 'Nuevo viaje disponible',
           CONCAT('Viaje de ', v_fare->>'final_fare', '$ en ', p_category, '. ¿Lo aceptas?'),
           'ride_available',
           jsonb_build_object('ride_id', v_ride_id, 'category', p_category,
                              'fare', (v_fare->>'final_fare')::NUMERIC,
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
  END IF;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_user_id, 'REQUEST_RIDE_WITH_PROOF', 'ride', v_ride_id,
          jsonb_build_object('fare', v_fare, 'proof_required', v_proof_required));

  RETURN v_ride_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.request_ride_with_proof(numeric, numeric, text, numeric, numeric, text, vehicle_category, text, text, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.request_ride_with_proof(numeric, numeric, text, numeric, numeric, text, vehicle_category, text, text, text) FROM anon;

-- ============================================================
-- 5. APPROVE_RIDE_PROOF: corregido el filtro de la oferta
--    (usaba driver_has_vehicle_for_category → auth.uid() = el
--     ADMIN → siempre FALSE → NO notificaba a nadie)
-- ============================================================
CREATE OR REPLACE FUNCTION public.approve_ride_proof(p_ride_id uuid, p_approve boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_ride RECORD;
  v_status TEXT;
  v_wallet RECORD;
  v_app_credit NUMERIC := 0.00;
  v_commission NUMERIC := 0.00;
  v_earning RECORD;
  v_fare NUMERIC;
  v_category vehicle_category;
BEGIN
  IF v_admin_id IS NULL OR public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('approve_ride_proof', 30);

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id FOR UPDATE;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF public.get_user_role(v_admin_id) = 'encargado'
     AND COALESCE(v_ride.origin_zone_id, '00000000-0000-0000-0000-000000000000') != public.caller_zone_id() THEN
    RAISE EXCEPTION 'No autorizado para viajes de otra ciudad';
  END IF;

  IF v_ride.proof_status != 'pendiente' THEN
    RAISE EXCEPTION 'El comprobante ya fue procesado';
  END IF;

  v_status := CASE WHEN p_approve THEN 'aprobado' ELSE 'rechazado' END;
  v_fare := v_ride.final_fare_usd;
  v_category := v_ride.category;

  UPDATE rides SET proof_status = v_status WHERE id = p_ride_id;

  IF p_approve THEN
    IF v_ride.status = 'buscando' THEN
      -- Oferta a los conductores que realmente pueden tomarlo:
      -- aprobados, en línea, con vehículo aprobado y activo de la
      -- categoría, de la MISMA ciudad y SIN viaje en curso.
      INSERT INTO notifications (user_id, title, body, type, data)
      SELECT p.id, 'Nuevo viaje disponible',
             CONCAT('Viaje de ', v_fare, '$ en ', v_category, '. ¿Lo aceptas?'),
             'ride_available',
             jsonb_build_object('ride_id', p_ride_id, 'category', v_category,
                                'fare', v_fare, 'url', '/conductor')
      FROM profiles p
      WHERE p.role = 'conductor'
        AND p.driver_status = 'aprobado'
        AND p.is_online = TRUE
        AND (p.zone_id IS NULL OR p.zone_id = v_ride.origin_zone_id)
        AND EXISTS (
          SELECT 1 FROM vehicles v
          WHERE v.driver_id = p.id
            AND v.category = v_category
            AND v.is_approved = TRUE
            AND v.is_active_vehicle = TRUE
        )
        AND NOT EXISTS (
          SELECT 1 FROM rides r
          WHERE r.driver_id = p.id
            AND r.status IN ('aceptada', 'en_ruta', 'incidente')
        )
      ORDER BY p.updated_at DESC
      LIMIT 25;
    END IF;

    IF v_ride.status = 'completada' AND v_ride.driver_id IS NOT NULL THEN
      v_commission := COALESCE(v_ride.commission_usd, 0);
      v_app_credit := GREATEST(COALESCE(v_ride.total_fare_usd, v_ride.final_fare_usd, 0) - v_commission, 0);

      SELECT * INTO v_earning FROM driver_earnings WHERE ride_id = p_ride_id;

      IF v_earning.id IS NOT NULL THEN
        UPDATE driver_earnings
        SET cash_received_usd = 0,
            app_credit_usd = v_app_credit,
            status = 'completado'
        WHERE ride_id = p_ride_id;
      ELSE
        INSERT INTO driver_earnings (
          ride_id, driver_id, fare_usd, commission_usd,
          cash_received_usd, app_credit_usd, payment_method, status
        ) VALUES (
          p_ride_id, v_ride.driver_id, COALESCE(v_ride.total_fare_usd, v_ride.final_fare_usd, 0), v_commission,
          0, v_app_credit, v_ride.payment_method, 'completado'
        );
      END IF;

      IF v_app_credit > 0 AND NOT EXISTS (
        SELECT 1 FROM transactions t
        WHERE t.ride_id = p_ride_id AND t.type = 'credito' AND t.user_id = v_ride.driver_id
      ) THEN
        SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.driver_id;
        IF v_wallet.id IS NOT NULL THEN
          UPDATE wallets
          SET balance_usd = balance_usd + v_app_credit,
              updated_at = NOW()
          WHERE user_id = v_ride.driver_id;

          INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
          VALUES (v_wallet.id, v_ride.driver_id, 'credito', v_app_credit, 'completado',
                  'Ganancia del viaje por Pago Móvil (comprobante aprobado)', p_ride_id);
        END IF;
      END IF;
    END IF;
  END IF;

  INSERT INTO notifications (user_id, title, body, type, data)
  VALUES (
    v_ride.client_id,
    CASE WHEN p_approve THEN 'Comprobante aprobado' ELSE 'Comprobante rechazado' END,
    CASE WHEN p_approve THEN 'Tu pago fue aprobado. El viaje ya está disponible para conductores.'
         ELSE 'Tu comprobante fue rechazado. Sube uno válido.' END,
    'proof_reviewed',
    jsonb_build_object('ride_id', p_ride_id, 'approved', p_approve)
  );

  IF NOT p_approve AND v_ride.status = 'buscando' THEN
    UPDATE rides SET status = 'cancelada',
                     cancelled_by = v_admin_id,
                     cancel_reason = 'Comprobante rechazado',
                     updated_at = NOW()
    WHERE id = p_ride_id;

    IF v_ride.coupon_id IS NOT NULL THEN
      DELETE FROM coupon_redemptions WHERE ride_id = p_ride_id;
      UPDATE coupons SET used_count = GREATEST(used_count - 1, 0), updated_at = NOW()
      WHERE id = v_ride.coupon_id;
    END IF;

    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (v_ride.client_id, 'Viaje cancelado',
            'Tu viaje fue cancelado porque el comprobante fue rechazado. Solicita de nuevo con un pago válido.',
            'ride_cancelled', jsonb_build_object('ride_id', p_ride_id));
  END IF;

  -- 📝 Auditoría
  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_admin_id, 'APPROVE_RIDE_PROOF', 'ride', p_ride_id,
          jsonb_build_object('approved', p_approve, 'status', v_status,
                             'fare', v_fare, 'zone_id', v_ride.origin_zone_id,
                             'driver_id', v_ride.driver_id, 'client_id', v_ride.client_id));

  RETURN jsonb_build_object('success', TRUE, 'proof_status', v_status);
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_ride_proof(uuid, boolean) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.approve_ride_proof(uuid, boolean) FROM anon;

-- ============================================================
-- 6. EXPIRE_UNASSIGNED_RIDES: viajes 'buscando' sin conductor
--    Se cancelan solos (10 min por defecto). Con Billetera se
--    devuelve el dinero AL INSTANTE (se debitó al crear el viaje
--    y nunca hubo conductor).
-- ============================================================
CREATE OR REPLACE FUNCTION public.expire_unassigned_rides(p_minutes INTEGER DEFAULT 10)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_ride RECORD;
  v_wallet RECORD;
  v_total INTEGER := 0;
  v_refunded INTEGER := 0;
  v_pending INTEGER := 0;
  v_cutoff TIMESTAMPTZ := NOW() - (GREATEST(COALESCE(p_minutes, 10), 1) || ' minutes')::INTERVAL;
BEGIN
  -- Solo el sistema (cron/service_role) o un super_admin
  IF auth.uid() IS NOT NULL AND public.get_user_role(auth.uid()) != 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  FOR v_ride IN
    SELECT id, client_id, coupon_id, final_fare_usd, payment_method, proof_status
    FROM rides
    WHERE status = 'buscando'
      AND driver_id IS NULL
      AND created_at < v_cutoff
    ORDER BY created_at
    LIMIT 200
    FOR UPDATE SKIP LOCKED
  LOOP
    v_total := v_total + 1;

    IF LOWER(COALESCE(v_ride.payment_method, '')) IN ('billetera', 'wallet')
       AND v_ride.final_fare_usd > 0 THEN
      -- La billetera se debitó al crear el viaje y nunca hubo conductor:
      -- se devuelve al instante (nadie se quedó con ese dinero)
      SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.client_id FOR UPDATE;
      IF v_wallet.id IS NOT NULL THEN
        UPDATE wallets
        SET balance_usd = balance_usd + v_ride.final_fare_usd,
            updated_at = NOW()
        WHERE id = v_wallet.id;

        INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
        VALUES (v_wallet.id, v_ride.client_id, 'credito', v_ride.final_fare_usd, 'completado',
                'Reembolso automático: no hubo conductor disponible', v_ride.id);
      END IF;
      v_refunded := v_refunded + 1;

      UPDATE rides
      SET status = 'cancelada',
          cancel_reason = 'Sin conductor disponible (reembolso automático)',
          reimbursement_status = 'auto_completado',
          cancellation_fee_usd = 0,
          driver_compensation_usd = 0,
          updated_at = NOW()
      WHERE id = v_ride.id;

      PERFORM public.notify_user(
        v_ride.client_id,
        'Sin conductor disponible',
        'No encontramos conductor para tu viaje y te devolvimos $' || v_ride.final_fare_usd || ' a tu billetera.',
        'ride_expired',
        jsonb_build_object('ride_id', v_ride.id, 'refund', v_ride.final_fare_usd, 'url', '/cliente/billetera')
      );

    ELSIF v_ride.proof_status = 'aprobado' AND v_ride.final_fare_usd > 0 THEN
      -- Pago Móvil ya cobrado (el dinero entró al banco): reembolso
      -- manual, igual que hace cancel_ride
      SELECT * INTO v_wallet FROM wallets WHERE user_id = v_ride.client_id;
      IF v_wallet.id IS NOT NULL THEN
        INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
        VALUES (v_wallet.id, v_ride.client_id, 'credito', v_ride.final_fare_usd, 'pendiente',
                'Reembolso pendiente: no hubo conductor disponible', v_ride.id);

        INSERT INTO notifications (user_id, title, body, type, data)
        SELECT id, 'Reembolso pendiente',
               CONCAT('Reembolsar $', v_ride.final_fare_usd, ' (viaje sin conductor)'),
               'refund_pending',
               jsonb_build_object('ride_id', v_ride.id, 'amount', v_ride.final_fare_usd, 'url', '/admin/transacciones')
        FROM profiles WHERE role IN ('super_admin', 'encargado');
      END IF;
      v_pending := v_pending + 1;

      UPDATE rides
      SET status = 'cancelada',
          cancel_reason = 'Sin conductor disponible (reembolso pendiente)',
          reimbursement_status = 'pendiente_manual',
          updated_at = NOW()
      WHERE id = v_ride.id;

      PERFORM public.notify_user(
        v_ride.client_id,
        'Sin conductor disponible',
        'No encontramos conductor para tu viaje. Un administrador procesará tu reembolso.',
        'ride_expired',
        jsonb_build_object('ride_id', v_ride.id, 'url', '/cliente')
      );

    ELSE
      -- Efectivo, o comprobante que aún no se aprueba: no entró dinero
      UPDATE rides
      SET status = 'cancelada',
          cancel_reason = 'Sin conductor disponible',
          reimbursement_status = 'no_aplica',
          updated_at = NOW()
      WHERE id = v_ride.id;

      PERFORM public.notify_user(
        v_ride.client_id,
        'Sin conductor disponible',
        'No encontramos conductor para tu viaje. Puedes intentarlo de nuevo.',
        'ride_expired',
        jsonb_build_object('ride_id', v_ride.id, 'url', '/cliente')
      );
    END IF;

    -- Liberar el cupón (la promo no se consume en un viaje que no ocurrió)
    IF v_ride.coupon_id IS NOT NULL THEN
      DELETE FROM coupon_redemptions WHERE ride_id = v_ride.id;
      UPDATE coupons SET used_count = GREATEST(used_count - 1, 0), updated_at = NOW()
      WHERE id = v_ride.coupon_id;
    END IF;

    -- Quitar la oferta de la campana de los conductores
    DELETE FROM notifications
    WHERE type = 'ride_available'
      AND data ->> 'ride_id' = v_ride.id::text;

    INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
    VALUES (NULL, 'EXPIRE_RIDE', 'ride', v_ride.id,
            jsonb_build_object('motivo', 'sin conductor tras ' || GREATEST(COALESCE(p_minutes, 10), 1) || ' min',
                               'payment_method', v_ride.payment_method,
                               'proof_status', v_ride.proof_status,
                               'reembolso_usd', CASE
                                 WHEN LOWER(COALESCE(v_ride.payment_method, '')) IN ('billetera', 'wallet')
                                 THEN v_ride.final_fare_usd ELSE 0 END));
  END LOOP;

  RETURN jsonb_build_object('success', TRUE,
                            'expirados', v_total,
                            'reembolsados_auto', v_refunded,
                            'reembolsos_pendientes', v_pending,
                            'minutos', GREATEST(COALESCE(p_minutes, 10), 1));
END;
$$;

GRANT EXECUTE ON FUNCTION public.expire_unassigned_rides(integer) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.expire_unassigned_rides(integer) FROM anon;

-- ============================================================
-- 7. CRON: se reutiliza el latido de 5 minutos que YA existe
--    (0 coste: el job tarda milisegundos)
-- ============================================================
DO $$
BEGIN
  BEGIN
    PERFORM cron.unschedule('bunrider-availability-reminders');
  EXCEPTION WHEN OTHERS THEN
    NULL; -- aún no existía
  END;

  PERFORM cron.schedule(
    'bunrider-availability-reminders',
    '*/5 * * * *',
    'SELECT public.process_availability_reminders(); SELECT public.expire_unassigned_rides();'
  );
END $$;

-- ============================================================
-- 8. VERIFICACIÓN
-- ============================================================
SELECT 'accept_ride con candado de conductor ocupado' AS comprobacion,
       (pg_get_functiondef(p.oid) LIKE '%Ya tienes un viaje en curso%')::text AS valor
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname='public' AND p.proname='accept_ride'
UNION ALL
SELECT 'oferta de request_ride excluye ocupados y exige vehículo aprobado',
       (pg_get_functiondef(p.oid) LIKE '%is_approved = TRUE%'
        AND pg_get_functiondef(p.oid) LIKE '%NOT EXISTS%')::text
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname='public' AND p.proname='request_ride'
UNION ALL
SELECT 'oferta de request_ride_with_proof corregida',
       (pg_get_functiondef(p.oid) LIKE '%is_active_vehicle = TRUE%')::text
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname='public' AND p.proname='request_ride_with_proof'
UNION ALL
SELECT 'approve_ride_proof SIN el helper roto',
       (pg_get_functiondef(p.oid) NOT LIKE '%driver_has_vehicle_for_category%')::text
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname='public' AND p.proname='approve_ride_proof'
UNION ALL
SELECT 'get_available_driver_counts devuelve available y busy',
       (pg_get_function_result(p.oid) LIKE '%busy%')::text
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname='public' AND p.proname='get_available_driver_counts'
UNION ALL
SELECT 'cron de 5 min llama también a la expiración',
       (SELECT (command LIKE '%expire_unassigned_rides%')::text
        FROM cron.job WHERE jobname='bunrider-availability-reminders');

SELECT '✅ Migración 080: disponibilidad de conductores lista' AS estado;
