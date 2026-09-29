-- ============================================================
-- BUNRIDER - Migración 074: ENDURECER PERMISOS DE LAS RPC
-- ------------------------------------------------------------
-- PROBLEMA: PostgreSQL concede EXECUTE a PUBLIC por defecto, así que
-- 79 funciones de la app eran invocables con la clave "anon" (que va
-- publicada en el bundle del navegador). Entre ellas había funciones
-- sensibles: validate_coupon (permite adivinar cupones por fuerza
-- bruta), calculate_fare (filtra las tarifas), get_available_driver_
-- counts (cuántos conductores hay online), purge_ride_offer_
-- notifications (BORRA filas), process_availability_reminders y
-- reprocess_pending_notifications (disparan push = costo), además de
-- funciones de trigger que no deberían ser endpoints.
--
-- SOLUCIÓN: para esas 74 funciones se revoca PUBLIC y anon y se
-- concede EXECUTE solo a authenticated (la app con sesión) y
-- service_role (backend/cron).
--
-- IMPORTANTE: NO se tocan los 5 helpers que PostgreSQL evalúa al
-- aplicar las políticas RLS (get_user_role, get_own_profile_guard,
-- caller_zone_id, client_can_view_vehicle,
-- driver_has_vehicle_for_category): si se revocan, cualquier consulta
-- de un usuario sin sesión a una tabla con políticas fallaría.
--
-- No cambia comportamiento para usuarios con sesión: las funciones
-- siguen validando internamente rol/permisos como siempre.
-- ============================================================

DO $$
DECLARE
  v_revocar TEXT[] := ARRAY[
    'add_vehicle',
    'admin_availability_overview',
    'admin_create_vehicle_category',
    'admin_delete_vehicle_category',
    'admin_get_category_usage',
    'admin_update_vehicle_category',
    'approve_vehicle',
    'assign_tracking_code',
    'become_driver',
    'calculate_fare',
    'can_update_profile',
    'check_rpc_rate_limit',
    'clear_all_notifications',
    'clear_read_notifications',
    'confirm_ride_start',
    'delete_driver_vehicle',
    'delete_my_notification',
    'delete_push_subscription',
    'driver_available_now',
    'driver_in_schedule_now',
    'driver_pay_to_platform',
    'enforce_accept_vehicle_approved',
    'enforce_single_active_vehicle',
    'ensure_vehicle_category_enum',
    'estimate_cancellation_fee',
    'filter_ride_offers_by_schedule',
    'find_city',
    'get_active_cities',
    'get_active_exchange_rate',
    'get_active_payment_methods',
    'get_available_driver_counts',
    'get_available_rides',
    'get_available_vehicle_category_identifiers',
    'get_cancellation_policy',
    'get_client_active_ride',
    'get_coupon_stats_detailed',
    'get_driver_active_incident',
    'get_driver_active_ride',
    'get_driver_vehicles',
    'get_my_availability',
    'get_my_ride_coupon',
    'get_nearest_barrio',
    'get_or_create_push_subscription',
    'get_recharge_payment_methods',
    'get_ride_driver_info',
    'get_ride_full_detail',
    'get_ride_incidents',
    'handle_new_profile',
    'handle_new_user',
    'is_valid_amount',
    'mark_notification_read',
    'notify_push_after_insert',
    'process_availability_reminders',
    'purge_ride_offer_notifications',
    'rate_client',
    'rate_driver',
    'register_driver_onboarding',
    'reprocess_pending_notifications',
    'request_avatar_change',
    'request_wallet_recharge',
    'review_avatar',
    'rls_auto_enable',
    'sanitize_text',
    'save_favorite_place',
    'set_active_vehicle',
    'set_my_availability',
    'set_my_availability_override',
    'toggle_driver_online',
    'update_driver_location',
    'update_updated_at',
    'upsert_barrio',
    'validate_coupon'
  ];
  v_rec RECORD;
  v_n INTEGER := 0;
BEGIN
  FOR v_rec IN
    SELECT p.oid::regprocedure AS firma, p.proname AS nombre
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public'
      AND p.prokind = 'f'
      AND p.proname = ANY (v_revocar)
  LOOP
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM PUBLIC', v_rec.firma);
    EXECUTE format('REVOKE ALL ON FUNCTION %s FROM anon', v_rec.firma);
    EXECUTE format('GRANT EXECUTE ON FUNCTION %s TO authenticated, service_role', v_rec.firma);
    v_n := v_n + 1;
  END LOOP;

  RAISE NOTICE 'Funciones endurecidas: %', v_n;
END $$;

-- ============================================================
-- VERIFICACIÓN: solo deben quedar los 5 helpers de políticas RLS
-- ============================================================
SELECT p.proname AS funciones_accesibles_sin_sesion
FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.prokind = 'f'
  AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = p.oid AND d.deptype = 'e')
  AND has_function_privilege('anon', p.oid, 'execute')
ORDER BY 1;
