import type { CashBills } from '@/lib/cash'

export type UserRole = 'cliente' | 'conductor' | 'encargado' | 'super_admin'
export type DriverStatus = 'pendiente' | 'aprobado' | 'rechazado' | 'suspendido'
export type VehicleCategoryType = 'moto' | 'carro' | 'camioneta' | (string & {})
export type RideStatus = 'buscando' | 'aceptada' | 'en_ruta' | 'completada' | 'cancelada' | 'incidente'
export type ReimbursementStatus = 'auto_completado' | 'pendiente_manual' | 'no_aplica'
export type IncidentType = 'accidente' | 'falla_mecanica' | 'urgencia_medica' | 'clima' | 'otro' | 'viaje_no_realizado' | 'disputa_cobro' | 'cancelacion_cliente'
export type IncidentStatus = 'abierto' | 'en_revision' | 'resuelto' | 'cerrado'
export type CancellationFault = 'cliente' | 'conductor' | 'accidente'
export type PaymentMethod = string
export type TransactionType = 'recarga' | 'comision' | 'debito' | 'credito' | 'ajuste'
export type TransactionStatus = 'pendiente' | 'aprobado' | 'rechazado' | 'completado'
export type ZoneType = 'cobertura_general' | 'zona_especifica'
export type AccountStatus = 'activo' | 'pausado' | 'bloqueado' | 'eliminado'

export interface Profile {
  id: string
  full_name: string
  email: string
  phone?: string
  role: UserRole
  avatar_url?: string
  avatar_pending_url?: string | null
  full_name_pending?: string | null
  full_name_pending_at?: string | null
  zone_id?: string
  driver_status?: DriverStatus
  is_online: boolean
  created_at: string
  updated_at: string
  onboarding_completed: boolean
  availability_auto?: boolean
  available_from?: string | null
  available_to?: string | null
  available_days?: number[] | null
  available_override_until?: string | null
  availability_push?: boolean
  // Estado de la cuenta (migración 079)
  status?: AccountStatus
  status_reason?: string | null
  status_until?: string | null
}

export interface DriverAvailability {
  is_online: boolean
  auto: boolean
  from?: string | null
  to?: string | null
  days?: number[]
  in_schedule: boolean
  override_until?: string | null
  push: boolean
  local_now?: string
  dow?: number
}

export interface Barrio {
  id: string
  name: string
  zone_id?: string
  tipo?: 'barrio' | 'urbanizacion' | 'sector'
  surcharge_usd: number
  surcharge_moto_usd?: number
  surcharge_carro_usd?: number
  surcharge_camioneta_usd?: number
  lat?: number
  lng?: number
  description?: string
  is_active: boolean
  created_at: string
  updated_at: string
}

export interface BarrioSurcharge {
  barrio_id: string
  zone_id?: string
  category: VehicleCategoryType
  surcharge_usd: number
  display_name?: string
  icon?: string
}

export interface PaymentMethodConfig {
  id: string
  name: string
  description?: string
  icon?: string
  is_active: boolean
  proof_required?: boolean
  for_recharge?: boolean
  created_at: string
}

export interface PaymentMethodField {
  id: string
  payment_method_id: string
  label: string
  value: string
  is_copyable: boolean
  created_at: string
}

export interface Zone {
  id: string
  name: string
  description?: string
  zone_type: ZoneType
  surcharge_usd: number
  center_lat?: number
  center_lng?: number
  support_whatsapp?: string
  polygon?: any
  is_active: boolean
  cash_opening_balance_usd?: number
  created_by?: string
  created_at: string
  updated_at: string
}

export interface VehicleCategory {
  id: string
  name: VehicleCategoryType
  display_name: string
  base_fare_usd: number
  max_passengers: number
  description?: string
  icon?: string
  is_active: boolean
  created_at: string
}

export interface Vehicle {
  id: string
  driver_id: string
  max_passengers: number
  category: VehicleCategoryType
  brand: string
  model: string
  year: number
  color: string
  plate: string
  photo_url?: string
  is_active: boolean
  is_approved?: boolean
  is_active_vehicle?: boolean
  shared_with_vehicle_id?: string | null
  is_shared?: boolean
  shared_with_name?: string | null
  created_at: string
  updated_at: string
}

export interface DriverDocument {
  id: string
  driver_id: string
  cedula_number: string
  cedula_photo_url: string
  license_number: string
  license_photo_url: string
  license_expiry_date: string
  profile_photo_url?: string
  created_at: string
  updated_at: string
}

export interface Wallet {
  id: string
  user_id: string
  balance_usd: number
  debt_limit_usd: number
  is_blocked: boolean
  created_at: string
  updated_at: string
}

export interface Transaction {
  id: string
  wallet_id: string
  user_id: string
  type: TransactionType
  amount_usd: number
  status: TransactionStatus
  description?: string
  reference?: string
  proof_url?: string
  ride_id?: string
  reviewed_by?: string
  reviewed_at?: string
  created_at: string
}

export interface Ride {
  id: string
  client_id: string
  driver_id?: string
  vehicle_id?: string
  category: VehicleCategoryType
  origin_lat: number
  origin_lng: number
  origin_address?: string
  origin_zone_id?: string
  destination_lat: number
  destination_lng: number
  destination_address?: string
  destination_zone_id?: string
  destination_barrio_id?: string
  destination_barrio_name?: string
  destination_is_exact?: boolean
  base_fare_usd: number
  origin_surcharge_usd: number
  destination_surcharge_usd: number
  total_fare_usd: number
  coupon_id?: string
  discount_usd: number
  final_fare_usd: number
  commission_usd: number
  commission_rate: number
  payment_method: PaymentMethod
  /** Efectivo: billetes con los que pagará el pasajero (migración 110) */
  cash_bills?: CashBills | null
  status: RideStatus
  tracking_code?: string
  proof_url?: string
  proof_status?: string
  driver_location_lat?: number
  driver_location_lng?: number
  driver_last_update?: string
  driver_start_confirmed?: boolean
  client_start_confirmed?: boolean
  started_at?: string
  completed_at?: string
  completed_by?: string
  client_confirmed_at?: string
  cancelled_by?: string
  cancel_reason?: string
  cancellation_fee_usd: number
  driver_compensation_usd: number
  incident_id?: string
  reimbursement_status?: ReimbursementStatus
  rating?: number
  review?: string
  client_rating?: number
  client_review?: string
  created_at: string
  updated_at: string
}

/**
 * Datos del cliente que ve el conductor SOLO después de aceptar el viaje.
 * Los devuelve la RPC `get_ride_client_info` (valida driver_id = auth.uid()).
 */
export interface RideClientInfo {
  client: {
    id: string
    full_name: string
    avatar_url: string | null
    rating_avg: number | null
    rating_count: number
    rides_count: number
  }
  tracking_code?: string | null
}

export interface CancellationPolicy {
  id: string
  ride_status: 'buscando' | 'aceptada' | 'en_ruta'
  at_fault: CancellationFault
  fee_rate: number
  min_fee: number
  max_fee?: number
  driver_compensation_rate: number
  refunds_commission: boolean
  is_active: boolean
  created_at: string
  updated_at: string
}

export interface RideIncident {
  id: string
  ride_id: string
  reported_by: string
  incident_type: IncidentType
  description?: string
  photo_urls: string[]
  status: IncidentStatus
  resolution?: string
  resolution_details?: any
  resolved_by?: string
  resolved_at?: string
  created_at: string
  updated_at: string
}

export interface CancellationEstimate {
  fee: number
  compensation: number
  refund: number
  /** Efectivo: cargo que se registrará y el admin deberá verificar */
  charge?: number
  payment_method: string
  commission_refunded: boolean
  note?: string
}

export interface DriverEarning {
  id: string
  ride_id: string
  driver_id: string
  fare_usd: number
  commission_usd: number
  cash_received_usd: number
  app_credit_usd: number
  payment_method: string
  status: 'completado' | 'cancelado' | 'ajustado'
  created_at: string
}

export interface DriverEarningSummary {
  ride_id: string
  fare_usd: number
  commission_usd: number
  cash_received_usd: number
  app_credit_usd: number
  payment_method: string
  destination: string | null
  created_at: string
}

export interface Coupon {
  id: string
  code: string
  description?: string
  discount_type: 'percentage' | 'fixed'
  discount_value: number
  max_uses?: number
  used_count: number
  valid_from?: string
  valid_until?: string
  per_user_limit?: number
  first_ride_only?: boolean
  min_fare_usd?: number
  is_active: boolean
  created_by?: string
  created_at: string
}

export interface Banner {
  id: string
  title: string
  subtitle?: string
  image_url?: string
  link_url?: string
  is_active: boolean
  sort_order: number
  starts_at?: string
  ends_at?: string
  zone_id?: string | null
  created_by?: string
  created_at: string
  updated_at: string
}

export interface FavoritePlace {
  id: string
  user_id: string
  name: string
  address?: string
  lat: number
  lng: number
  created_at: string
}

export interface ExchangeRate {
  id: string
  rate_bs_per_usd: number
  is_active: boolean
  updated_by?: string
  updated_at: string
}

export interface Payout {
  id: string
  driver_id: string
  amount_usd: number
  type: 'driver_pay_platform' | 'platform_pay_driver'
  status: 'pendiente' | 'aprobado' | 'rechazado' | 'confirmado'
  proof_url?: string
  payment_method?: string | null
  created_by?: string
  reviewed_by?: string
  ride_id?: string
  description?: string
  created_at: string
  updated_at: string
}

export interface Notification {
  id: string
  user_id: string
  title: string
  body?: string
  type?: string
  data?: any
  is_read: boolean
  created_at: string
}

export interface PushSubscription {
  id: string
  user_id: string
  endpoint: string
  p256dh: string
  auth: string
  user_agent?: string
  created_at: string
  updated_at: string
}

export interface NotificationOutbox {
  id: string
  notification_id: string
  user_id: string
  sent_at?: string
  error?: string
  attempts: number
  created_at: string
}

export interface FareCalculation {
  base_fare: number
  origin_surcharge: number
  destination_surcharge: number
  total_fare: number
  discount: number
  final_fare: number
  origin_zone_id: string
  destination_zone_id: string
  destination_barrio_id?: string | null
  destination_barrio_name?: string | null
  coupon_id?: string | null
  coupon_code?: string | null
  coupon_reason?: string | null
  coupon_message?: string | null
}

export interface CouponStats {
  total_discount_usd: number
  redemptions: number
  viajes_con_cupon?: number
  usuarios_unicos?: number
  descuento_promedio?: number
  cupones_activos?: number
  top_cupones?: { code: string; redemptions: number; discount: number }[]
}

// ============================================================
// Estado de cuentas / tesorería (migración 111)
// ============================================================
export interface TreasuryZoneInfo {
  zone_id: string | null
  es_global: boolean
  forzada_por_rol: boolean
}

export interface TreasuryOverview {
  zona: TreasuryZoneInfo
  banco: {
    recargas: number
    viajes_pago_movil: number
    cobros_conductores: number
    pagos_conductores: number
    total: number
    digital: { ingresos: number; egresos: number; neto: number }
    billetera: { ingresos: number; egresos: number; neto: number }
    sin_clasificar: { ingresos: number; egresos: number; neto: number }
  }
  efectivo: {
    por_cobrar: number
    recargas_efectivo: number
    cobrado_conductores: number
    pagado_conductores: number
    en_caja: number
    fondo_inicial: number
    en_caja_total: number
  }
  deudas: {
    conductores_deben: number
    app_debe_conductores: number
    neto_conductores: number
    clientes_deben: number
    app_debe_clientes: number
    neto_general: number
  }
  conteos: {
    conductores_total: number
    conductores_con_deuda: number
    conductores_con_saldo: number
    conductores_sobre_limite: number
  }
  cuadre_diferencia: number
}

export interface DriverAccount {
  id: string
  full_name: string
  email?: string | null
  phone?: string | null
  zone_id?: string | null
  zone_name?: string | null
  driver_status?: string | null
  account_status?: string | null
  balance_usd: number
  debt_limit_usd: number
  excede_limite: boolean
  pending_payout_usd: number
  last_movement_at?: string | null
}

export interface DriverAccountsResponse {
  total: number
  totales: {
    suma_deben: number
    suma_debo: number
    con_deuda: number
    con_saldo: number
    sobre_limite: number
  }
  items: DriverAccount[]
}