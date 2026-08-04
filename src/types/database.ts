export type UserRole = 'cliente' | 'conductor' | 'encargado' | 'super_admin'
export type DriverStatus = 'pendiente' | 'aprobado' | 'rechazado' | 'suspendido'
export type VehicleCategoryType = 'moto' | 'carro' | 'camioneta'
export type RideStatus = 'buscando' | 'aceptada' | 'en_ruta' | 'completada' | 'cancelada' | 'incidente'
export type ReimbursementStatus = 'auto_completado' | 'pendiente_manual' | 'no_aplica'
export type IncidentType = 'accidente' | 'falla_mecanica' | 'urgencia_medica' | 'clima' | 'otro'
export type IncidentStatus = 'abierto' | 'en_revision' | 'resuelto' | 'cerrado'
export type CancellationFault = 'cliente' | 'conductor' | 'accidente'
export type PaymentMethod = string
export type TransactionType = 'recarga' | 'comision' | 'debito' | 'credito' | 'ajuste'
export type TransactionStatus = 'pendiente' | 'aprobado' | 'rechazado' | 'completado'
export type ZoneType = 'cobertura_general' | 'zona_especifica'

export interface Profile {
  id: string
  full_name: string
  email: string
  phone?: string
  role: UserRole
  avatar_url?: string
  zone_id?: string
  driver_status?: DriverStatus
  is_online: boolean
  created_at: string
  updated_at: string
  onboarding_completed: boolean
}

export interface Barrio {
  id: string
  name: string
  surcharge_usd: number
  lat?: number
  lng?: number
  description?: string
  is_active: boolean
  created_at: string
  updated_at: string
}

export interface PaymentMethodConfig {
  id: string
  name: string
  description?: string
  icon?: string
  is_active: boolean
  proof_required?: boolean
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
  polygon?: any
  is_active: boolean
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
  status: RideStatus
  proof_url?: string
  proof_status?: string
  driver_location_lat?: number
  driver_location_lng?: number
  driver_last_update?: string
  driver_start_confirmed?: boolean
  client_start_confirmed?: boolean
  started_at?: string
  completed_at?: string
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
  payment_method: string
  commission_refunded: boolean
  note?: string
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
}