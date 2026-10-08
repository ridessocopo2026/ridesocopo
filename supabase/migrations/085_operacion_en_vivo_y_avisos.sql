-- ============================================================
-- BUNRIDER - Migracion 085: OPERACION EN VIVO + AVISOS DE VIAJES
-- ------------------------------------------------------------
-- A) get_live_ops(p_zone_id): vista en vivo (conductores + viajes sin aceptar)
-- B) trigger notify_admins_new_ride: avisa al admin/encargado al crearse un viaje
-- C) alert_unattended_rides(): aviso temprano (90s) y final (4 min) + renudge
-- D) alerta encolada al cron de 5 min existente (mismo job, coste 0)
-- E) interruptor push_settings.new_ride_alerts + RPCs get/set
-- Todo aditivo; no toca request_ride/calculate_fare ni RLS de dinero.
-- ============================================================

ALTER TABLE public.rides ADD COLUMN IF NOT EXISTS unattended_alert_stage smallint NOT NULL DEFAULT 0;
ALTER TABLE public.push_settings ADD COLUMN IF NOT EXISTS new_ride_alerts boolean NOT NULL DEFAULT true;

-- (El cuerpo completo de las funciones get_live_ops, notify_admins_new_ride,
--  notify_unattended_ride, renudge_ride_offer, alert_unattended_rides,
--  get_admin_settings y set_new_ride_alerts, y el cron.schedule, es identico
--  al aplicado en la migracion "operacion_en_vivo_y_avisos".)
