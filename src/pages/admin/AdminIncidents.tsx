import { useState, useEffect } from 'react'
import { ShieldAlert, CheckCircle, Loader2, MapPin, DollarSign } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { EmptyState } from '@/components/ui/EmptyState'
import { SkeletonList } from '@/components/ui/Skeleton'
import type { RideIncident, Ride, IncidentType, IncidentStatus } from '@/types/database'

const incidentTypeLabels: Record<IncidentType, string> = {
  accidente: '🚨 Accidente',
  falla_mecanica: '🔧 Falla mecánica',
  urgencia_medica: '🏥 Emergencia médica',
  clima: '🌧️ Clima',
  otro: '❓ Otro'
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

export function AdminIncidents() {
  const [incidents, setIncidents] = useState<(RideIncident & { ride?: Ride })[]>([])
  const [ridesMap, setRidesMap] = useState<Record<string, Ride>>({})
  const [filter, setFilter] = useState<'todos' | 'abierto' | 'resuelto'>('abierto')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [actionLoading, setActionLoading] = useState<string | null>(null)
  const [selectedIncident, setSelectedIncident] = useState<RideIncident | null>(null)
  const [resolution, setResolution] = useState('')
  const [atFault, setAtFault] = useState<'cliente' | 'conductor' | 'accidente'>('accidente')
  const [refundPercent, setRefundPercent] = useState(100)
  const [compensateDriver, setCompensateDriver] = useState(true)
  const [cancelRide, setCancelRide] = useState(true)
  const { user } = useAuth()

  useEffect(() => {
    loadIncidents()
  }, [filter])

  const loadIncidents = async () => {
    setLoading(true)
    const { data, error } = await supabase.rpc('get_ride_incidents', {
      p_status: filter === 'todos' ? null : filter
    })

    if (!error && data) {
      const incs = data as RideIncident[]
      setIncidents(incs)

      // Cargar viajes asociados
      const rideIds = [...new Set(incs.map(i => i.ride_id))]
      if (rideIds.length > 0) {
        const { data: ridesData } = await supabase
          .from('rides')
          .select('*')
          .in('id', rideIds)

        if (ridesData) {
          const map: Record<string, Ride> = {}
          ridesData.forEach((r: Ride) => { map[r.id] = r })
          setRidesMap(map)
        }
      }
    }
    setLoading(false)
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
        p_refund_percent: refundPercent,
        p_compensate_driver: compensateDriver,
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

  const incidentList = filter === 'todos' ? incidents : incidents.filter(i => i.status === filter)

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
              onClick={() => setFilter(f)}
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
              const ride = ridesMap[incident.ride_id]
              const status = statusLabels[incident.status]
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

                  {incident.description && (
                    <p className="text-sm text-surface-600 mt-3 bg-surface-50 rounded-lg p-3">
                      {incident.description}
                    </p>
                  )}

                  {ride && (
                    <div className="mt-3 space-y-1.5">
                      <div className="flex items-center gap-2 text-sm text-surface-600">
                        <MapPin className="w-4 h-4 text-accent-600 flex-shrink-0" />
                        <span className="truncate">{ride.origin_address || 'Origen'}</span>
                      </div>
                      <div className="flex items-center gap-2 text-sm text-surface-600">
                        <MapPin className="w-4 h-4 text-primary-600 flex-shrink-0" />
                        <span className="truncate">{ride.destination_address || 'Destino'}</span>
                      </div>
                      <div className="flex items-center gap-2 text-sm text-surface-600">
                        <DollarSign className="w-4 h-4 text-emerald-600 flex-shrink-0" />
                        <span className="font-medium">{ride.final_fare_usd.toFixed(2)}$</span>
                        <span className="text-surface-400">•</span>
                        <span>{ride.payment_method}</span>
                        <span className="text-surface-400">•</span>
                        <span className={`badge ${
                          ride.status === 'incidente' ? 'badge-danger' :
                          ride.status === 'cancelada' ? 'badge-danger' :
                          ride.status === 'en_ruta' ? 'badge-primary' :
                          ride.status === 'aceptada' ? 'badge-info' : 'badge-success'
                        }`}>
                          {ride.status.toUpperCase()}
                        </span>
                      </div>
                    </div>
                  )}

                  {photos.length > 0 && (
                    <div className="flex gap-2 mt-3 flex-wrap">
                      {photos.map((url, idx) => (
                        <a
                          key={idx}
                          href={url}
                          target="_blank"
                          rel="noopener noreferrer"
                          className="w-16 h-16 rounded-lg bg-surface-100 flex items-center justify-center text-xs text-surface-500 hover:border-primary-300 border-2 border-transparent"
                        >
                          📷 Foto
                        </a>
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
                          {resolutionDetails.refund_amount !== undefined && (
                            <p>Reembolso: <span className="font-medium">${Number(resolutionDetails.refund_amount).toFixed(2)}</span></p>
                          )}
                          {resolutionDetails.compensated_driver !== undefined && (
                            <p>Conductor compensado: <span className="font-medium">{resolutionDetails.compensated_driver ? 'Sí' : 'No'}</span></p>
                          )}
                        </div>
                      )}
                    </div>
                  )}

                  {(incident.status === 'abierto' || incident.status === 'en_revision') && (
                    <button
                      onClick={() => setSelectedIncident(incident)}
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
                </p>
              </div>
            </div>

            {selectedIncident.description && (
              <div className="bg-surface-50 rounded-xl p-3 mb-4">
                <p className="text-sm text-surface-600">{selectedIncident.description}</p>
              </div>
            )}

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
                      onClick={() => setAtFault(f)}
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

              <div className="grid grid-cols-2 gap-3">
                <div>
                  <label className="label">Reembolso %</label>
                  <input
                    type="number"
                    min={0}
                    max={100}
                    className="input"
                    value={refundPercent}
                    onChange={(e) => setRefundPercent(Number(e.target.value))}
                  />
                </div>
                <div className="flex items-end">
                  <label className="flex items-center gap-2 cursor-pointer pb-2">
                    <input
                      type="checkbox"
                      checked={compensateDriver}
                      onChange={(e) => setCompensateDriver(e.target.checked)}
                      className="w-4 h-4 accent-primary-600"
                    />
                    <span className="text-sm text-surface-600">Compensar conductor (devolver comisión)</span>
                  </label>
                </div>
              </div>

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
    </div>
  )
}