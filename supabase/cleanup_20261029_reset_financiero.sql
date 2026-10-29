-- ============================================================
-- RESET FINANCIERO - 29/10/2026
-- ------------------------------------------------------------
-- SOLO PARA DATOS DE PRUEBA. Ejecutado por solicitud del admin:
-- "todas las transacciones han sido de pruebas, nadie le debe a
--  nadie y nadie ha ganado nada".
--
-- Qué hace:
--   1) Respalda en el esquema `backup` (no expuesto por PostgREST):
--      transacciones, driver_earnings, payouts, wallets,
--      campos financieros de rides y notificaciones financieras.
--   2) Borra transactions, driver_earnings y payouts.
--   3) Deja todos los saldos de wallets en 0.
--   4) Resetea fee/compensación/reembolso de los rides.
--   5) Borra notificaciones financieras obsoletas.
--   6) Registra la limpieza en audit_logs.
--
-- NO ejecutar en producción con datos reales.
-- ============================================================

begin;

create schema if not exists backup;

create table if not exists backup.transactions_20261029 as
  select * from public.transactions;

create table if not exists backup.driver_earnings_20261029 as
  select * from public.driver_earnings;

create table if not exists backup.payouts_20261029 as
  select * from public.payouts;

create table if not exists backup.wallets_20261029 as
  select * from public.wallets;

create table if not exists backup.rides_finanzas_20261029 as
  select id, cancellation_fee_usd, driver_compensation_usd, reimbursement_status
  from public.rides
  where cancellation_fee_usd <> 0
     or driver_compensation_usd <> 0
     or reimbursement_status is not null;

create table if not exists backup.notificaciones_financieras_20261029 as
  select * from public.notifications
  where type in (
    'refund_pending','refund_completed','refund_rejected',
    'recharge_approved','recharge_rejected','recharge_pending',
    'payout_driver_pay','payout_platform_pay','payout_approved','payout_rejected','payout_confirmed',
    'debt_adjustment','debt_payment',
    'cancellation_charge_pending','cancellation_charge_approved','cancellation_charge_waived',
    'driver_compensation'
  );

insert into public.audit_logs (user_id, action, entity_type, entity_id, details)
values (
  'cbbd6371-d96b-44aa-8f32-460b8ade5594',
  'CLEANUP_TEST_DATA',
  'system',
  null,
  jsonb_build_object(
    'reason', 'Datos de prueba: reset financiero solicitado por el administrador',
    'transactions_deleted', (select count(*) from public.transactions),
    'driver_earnings_deleted', (select count(*) from public.driver_earnings),
    'payouts_deleted', (select count(*) from public.payouts),
    'wallets_zeroed', (select count(*) from public.wallets where balance_usd <> 0),
    'rides_financial_reset', (select count(*) from public.rides where cancellation_fee_usd <> 0 or driver_compensation_usd <> 0 or reimbursement_status is not null),
    'financial_notifications_deleted', (select count(*) from public.notifications where type in (
      'refund_pending','refund_completed','refund_rejected',
      'recharge_approved','recharge_rejected','recharge_pending',
      'payout_driver_pay','payout_platform_pay','payout_approved','payout_rejected','payout_confirmed',
      'debt_adjustment','debt_payment',
      'cancellation_charge_pending','cancellation_charge_approved','cancellation_charge_waived',
      'driver_compensation')),
    'backup_schema', 'backup'
  )
);

delete from public.transactions;
delete from public.driver_earnings;
delete from public.payouts;

delete from public.notifications
where type in (
  'refund_pending','refund_completed','refund_rejected',
  'recharge_approved','recharge_rejected','recharge_pending',
  'payout_driver_pay','payout_platform_pay','payout_approved','payout_rejected','payout_confirmed',
  'debt_adjustment','debt_payment',
  'cancellation_charge_pending','cancellation_charge_approved','cancellation_charge_waived',
  'driver_compensation'
);

update public.wallets
set balance_usd = 0, updated_at = now()
where balance_usd <> 0;

update public.rides
set cancellation_fee_usd = 0,
    driver_compensation_usd = 0,
    reimbursement_status = null,
    updated_at = now()
where cancellation_fee_usd <> 0
   or driver_compensation_usd <> 0
   or reimbursement_status is not null;

commit;

-- Verificación
select
  (select count(*) from public.transactions) as transactions,
  (select count(*) from public.driver_earnings) as driver_earnings,
  (select count(*) from public.payouts) as payouts,
  (select count(*) from public.wallets where balance_usd <> 0) as wallets_con_saldo,
  (select count(*) from public.rides where cancellation_fee_usd <> 0 or driver_compensation_usd <> 0 or reimbursement_status is not null) as rides_con_finanzas;
