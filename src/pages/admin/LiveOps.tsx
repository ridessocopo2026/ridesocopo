import { useState, useEffect, useRef, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import { Activity, RefreshCw, Phone, Car, Bike, Truck, Clock, Loader2, ChevronLeft } from 'lucide-react'
import { supabase } from '@/lib/supabase'
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

const catLabel = (c: string): string => ({ moto: 'Moto', carro: 'Carro', camioneta: 'Camioneta' } as Record<string, string>)[c] || c
const catIcon = (c: string) => c === 'moto' ? <Bike className="w-4 h-4" /> : c === 'camioneta' ? <Truck className="w-4 h-4" /> : <Car className="w-4 h-4" />

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
  const [loading, setLoading] = useState(true)
  const [refreshing, setRefreshing] = useState(false)
  const [error, setError] = useState('')
  const [updatedAt, setUpdatedAt] = useState<Date | null>(null)
  const busyRef = useRef(false)

  const load = useCallback(async () => {
    if (busyRef.current) return
    busyRef.current = true
    try {
      const { data, error } = await supabase.rpc('get_live_ops', { p_zone_id: isEncargado ? null : (cityId || null) })
      if (error) throw error
      const d = (data || {}) as { counts?: LiveCount[]; drivers?: LiveDriver[]; pending_rides?: LivePending[] }
      setCounts(d.counts || [])
      setDrivers(d.drivers || [])
      setPending(d.pending_rides || [])
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
    supabase.rpc('get_active_cities').then(({ data }) => {
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

  const totalAvailable = counts.reduce((a, c) => a + Number(c.available || 0), 0)
  const totalBusy = counts.reduce((a, c) => a + Number(c.busy || 0), 0)

  const statusOf = (d: LiveDriver): { label: string; cls: string } => {
    if (d.busy) return { label: 'Ocupado', cls: 'bg-amber-100 text-amber-700' }
    if (d.available_now) return { label: 'Disponible', cls: 'bg-emerald-100 text-emerald-700' }
    if (d.is_online && !d.in_schedule) return { label: 'Fuera de horario', cls: 'bg-surface-100 text-surface-500' }
    return { label: 'Desconectado', cls: 'bg-surface-100 text-surface-500' }
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-primary-600 border-b border-primary-700 px-6 py-4">
        <div className="flex items-center justify-between max-w-md mx-auto">
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

      <div className="max-w-md mx-auto px-4 py-4 space-y-4">
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