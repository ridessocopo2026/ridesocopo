-- ============================================================
-- RIDESOCOPÓ - Migración: NOTIFICACIONES PUSH WEB + IN-APP
-- Sistema completo: push_subscriptions + notification_outbox
-- + helper notify_user + trigger pg_net + envío masivo admin
-- ============================================================

-- 1. HABILITAR pg_net (para llamar a la Edge Function desde trigger)
-- Si no se puede activar desde SQL, activarla manualmente en Dashboard → Extensions
CREATE EXTENSION IF NOT EXISTS pg_net;

-- ============================================================
-- 2. TABLA: PUSH_SUBSCRIPTIONS (suscripciones web-push por usuario)
-- ============================================================
CREATE TABLE IF NOT EXISTS push_subscriptions (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  endpoint TEXT NOT NULL UNIQUE,
  p256dh TEXT NOT NULL,
  auth TEXT NOT NULL,
  user_agent TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW(),
  UNIQUE(user_id, endpoint)
);

-- Índice para búsqueda rápida por usuario
CREATE INDEX IF NOT EXISTS idx_push_subscriptions_user ON push_subscriptions(user_id);

-- Permisos
GRANT ALL ON public.push_subscriptions TO anon, authenticated, service_role;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO anon, authenticated, service_role;

-- RLS: cada usuario gestiona sus propias suscripciones
ALTER TABLE push_subscriptions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "user_view_own_push_subscriptions" ON public.push_subscriptions;
CREATE POLICY "user_view_own_push_subscriptions" ON public.push_subscriptions
  FOR SELECT USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "user_insert_own_push_subscriptions" ON public.push_subscriptions;
CREATE POLICY "user_insert_own_push_subscriptions" ON public.push_subscriptions
  FOR INSERT WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "user_delete_own_push_subscriptions" ON public.push_subscriptions;
CREATE POLICY "user_delete_own_push_subscriptions" ON public.push_subscriptions
  FOR DELETE USING (auth.uid() = user_id);

-- El sistema (Edge Function con service_role) puede gestionar todas
DROP POLICY IF EXISTS "system_manage_push_subscriptions" ON public.push_subscriptions;
CREATE POLICY "system_manage_push_subscriptions" ON public.push_subscriptions
  FOR ALL USING (TRUE);

-- ============================================================
-- 3. TABLA: NOTIFICATION_OUTBOX (cola para la Edge Function)
-- ============================================================
CREATE TABLE IF NOT EXISTS notification_outbox (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  notification_id UUID UNIQUE NOT NULL REFERENCES notifications(id) ON DELETE CASCADE,
  user_id UUID NOT NULL REFERENCES profiles(id) ON DELETE CASCADE,
  sent_at TIMESTAMPTZ,
  error TEXT,
  attempts INTEGER DEFAULT 0,
  created_at TIMESTAMPTZ DEFAULT NOW()
);

-- Índices para consultas eficientes de la cola
CREATE INDEX IF NOT EXISTS idx_outbox_pending ON notification_outbox((sent_at IS NULL)) WHERE sent_at IS NULL;
CREATE INDEX IF NOT EXISTS idx_outbox_user ON notification_outbox(user_id);

-- Permisos (solo service_role debe leerla; se deshabilita RLS para el sistema)
GRANT ALL ON public.notification_outbox TO anon, authenticated, service_role;
ALTER TABLE notification_outbox ENABLE ROW LEVEL SECURITY;

-- Solo el sistema puede gestionar la cola (vía service_role)
DROP POLICY IF EXISTS "system_manage_outbox" ON public.notification_outbox;
CREATE POLICY "system_manage_outbox" ON public.notification_outbox
  FOR ALL USING (TRUE);

-- ============================================================
-- 4. TABLA: PUSH_SETTINGS (configuración de la Edge Function)
-- ============================================================
CREATE TABLE IF NOT EXISTS push_settings (
  id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
  function_url TEXT NOT NULL,
  function_secret TEXT NOT NULL,
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

GRANT ALL ON public.push_settings TO anon, authenticated, service_role;
ALTER TABLE push_settings ENABLE ROW LEVEL SECURITY;
-- Solo el sistema (service_role) la lee
DROP POLICY IF EXISTS "system_manage_push_settings" ON public.push_settings;
CREATE POLICY "system_manage_push_settings" ON public.push_settings
  FOR ALL USING (TRUE);

-- Insertar configuración inicial (cambiar URL y secreto con el comando de despliegue)
INSERT INTO push_settings (function_url, function_secret)
VALUES (
  'https://inxxhkwybjkcaeyahami.supabase.co/functions/v1/push-notifications',
  'REEMPLAZAR_CON_SECRETO_SEGURO'
)
ON CONFLICT (id) DO NOTHING;

-- ============================================================
-- 5. FUNCIÓN HELPER: NOTIFY_USER
-- Inserta en notifications (in-app) + notification_outbox (push)
-- Esta es la función CENTRAL que deben usar todas las RPC.
-- ============================================================
CREATE OR REPLACE FUNCTION public.notify_user(
  p_user_id UUID,
  p_title TEXT,
  p_body TEXT DEFAULT NULL,
  p_type TEXT DEFAULT NULL,
  p_data JSONB DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_notification_id UUID;
BEGIN
  IF p_user_id IS NULL THEN
    RETURN NULL;
  END IF;

  INSERT INTO notifications (user_id, title, body, type, data)
  VALUES (p_user_id, p_title, p_body, p_type, p_data)
  RETURNING id INTO v_notification_id;

  -- Encolar para push (solo si el usuario tiene suscripciones activas)
  IF EXISTS (
    SELECT 1 FROM push_subscriptions WHERE user_id = p_user_id
  ) THEN
    INSERT INTO notification_outbox (notification_id, user_id)
    VALUES (v_notification_id, p_user_id)
    ON CONFLICT (notification_id) DO NOTHING;
  END IF;

  RETURN v_notification_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_user TO anon, authenticated, service_role;

-- ============================================================
-- 6. FUNCIÓN: NOTIFICAR A MÚLTIPLES USUARIOS (por rol)
-- INÚTIL internamente, usada por RPCs de negocio
-- ============================================================
CREATE OR REPLACE FUNCTION public.notify_users_by_role(
  p_title TEXT,
  p_body TEXT,
  p_type TEXT,
  p_data JSONB DEFAULT NULL,
  p_target TEXT DEFAULT 'todos'
)
RETURNS INTEGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_count INTEGER := 0;
BEGIN
  -- Insertar notificaciones para todos los usuarios del target
  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT p.user_id, p_title, p_body, p_type, p_data
  FROM (
    SELECT id AS user_id FROM profiles
    WHERE
      CASE p_target
        WHEN 'todos' THEN TRUE
        WHEN 'clientes' THEN role = 'cliente'
        WHEN 'conductores' THEN role = 'conductor'
        WHEN 'admins' THEN role IN ('super_admin', 'encargado')
        ELSE FALSE
      END
  ) p;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- Encolar push para quienes tengan suscripciones
  INSERT INTO notification_outbox (notification_id, user_id)
  SELECT n.id, n.user_id
  FROM notifications n
  WHERE n.created_at >= NOW() - INTERVAL '1 minute'
    AND n.id IN (
      SELECT id FROM notifications
      WHERE created_at >= NOW() - INTERVAL '1 minute'
    )
    AND EXISTS (SELECT 1 FROM push_subscriptions ps WHERE ps.user_id = n.user_id)
  ON CONFLICT (notification_id) DO NOTHING;

  RETURN v_count;
END;
$$;

GRANT EXECUTE ON FUNCTION public.notify_users_by_role TO anon, authenticated, service_role;

-- ============================================================
-- 7. RPC: ENVÍO MASIVO DESDE EL ADMIN
-- Solo super_admin puede enviar a todos/rol específico
-- ============================================================
CREATE OR REPLACE FUNCTION public.send_admin_notification(
  p_title TEXT,
  p_body TEXT DEFAULT NULL,
  p_target TEXT DEFAULT 'todos'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_count INTEGER;
BEGIN
  IF public.get_user_role(v_admin_id) != 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado: solo super_admin puede enviar notificaciones';
  END IF;

  IF p_target NOT IN ('todos', 'clientes', 'conductores', 'admins') THEN
    RAISE EXCEPTION 'Destino inválido. Use: todos, clientes, conductores, admins';
  END IF;

  -- Insertar en notifications
  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT id, p_title, p_body, 'admin_broadcast',
         jsonb_build_object('target', p_target)
  FROM profiles
  WHERE
    CASE p_target
      WHEN 'todos' THEN TRUE
      WHEN 'clientes' THEN role = 'cliente'
      WHEN 'conductores' THEN role = 'conductor'
      WHEN 'admins' THEN role IN ('super_admin', 'encargado')
      ELSE FALSE
    END;

  GET DIAGNOSTICS v_count = ROW_COUNT;

  -- Encolar push para quienes tengan suscripciones
  INSERT INTO notification_outbox (notification_id, user_id)
  SELECT n.id, n.user_id
  FROM notifications n
  WHERE n.created_at >= NOW() - INTERVAL '1 minute'
    AND n.type = 'admin_broadcast'
    AND EXISTS (SELECT 1 FROM push_subscriptions ps WHERE ps.user_id = n.user_id)
  ON CONFLICT (notification_id) DO NOTHING;

  -- Auditoría
  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_admin_id, 'SEND_BROADCAST', 'notification', NULL,
          jsonb_build_object('title', p_title, 'target', p_target, 'count', v_count));

  RETURN jsonb_build_object('success', TRUE, 'sent', v_count, 'target', p_target);
END;
$$;

GRANT EXECUTE ON FUNCTION public.send_admin_notification TO anon, authenticated, service_role;

-- ============================================================
-- 8. RPC: GESTIÓN DE SUSCRIPCIONES PUSH
-- ============================================================

-- Crear o actualizar suscripción (upsert seguro)
CREATE OR REPLACE FUNCTION public.get_or_create_push_subscription(
  p_endpoint TEXT,
  p_p256dh TEXT,
  p_auth TEXT,
  p_user_agent TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_sub_id UUID;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  IF p_endpoint IS NULL OR p_endpoint = '' OR p_p256dh IS NULL OR p_auth IS NULL THEN
    RAISE EXCEPTION 'Datos de suscripción incompletos';
  END IF;

  -- Upsert
  INSERT INTO push_subscriptions (user_id, endpoint, p256dh, auth, user_agent)
  VALUES (v_user_id, p_endpoint, p_p256dh, p_auth, p_user_agent)
  ON CONFLICT (endpoint) DO UPDATE
  SET p256dh = EXCLUDED.p256dh,
      auth = EXCLUDED.auth,
      user_agent = EXCLUDED.user_agent,
      updated_at = NOW()
  RETURNING id INTO v_sub_id;

  RETURN v_sub_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_or_create_push_subscription TO anon, authenticated, service_role;

-- Eliminar suscripción (al desuscribirse)
CREATE OR REPLACE FUNCTION public.delete_push_subscription(p_endpoint TEXT)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  IF v_user_id IS NULL OR p_endpoint IS NULL THEN
    RETURN FALSE;
  END IF;

  DELETE FROM push_subscriptions
  WHERE endpoint = p_endpoint AND user_id = v_user_id;

  RETURN FOUND;
END;
$$;

GRANT EXECUTE ON FUNCTION public.delete_push_subscription TO anon, authenticated, service_role;

-- ============================================================
-- 9. FUNCIÓN: MARCAR NOTIFICACIÓN COMO LEÍDA
-- ============================================================
CREATE OR REPLACE FUNCTION public.mark_notification_read(p_notification_id UUID)
RETURNS BOOLEAN
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RETURN FALSE;
  END IF;

  UPDATE notifications SET is_read = TRUE
  WHERE id = p_notification_id AND user_id = v_user_id;

  RETURN FOUND;
END;
$$;

GRANT EXECUTE ON FUNCTION public.mark_notification_read TO anon, authenticated, service_role;

-- ============================================================
-- 10. TRIGGER: ENCOLAR PUSH AL INSERTAR NOTIFICACIÓN
-- Llama a la Edge Function via pg_net para cada notificación insertada.
-- ============================================================
CREATE OR REPLACE FUNCTION public.notify_push_after_insert()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_settings RECORD;
  v_has_subs BOOLEAN;
  v_pg_net_available BOOLEAN;
BEGIN
  -- Solo encolar si el usuario tiene suscripciones push (ahorra llamadas)
  SELECT EXISTS (
    SELECT 1 FROM push_subscriptions WHERE user_id = NEW.user_id
  ) INTO v_has_subs;

  IF NOT v_has_subs THEN
    RETURN NEW;
  END IF;

  -- Leer configuración
  SELECT * INTO v_settings FROM push_settings LIMIT 1;

  IF v_settings.id IS NULL OR v_settings.function_url IS NULL OR v_settings.function_secret IS NULL THEN
    RETURN NEW;
  END IF;

  -- Verificar que pg_net esté disponible ANTES de usarlo.
  -- Así el trigger NUNCA rompe el flujo de negocio si pg_net no estuviera instalado.
  SELECT EXISTS (
    SELECT 1 FROM pg_extension WHERE extname = 'pg_net'
  ) INTO v_pg_net_available;

  IF NOT v_pg_net_available THEN
    RETURN NEW;
  END IF;

  -- Llamar a la Edge Function asíncronamente.
  -- NOTA: en Supabase, pg_net se instala en schema "net" (no "pg_net").
  PERFORM net.http_post(
    url := v_settings.function_url,
    headers := jsonb_build_object(
      'Content-Type', 'application/json',
      'Authorization', 'Bearer ' || v_settings.function_secret
    ),
    body := jsonb_build_object('notification_id', NEW.id)
  );

  RETURN NEW;

EXCEPTION WHEN OTHERS THEN
  -- NUNCA romper el flujo de negocio aunque pg_net falle
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS on_notification_inserted ON notifications;
CREATE TRIGGER on_notification_inserted
  AFTER INSERT ON notifications
  FOR EACH ROW EXECUTE FUNCTION public.notify_push_after_insert();

-- ============================================================
-- 11. REFACTOR DE FUNCIONES EXISTENTES PARA USAR NOTIFY_USER
-- ============================================================

-- 11.1 accept_ride → notifica al cliente
CREATE OR REPLACE FUNCTION public.accept_ride(p_ride_id UUID)
RETURNS JSONB
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

  SELECT driver_status INTO v_ride FROM profiles WHERE id = v_driver_id;
  IF v_ride.driver_status != 'aprobado' THEN
    RAISE EXCEPTION 'Conductor no aprobado';
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id AND status = 'buscando';
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no disponible';
  END IF;

  SELECT * INTO v_vehicle FROM vehicles
  WHERE driver_id = v_driver_id AND category = v_ride.category AND is_active = TRUE
  LIMIT 1;

  IF v_vehicle.id IS NULL THEN
    RAISE EXCEPTION 'No tiene un vehículo activo de la categoría requerida';
  END IF;

  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_driver_id;

  v_commission := ROUND(v_ride.total_fare_usd * v_ride.commission_rate / 100, 2);

  IF v_wallet.balance_usd < -v_wallet.debt_limit_usd THEN
    RETURN jsonb_build_object(
      'success', FALSE,
      'error', 'DEUDA_EXCEDIDA',
      'message', 'Tienes una deuda pendiente que supera el límite permitido. Contacta al administrador para regularizar tu situación.',
      'deuda_actual', v_wallet.balance_usd,
      'limite_deuda', v_wallet.debt_limit_usd
    );
  END IF;

  UPDATE wallets
  SET balance_usd = balance_usd - v_commission,
      updated_at = NOW()
  WHERE user_id = v_driver_id;

  INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
  VALUES (v_wallet.id, v_driver_id, 'comision', v_commission, 'completado',
          'Comisión por viaje', p_ride_id);

  UPDATE rides
  SET driver_id = v_driver_id,
      vehicle_id = v_vehicle.id,
      commission_usd = v_commission,
      status = 'aceptada',
      started_at = NOW()
  WHERE id = p_ride_id;

  -- NOTIFICAR al cliente (in-app + push)
  PERFORM public.notify_user(
    v_ride.client_id,
    'Conductor asignado',
    'Un conductor ha aceptado tu viaje',
    'ride_accepted',
    jsonb_build_object('ride_id', p_ride_id, 'url', '/cliente/viaje/' || p_ride_id)
  );

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_driver_id, 'ACCEPT_RIDE', 'ride', p_ride_id,
          jsonb_build_object('commission', v_commission));

  RETURN jsonb_build_object(
    'success', TRUE,
    'ride_id', p_ride_id,
    'commission', v_commission
  );
END;
$$;

-- 11.2 request_ride → notifica a conductores disponibles
CREATE OR REPLACE FUNCTION public.request_ride(
  p_origin_lat NUMERIC,
  p_origin_lng NUMERIC,
  p_origin_address TEXT,
  p_dest_lat NUMERIC,
  p_dest_lng NUMERIC,
  p_dest_address TEXT,
  p_category vehicle_category,
  p_payment_method TEXT DEFAULT 'efectivo',
  p_coupon_code TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_fare JSONB;
  v_ride_id UUID;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  v_fare := public.calculate_fare(
    p_origin_lat, p_origin_lng,
    p_dest_lat, p_dest_lng,
    p_category, p_coupon_code
  );

  IF NOT EXISTS (SELECT 1 FROM payment_methods WHERE name = p_payment_method AND is_active = TRUE) THEN
    RAISE EXCEPTION 'Método de pago no disponible';
  END IF;

  INSERT INTO rides (
    client_id, category,
    origin_lat, origin_lng, origin_address,
    destination_lat, destination_lng, destination_address,
    destination_barrio_id, destination_barrio_name,
    base_fare_usd, origin_surcharge_usd, destination_surcharge_usd,
    total_fare_usd, discount_usd, final_fare_usd,
    payment_method, status
  ) VALUES (
    v_user_id, p_category,
    p_origin_lat, p_origin_lng, p_origin_address,
    p_dest_lat, p_dest_lng, p_dest_address,
    (v_fare->>'destination_barrio_id')::UUID,
    v_fare->>'destination_barrio_name',
    (v_fare->>'base_fare')::NUMERIC,
    (v_fare->>'origin_surcharge')::NUMERIC,
    (v_fare->>'destination_surcharge')::NUMERIC,
    (v_fare->>'total_fare')::NUMERIC,
    (v_fare->>'discount')::NUMERIC,
    (v_fare->>'final_fare')::NUMERIC,
    p_payment_method, 'buscando'
  ) RETURNING id INTO v_ride_id;

  -- NOTIFICAR a conductores disponibles (en línea + aprobados + categoría)
  -- El trigger on_notification_inserted encolará el push automáticamente.
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
    AND public.driver_has_vehicle_for_category(p_category) = TRUE;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_user_id, 'REQUEST_RIDE', 'ride', v_ride_id, v_fare);

  RETURN v_ride_id;
END;
$$;

-- 11.3 request_ride_with_proof → notifica admins + conductores
CREATE OR REPLACE FUNCTION public.request_ride_with_proof(
  p_origin_lat NUMERIC,
  p_origin_lng NUMERIC,
  p_origin_address TEXT,
  p_dest_lat NUMERIC,
  p_dest_lng NUMERIC,
  p_dest_address TEXT,
  p_category vehicle_category,
  p_payment_method TEXT,
  p_proof_url TEXT,
  p_coupon_code TEXT DEFAULT NULL
)
RETURNS UUID
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

  INSERT INTO rides (
    client_id, category,
    origin_lat, origin_lng, origin_address,
    destination_lat, destination_lng, destination_address,
    destination_barrio_id, destination_barrio_name,
    base_fare_usd, origin_surcharge_usd, destination_surcharge_usd,
    total_fare_usd, discount_usd, final_fare_usd,
    payment_method, status, proof_url, proof_status
  ) VALUES (
    v_user_id, p_category,
    p_origin_lat, p_origin_lng, p_origin_address,
    p_dest_lat, p_dest_lng, p_dest_address,
    (v_fare->>'destination_barrio_id')::UUID,
    v_fare->>'destination_barrio_name',
    (v_fare->>'base_fare')::NUMERIC,
    (v_fare->>'origin_surcharge')::NUMERIC,
    (v_fare->>'destination_surcharge')::NUMERIC,
    (v_fare->>'total_fare')::NUMERIC,
    (v_fare->>'discount')::NUMERIC,
    (v_fare->>'final_fare')::NUMERIC,
    p_payment_method, 'buscando',
    CASE WHEN v_proof_required THEN p_proof_url ELSE NULL END,
    CASE WHEN v_proof_required THEN 'pendiente' ELSE 'aprobado' END
  ) RETURNING id INTO v_ride_id;

  -- NOTIFICAR a admins si requiere aprobación
  -- El trigger on_notification_inserted encolará el push automáticamente.
  IF v_proof_required THEN
    INSERT INTO notifications (user_id, title, body, type, data)
    SELECT id, 'Comprobante por aprobar',
           'Nuevo comprobante de pago pendiente de revisión para un viaje',
           'proof_pending',
           jsonb_build_object('ride_id', v_ride_id, 'url', '/admin/comprobantes')
    FROM profiles WHERE role IN ('super_admin', 'encargado');
  END IF;

  -- NOTIFICAR a conductores disponibles
  -- El trigger on_notification_inserted encolará el push automáticamente.
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
    AND public.driver_has_vehicle_for_category(p_category) = TRUE;

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_user_id, 'REQUEST_RIDE_WITH_PROOF', 'ride', v_ride_id, v_fare);

  RETURN v_ride_id;
END;
$$;

-- 11.4 complete_ride → notifica al otro usuario
CREATE OR REPLACE FUNCTION public.complete_ride(
  p_ride_id UUID,
  p_rating INTEGER DEFAULT NULL,
  p_review TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_ride RECORD;
  v_settlement JSONB;
BEGIN
  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF v_ride.driver_id != v_user_id AND v_ride.client_id != v_user_id THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF v_ride.status NOT IN ('aceptada', 'en_ruta') THEN
    RAISE EXCEPTION 'Estado inválido';
  END IF;

  UPDATE rides
  SET status = 'completada',
      completed_at = NOW(),
      rating = COALESCE(p_rating, rating),
      review = COALESCE(p_review, review)
  WHERE id = p_ride_id;

  IF v_ride.driver_id IS NOT NULL THEN
    v_settlement := public.settle_ride_earnings(p_ride_id);
  END IF;

  -- NOTIFICAR al otro usuario
  IF v_user_id = v_ride.driver_id THEN
    PERFORM public.notify_user(
      v_ride.client_id,
      'Viaje completado',
      'Tu viaje ha finalizado',
      'ride_completed',
      jsonb_build_object('ride_id', p_ride_id, 'url', '/cliente/viaje/' || p_ride_id)
    );
  ELSE
    PERFORM public.notify_user(
      v_ride.driver_id,
      'Viaje completado',
      'El viaje ha finalizado',
      'ride_completed',
      jsonb_build_object('ride_id', p_ride_id, 'url', '/conductor/viaje/' || p_ride_id)
    );
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'ride_id', p_ride_id, 'settlement', v_settlement);
END;
$$;

-- 11.5 confirm_ride_start → notifica a ambos
CREATE OR REPLACE FUNCTION public.confirm_ride_start(p_ride_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_ride RECORD;
  v_is_driver BOOLEAN;
  v_is_client BOOLEAN;
  v_both_confirmed BOOLEAN := FALSE;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  v_is_driver := (v_ride.driver_id = v_user_id);
  v_is_client := (v_ride.client_id = v_user_id);

  IF NOT v_is_driver AND NOT v_is_client THEN
    RAISE EXCEPTION 'No autorizado para este viaje';
  END IF;

  IF v_ride.status != 'aceptada' THEN
    RAISE EXCEPTION 'El viaje debe estar aceptado para poder iniciarse';
  END IF;

  IF v_is_driver THEN
    UPDATE rides SET driver_start_confirmed = TRUE WHERE id = p_ride_id;
  ELSE
    UPDATE rides SET client_start_confirmed = TRUE WHERE id = p_ride_id;
  END IF;

  SELECT (driver_start_confirmed AND client_start_confirmed) INTO v_both_confirmed
  FROM rides WHERE id = p_ride_id;

  IF v_both_confirmed THEN
    UPDATE rides SET status = 'en_ruta' WHERE id = p_ride_id;

    -- NOTIFICAR a ambos
    PERFORM public.notify_user(
      v_ride.driver_id, '¡Viaje iniciado!', 'Ambos confirmaron. Buen viaje.',
      'ride_started', jsonb_build_object('ride_id', p_ride_id, 'url', '/conductor/viaje/' || p_ride_id)
    );
    PERFORM public.notify_user(
      v_ride.client_id, '¡Viaje iniciado!', 'Ambos confirmaron. Buen viaje.',
      'ride_started', jsonb_build_object('ride_id', p_ride_id, 'url', '/cliente/viaje/' || p_ride_id)
    );

    INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
    VALUES (v_user_id, 'RIDE_STARTED', 'ride', p_ride_id,
            jsonb_build_object('both_confirmed', TRUE));
  END IF;

  RETURN jsonb_build_object(
    'success', TRUE,
    'ride_id', p_ride_id,
    'both_confirmed', v_both_confirmed,
    'driver_confirmed', (SELECT driver_start_confirmed FROM rides WHERE id = p_ride_id),
    'client_confirmed', (SELECT client_start_confirmed FROM rides WHERE id = p_ride_id),
    'status', (SELECT status FROM rides WHERE id = p_ride_id)
  );
END;
$$;

-- 11.6 cancel_ride → notificar al otro usuario
CREATE OR REPLACE FUNCTION public.cancel_ride(
  p_ride_id UUID,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_ride RECORD;
  v_wallet RECORD;
  v_other_user UUID;
BEGIN
  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;

  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF v_ride.client_id != v_user_id AND v_ride.driver_id != v_user_id THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF v_ride.status = 'aceptada' AND v_ride.driver_id = v_user_id THEN
    SELECT * INTO v_wallet FROM wallets WHERE user_id = v_user_id;
    UPDATE wallets SET balance_usd = balance_usd + v_ride.commission_usd
    WHERE user_id = v_user_id;

    INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, ride_id)
    VALUES (v_wallet.id, v_user_id, 'credito', v_ride.commission_usd, 'completado',
            'Reembolso de comisión por cancelación', p_ride_id);
  END IF;

  UPDATE rides
  SET status = 'cancelada',
      cancelled_by = v_user_id,
      cancel_reason = p_reason
  WHERE id = p_ride_id;

  -- NOTIFICAR al otro usuario (si existe el viaje con ambos)
  IF v_ride.client_id IS NOT NULL AND v_ride.driver_id IS NOT NULL THEN
    v_other_user := CASE WHEN v_user_id = v_ride.client_id THEN v_ride.driver_id ELSE v_ride.client_id END;

    PERFORM public.notify_user(
      v_other_user,
      'Viaje cancelado',
      COALESCE(p_reason, 'El viaje fue cancelado'),
      'ride_cancelled',
      jsonb_build_object('ride_id', p_ride_id)
    );
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'ride_id', p_ride_id);
END;
$$;

-- 11.7 register_driver_onboarding → notifica a admins
CREATE OR REPLACE FUNCTION public.register_driver_onboarding(
  p_full_name TEXT,
  p_phone TEXT,
  p_cedula_number TEXT,
  p_cedula_photo_url TEXT,
  p_license_number TEXT,
  p_license_photo_url TEXT,
  p_license_expiry_date DATE,
  p_profile_photo_url TEXT,
  p_vehicle_category vehicle_category,
  p_vehicle_brand TEXT,
  p_vehicle_model TEXT,
  p_vehicle_year INTEGER,
  p_vehicle_color TEXT,
  p_vehicle_plate TEXT,
  p_vehicle_photo_url TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  UPDATE profiles
  SET full_name = p_full_name,
      phone = p_phone,
      role = 'conductor',
      driver_status = 'pendiente',
      onboarding_completed = TRUE
  WHERE id = v_user_id;

  INSERT INTO driver_documents (
    driver_id, cedula_number, cedula_photo_url,
    license_number, license_photo_url, license_expiry_date, profile_photo_url
  ) VALUES (
    v_user_id, p_cedula_number, p_cedula_photo_url,
    p_license_number, p_license_photo_url, p_license_expiry_date, p_profile_photo_url
  );

  INSERT INTO vehicles (
    driver_id, category, brand, model, year, color, plate, photo_url
  ) VALUES (
    v_user_id, p_vehicle_category, p_vehicle_brand, p_vehicle_model,
    p_vehicle_year, p_vehicle_color, p_vehicle_plate, p_vehicle_photo_url
  );

  -- NOTIFICAR a encargados y admins
  -- El trigger on_notification_inserted encolará el push automáticamente.
  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT id, 'Nuevo conductor pendiente',
         p_full_name || ' ha solicitado ser conductor',
         'driver_pending',
         jsonb_build_object('driver_id', v_user_id, 'url', '/admin/conductores')
  FROM profiles WHERE role IN ('super_admin', 'encargado');

  RETURN jsonb_build_object('success', TRUE, 'status', 'pendiente');
END;
$$;

-- 11.8 review_driver → notifica al conductor
CREATE OR REPLACE FUNCTION public.review_driver(
  p_driver_id UUID,
  p_approve BOOLEAN,
  p_reason TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reviewer_id UUID := auth.uid();
  v_reviewer RECORD;
  v_new_status driver_status;
BEGIN
  SELECT * INTO v_reviewer FROM profiles WHERE id = v_reviewer_id;
  IF v_reviewer.role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado para revisar conductores';
  END IF;

  v_new_status := CASE WHEN p_approve THEN 'aprobado' ELSE 'rechazado' END;

  UPDATE profiles
  SET driver_status = v_new_status
  WHERE id = p_driver_id;

  -- NOTIFICAR al conductor
  PERFORM public.notify_user(
    p_driver_id,
    CASE WHEN p_approve THEN '¡Cuenta aprobada!' ELSE 'Cuenta rechazada' END,
    CASE WHEN p_approve THEN 'Ya puedes comenzar a trabajar. ¡Bienvenido a RideSocopó!'
         ELSE COALESCE(p_reason, 'Tu solicitud fue rechazada. Contacta al administrador.') END,
    'driver_review',
    jsonb_build_object('approved', p_approve, 'url', '/conductor')
  );

  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_reviewer_id, 'REVIEW_DRIVER', 'profile', p_driver_id,
          jsonb_build_object('approved', p_approve, 'reason', p_reason));

  RETURN jsonb_build_object('success', TRUE, 'driver_id', p_driver_id, 'status', v_new_status);
END;
$$;

-- 11.9 approve_recharge → notifica al usuario
CREATE OR REPLACE FUNCTION public.approve_recharge(
  p_transaction_id UUID,
  p_approve BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_reviewer_id UUID := auth.uid();
  v_reviewer RECORD;
  v_txn RECORD;
  v_wallet RECORD;
BEGIN
  SELECT * INTO v_reviewer FROM profiles WHERE id = v_reviewer_id;
  IF v_reviewer.role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT * INTO v_txn FROM transactions WHERE id = p_transaction_id AND status = 'pendiente';
  IF v_txn.id IS NULL THEN
    RAISE EXCEPTION 'Transacción no encontrada o ya procesada';
  END IF;

  IF p_approve THEN
    UPDATE wallets SET balance_usd = balance_usd + v_txn.amount_usd
    WHERE user_id = v_txn.user_id;

    UPDATE transactions SET status = 'aprobado', reviewed_by = v_reviewer_id, reviewed_at = NOW()
    WHERE id = p_transaction_id;

    PERFORM public.notify_user(
      v_txn.user_id,
      'Recarga aprobada',
      'Tu recarga de $' || v_txn.amount_usd || ' ha sido aprobada',
      'recharge_approved',
      jsonb_build_object('transaction_id', p_transaction_id, 'url', '/cliente/billetera')
    );
  ELSE
    UPDATE transactions SET status = 'rechazado', reviewed_by = v_reviewer_id, reviewed_at = NOW()
    WHERE id = p_transaction_id;

    PERFORM public.notify_user(
      v_txn.user_id,
      'Recarga rechazada',
      'Tu recarga fue rechazada. Verifica el comprobante e intenta de nuevo.',
      'recharge_rejected',
      jsonb_build_object('transaction_id', p_transaction_id, 'url', '/cliente/billetera')
    );
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'transaction_id', p_transaction_id);
END;
$$;

-- 11.10 request_wallet_recharge → notifica a admins
CREATE OR REPLACE FUNCTION public.request_wallet_recharge(
  p_amount_usd NUMERIC,
  p_proof_url TEXT,
  p_reference TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_wallet RECORD;
  v_txn_id UUID;
  v_user_profile RECORD;
BEGIN
  IF p_amount_usd <= 0 THEN
    RAISE EXCEPTION 'Monto inválido';
  END IF;

  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_user_id;
  SELECT * INTO v_user_profile FROM profiles WHERE id = v_user_id;

  INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, proof_url, reference)
  VALUES (v_wallet.id, v_user_id, 'recarga', p_amount_usd, 'pendiente',
          'Recarga de saldo', p_proof_url, p_reference)
  RETURNING id INTO v_txn_id;

  -- NOTIFICAR a admins
  -- El trigger on_notification_inserted encolará el push automáticamente.
  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT id, 'Recarga por aprobar',
         CONCAT(v_user_profile.full_name, ' solicitó una recarga de $', p_amount_usd),
         'recharge_pending',
         jsonb_build_object('transaction_id', v_txn_id, 'url', '/admin/comprobantes')
  FROM profiles WHERE role IN ('super_admin', 'encargado');

  RETURN v_txn_id;
END;
$$;

-- 11.11 approve_ride_proof → notifica al cliente
CREATE OR REPLACE FUNCTION public.approve_ride_proof(
  p_ride_id UUID,
  p_approve BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_ride RECORD;
  v_status TEXT;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF v_ride.proof_status != 'pendiente' THEN
    RAISE EXCEPTION 'El comprobante ya fue procesado';
  END IF;

  v_status := CASE WHEN p_approve THEN 'aprobado' ELSE 'rechazado' END;

  UPDATE rides SET proof_status = v_status WHERE id = p_ride_id;

  -- NOTIFICAR al cliente
  PERFORM public.notify_user(
    v_ride.client_id,
    CASE WHEN p_approve THEN 'Comprobante aprobado' ELSE 'Comprobante rechazado' END,
    CASE WHEN p_approve THEN 'Tu pago fue aprobado. El viaje puede continuar.'
         ELSE 'Tu comprobante fue rechazado. Sube uno válido.' END,
    'proof_reviewed',
    jsonb_build_object('ride_id', p_ride_id, 'approved', p_approve,
                       'url', '/cliente/viaje/' || p_ride_id)
  );

  RETURN jsonb_build_object('success', TRUE, 'proof_status', v_status);
END;
$$;

-- 11.12 driver_pay_to_platform → notifica a admins
CREATE OR REPLACE FUNCTION public.driver_pay_to_platform(
  p_amount_usd NUMERIC,
  p_proof_url TEXT,
  p_description TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_payout_id UUID;
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  IF p_amount_usd <= 0 THEN
    RAISE EXCEPTION 'Monto inválido';
  END IF;

  IF p_proof_url IS NULL OR p_proof_url = '' THEN
    RAISE EXCEPTION 'Debes subir un comprobante';
  END IF;

  INSERT INTO payouts (driver_id, amount_usd, type, status, proof_url, description, created_by)
  VALUES (v_driver_id, p_amount_usd, 'driver_pay_platform', 'pendiente', p_proof_url,
          COALESCE(p_description, 'Pago del conductor a la plataforma'), v_driver_id)
  RETURNING id INTO v_payout_id;

  -- NOTIFICAR a admins/encargados
  -- El trigger on_notification_inserted encolará el push automáticamente.
  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT id, 'Pago de conductor por aprobar',
         'Un conductor pagó ' || p_amount_usd || '$ a la plataforma. Revisar.',
         'payout_driver_pay',
         jsonb_build_object('payout_id', v_payout_id, 'url', '/admin/liquidaciones')
  FROM profiles WHERE role IN ('super_admin', 'encargado');

  RETURN v_payout_id;
END;
$$;

-- 11.13 admin_pay_driver → notifica al conductor
CREATE OR REPLACE FUNCTION public.admin_pay_driver(
  p_driver_id UUID,
  p_amount_usd NUMERIC,
  p_description TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_payout_id UUID;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF p_amount_usd <= 0 THEN
    RAISE EXCEPTION 'Monto inválido';
  END IF;

  INSERT INTO payouts (driver_id, amount_usd, type, status, description, created_by)
  VALUES (p_driver_id, p_amount_usd, 'platform_pay_driver', 'pendiente',
          COALESCE(p_description, 'Pago de la plataforma al conductor'), v_admin_id)
  RETURNING id INTO v_payout_id;

  -- NOTIFICAR al conductor
  PERFORM public.notify_user(
    p_driver_id,
    'Pago disponible',
    'La plataforma te pagará ' || p_amount_usd || '$. Confirma cuando lo recibas.',
    'payout_platform_pay',
    jsonb_build_object('payout_id', v_payout_id, 'url', '/conductor/billetera')
  );

  RETURN v_payout_id;
END;
$$;

-- 11.14 approve_payout → notifica al conductor
CREATE OR REPLACE FUNCTION public.approve_payout(
  p_payout_id UUID,
  p_approve BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_payout RECORD;
  v_wallet RECORD;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT * INTO v_payout FROM payouts WHERE id = p_payout_id;
  IF v_payout.id IS NULL THEN
    RAISE EXCEPTION 'Pago no encontrado';
  END IF;

  IF v_payout.status != 'pendiente' THEN
    RAISE EXCEPTION 'El pago ya fue procesado';
  END IF;

  IF v_payout.type = 'driver_pay_platform' AND p_approve THEN
    SELECT * INTO v_wallet FROM wallets WHERE user_id = v_payout.driver_id;
    UPDATE wallets
    SET balance_usd = balance_usd + v_payout.amount_usd,
        updated_at = NOW()
    WHERE user_id = v_payout.driver_id;

    UPDATE payouts SET status = 'aprobado', reviewed_by = v_admin_id, updated_at = NOW()
    WHERE id = p_payout_id;

    INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description)
    VALUES (v_wallet.id, v_payout.driver_id, 'credito', v_payout.amount_usd, 'completado',
            'Pago del conductor a la plataforma (aprobado)');

    -- NOTIFICAR al conductor
    PERFORM public.notify_user(
      v_payout.driver_id,
      'Pago aprobado',
      'Tu pago de ' || v_payout.amount_usd || '$ fue aprobado. Tu deuda fue actualizada.',
      'payout_approved',
      jsonb_build_object('payout_id', p_payout_id, 'url', '/conductor/billetera')
    );
  ELSIF v_payout.type = 'driver_pay_platform' AND NOT p_approve THEN
    UPDATE payouts SET status = 'rechazado', reviewed_by = v_admin_id, updated_at = NOW()
    WHERE id = p_payout_id;

    -- NOTIFICAR al conductor
    PERFORM public.notify_user(
      v_payout.driver_id,
      'Pago rechazado',
      'Tu pago de ' || v_payout.amount_usd || '$ fue rechazado. Verifica el comprobante.',
      'payout_rejected',
      jsonb_build_object('payout_id', p_payout_id, 'url', '/conductor/billetera')
    );
  ELSIF v_payout.type = 'platform_pay_driver' THEN
    UPDATE payouts SET reviewed_by = v_admin_id, updated_at = NOW() WHERE id = p_payout_id;
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'payout_id', p_payout_id, 'status',
    (SELECT status FROM payouts WHERE id = p_payout_id));
END;
$$;

-- 11.15 driver_confirm_payout → notifica a admins al confirmar
CREATE OR REPLACE FUNCTION public.driver_confirm_payout(p_payout_id UUID)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_payout RECORD;
  v_wallet RECORD;
BEGIN
  SELECT * INTO v_payout FROM payouts WHERE id = p_payout_id;
  IF v_payout.id IS NULL THEN
    RAISE EXCEPTION 'Pago no encontrado';
  END IF;

  IF v_payout.driver_id != v_driver_id THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF v_payout.type != 'platform_pay_driver' OR v_payout.status != 'pendiente' THEN
    RAISE EXCEPTION 'Pago no válido para confirmar';
  END IF;

  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_driver_id;
  UPDATE wallets
  SET balance_usd = balance_usd - v_payout.amount_usd,
      updated_at = NOW()
  WHERE user_id = v_driver_id;

  UPDATE payouts SET status = 'confirmado', updated_at = NOW() WHERE id = p_payout_id;

  INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description)
  VALUES (v_wallet.id, v_driver_id, 'debito', v_payout.amount_usd, 'completado',
          'Pago recibido de la plataforma');

  -- NOTIFICAR a admins
  -- El trigger on_notification_inserted encolará el push automáticamente.
  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT id, 'Conductor confirmó pago',
         'Un conductor confirmó que recibió su pago de ' || v_payout.amount_usd || '$.',
         'payout_confirmed',
         jsonb_build_object('payout_id', p_payout_id, 'url', '/admin/liquidaciones')
  FROM profiles WHERE role IN ('super_admin', 'encargado');

  RETURN jsonb_build_object('success', TRUE, 'new_balance', v_wallet.balance_usd - v_payout.amount_usd);
END;
$$;

-- 11.16 adjust_driver_debt → notifica al conductor
CREATE OR REPLACE FUNCTION public.adjust_driver_debt(
  p_driver_id UUID,
  p_amount_usd NUMERIC,
  p_description TEXT DEFAULT 'Ajuste de deuda'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_wallet RECORD;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  SELECT * INTO v_wallet FROM wallets WHERE user_id = p_driver_id;

  UPDATE wallets
  SET balance_usd = balance_usd + p_amount_usd,
      updated_at = NOW()
  WHERE user_id = p_driver_id;

  INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, reviewed_by)
  VALUES (v_wallet.id, p_driver_id, 'ajuste', p_amount_usd, 'completado', p_description, v_admin_id);

  -- NOTIFICAR al conductor
  PERFORM public.notify_user(
    p_driver_id,
    'Ajuste de deuda',
    'Tu billetera fue ajustada: $' || p_amount_usd || '. Motivo: ' || p_description,
    'debt_adjustment',
    jsonb_build_object('amount', p_amount_usd, 'url', '/conductor/billetera')
  );

  RETURN jsonb_build_object(
    'success', TRUE,
    'driver_id', p_driver_id,
    'nuevo_balance', v_wallet.balance_usd + p_amount_usd
  );
END;
$$;

-- 11.17 rate_driver → notifica al conductor (opcional, al calificar)
CREATE OR REPLACE FUNCTION public.rate_driver(
  p_ride_id UUID,
  p_rating INTEGER,
  p_review TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_client_id UUID := auth.uid();
  v_ride RECORD;
BEGIN
  IF v_client_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  IF p_rating < 1 OR p_rating > 5 THEN
    RAISE EXCEPTION 'Calificación inválida (1-5)';
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF v_ride.client_id != v_client_id THEN
    RAISE EXCEPTION 'No autorizado para calificar este viaje';
  END IF;

  IF v_ride.status != 'completada' THEN
    RAISE EXCEPTION 'Solo puedes calificar viajes completados';
  END IF;

  UPDATE rides
  SET rating = p_rating,
      review = COALESCE(p_review, review)
  WHERE id = p_ride_id;

  -- NOTIFICAR al conductor (solo si no es rechazo grave)
  IF v_ride.driver_id IS NOT NULL THEN
    PERFORM public.notify_user(
      v_ride.driver_id,
      'Nueva calificación',
      'Te calificaron con ' || p_rating || ' estrellas.',
      'driver_rated',
      jsonb_build_object('ride_id', p_ride_id, 'rating', p_rating, 'url', '/conductor/historial')
    );
  END IF;

  RETURN jsonb_build_object('success', TRUE, 'ride_id', p_ride_id);
END;
$$;

-- 11.18 rate_client → notifica al cliente
CREATE OR REPLACE FUNCTION public.rate_client(
  p_ride_id UUID,
  p_rating INTEGER,
  p_review TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_ride RECORD;
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  IF p_rating < 1 OR p_rating > 5 THEN
    RAISE EXCEPTION 'Calificación inválida (1-5)';
  END IF;

  SELECT * INTO v_ride FROM rides WHERE id = p_ride_id;
  IF v_ride.id IS NULL THEN
    RAISE EXCEPTION 'Viaje no encontrado';
  END IF;

  IF v_ride.driver_id != v_driver_id THEN
    RAISE EXCEPTION 'No autorizado para calificar este viaje';
  END IF;

  IF v_ride.status != 'completada' THEN
    RAISE EXCEPTION 'Solo puedes calificar viajes completados';
  END IF;

  UPDATE rides
  SET client_rating = p_rating,
      client_review = COALESCE(p_review, client_review)
  WHERE id = p_ride_id;

  -- NOTIFICAR al cliente
  PERFORM public.notify_user(
    v_ride.client_id,
    'Nueva calificación',
    'El conductor te calificó con ' || p_rating || ' estrellas.',
    'client_rated',
    jsonb_build_object('ride_id', p_ride_id, 'rating', p_rating, 'url', '/cliente/historial')
  );

  RETURN jsonb_build_object('success', TRUE, 'ride_id', p_ride_id);
END;
$$;

-- ============================================================
-- 12. REOTORGAR GRANT EXECUTE A TODAS LAS FUNCIONES REFACTORIZADAS
-- ============================================================
GRANT EXECUTE ON FUNCTION public.notify_user TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.notify_users_by_role TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.send_admin_notification TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_or_create_push_subscription TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.delete_push_subscription TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.mark_notification_read TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.accept_ride TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.request_ride TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.request_ride_with_proof TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.complete_ride TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.confirm_ride_start TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.cancel_ride TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.register_driver_onboarding TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.review_driver TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.approve_recharge TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.request_wallet_recharge TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.approve_ride_proof TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.driver_pay_to_platform TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.admin_pay_driver TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.approve_payout TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.driver_confirm_payout TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.adjust_driver_debt TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rate_driver TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.rate_client TO anon, authenticated, service_role;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'Migración de notificaciones push completada' AS estado;