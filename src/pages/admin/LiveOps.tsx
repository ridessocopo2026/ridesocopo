import { useState, useEffect, useRef, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import { Activity, RefreshCw, Phone, Car, Bike, Truck, Clock, Loader2, ChevronLeft, Gauge, Navigation, MapPin } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { LiveRideMap } from '@/components/admin/LiveRideMap'
import { WhatsAppIcon } from '@/components/ui/WhatsAppIcon'
import { getActiveCities } from '@/lib/cities'
import { useAuth } from '@/contexts/AuthContext'
import { fmt, whatsappNumber } from '@/lib/format'

interface LiveCount { category: string; available: number; busy: number }
interface LiveVehicle { brand?: string; model?: string; plate?: string; category?: string }
interface LiveDriver {
  driver_id: string
  full_name: string
  phone: string | null
  zone_id: string | null
  is_online: boolean
  in_schedule: boolean
  available_now: boolean
  busy: boolean
  categories: string[]
  vehicle: LiveVehicle | null
}
interface LivePending {
  ride_id: string
  tracking_code: string | null
  category: string
  final_fare_usd: number
  origin_zone_id: string | null
  created_at: string
  payment_method: string | null
  waiting_minutes: number
}

interface LiveActiveRide {
  ride_id: string
  tracking_code: string | null
  status: string
  category: string
  payment_method: string | null
  final_fare_usd: number
  client_id: string | null
  cliente: string | null
  cliente_phone: string | null
  driver_id: string | null
  conductor: string | null
  conductor_phone: string | null
  vehiculo: LiveVehicle | null
  origin_address: string | null
  origin_barrio_name: string | null
  origin_lat: number
  origin_lng: number
  destination_address: string | null
  destination_barrio_name: string | null
  destination_lat: number
  destination_lng: number
  driver_location_lat: number | null
  driver_location_lng: number | null
  driver_last_update: string | null
  created_at: string
  started_at: string | null
  updated_at: string
  minutos_transcurridos: number
  minutos_sin_gps: number | null
  gps_vencido: boolean
  distancia_conductor_origen_km: number | null
  distancia_origen_destino_km: number
}

interface ActiveCounts {
  buscando: number
  aceptada: number
  en_ruta: number
  incidente: number
  total: number
}

interface OpsUsage {
  rides_today: number
  rides_month: number
  last7: { d: string; n: number }[]
  drivers_online: number
  realtime_per_ride: number
  msgs_month_est: number
  pro_limit: number
  pct_of_pro: number
}

const catLabel = (c: string): string => ({ moto: 'Moto', carro: 'Carro', camioneta: 'Camioneta' } as Record<string, string>)[c] || c
const catIcon = (c: string) => c === 'moto' ? <Bike className="w-4 h-4" /> : c === 'camioneta' ? <Truck className="w-4 h-4" /> : <Car className="w-4 h-4" />

const statusPriority = (s: string): number =>
  ({ en_ruta: 0, incidente: 1, aceptada: 2, buscando: 3 } as Record<string, number>)[s] ?? 9

const rideStatusInfo: Record<string, { label: string; cls: string }> = {
  buscando: { label: 'Buscando', cls: 'badge-warning' },
  aceptada: { label: 'Aceptado', cls: 'badge-info' },
  en_ruta: { label: 'En ruta', cls: 'badge-primary' },
  incidente: { label: 'Incidente', cls: 'badge-danger' }
}

export function LiveOps() {
  const { user } = useAuth()
  const navigate = useNavigate()
  const isEncargado = user?.role === 'encargado'
  const backPath = isEncargado ? '/encargado' : '/admin'

  const [cities, setCities] = useState<{ id: string; name: string }[]>([])
  const [cityId, setCityId] = useState('')
  const [counts, setCounts] = useState<LiveCount[]>([])
  const [drivers, setDrivers] = useState<LiveDriver[]>([])
  const [pending, setPending] = useState<LivePending[]>([])
  const [activeRides, setActiveRides] = useState<LiveActiveRide[]>([])
  const [activeCounts, setActiveCounts] = useState<ActiveCounts | null>(null)
  const [selectedRideId, setSelectedRideId] = useState<string | null>(null)
  const [statusFilter, setStatusFilter] = useState<'todos' | 'buscando' | 'aceptada' | 'en_ruta' | 'incidente'>('todos')
  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [error, setError] = useState('')
  const [updatedAt, setUpdatedAt] = useState<Date | null>(null)
  const [usage, setUsage] = useState<OpsUsage | null>(null)
  const busyRef = useRef(false)

  const load = useCallback(async () => {
    if (busyRef.current) return
    busyRef.current = true
    try {
      const [liveRes, usageRes] = await Promise.all([
        supabase.rpc('get_live_ops', { p_zone_id: isEncargado ? null : (cityId || null) }),
        supabase.rpc('get_ops_usage', { p_realtime_per_ride: 150 })
      ])
      if (liveRes.error) throw liveRes.error
      const d = (liveRes.data || {}) as {
        counts?: LiveCount[]
        drivers?: LiveDriver[]
        pending_rides?: LivePending[]
        active_rides?: LiveActiveRide[]
        active_counts?: ActiveCounts
      }
      setCounts(d.counts || [])
      setDrivers(d.drivers || [])
      setPending(d.pending_rides || [])
      const active = d.active_rides || []
      setActiveRides(active)
      setActiveCounts(d.active_counts || null)
      setSelectedRideId((prev) => {
        if (prev && active.some((r) => r.ride_id === prev)) return prev
        const preferred = [...active].sort(
          (a, b) => statusPriority(a.status) - statusPriority(b.status)
        )[0]
        return preferred?.ride_id || null
      })
      if (!usageRes.error && usageRes.data) setUsage(usageRes.data as OpsUsage)
      setUpdatedAt(new Date())
      setError('')
    } catch (err: any) {
      setError(err.message || 'Error cargando datos')
    } finally {
      busyRef.current = false
      setLoading(false)
      setRefreshing(false)
    }
  }, [isEncargado, cityId])

  useEffect(() => {
    if (isEncargado) return
    getActiveCities().then(({ data }) => {
      if (data) setCities(data as { id: string; name: string }[])
    })
  }, [isEncargado])

  useEffect(() => {
    void load()
    const tick = () => { if (document.visibilityState === 'visible') void load() }
    const timer = window.setInterval(tick, 20000)
    const onVis = () => { if (document.visibilityState === 'visible') void load() }
    document.addEventListener('visibilitychange', onVis)
    const channel = supabase
      .channel('live-ops')
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'rides', filter: 'status=eq.buscando' }, () => { void load() })
      .subscribe()
    return () => {
      window.clearInterval(timer)
      document.removeEventListener('visibilitychange', onVis)
      supabase.removeChannel(channel)
    }
  }, [load])

  // Realtime solo del viaje seleccionado: mueve el mapa sin gastar mensajes de todos los viajes.
  useEffect(() => {
    if (!selectedRideId) return
    let timer: number | undefined
    const channel = supabase
      .channel(`live-ride-${selectedRideId}`)
      .on('postgres_changes', {
        event: 'UPDATE',
        schema: 'public',
        table: 'rides',
        filter: `id=eq.${selectedRideId}`
      }, () => {
        window.clearTimeout(timer)
        timer = window.setTimeout(() => { void load() }, 1200)
      })
      .subscribe()
    return () => {
      window.clearTimeout(timer)
      supabase.removeChannel(channel)
    }
  }, [selectedRideId, load])

  const totalAvailable = counts.reduce((a, c) => a + Number(c.available || 0), 0)
  const totalBusy = counts.reduce((a, c) => a + Number(c.busy || 0), 0)
  const maxDay = usage && usage.last7.length ? Math.max(1, ...usage.last7.map((d) => d.n)) : 1
  const usagePct = usage ? Math.min(100, usage.pct_of_pro) : 0
  const gaugeColor = usagePct >= 80 ? 'text-red-600' : usagePct >= 50 ? 'text-amber-600' : 'text-emerald-600'
  const gaugeBar = usagePct >= 80 ? 'bg-red-500' : usagePct >= 50 ? 'bg-amber-500' : 'bg-emerald-500'

  const statusOf = (d: LiveDriver): { label: string; cls: string } => {
    if (d.busy) return { label: 'Ocupado', cls: 'bg-amber-100 text-amber-700' }
    if (d.available_now) return { label: 'Disponible', cls: 'bg-emerald-100 text-emerald-700' }
    if (d.is_online && !d.in_schedule) return { label: 'Fuera de horario', cls: 'bg-surface-100 text-surface-500' }
    return { label: 'Desconectado', cls: 'bg-surface-100 text-surface-500' }
  }

  const sortedActive = [...activeRides].sort(
    (a, b) => statusPriority(a.status) - statusPriority(b.status) || a.created_at.localeCompare(b.created_at)
  )
  const filteredActive = statusFilter === 'todos'
    ? sortedActive
    : sortedActive.filter((r) => r.status === statusFilter)
  const selectedRide = activeRides.find((r) => r.ride_id === selectedRideId) || sortedActive[0] || null
  const activeTotal = activeCounts?.total ?? activeRides.length

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-primary-600 border-b border-primary-700 px-6 py-4">
        <div className="flex items-center justify-between max-w-5xl mx-auto">
          <div className="flex items-center gap-3">
            <button onClick={() => navigate(backPath)} className="p-2 text-white/80 hover:text-white" aria-label="Volver">
              <ChevronLeft className="w-5 h-5" />
            </button>
            <Activity className="w-5 h-5 text-white" />
            <div>
              <h1 className="text-lg font-bold text-white">Operacion en vivo</h1>
              <p className="text-xs text-white/80">{updatedAt ? 'Actualizado ' + updatedAt.toLocaleTimeString('es-VE') : 'Conductores y viajes'}</p>
            </div>
          </div>
          <button onClick={() => { setRefreshing(true); void load() }} className="p-2 text-white/80 hover:text-white" aria-label="Actualizar">
            {refreshing ? <Loader2 className="w-5 h-5 animate-spin" /> : <RefreshCw className="w-5 h-5" />}
          </button>
        </div>
      </div>

      <div className="max-w-5xl mx-auto px-4 py-4 space-y-4">
        {error && <div className="card p-3 bg-red-50 border-red-200 text-sm text-red-600">{error}</div>}

        {!isEncargado && cities.length > 1 && (
          <div className="card p-3 flex items-center justify-between gap-2">
            <span className="text-sm font-medium text-surface-600">Ciudad</span>
            <select className="input w-auto py-1.5 text-sm" value={cityId} onChange={(e) => setCityId(e.target.value)}>
              <option value="">Todas</option>
              {cities.map((c) => (<option key={c.id} value={c.id}>{c.name}</option>))}
            </select>
          </div>
        )}

        {/* Viajes en curso: supervision en vivo */}
        <div className="space-y-3">
          <div className="flex items-center justify-between gap-2">
            <h2 className="text-sm font-semibold text-surface-700 flex items-center gap-2">
              <Navigation className="w-4 h-4 text-primary-600" /> Viajes en curso ({activeTotal})
            </h2>
            {activeCounts && (
              <span className="text-[11px] text-surface-400">
                {activeCounts.buscando} buscando · {activeCounts.aceptada} aceptados · {activeCounts.en_ruta} en ruta · {activeCounts.incidente} incidentes
              </span>
            )}
          </div>

          <div className="flex gap-2 overflow-x-auto pb-1">
            {(['todos', 'en_ruta', 'aceptada', 'buscando', 'incidente'] as const).map((f) => (
              <button
                key={f}
                onClick={() => setStatusFilter(f)}
                className={`px-3 py-1.5 rounded-full text-xs font-medium whitespace-nowrap transition-colors ${
                  statusFilter === f
                    ? 'bg-primary-600 text-white'
                    : 'bg-white border border-surface-200 text-surface-600 hover:border-primary-300'
                }`}
              >
                {f === 'todos' ? 'Todos' : rideStatusInfo[f].label}{' '}
                {f === 'todos' ? activeTotal : (activeCounts?.[f] ?? 0)}
              </button>
            ))}
          </div>

          {loading ? (
            <div className="card p-4 text-sm text-surface-400">Cargando viajes...</div>
          ) : filteredActive.length === 0 ? (
            <div className="card p-4 text-sm text-surface-500">No hay viajes en curso con este filtro.</div>
          ) : (
            <div className="grid gap-4 lg:grid-cols-5">
              <div className="lg:col-span-2 space-y-2 max-h-[520px] overflow-y-auto pr-1">
                {filteredActive.map((r) => {
                  const st = rideStatusInfo[r.status] || rideStatusInfo.buscando
                  const waCliente = whatsappNumber(r.cliente_phone)
                  const waConductor = whatsappNumber(r.conductor_phone)
                  const selected = selectedRide?.ride_id === r.ride_id
                  return (
                    <div
                      key={r.ride_id}
                      role="button"
                      tabIndex={0}
                      onClick={() => setSelectedRideId(r.ride_id)}
                      onKeyDown={(e) => {
                        if (e.key === 'Enter' || e.key === ' ') setSelectedRideId(r.ride_id)
                      }}
                      className={`w-full text-left card p-3 cursor-pointer transition-all ${
                        selected ? 'border-2 border-primary-500 ring-1 ring-primary-100' : 'border-2 border-transparent'
                      }`}
                    >
                      <div className="flex items-center justify-between gap-2">
                        <span className={`badge ${st.cls}`}>{st.label}</span>
                        <span className="text-[11px] text-surface-400">
                          {r.tracking_code || ''} · {r.minutos_transcurridos} min
                        </span>
                      </div>

                      <p className="mt-2 text-sm font-semibold text-surface-800 truncate flex items-center gap-1.5">
                        <span className="text-primary-600">{catIcon(r.category)}</span>
                        {r.cliente || 'Cliente'}
                      </p>
                      <div className="mt-1 flex flex-wrap items-center gap-2 text-[11px] text-surface-500">
                        {r.cliente_phone ? (
                          <>
                            <a href={`tel:${r.cliente_phone}`} onClick={(e) => e.stopPropagation()} className="inline-flex items-center gap-1 text-primary-600 hover:underline">
                              <Phone className="w-3 h-3" /> {r.cliente_phone}
                            </a>
                            {waCliente && (
                              <a href={`https://wa.me/${waCliente}`} target="_blank" rel="noopener noreferrer" onClick={(e) => e.stopPropagation()} className="inline-flex items-center gap-1 text-emerald-600 hover:underline">
                                <WhatsAppIcon className="w-3.5 h-3.5" /> WhatsApp
                              </a>
                            )}
                          </>
                        ) : (
                          <span>Sin teléfono</span>
                        )}
                      </div>

                      <p className="mt-1 text-[11px] text-surface-500 truncate flex items-center gap-1">
                        <Car className="w-3 h-3" />
                        {r.conductor || 'Sin conductor'}
                        {r.conductor_phone ? ` · ${r.conductor_phone}` : ''}
                        {waConductor && r.conductor && (
                          <a href={`https://wa.me/${waConductor}`} target="_blank" rel="noopener noreferrer" onClick={(e) => e.stopPropagation()} className="text-emerald-600" aria-label="WhatsApp conductor">
                            <WhatsAppIcon className="w-3.5 h-3.5" />
                          </a>
                        )}
                        {r.vehiculo?.plate ? ` · ${r.vehiculo.plate}` : ''}
                      </p>

                      <p className="mt-1 text-[11px] text-surface-600 truncate">
                        <MapPin className="w-3 h-3 inline text-emerald-600" /> {r.origin_barrio_name || r.origin_address || 'Origen'}
                        {' → '}
                        <MapPin className="w-3 h-3 inline text-red-500" /> {r.destination_barrio_name || r.destination_address || 'Destino'}
                      </p>
                      <p className="mt-0.5 text-[10px] text-surface-400 truncate">
                        Ref: {r.origin_address || '—'} → {r.destination_address || '—'}
                      </p>

                      <div className="mt-1 flex flex-wrap gap-x-3 gap-y-0.5 text-[10px] text-surface-500">
                        <span>{fmt(r.final_fare_usd)} · {r.payment_method || '—'}</span>
                        {r.distancia_conductor_origen_km != null && <span>Al origen: {r.distancia_conductor_origen_km} km</span>}
                        <span>Viaje: {r.distancia_origen_destino_km} km</span>
                        {r.driver_id && (
                          r.gps_vencido
                            ? <span className="text-amber-600 font-medium">GPS sin señal hace {r.minutos_sin_gps ?? '—'} min</span>
                            : <span>GPS hace {r.minutos_sin_gps ?? 0} min</span>
                        )}
                      </div>
                    </div>
                  )
                })}
              </div>

              <div className="lg:col-span-3 lg:sticky lg:top-4 h-fit">
                <LiveRideMap ride={selectedRide} />
                {selectedRide && (
                  <div className="card mt-2 p-3 text-xs text-surface-500 space-y-0.5">
                    <p className="font-semibold text-surface-700">
                      {selectedRide.tracking_code || 'Viaje'} · {rideStatusInfo[selectedRide.status]?.label || selectedRide.status}
                    </p>
                    <p>{selectedRide.cliente || 'Cliente'} {selectedRide.cliente_phone ? `· ${selectedRide.cliente_phone}` : '· Sin teléfono'}</p>
                    <p>{selectedRide.conductor || 'Sin conductor'} {selectedRide.conductor_phone ? `· ${selectedRide.conductor_phone}` : ''}</p>
                    <p>{selectedRide.origin_barrio_name || selectedRide.origin_address} → {selectedRide.destination_barrio_name || selectedRide.destination_address}</p>
                  </div>
                )}
              </div>
            </div>
          )}
        </div>
        <div className="grid grid-cols-2 gap-3">
          <div className="card p-4">
            <p className="text-xs text-surface-400">Disponibles ahora</p>
            <p className="text-2xl font-bold text-emerald-600">{loading ? '-' : totalAvailable}</p>
          </div>
          <div className="card p-4">
            <p className="text-xs text-surface-400">En viaje (ocupados)</p>
            <p className="text-2xl font-bold text-amber-600">{loading ? '-' : totalBusy}</p>
          </div>
        </div>

        {counts.length > 0 && (
          <div className="card p-3 flex flex-wrap gap-2">
            {counts.map((c) => (
              <span key={c.category} className="badge-info">
                {catIcon(c.category)} {catLabel(c.category)}: {c.available} / {c.busy}
              </span>
            ))}
          </div>
        )}

        {usage && (
          <div className="card p-4 space-y-3">
            <div className="flex items-center justify-between">
              <h2 className="text-sm font-semibold text-surface-700 flex items-center gap-2">
                <Gauge className="w-4 h-4 text-primary-600" /> Consumo del mes
              </h2>
              <span className="text-[11px] text-surface-400">Plan Pro ($25)</span>
            </div>
            <div className="grid grid-cols-3 gap-2">
              <div><p className="text-[11px] text-surface-400">Pedidos hoy</p><p className="text-lg font-bold text-surface-800">{usage.rides_today}</p></div>
              <div><p className="text-[11px] text-surface-400">Del mes</p><p className="text-lg font-bold text-surface-800">{usage.rides_month}</p></div>
              <div><p className="text-[11px] text-surface-400">Online</p><p className="text-lg font-bold text-surface-800">{usage.drivers_online}</p></div>
            </div>
            <div>
              <p className="text-[11px] text-surface-400 mb-1">Ultimos 7 dias</p>
              <div className="flex items-end gap-1 h-12">
                {usage.last7.map((d) => (
                  <div key={d.d} className="flex-1 bg-primary-500 rounded-t" style={{ height: Math.max(6, (d.n / maxDay) * 100) + '%' }} title={d.n + ' pedidos'} />
                ))}
              </div>
            </div>
            <div>
              <div className="flex justify-between text-xs mb-1">
                <span className="text-surface-500">Mensajes Realtime (est.)</span>
                <span className={'font-semibold ' + gaugeColor}>{usage.msgs_month_est.toLocaleString('es-VE')} / 5M ({usagePct}%)</span>
              </div>
              <div className="h-2 rounded-full bg-surface-100 overflow-hidden">
                <div className={'h-full ' + gaugeBar} style={{ width: usagePct + '%' }} />
              </div>
              <p className="text-[11px] text-surface-400 mt-1">~{usage.realtime_per_ride} mensajes por pedido. Limite Pro: 5M/mes.</p>
            </div>
          </div>
        )}

        <div>
          <h2 className="text-sm font-semibold text-surface-700 mb-2 flex items-center gap-2">
            <Clock className="w-4 h-4 text-primary-600" /> Viajes sin aceptar ({pending.length})
          </h2>
          {pending.length === 0 ? (
            <div className="card p-3 text-sm text-surface-500">No hay viajes esperando conductor.</div>
          ) : (
            <div className="space-y-2">
              {pending.map((p) => (
                <button
                  key={p.ride_id}
                  onClick={() => navigate(isEncargado ? '/encargado' : '/admin/viajes')}
                  className={'w-full card p-3 flex items-center justify-between text-left ' + (p.waiting_minutes >= 4 ? 'border-2 border-red-200 bg-red-50/50' : p.waiting_minutes >= 1 ? 'border-2 border-amber-200 bg-amber-50/40' : '')}
                >
                  <div className="flex items-center gap-3">
                    <div className="w-9 h-9 rounded-lg bg-primary-50 text-primary-600 flex items-center justify-center">{catIcon(p.category)}</div>
                    <div>
                      <p className="font-semibold text-surface-800 text-sm">{catLabel(p.category)} &middot; {fmt(p.final_fare_usd)}</p>
                      <p className="text-[11px] text-surface-400">{p.tracking_code || ''} {p.payment_method ? ('&middot; ' + p.payment_method) : ''}</p>
                    </div>
                  </div>
                  <span className={'badge ' + (p.waiting_minutes >= 4 ? 'badge-danger' : 'badge-warning')}>{p.waiting_minutes} min</span>
                </button>
              ))}
            </div>
          )}
        </div>

        <div>
          <h2 className="text-sm font-semibold text-surface-700 mb-2 flex items-center gap-2">
            <Car className="w-4 h-4 text-primary-600" /> Conductores ({drivers.length})
          </h2>
          {loading ? (
            <div className="card p-3 text-sm text-surface-400">Cargando...</div>
          ) : drivers.length === 0 ? (
            <div className="card p-3 text-sm text-surface-500">No hay conductores aprobados en esta ciudad.</div>
          ) : (
            <div className="space-y-2">
              {drivers.map((d) => {
                const st = statusOf(d)
                const wa = whatsappNumber(d.phone)
                const veh = d.vehicle ? ((d.vehicle.brand || '') + ' ' + (d.vehicle.model || '')).trim() : ''
                return (
                  <div key={d.driver_id} className="card p-3 flex items-center justify-between gap-2">
                    <div className="min-w-0">
                      <p className="font-semibold text-surface-800 text-sm truncate">{d.full_name || 'Conductor'}</p>
                      <p className="text-[11px] text-surface-400 truncate">
                        {(d.categories || []).map(catLabel).join(', ') || '-'}
                        {veh ? ' \u00b7 ' + veh : ''}{d.vehicle?.plate ? ' \u00b7 ' + d.vehicle.plate : ''}
                      </p>
                    </div>
                    <div className="flex items-center gap-2 shrink-0">
                      <span className={'badge ' + st.cls}>{st.label}</span>
                      {wa ? (
                        <a href={'https://wa.me/' + wa} target="_blank" rel="noopener noreferrer" className="w-9 h-9 rounded-full bg-emerald-500 text-white flex items-center justify-center hover:bg-emerald-600" aria-label="WhatsApp">
                          <Phone className="w-4 h-4" />
                        </a>
                      ) : null}
                    </div>
                  </div>
                )
              })}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}