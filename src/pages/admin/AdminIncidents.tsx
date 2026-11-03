import { useCallback, useEffect, useState } from 'react'
import { ShieldAlert, CheckCircle, Loader2, MapPin, DollarSign, Camera, ChevronLeft, ChevronRight } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { EmptyState } from '@/components/ui/EmptyState'
import { SkeletonList } from '@/components/ui/Skeleton'
import { ImageLightbox } from '@/components/ui/ImageLightbox'
import { IncidentContacts } from '@/components/admin/IncidentContacts'
import type { IncidentPerson } from '@/components/admin/IncidentContacts'
import { resolveProofUrl } from '@/lib/storageUtils'
import type {
  AdminIncidentRow,
  AdminIncidentsPage,
  IncidentType,
  IncidentStatus
} from '@/types/database'

/** Incidentes por página: paginar en el servidor ahorra egress. */
const PAGE_SIZE = 20

const incidentTypeLabels: Record<IncidentType, string> = {
  accidente: '🚨 Accidente',
  falla_mecanica: '🔧 Falla mecánica',
  urgencia_medica: '🏥 Emergencia médica',
  clima: '🌧️ Clima',
  otro: '❓ Otro',
  viaje_no_realizado: '🚫 Viaje no realizado',
  disputa_cobro: '💸 Disputa de cobro',
  cancelacion_cliente: '🚫 Cancelación en curso'
}

const statusLabels: Record<IncidentStatus, { label: string; className: string }> = {
  abierto: { label: 'Abierto', className: 'badge-warning' },
  en_revision: { label: 'En revisión', className: 'badge-info' },
  resuelto: { label: 'Resuelto', className: 'badge-success' },
  cerrado: { label: 'Cerrado', className: 'badge-danger' }
}

// @ts-ignore - Supabase devuelve JSONB como string o array según la versión
// Esta función sanitiza photo_urls para que SIEMPRE sea un array de strings
const parsePhotoUrls = (photoUrls: any): string[] => {
  if (!photoUrls) return []
  if (Array.isArray(photoUrls)) {
    return photoUrls.filter((u): u is string => typeof u === 'string')
  }
  if (typeof photoUrls === 'string') {
    try {
      const parsed = JSON.parse(photoUrls)
      return Array.isArray(parsed) ? parsed.filter((u): u is string => typeof u === 'string') : []
    } catch {
      return photoUrls.trim() ? [photoUrls.trim()] : []
    }
  }
  return []
}

// @ts-ignore - resolution_details viene de JSONB y puede ser string u objeto
const parseResolutionDetails = (details: any): any => {
  if (!details) return null
  if (typeof details === 'string') {
    try { return JSON.parse(details) } catch { return null }
  }
  return details
}

/** Texto del incidente sin el emoji inicial: "🚨 Accidente" → "Accidente" */
const incidentTypeName = (type: IncidentType): string =>
  incidentTypeLabels[type].split(' ').slice(1).join(' ') || incidentTypeLabels[type]

/**
 * Personas involucradas de un incidente, listas para el componente de
 * contactos. Se agrega a quien reportó cuando no es el cliente ni el
 * conductor (por ejemplo un encargado), para no dejarlo sin contacto.
 */
const buildIncidentPeople = (incident: AdminIncidentRow): IncidentPerson[] => {
  const people: IncidentPerson[] = []

  if (incident.client_id) {
    people.push({
      key: `cliente-${incident.id}`,
      label: 'Cliente',
      kind: 'cliente',
      name: incident.client_name,
      phone: incident.client_phone,
      isReporter: incident.reported_by === incident.client_id
    })
  }

  if (incident.driver_id) {
    people.push({
      key: `conductor-${incident.id}`,
      label: 'Conductor',
      kind: 'conductor',
      name: incident.driver_name,
      phone: incident.driver_phone,
      isReporter: incident.reported_by === incident.driver_id
    })
  }

  const reporterIsParticipant =
    incident.reported_by === incident.client_id || incident.reported_by === incident.driver_id

  if (incident.reported_by && !reporterIsParticipant) {
    people.push({
      key: `reporto-${incident.id}`,
      label: `Reportó (${incident.reporter_role || 'usuario'})`,
      kind: 'soporte',
      name: incident.reporter_name,
      phone: incident.reporter_phone,
      isReporter: true
    })
  }

  return people.map((p) =>
    p.isReporter ? { ...p, note: 'Reportó este incidente' } : p
  )
}

/** Mensaje de WhatsApp ya escrito con el contexto del incidente. */
const incidentWhatsAppMessage =
  (incident: AdminIncidentRow) =>
  (person: IncidentPerson): string => {
    const firstName = person.name ? person.name.trim().split(' ')[0] : ''
    const saludo = firstName ? `Hola ${firstName}, ` : 'Hola, '
    const viaje = incident.tracking_code ? ` del viaje ${incident.tracking_code}` : ''
    return (
      `${saludo}te escribimos de BunRider por el incidente${viaje} ` +
      `(${incidentTypeName(incident.incident_type)}). ` +
      `Necesitamos confirmar unos datos para resolverlo.`
    )
  }

export function AdminIncidents() {
  const [incidents, setIncidents] = useState<AdminIncidentRow[]>([])
  const [total, setTotal] = useState(0)
  const [page, setPage] = useState(0)
  const [filter, setFilter] = useState<'todos' | 'abierto' | 'resuelto'>('abierto')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [actionLoading, setActionLoading] = useState<string | null>(null)
  const [selectedIncident, setSelectedIncident] = useState<AdminIncidentRow | null>(null)
  const [resolution, setResolution] = useState('')
  const [atFault, setAtFault] = useState<'cliente' | 'conductor' | 'accidente'>('accidente')
  // Montos explícitos en $ que el admin decide (sin porcentajes ambiguos)
  const [refundClientAmount, setRefundClientAmount] = useState(0)
  const [penalizeAmount, setPenalizeAmount] = useState(0)
  const [compensateDriverAmount, setCompensateDriverAmount] = useState(0)
  const [cancelRide, setCancelRide] = useState(true)
  // Foto de evidencia: la URL firmada se pide SOLO al hacer clic (ahorra egress)
  const [photo, setPhoto] = useState<{ src: string; title?: string } | null>(null)
  const [photoLoading, setPhotoLoading] = useState<string | null>(null)

  // La fila ya trae los datos del viaje: no hace falta un mapa aparte de rides
  const selectedRide = selectedIncident
  const fare = selectedIncident?.final_fare_usd ?? 0
  const commission = selectedIncident?.commission_usd ?? 0
  const paymentMethod = selectedIncident?.payment_method?.toLowerCase() ?? ''
  // Incidente automático de cancelación (viaje ya aceptado / en curso)
  const isCancellationIncident = selectedIncident?.incident_type === 'cancelacion_cliente'
  const cancellationFee = selectedIncident?.cancellation_fee_usd ?? 0
  const alreadyCompensated = selectedIncident?.driver_compensation_usd ?? 0
  const suggestedCompensation = selectedIncident?.suggested_compensation_usd ?? 0
  // Negativo = hay que revertir lo ya pagado al conductor
  const compensationDelta = compensateDriverAmount - alreadyCompensated

  // Al abrir el modal, pre-cargar montos sugeridos según el culpable
  const openIncident = (incident: AdminIncidentRow) => {
    setSelectedIncident(incident)
    // La fila ya trae el viaje completo (una sola llamada a la base)
    const ride = incident
    const f = ride.final_fare_usd ?? 0
    const c = ride.commission_usd ?? 0

    if (incident.incident_type === 'cancelacion_cliente') {
      // El culpable se deduce de quién canceló; el cargo ya está registrado
      const byDriver = !!(ride && ride.cancelled_by && ride.cancelled_by === ride.driver_id)
      setAtFault(byDriver ? 'conductor' : 'cliente')
      setRefundClientAmount(0)
      setPenalizeAmount(byDriver ? 0 : (ride?.cancellation_fee_usd ?? 0))
      // La compensación NO se paga automáticamente: arranca en 0 y el admin decide.
      setCompensateDriverAmount(0)
      setCancelRide(true)
      return
    }

    setAtFault('accidente')
    // Accidente por defecto: 100% reembolso + comisión devuelta
    setRefundClientAmount(f)
    setPenalizeAmount(0)
    setCompensateDriverAmount(c)
  }

  // Al cambiar el culpable, actualizar montos sugeridos
  const handleAtFaultChange = (fault: 'cliente' | 'conductor' | 'accidente') => {
    setAtFault(fault)
    const ride = selectedIncident
    const f = ride?.final_fare_usd ?? 0
    const c = ride?.commission_usd ?? 0

    if (selectedIncident?.incident_type === 'cancelacion_cliente') {
      setRefundClientAmount(0)
      setPenalizeAmount(fault === 'cliente' ? (ride?.cancellation_fee_usd ?? 0) : 0)
      // No tocar la compensación: es decisión explícita del admin.
      return
    }

    if (fault === 'cliente') {
      // Cliente culpable: reembolso 20%, penaliza 50% de lo reembolsado, NO compensa conductor
      const r = Math.round(f * 0.20 * 100) / 100
      setRefundClientAmount(Math.min(r, f))
      setPenalizeAmount(Math.round(r * 0.50 * 100) / 100)
      setCompensateDriverAmount(0)
    } else if (fault === 'conductor') {
      // Conductor culpable: reembolso 100%, penaliza 20% de la tarifa, NO compensa
      setRefundClientAmount(f)
      setPenalizeAmount(Math.round(f * 0.20 * 100) / 100)
      setCompensateDriverAmount(0)
    } else {
      // Accidente: reembolso 100%, sin penalización, devuelve comisión
      setRefundClientAmount(f)
      setPenalizeAmount(0)
      setCompensateDriverAmount(c)
    }
  }

  // 💰 COSTO: una sola RPC trae incidente + viaje + contactos (antes 3 requests)
  const loadIncidents = useCallback(async () => {
    setLoading(true)
    const { data, error: loadError } = await supabase.rpc('get_admin_incidents', {
      p_status: filter === 'todos' ? null : filter,
      p_limit: PAGE_SIZE,
      p_offset: page * PAGE_SIZE
    })

    if (loadError) {
      setError(loadError.message)
      setIncidents([])
      setTotal(0)
    } else {
      const payload = (data ?? { total: 0, items: [] }) as AdminIncidentsPage
      setIncidents(payload.items ?? [])
      setTotal(payload.total ?? 0)
    }

    setLoading(false)
  }, [filter, page])

  useEffect(() => {
    loadIncidents()
  }, [loadIncidents])

  // Cambiar de filtro vuelve a la página 1 (React agrupa ambos estados → 1 request)
  const changeFilter = (next: typeof filter) => {
    setPage(0)
    setFilter(next)
  }

  // Foto de evidencia: bucket privado `payments` → URL firmada SOLO al abrirla
  const openPhoto = async (path: string) => {
    setPhotoLoading(path)
    const url = await resolveProofUrl(path, 'payments')
    setPhotoLoading(null)
    if (url) {
      setPhoto({ src: url, title: 'Foto del incidente' })
    } else {
      setError('No se pudo abrir la foto del incidente (archivo no disponible)')
    }
  }

  const handleResolve = async (incidentId: string) => {
    if (!resolution.trim()) {
      setError('Escribe una resolución para el incidente')
      return
    }

    setError('')
    setActionLoading(incidentId)

    try {
      const { data, error } = await supabase.rpc('resolve_ride_incident', {
        p_incident_id: incidentId,
        p_resolution: resolution,
        p_at_fault: atFault,
        p_refund_client: refundClientAmount,
        p_penalize_culpable: penalizeAmount,
        p_compensate_driver: compensateDriverAmount,
        p_cancel_ride: cancelRide
      })

      if (error) throw error

      // Actualizar lista
      setSelectedIncident(null)
      setResolution('')
      loadIncidents()
    } catch (err: any) {
      setError(err.message)
    } finally {
      setActionLoading(null)
    }
  }

  // El servidor ya filtró y paginó: no se repite el trabajo en el cliente
  const incidentList = incidents
  const totalPages = Math.max(1, Math.ceil(total / PAGE_SIZE))

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 bg-red-600 rounded-xl flex items-center justify-center">
            <ShieldAlert className="w-5 h-5 text-white" />
          </div>
          <div>
            <h1 className="text-lg font-bold text-surface-800">Incidentes y accidentes</h1>
            <p className="text-xs text-surface-500">Gestiona los reportes de la plataforma</p>
          </div>
        </div>
      </div>

      <div className="max-w-4xl mx-auto px-4 py-6">
        {error && (
          <div className="mb-4">
            <ErrorMessage message={error} onDismiss={() => setError('')} />
          </div>
        )}

        {/* Filtros */}
        <div className="flex gap-2 mb-6">
          {(['abierto', 'resuelto', 'todos'] as const).map((f) => (
            <button
              key={f}
              onClick={() => changeFilter(f)}
              className={`px-4 py-2 rounded-xl text-sm font-medium transition-all ${
                filter === f
                  ? 'bg-primary-600 text-white'
                  : 'bg-white border-2 border-surface-200 text-surface-600 hover:border-primary-300'
              }`}
            >
              {f === 'abierto' ? 'Abiertos' : f === 'resuelto' ? 'Resueltos' : 'Todos'}
            </button>
          ))}
        </div>

        {loading ? (
          <SkeletonList count={3} />
        ) : incidentList.length === 0 ? (
          <EmptyState
            icon={<ShieldAlert className="w-8 h-8" />}
            title="Sin incidentes"
            description="No hay incidentes reportados en esta categoría"
          />
        ) : (
          <div className="space-y-4">
            {incidentList.map((incident) => {
              // La fila ya trae el viaje y los contactos: no hay consultas extra
              const ride = incident
              const status = statusLabels[incident.status]
              const people = buildIncidentPeople(incident)
              const photos = parsePhotoUrls((incident as any).photo_urls)
              const resolutionDetails = parseResolutionDetails((incident as any).resolution_details)

              return (
                <div key={incident.id} className="card">
                  <div className="flex items-start justify-between gap-4">
                    <div className="flex items-center gap-3">
                      <div className={`w-11 h-11 rounded-xl flex items-center justify-center flex-shrink-0 ${
                        incident.status === 'resuelto' || incident.status === 'cerrado'
                          ? 'bg-emerald-50 text-emerald-600'
                          : 'bg-red-50 text-red-600'
                      }`}>
                        <ShieldAlert className="w-5 h-5" />
                      </div>
                      <div>
                        <h3 className="font-semibold text-surface-800">
                          {incidentTypeLabels[incident.incident_type]}
                        </h3>
                        <p className="text-xs text-surface-500">
                          {new Date(incident.created_at).toLocaleString('es-VE', {
                            day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit'
                          })}
                        </p>
                      </div>
                    </div>
                    <span className={status.className}>{status.label}</span>
                  </div>

                  {/* Involucrados + WhatsApp con mensaje listo, en un toque */}
                  <IncidentContacts
                    people={people}
                    message={incidentWhatsAppMessage(incident)}
                    compact
                    className="mt-3 rounded-xl border border-surface-200 bg-surface-50/60 p-2"
                  />

                  {incident.description && (
                    <p className="text-sm text-surface-600 mt-3 bg-surface-50 rounded-lg p-3">
                      {incident.description}
                    </p>
                  )}

                  <div className="mt-3 space-y-1.5">
                    <div className="flex items-center gap-2 text-sm text-surface-600">
                      <MapPin className="w-4 h-4 text-accent-600 flex-shrink-0" />
                      <span className="truncate">{ride.origin_address || 'Origen'}</span>
                    </div>
                    <div className="flex items-center gap-2 text-sm text-surface-600">
                      <MapPin className="w-4 h-4 text-primary-600 flex-shrink-0" />
                      <span className="truncate">{ride.destination_address || 'Destino'}</span>
                    </div>
                    <div className="flex items-center gap-2 text-sm text-surface-600 flex-wrap">
                      <DollarSign className="w-4 h-4 text-emerald-600 flex-shrink-0" />
                      <span className="font-medium">{ride.final_fare_usd.toFixed(2)}$</span>
                      <span className="text-surface-400">•</span>
                      <span>{ride.payment_method}</span>
                      {ride.tracking_code && (
                        <>
                          <span className="text-surface-400">•</span>
                          <span className="font-mono text-xs text-surface-500">{ride.tracking_code}</span>
                        </>
                      )}
                      <span className="text-surface-400">•</span>
                      <span className={`badge ${
                        ride.ride_status === 'incidente' ? 'badge-danger' :
                        ride.ride_status === 'cancelada' ? 'badge-danger' :
                        ride.ride_status === 'en_ruta' ? 'badge-primary' :
                        ride.ride_status === 'aceptada' ? 'badge-info' : 'badge-success'
                      }`}>
                        {ride.ride_status.toUpperCase()}
                      </span>
                    </div>
                  </div>

                  {photos.length > 0 && (
                    <div className="flex gap-2 mt-3 flex-wrap">
                      {photos.map((path, idx) => (
                        <button
                          key={idx}
                          type="button"
                          onClick={() => openPhoto(path)}
                          disabled={photoLoading === path}
                          className="w-16 h-16 rounded-lg bg-surface-100 flex flex-col items-center justify-center gap-0.5 text-[10px] text-surface-500 hover:border-primary-300 border-2 border-transparent disabled:opacity-60"
                          title="Ver foto del incidente"
                        >
                          {photoLoading === path
                            ? <Loader2 className="w-4 h-4 animate-spin" />
                            : <Camera className="w-4 h-4" />}
                          Foto {idx + 1}
                        </button>
                      ))}
                    </div>
                  )}

                  {incident.resolution && (
                    <div className="mt-3 bg-emerald-50 border border-emerald-200 rounded-lg p-3">
                      <p className="text-xs font-semibold text-emerald-700 mb-1">Resolución:</p>
                      <p className="text-sm text-emerald-800">{incident.resolution}</p>
                      {resolutionDetails && (
                        <div className="text-xs text-emerald-600 mt-2 space-y-0.5">
                          {resolutionDetails.at_fault && (
                            <p>Culpable: <span className="font-medium">{resolutionDetails.at_fault}</span></p>
                          )}
                          {resolutionDetails.refund_client !== undefined && Number(resolutionDetails.refund_client) > 0 && (
                            <p>Reembolso al cliente: <span className="font-medium">{Number(resolutionDetails.refund_client).toFixed(2)}$</span></p>
                          )}
                          {resolutionDetails.penalty !== undefined && Number(resolutionDetails.penalty) > 0 && (
                            <p className="text-red-600">Penalización al {resolutionDetails.at_fault}: <span className="font-medium">{Number(resolutionDetails.penalty).toFixed(2)}$</span></p>
                          )}
                          {resolutionDetails.compensate_driver !== undefined && Number(resolutionDetails.compensate_driver) > 0 && (
                            <p>Compensación al conductor: <span className="font-medium">{Number(resolutionDetails.compensate_driver).toFixed(2)}$</span></p>
                          )}
                          {Number(resolutionDetails.compensation_reversed) > 0 && (
                            <p className="text-red-600">Reversión al conductor: <span className="font-medium">-{Number(resolutionDetails.compensation_reversed).toFixed(2)}$</span></p>
                          )}
                          {resolutionDetails.ride_cancelled !== undefined && (
                            <p>Viaje cancelado: <span className="font-medium">{resolutionDetails.ride_cancelled ? 'Sí' : 'No'}</span></p>
                          )}
                        </div>
                      )}
                    </div>
                  )}

                  {(incident.status === 'abierto' || incident.status === 'en_revision') && (
                    <button
                      onClick={() => openIncident(incident)}
                      className="btn-primary w-full mt-4"
                    >
                      Resolver incidente
                    </button>
                  )}
                </div>
              )
            })}
          </div>
        )}

        {/* Paginación en el servidor: 20 incidentes por página */}
        {!loading && total > PAGE_SIZE && (
          <div className="flex items-center justify-between gap-3 mt-6">
            <button
              type="button"
              className="btn-outline text-xs px-3 py-1.5"
              disabled={page === 0}
              onClick={() => setPage((p) => Math.max(0, p - 1))}
            >
              <ChevronLeft className="w-4 h-4" /> Anterior
            </button>
            <span className="text-xs text-surface-500 text-center">
              Página {page + 1} de {totalPages} · {total} incidente{total !== 1 ? 's' : ''}
            </span>
            <button
              type="button"
              className="btn-outline text-xs px-3 py-1.5"
              disabled={page + 1 >= totalPages}
              onClick={() => setPage((p) => p + 1)}
            >
              Siguiente <ChevronRight className="w-4 h-4" />
            </button>
          </div>
        )}
      </div>

      {/* Modal de resolución */}
      {selectedIncident && (
        <div className="fixed inset-0 bg-black/40 z-50 flex items-center justify-center p-4">
          <div className="bg-white rounded-2xl p-6 max-w-lg w-full max-h-[90vh] overflow-y-auto">
            <div className="flex items-center gap-3 mb-4">
              <div className="w-10 h-10 bg-red-50 rounded-full flex items-center justify-center">
                <ShieldAlert className="w-5 h-5 text-red-600" />
              </div>
              <div>
                <h2 className="text-lg font-bold text-surface-800">Resolver incidente</h2>
                <p className="text-xs text-surface-500">
                  {incidentTypeLabels[selectedIncident.incident_type]}
                  {selectedIncident.tracking_code ? ` · Viaje ${selectedIncident.tracking_code}` : ''}
                </p>
              </div>
            </div>

            {selectedIncident.description && (
              <div className="bg-surface-50 rounded-xl p-3 mb-4">
                <p className="text-sm text-surface-600">{selectedIncident.description}</p>
              </div>
            )}

            {/* Involucrados primero: resolver el caso = contactarlos */}
            <IncidentContacts
              people={buildIncidentPeople(selectedIncident)}
              message={incidentWhatsAppMessage(selectedIncident)}
              className="rounded-xl border border-primary-100 bg-primary-50/40 p-3 mb-4"
            />

            <div className="space-y-4 mb-4">
              <div>
                <label className="label">Resolución *</label>
                <textarea
                  className="input min-h-[80px]"
                  placeholder="Describe qué ocurrió y cómo se resolvió..."
                  value={resolution}
                  onChange={(e) => setResolution(e.target.value)}
                />
              </div>

              <div>
                <label className="label">Culpable del incidente</label>
                <div className="grid grid-cols-3 gap-2">
                  {(['cliente', 'conductor', 'accidente'] as const).map((f) => (
                    <button
                      key={f}
                      type="button"
                      onClick={() => handleAtFaultChange(f)}
                      className={`p-3 rounded-xl border-2 text-sm font-medium transition-all ${
                        atFault === f
                          ? 'border-primary-600 bg-primary-50 text-primary-700'
                          : 'border-surface-200 text-surface-600'
                      }`}
                    >
                      {f === 'accidente' ? 'Accidente' : f === 'cliente' ? 'Cliente' : 'Conductor'}
                    </button>
                  ))}
                </div>
              </div>

              {/* Vista previa de cálculos en vivo */}
              {selectedRide && (
                <div className="bg-surface-50 rounded-xl p-4 space-y-2">
                  <p className="text-xs font-semibold text-surface-500 uppercase tracking-wide mb-2">
                    Vista previa de resolución
                  </p>
                  <div className="flex justify-between text-sm">
                    <span className="text-surface-500">Tarifa del viaje</span>
                    <span className="font-medium">{fare.toFixed(2)}$</span>
                  </div>
                  <div className="flex justify-between text-sm">
                    <span className="text-surface-500">Método de pago</span>
                    <span className="font-medium">{selectedRide.payment_method}</span>
                  </div>
                  {isCancellationIncident ? (
                    <>
                      <div className="border-t border-surface-200 pt-2 flex justify-between text-sm">
                        <span className={penalizeAmount > 0 ? 'text-red-600 font-medium' : 'text-surface-500 font-medium'}>
                          {atFault === 'conductor'
                            ? '→ Penalización al conductor'
                            : penalizeAmount > 0 ? '→ Cargo al cliente' : '→ Cargo eximido'}
                        </span>
                        <span className={`font-bold ${penalizeAmount > 0 ? 'text-red-600' : 'text-surface-500'}`}>
                          {penalizeAmount.toFixed(2)}$
                        </span>
                      </div>
                      <div className="flex justify-between text-sm">
                        <span className="text-blue-600 font-medium">→ Compensación al conductor</span>
                        <span className="font-bold text-blue-600">{compensateDriverAmount.toFixed(2)}$</span>
                      </div>
                      {compensationDelta < 0 && (
                        <div className="flex justify-between text-sm">
                          <span className="text-red-600 font-medium">→ Reversión al conductor</span>
                          <span className="font-bold text-red-600">-{Math.abs(compensationDelta).toFixed(2)}$</span>
                        </div>
                      )}
                      <p className="text-[10px] text-surface-400 mt-2">
                        {alreadyCompensated > 0
                          ? `Ya pagado: ${alreadyCompensated.toFixed(2)}$. Si bajas el monto se revierte la diferencia.`
                          : 'Solo se paga lo que decidas aquí; no hay compensación automática.'}
                      </p>
                    </>
                  ) : (
                    <>
                      <div className="border-t border-surface-200 pt-2 flex justify-between text-sm">
                        <span className="text-emerald-600 font-medium">→ Reembolso al cliente</span>
                        <span className="font-bold text-emerald-600">{refundClientAmount.toFixed(2)}$</span>
                      </div>
                      <div className="flex justify-between text-sm">
                        <span className="text-blue-600 font-medium">→ Compensación al conductor</span>
                        <span className="font-bold text-blue-600">{compensateDriverAmount.toFixed(2)}$</span>
                      </div>
                      {penalizeAmount > 0 && (
                        <div className="flex justify-between text-sm">
                          <span className="text-red-600 font-medium">→ Penalización ({atFault})</span>
                          <span className="font-bold text-red-600">-{penalizeAmount.toFixed(2)}$</span>
                        </div>
                      )}
                      <p className="text-[10px] text-surface-400 mt-2">
                        {atFault === 'cliente'
                          ? 'El cliente es culpable: recibe menos reembolso, el conductor es compensado.'
                          : atFault === 'conductor'
                            ? 'El conductor es culpable: no recibe compensación y paga penalización.'
                            : 'Accidente: ambos inocentes, se reembolsa y se devuelve comisión.'}
                      </p>
                    </>
                  )}
                </div>
              )}

              <div className="space-y-3">
                {!isCancellationIncident && (
                  <div>
                    <label className="label">Reembolso al cliente ($)</label>
                    <input
                      type="number"
                      min={0}
                      step="0.01"
                      className="input"
                      max={fare}
                      value={refundClientAmount}
                      onChange={(e) => setRefundClientAmount(Math.max(0, Number(e.target.value)))}
                    />
                    <p className="text-xs text-surface-400 mt-1">Máximo {fare.toFixed(2)}$ (tarifa pagada)</p>
                  </div>
                )}

                {isCancellationIncident ? (
                  <div>
                    <label className="label">
                      {atFault === 'conductor' ? 'Penalización al conductor ($)' : 'Cargo al cliente ($)'}
                    </label>
                    <input
                      type="number"
                      min={0}
                      step="0.01"
                      className="input"
                      max={atFault === 'conductor' ? undefined : cancellationFee}
                      value={penalizeAmount}
                      onChange={(e) => setPenalizeAmount(Math.max(0, Number(e.target.value)))}
                    />
                    <p className="text-xs text-surface-400 mt-1">
                      {atFault === 'conductor'
                        ? 'Se descuenta de la billetera del conductor.'
                        : <>Cargo registrado: {cancellationFee.toFixed(2)}$.{penalizeAmount > 0 ? ' Se descontará de la billetera del cliente.' : ' En 0 se exime el cargo.'}</>}
                    </p>
                  </div>
                ) : (
                  <div>
                    <label className="label">
                      Penalización al {atFault === 'cliente' ? 'cliente' : atFault === 'conductor' ? 'conductor' : '— no aplica'} ($)
                    </label>
                    <input
                      type="number"
                      min={0}
                      step="0.01"
                      className="input"
                      value={penalizeAmount}
                      onChange={(e) => setPenalizeAmount(Math.max(0, Number(e.target.value)))}
                    />
                    <p className="text-xs text-surface-400 mt-1">
                      {atFault === 'accidente' ? 'No se puede penalizar en un accidente' : 'Se descuenta de la billetera del culpable'}
                    </p>
                  </div>
                )}

                <div>
                  <label className="label">
                    {isCancellationIncident ? 'Compensación al conductor (la decides tú, $)' : 'Compensación al conductor ($)'}
                  </label>
                  <input
                    type="number"
                    min={0}
                    step="0.01"
                    className="input"
                    value={compensateDriverAmount}
                    onChange={(e) => setCompensateDriverAmount(Math.max(0, Number(e.target.value)))}
                  />
                  {isCancellationIncident ? (
                    <div className="mt-1 space-y-1">
                      <p className="text-xs text-surface-400">
                        {alreadyCompensated > 0
                          ? `Ya pagado: ${alreadyCompensated.toFixed(2)}$.`
                          : 'No se ha pagado nada todavía.'}
                        {' '}Sugerencia: {suggestedCompensation.toFixed(2)}$.
                      </p>
                      {suggestedCompensation > 0 && compensateDriverAmount !== suggestedCompensation && (
                        <button
                          type="button"
                          onClick={() => setCompensateDriverAmount(suggestedCompensation)}
                          className="text-xs font-medium text-primary-600 hover:underline"
                        >
                          Aplicar sugerencia ({suggestedCompensation.toFixed(2)}$)
                        </button>
                      )}
                      {compensationDelta < 0 && (
                        <p className="text-xs font-medium text-red-600">
                          Se descontarán {Math.abs(compensationDelta).toFixed(2)}$ de la billetera del conductor (reversión).
                        </p>
                      )}
                    </div>
                  ) : (
                    <p className="text-xs text-surface-400 mt-1">Se suma a la billetera del conductor</p>
                  )}
                </div>
              </div>

              {!isCancellationIncident && (
                <div>
                  <label className="flex items-center gap-2 cursor-pointer">
                    <input
                      type="checkbox"
                      checked={cancelRide}
                      onChange={(e) => setCancelRide(e.target.checked)}
                      className="w-4 h-4 accent-primary-600"
                    />
                    <span className="text-sm text-surface-600">Cancelar el viaje</span>
                  </label>
                </div>
              )}
            </div>

            <div className="flex gap-3">
              <button
                onClick={() => setSelectedIncident(null)}
                className="btn-outline flex-1"
              >
                Volver
              </button>
              <button
                onClick={() => handleResolve(selectedIncident.id)}
                className="btn-primary flex-1"
                disabled={actionLoading === selectedIncident.id}
              >
                {actionLoading === selectedIncident.id
                  ? <Loader2 className="w-4 h-4 animate-spin mx-auto" />
                  : <><CheckCircle className="w-4 h-4" /> Resolver</>}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Visor de la foto de evidencia (URL firmada pedida al abrir) */}
      <ImageLightbox
        src={photo?.src}
        title={photo?.title}
        onClose={() => setPhoto(null)}
      />
    </div>
  )
}