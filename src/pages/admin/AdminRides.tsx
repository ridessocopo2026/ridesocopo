import { useState, useEffect } from 'react'
import { Car, Search, Loader2, ChevronDown, ChevronUp, MapPin, DollarSign, Receipt, ShieldAlert, Copy } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { fmt, todayVE, daysAgoVE } from '@/lib/format'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { EmptyState } from '@/components/ui/EmptyState'
import { SkeletonList } from '@/components/ui/Skeleton'

interface RideItem {
  ride_id: string
  tracking_code: string | null
  status: string
  payment_method: string
  final_fare_usd: number
  commission_usd: number
  fecha: string
  origin_address: string | null
  destination_address: string | null
  destination_barrio_name: string | null
  proof_status: string | null
  cancellation_fee_usd: number
  driver_compensation_usd: number
  cliente: string | null
  conductor: string | null
  cash_received: number
  app_credit: number
}

interface RidesResponse {
  total: number
  items: RideItem[]
}

interface FullDetail {
  ride: any
  transacciones: any[]
  incidente: any
}

const statusBadge: Record<string, { label: string; cls: string }> = {
  buscando: { label: 'Buscando', cls: 'badge-warning' },
  aceptada: { label: 'Aceptada', cls: 'badge-info' },
  en_ruta: { label: 'En ruta', cls: 'badge-primary' },
  completada: { label: 'Completada', cls: 'badge-success' },
  cancelada: { label: 'Cancelada', cls: 'badge-danger' },
  incidente: { label: 'Incidente', cls: 'badge-danger' }
}

export function AdminRides() {
  const [rides, setRides] = useState<RideItem[]>([])
  const [total, setTotal] = useState(0)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [page, setPage] = useState(0)
  const [pageSize] = useState(25)
  const [search, setSearch] = useState('')
  const [applying, setApplying] = useState(false)
  const [expandedId, setExpandedId] = useState<string | null>(null)
  const [details, setDetails] = useState<Record<string, FullDetail>>({})
  const [detailLoading, setDetailLoading] = useState<string | null>(null)

  useEffect(() => {
    loadRides()
  }, [page, pageSize])

  const loadRides = async () => {
    setLoading(true)
    setError('')
    try {
      const { data, error } = await supabase.rpc('get_admin_rides', {
        p_search: search || null,
        p_fecha_inicio: `${daysAgoVE(90)}T00:00:00`,
        p_fecha_fin: `${todayVE()}T23:59:59`,
        p_status: null,
        p_limit: pageSize,
        p_offset: page * pageSize
      })
      if (error) throw error
      const res = data as RidesResponse
      setRides(res.items || [])
      setTotal(res.total || 0)
    } catch (err: any) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  const handleApply = async () => {
    setApplying(true)
    setPage(0)
    await loadRides()
    setApplying(false)
  }

  const toggleExpand = async (rideId: string) => {
    if (expandedId === rideId) {
      setExpandedId(null)
      return
    }

    setExpandedId(rideId)

    // Si no hay detalle cargado, cargarlo
    if (!details[rideId]) {
      setDetailLoading(rideId)
      try {
        const { data, error } = await supabase.rpc('get_ride_full_detail', {
          p_ride_id: rideId
        })
        if (error) throw error
        setDetails(prev => ({ ...prev, [rideId]: data as FullDetail }))
      } catch (err: any) {
        setError(err.message)
      } finally {
        setDetailLoading(null)
      }
    }
  }

  const totalPages = Math.max(1, Math.ceil(total / pageSize))

  const copyTracking = (code: string) => {
    navigator.clipboard.writeText(code)
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 bg-blue-600 rounded-xl flex items-center justify-center">
            <Car className="w-5 h-5 text-white" />
          </div>
          <div>
            <h1 className="text-lg font-bold text-surface-800">Viajes</h1>
            <p className="text-xs text-surface-500">Busca por tracking, cliente o conductor</p>
          </div>
        </div>
      </div>

      <div className="max-w-4xl mx-auto px-4 py-6 space-y-4">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        {/* Búsqueda */}
        <div className="card p-4">
          <div className="flex gap-2">
            <div className="relative flex-1">
              <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-surface-400" />
              <input
                type="text"
                className="input pl-10"
                placeholder="Buscar por RS-XXXXXX, nombre del cliente o conductor..."
                value={search}
                onChange={(e) => setSearch(e.target.value)}
                onKeyDown={(e) => e.key === 'Enter' && handleApply()}
              />
            </div>
            <button onClick={handleApply} className="btn-primary" disabled={applying}>
              {applying ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Buscar'}
            </button>
          </div>
          <p className="text-xs text-surface-400 mt-2">{total} viajes encontrados</p>
        </div>

        {/* Lista */}
        {loading ? (
          <SkeletonList count={5} />
        ) : rides.length === 0 ? (
          <EmptyState
            icon={<Car className="w-8 h-8" />}
            title="Sin viajes"
            description="No hay viajes en el rango o búsqueda"
          />
        ) : (
          <div className="space-y-3">
            {rides.map((r) => {
              const st = statusBadge[r.status] || { label: r.status, cls: 'badge-info' }
              const isExpanded = expandedId === r.ride_id
              const detail = details[r.ride_id]

              return (
                <div key={r.ride_id} className="card">
                  {/* Card compacta */}
                  <button
                    onClick={() => toggleExpand(r.ride_id)}
                    className="w-full flex items-center justify-between gap-3"
                  >
                    <div className="flex items-center gap-3 min-w-0">
                      <div className="w-10 h-10 bg-blue-50 rounded-lg flex items-center justify-center text-blue-600 flex-shrink-0">
                        <Car className="w-5 h-5" />
                      </div>
                      <div className="min-w-0 text-left">
                        <div className="flex items-center gap-2">
                          <p className="font-mono text-sm font-bold text-blue-700">{r.tracking_code}</p>
                          {r.tracking_code && (
                            <button
                              onClick={(e) => { e.stopPropagation(); copyTracking(r.tracking_code!) }}
                              className="p-1 text-surface-400 hover:text-primary-600"
                              title="Copiar tracking"
                            >
                              <Copy className="w-3 h-3" />
                            </button>
                          )}
                        </div>
                        <p className="text-xs text-surface-500 truncate">
                          <MapPin className="w-3 h-3 inline mr-1" />
                          {r.origin_address} → {r.destination_address || r.destination_barrio_name}
                        </p>
                        <p className="text-[10px] text-surface-400">
                          {new Date(r.fecha).toLocaleDateString('es-VE')} • {r.cliente || '—'} → {r.conductor || '—'}
                        </p>
                      </div>
                    </div>
                    <div className="flex items-center gap-2 flex-shrink-0">
                      <span className={st.cls}>{st.label}</span>
                      <span className="font-bold text-surface-800">{fmt(r.final_fare_usd)}</span>
                      {isExpanded ? <ChevronUp className="w-4 h-4 text-surface-400" /> : <ChevronDown className="w-4 h-4 text-surface-400" />}
                    </div>
                  </button>

                  {/* Detalle expandible */}
                  {isExpanded && (
                    <div className="mt-3 pt-3 border-t border-surface-100 space-y-3">
                      {detailLoading === r.ride_id ? (
                        <div className="flex justify-center py-4"><Loader2 className="w-6 h-6 animate-spin text-blue-600" /></div>
                      ) : detail ? (
                        <>
                          {/* Info del viaje */}
                          <div className="grid grid-cols-2 gap-2 text-sm">
                            <div className="bg-surface-50 rounded-lg p-2">
                              <p className="text-[10px] text-surface-400">Tarifa</p>
                              <p className="font-semibold">{fmt(r.final_fare_usd)}</p>
                            </div>
                            <div className="bg-surface-50 rounded-lg p-2">
                              <p className="text-[10px] text-surface-400">Método</p>
                              <p className="font-semibold">{r.payment_method}</p>
                            </div>
                            <div className="bg-surface-50 rounded-lg p-2">
                              <p className="text-[10px] text-surface-400">Comisión</p>
                              <p className="font-semibold">{fmt(r.commission_usd)}</p>
                            </div>
                            <div className="bg-surface-50 rounded-lg p-2">
                              <p className="text-[10px] text-surface-400">Comprobante</p>
                              <p className="font-semibold">{r.proof_status || 'N/A'}</p>
                            </div>
                            {(r.cancellation_fee_usd > 0 || r.driver_compensation_usd > 0) && (
                              <>
                                <div className="bg-red-50 rounded-lg p-2">
                                  <p className="text-[10px] text-red-500">Fee cancelación</p>
                                  <p className="font-semibold text-red-600">{fmt(r.cancellation_fee_usd)}</p>
                                </div>
                                <div className="bg-emerald-50 rounded-lg p-2">
                                  <p className="text-[10px] text-emerald-600">Compensación</p>
                                  <p className="font-semibold text-emerald-700">{fmt(r.driver_compensation_usd)}</p>
                                </div>
                              </>
                            )}
                          </div>

                          {/* Transacciones */}
                          {detail.transacciones && detail.transacciones.length > 0 && (
                            <div>
                              <p className="text-xs font-semibold text-surface-500 flex items-center gap-1 mb-2">
                                <Receipt className="w-3 h-3" /> Transacciones del viaje
                              </p>
                              <div className="space-y-1">
                                {detail.transacciones.map((t: any) => (
                                  <div key={t.id} className="flex items-center justify-between text-xs bg-surface-50 rounded-lg px-2 py-1.5">
                                    <div className="flex items-center gap-2 min-w-0">
                                      <span className={`w-2 h-2 rounded-full ${Number(t.monto) >= 0 ? 'bg-emerald-500' : 'bg-red-500'} flex-shrink-0`} />
                                      <span className="truncate">{t.descripcion || t.tipo}</span>
                                      <span className="text-[10px] text-surface-400">({t.usuario})</span>
                                    </div>
                                    <span className={`font-semibold flex-shrink-0 ${Number(t.monto) >= 0 ? 'text-emerald-600' : 'text-red-500'}`}>
                                      {Number(t.monto) >= 0 ? '+' : ''}{fmt(t.monto)}
                                    </span>
                                  </div>
                                ))}
                              </div>
                            </div>
                          )}

                          {/* Incidente */}
                          {detail.incidente && (
                            <div className="bg-red-50 border border-red-200 rounded-lg p-3">
                              <p className="text-xs font-semibold text-red-700 flex items-center gap-1 mb-1">
                                <ShieldAlert className="w-3 h-3" /> Incidente: {detail.incidente.incident_type}
                              </p>
                              <p className="text-xs text-red-600">{detail.incidente.description || 'Sin descripción'}</p>
                              {detail.incidente.resolution && (
                                <p className="text-xs text-emerald-700 mt-1">Resuelto: {detail.incidente.resolution}</p>
                              )}
                            </div>
                          )}
                        </>
                      ) : (
                        <p className="text-center text-xs text-surface-400 py-2">Sin detalle disponible</p>
                      )}
                    </div>
                  )}
                </div>
              )
            })}
          </div>
        )}

        {/* Paginación */}
        <div className="flex items-center justify-between px-1">
          <button className="btn-outline text-xs px-3 py-1.5" disabled={page === 0} onClick={() => setPage(page - 1)}>
            ← Anterior
          </button>
          <span className="text-xs text-surface-500">Página {page + 1} de {totalPages}</span>
          <button className="btn-outline text-xs px-3 py-1.5" disabled={page + 1 >= totalPages} onClick={() => setPage(page + 1)}>
            Siguiente →
          </button>
        </div>
      </div>
    </div>
  )
}