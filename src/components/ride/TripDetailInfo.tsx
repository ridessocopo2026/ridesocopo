import { XCircle, ShieldAlert, CalendarDays, Receipt } from 'lucide-react'
import type { Ride, RideIncident, IncidentType, IncidentStatus } from '@/types/database'

interface TripDetailInfoProps {
  ride: Ride
  incident?: RideIncident | null
  currentUserId?: string
}

const incidentTypeLabels: Record<IncidentType, string> = {
  accidente: '🚨 Accidente',
  falla_mecanica: '🔧 Falla mecánica',
  urgencia_medica: '🏥 Emergencia médica',
  clima: '🌧️ Clima',
  otro: '❓ Otro',
  viaje_no_realizado: '🚫 Viaje no realizado',
  disputa_cobro: '💸 Disputa de cobro'
}

const incidentStatusLabels: Record<IncidentStatus, { label: string; className: string }> = {
  abierto: { label: 'Abierto', className: 'badge-warning' },
  en_revision: { label: 'En revisión', className: 'badge-info' },
  resuelto: { label: 'Resuelto', className: 'badge-success' },
  cerrado: { label: 'Cerrado', className: 'badge-danger' }
}

const faultLabels: Record<string, string> = {
  cliente: 'El cliente',
  conductor: 'El conductor',
  accidente: 'Accidente / Fuerza mayor'
}

const reimbursementLabels: Record<string, string> = {
  auto_completado: 'Reembolsado automáticamente a la billetera',
  pendiente_manual: 'Reembolso manual pendiente (Pago Móvil)',
  no_aplica: 'No aplica (pago en efectivo o sin retención)'
}

const rideStatusLabels: Record<string, string> = {
  buscando: 'Buscando conductor',
  aceptada: 'Aceptada',
  en_ruta: 'En ruta al destino',
  completada: 'Completada',
  cancelada: 'Cancelada',
  incidente: 'Incidente en revisión'
}

// resolution_details viene como JSONB: puede ser objeto o string según la versión
const parseResolutionDetails = (details: any): any => {
  if (!details) return null
  if (typeof details === 'string') {
    try { return JSON.parse(details) } catch { return null }
  }
  return details
}

const fmt = (value: number | string | null | undefined): string =>
  `${Number(value ?? 0).toFixed(2)}$`

const fmtDate = (iso?: string): string | null => {
  if (!iso) return null
  return new Date(iso).toLocaleString('es-VE', {
    day: 'numeric', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit'
  })
}

export function TripDetailInfo({ ride, incident, currentUserId }: TripDetailInfoProps) {
  const details = parseResolutionDetails(incident?.resolution_details)
  const incidentResolved = !!incident && (incident.status === 'resuelto' || incident.status === 'cerrado')
  const isDispute = !!incident && (
    incident.incident_type === 'viaje_no_realizado' ||
    incident.incident_type === 'disputa_cobro' ||
    ride.status === 'completada'
  )

  const whoCancelled = (): string => {
    if (!ride.cancelled_by) return 'No registrado'
    if (currentUserId && ride.cancelled_by === currentUserId) {
      return ride.cancelled_by === ride.client_id ? 'Tú (cliente)' : 'Tú (conductor)'
    }
    if (ride.cancelled_by === ride.client_id) return 'El cliente'
    if (ride.cancelled_by === ride.driver_id) return 'El conductor'
    return 'La administración'
  }

  // Fila de monto que soporta el formato V3 y el formato legacy (017)
  const moneyRow = (
    key: string,
    legacyKey: string | null,
    label: string,
    className: string
  ) => {
    const raw = details?.[key] ?? (legacyKey ? details?.[legacyKey] : undefined)
    if (raw === undefined || raw === null) return null
    const value = Number(raw)
    if (isNaN(value) || value <= 0) return null
    return (
      <div key={label} className="flex justify-between text-sm">
        <span className="text-surface-500">{label}</span>
        <span className={`font-medium ${className}`}>{fmt(value)}</span>
      </div>
    )
  }

  return (
    <>
      {/* Resumen del viaje */}
      <div className="card">
        <div className="flex items-center gap-2 mb-3">
          <CalendarDays className="w-5 h-5 text-primary-600" />
          <h2 className="font-semibold text-surface-800">Resumen del viaje</h2>
        </div>
        <div className="space-y-2 text-sm">
          <div className="flex justify-between">
            <span className="text-surface-500">Estado</span>
            <span className="font-medium text-surface-700">{rideStatusLabels[ride.status] || ride.status}</span>
          </div>
          {ride.tracking_code && (
            <div className="flex justify-between">
              <span className="text-surface-500">Código de seguimiento</span>
              <span className="font-mono font-bold text-primary-600">{ride.tracking_code}</span>
            </div>
          )}
          <div className="flex justify-between">
            <span className="text-surface-500">Solicitado</span>
            <span className="text-surface-700">{fmtDate(ride.created_at)}</span>
          </div>
          {ride.started_at && (
            <div className="flex justify-between">
              <span className="text-surface-500">Iniciado</span>
              <span className="text-surface-700">{fmtDate(ride.started_at)}</span>
            </div>
          )}
          {ride.completed_at && (
            <div className="flex justify-between">
              <span className="text-surface-500">Completado</span>
              <span className="text-surface-700">{fmtDate(ride.completed_at)}</span>
            </div>
          )}
          <div className="flex justify-between">
            <span className="text-surface-500">Método de pago</span>
            <span className="text-surface-700">{ride.payment_method || 'No especificado'}</span>
          </div>
        </div>
      </div>

      {/* Cancelación del viaje */}
      {ride.status === 'cancelada' && (
        <div className="card border-2 border-red-100 bg-red-50/40">
          <div className="flex items-center gap-2 mb-3">
            <XCircle className="w-5 h-5 text-red-600" />
            <h2 className="font-semibold text-surface-800">Cancelación del viaje</h2>
          </div>
          <div className="space-y-2 text-sm">
            <div className="flex justify-between">
              <span className="text-surface-500">Cancelado por</span>
              <span className="font-medium text-surface-700">{whoCancelled()}</span>
            </div>
            {ride.cancel_reason && (
              <div className="flex justify-between gap-4">
                <span className="text-surface-500 flex-shrink-0">Motivo</span>
                <span className="text-surface-700 text-right">{ride.cancel_reason}</span>
              </div>
            )}
            {Number(ride.cancellation_fee_usd) > 0 && (
              <div className="flex justify-between">
                <span className="text-surface-500">Tarifa de cancelación</span>
                <span className="font-medium text-red-600">{fmt(ride.cancellation_fee_usd)}</span>
              </div>
            )}
            {Number(ride.driver_compensation_usd) > 0 && (
              <div className="flex justify-between">
                <span className="text-surface-500">Compensación al conductor</span>
                <span className="font-medium text-emerald-700">{fmt(ride.driver_compensation_usd)}</span>
              </div>
            )}
            {ride.reimbursement_status && (
              <div className="flex justify-between gap-4">
                <span className="text-surface-500 flex-shrink-0">Reembolso al cliente</span>
                <span className="text-surface-700 text-right">
                  {reimbursementLabels[ride.reimbursement_status] || ride.reimbursement_status}
                </span>
              </div>
            )}
          </div>
        </div>
      )}

      {/* Incidente / Disputa */}
      {incident && (
        <div className={`card border-2 ${incidentResolved ? 'border-amber-100' : 'border-red-100'}`}>
          <div className="flex items-center justify-between mb-3">
            <div className="flex items-center gap-2">
              <ShieldAlert className={`w-5 h-5 ${incidentResolved ? 'text-emerald-600' : 'text-red-600'}`} />
              <h2 className="font-semibold text-surface-800">
                {isDispute ? 'Disputa del viaje' : 'Incidente del viaje'}
              </h2>
            </div>
            <span className={incidentStatusLabels[incident.status].className}>
              {incidentStatusLabels[incident.status].label}
            </span>
          </div>

          <div className="space-y-2 text-sm">
            <div className="flex justify-between">
              <span className="text-surface-500">Motivo del reporte</span>
              <span className="font-medium text-surface-700">{incidentTypeLabels[incident.incident_type]}</span>
            </div>
            <div className="flex justify-between">
              <span className="text-surface-500">Fecha del reporte</span>
              <span className="text-surface-700">{fmtDate(incident.created_at)}</span>
            </div>
            {incident.description && (
              <div>
                <p className="text-surface-500 mb-1">Descripción</p>
                <p className="text-surface-700 bg-surface-50 rounded-lg p-3 border border-surface-100">
                  {incident.description}
                </p>
              </div>
            )}

            {incidentResolved ? (
              <div className="mt-2 space-y-3">
                {incident.resolution && (
                  <div className="bg-emerald-50 border border-emerald-200 rounded-lg p-3">
                    <p className="text-xs font-semibold text-emerald-700 mb-1">
                      Resolución del administrador
                    </p>
                    <p className="text-sm text-emerald-800">{incident.resolution}</p>
                  </div>
                )}
                {details && Object.keys(details).length > 0 && (
                  <div className="space-y-1.5">
                    <p className="text-xs font-semibold text-surface-500 uppercase tracking-wide">
                      Detalles de la resolución
                    </p>
                    {details.at_fault && (
                      <div className="flex justify-between text-sm">
                        <span className="text-surface-500">Culpable</span>
                        <span className="font-medium text-surface-700">
                          {faultLabels[details.at_fault] || details.at_fault}
                        </span>
                      </div>
                    )}
                    {moneyRow('refund_client', 'refund_amount', 'Reembolso al cliente', 'text-emerald-700')}
                    {moneyRow('penalty', null, 'Penalización', 'text-red-600')}
                    {moneyRow('compensate_driver', 'compensated_driver', 'Compensación al conductor', 'text-emerald-700')}
                    {details.ride_cancelled !== undefined && (
                      <div className="flex justify-between text-sm">
                        <span className="text-surface-500">Viaje cancelado</span>
                        <span className="font-medium text-surface-700">
                          {details.ride_cancelled ? 'Sí' : 'No'}
                        </span>
                      </div>
                    )}
                  </div>
                )}
              </div>
            ) : (
              <div className="bg-amber-50 border border-amber-200 rounded-lg p-3 mt-2">
                <p className="text-xs text-amber-700">
                  La plataforma está revisando este reporte. Se te notificará cuando haya una resolución.
                </p>
              </div>
            )}
          </div>
        </div>
      )}


      {/* Desglose de la tarifa */}
      <div className="card">
        <div className="flex items-center gap-2 mb-3">
          <Receipt className="w-5 h-5 text-primary-600" />
          <h2 className="font-semibold text-surface-800">Desglose de la tarifa</h2>
        </div>
        <div className="space-y-2 text-sm">
          <div className="flex justify-between">
            <span className="text-surface-500">Tarifa base</span>
            <span className="text-surface-700">{fmt(ride.base_fare_usd)}</span>
          </div>
          <div className="flex justify-between">
            <span className="text-surface-500">Recargo por origen</span>
            <span className="text-surface-700">{fmt(ride.origin_surcharge_usd)}</span>
          </div>
          <div className="flex justify-between">
            <span className="text-surface-500">Recargo por destino</span>
            <span className="text-surface-700">{fmt(ride.destination_surcharge_usd)}</span>
          </div>
          <div className="flex justify-between">
            <span className="text-surface-500">Total estimado</span>
            <span className="text-surface-700">{fmt(ride.total_fare_usd)}</span>
          </div>
          {Number(ride.discount_usd) > 0 && (
            <div className="flex justify-between">
              <span className="text-surface-500">Descuento aplicado</span>
              <span className="font-medium text-emerald-700">-{fmt(ride.discount_usd)}</span>
            </div>
          )}
          <div className="flex justify-between">
            <span className="text-surface-500">Comisión de la app</span>
            <span className="text-surface-700">{fmt(ride.commission_usd)}</span>
          </div>
          <div className="flex justify-between pt-2 border-t border-surface-100">
            <span className="font-semibold text-surface-800">Tarifa final</span>
            <span className="font-bold text-primary-600">{fmt(ride.final_fare_usd)}</span>
          </div>
        </div>
      </div>
    </>
  )
}

