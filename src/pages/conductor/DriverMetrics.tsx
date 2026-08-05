import { useState, useEffect } from 'react'
import { BarChart3, Calendar, Filter, Loader2, HandCoins, Wallet, CreditCard, Car, TrendingUp, AlertTriangle } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { fmt, todayVE, daysAgoVE, fechaInicioVE, fechaFinVE } from '@/lib/format'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { SkeletonList } from '@/components/ui/Skeleton'
import { Pagination } from '@/components/ui/Pagination'

interface DriverMetricsData {
  resumen: {
    total_viajes: number
    viajes_completados: number
    viajes_cancelados: number
    viajes_incidentes: number
    comisiones_totales: number
    tarifa_total: number
    tarifa_promedio: number
    efectivo_recibido: number
    app_acredito: number
  }
  por_metodo: {
    metodo: string
    viajes: number
    completados: number
    tarifa_total: number
    efectivo_recibido: number
    app_acredito: number
  }[]
  detalle_viajes: {
    ride_id: string
    payment_method: string
    status: string
    final_fare_usd: number
    commission_usd: number
    created_at: string
    destination_address: string | null
    cash_received: number
    app_credit: number
  }[]
}

const PAGE_SIZE = 10

export function DriverMetrics() {
  const [data, setData] = useState<DriverMetricsData | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [fechaInicio, setFechaInicio] = useState<string>(() => daysAgoVE(30))
  const [fechaFin, setFechaFin] = useState<string>(() => todayVE())
  const [metodo, setMetodo] = useState('')
  const [applying, setApplying] = useState(false)
  const [page, setPage] = useState(1)

  useEffect(() => {
    loadMetrics()
  }, [])

  const loadMetrics = async () => {
    setLoading(true)
    setError('')
    try {
      const { data, error } = await supabase.rpc('get_driver_metrics', {
        p_fecha_inicio: fechaInicioVE(fechaInicio),
        p_fecha_fin: fechaFinVE(fechaFin),
        p_metodo: metodo || null
      })
      if (error) throw error
      setData(data as DriverMetricsData)
    } catch (err: any) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  const handleApply = async () => {
    setApplying(true)
    setPage(1)
    await loadMetrics()
    setApplying(false)
  }

  const totalPages = data ? Math.max(1, Math.ceil((data.detalle_viajes?.length || 0) / PAGE_SIZE)) : 1
  const pageItems = data?.detalle_viajes?.slice((page - 1) * PAGE_SIZE, page * PAGE_SIZE) || []
  const statusLabel: Record<string, string> = {
    completada: 'Completado',
    cancelada: 'Cancelado',
    buscando: 'Buscando',
    aceptada: 'Aceptado',
    en_ruta: 'En ruta',
    incidente: 'Incidente'
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 bg-emerald-600 rounded-xl flex items-center justify-center">
            <BarChart3 className="w-5 h-5 text-white" />
          </div>
          <div>
            <h1 className="text-lg font-bold text-surface-800">Mis métricas</h1>
            <p className="text-xs text-surface-500">Tus viajes, ganancias y comisiones</p>
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6 space-y-6">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        {/* Filtros */}
        <div className="card space-y-4">
          <h2 className="font-semibold text-surface-800 flex items-center gap-2">
            <Filter className="w-4 h-4 text-primary-600" /> Filtros
          </h2>
          <div className="grid grid-cols-2 gap-3">
            <div>
              <label className="label">Desde</label>
              <input type="date" className="input" value={fechaInicio} onChange={(e) => setFechaInicio(e.target.value)} />
            </div>
            <div>
              <label className="label">Hasta</label>
              <input type="date" className="input" value={fechaFin} onChange={(e) => setFechaFin(e.target.value)} />
            </div>
          </div>
          <div className="flex items-end gap-3">
            <div className="flex-1">
              <label className="label">Método de pago</label>
              <select className="input" value={metodo} onChange={(e) => setMetodo(e.target.value)}>
                <option value="">Todos</option>
                <option value="efectivo">Efectivo</option>
                <option value="billetera">Billetera</option>
                <option value="pago móvil">Pago Móvil</option>
              </select>
            </div>
            <button onClick={handleApply} className="btn-primary" disabled={applying || loading}>
              {applying || loading ? <Loader2 className="w-4 h-4 animate-spin" /> : <><Calendar className="w-4 h-4" /> Aplicar</>}
            </button>
          </div>
        </div>

        {loading ? (
          <SkeletonList count={4} />
        ) : !data ? (
          <div className="text-center py-10 text-surface-400">Sin datos para mostrar</div>
        ) : (
          <>
            {/* Resumen financiero */}
            <div className="grid grid-cols-2 gap-2">
              <div className="card p-3 bg-amber-50 border-amber-200">
                <p className="text-[10px] uppercase tracking-wide text-amber-700 font-semibold flex items-center gap-1">
                  <HandCoins className="w-3 h-3" /> Efectivo recibido
                </p>
                <p className="text-xl font-bold text-amber-600 mt-1">{fmt(data.resumen.efectivo_recibido)}</p>
                <p className="text-[10px] text-amber-500">Lo tienes en mano</p>
              </div>
              <div className="card p-3 bg-emerald-50 border-emerald-200">
                <p className="text-[10px] uppercase tracking-wide text-emerald-700 font-semibold flex items-center gap-1">
                  <Wallet className="w-3 h-3" /> App te acreditó
                </p>
                <p className="text-xl font-bold text-emerald-600 mt-1">{fmt(data.resumen.app_acredito)}</p>
                <p className="text-[10px] text-emerald-500">En tu saldo virtual</p>
              </div>
            </div>

            <div className="grid grid-cols-2 gap-2">
              <div className="card p-3">
                <p className="text-xs text-surface-500">Tarifa total generada</p>
                <p className="text-xl font-bold text-surface-800 mt-1">{fmt(data.resumen.tarifa_total)}</p>
              </div>
              <div className="card p-3">
                <p className="text-xs text-surface-500">Comisiones a plataforma</p>
                <p className="text-xl font-bold text-red-500 mt-1">{fmt(data.resumen.comisiones_totales)}</p>
              </div>
            </div>

            {/* Viajes */}
            <div className="grid grid-cols-4 gap-2">
              <div className="card p-3 text-center">
                <p className="text-[10px] text-surface-400">Viajes</p>
                <p className="text-lg font-bold text-surface-800">{data.resumen.total_viajes}</p>
              </div>
              <div className="card p-3 text-center">
                <p className="text-[10px] text-emerald-600">Completados</p>
                <p className="text-lg font-bold text-emerald-600">{data.resumen.viajes_completados}</p>
              </div>
              <div className="card p-3 text-center">
                <p className="text-[10px] text-red-500">Cancelados</p>
                <p className="text-lg font-bold text-red-500">{data.resumen.viajes_cancelados}</p>
              </div>
              <div className="card p-3 text-center">
                <p className="text-[10px] text-amber-500">Incidentes</p>
                <p className="text-lg font-bold text-amber-500">{data.resumen.viajes_incidentes}</p>
              </div>
            </div>

            {/* Por método */}
            <div className="card">
              <h2 className="font-semibold text-surface-800 mb-3 flex items-center gap-2">
                <Car className="w-4 h-4 text-primary-600" /> Por método de pago
              </h2>
              {data.por_metodo.length === 0 ? (
                <p className="text-sm text-surface-400">Sin datos en el rango</p>
              ) : (
                <div className="space-y-2">
                  {data.por_metodo.map((m) => (
                    <div key={m.metodo} className="flex items-center justify-between px-3 py-2 bg-surface-50 rounded-lg">
                      <div>
                        <p className="text-sm font-medium text-surface-700 capitalize">{m.metodo}</p>
                        <p className="text-xs text-surface-400">{m.viajes} viajes • {m.completados} completados</p>
                      </div>
                      <div className="text-right text-sm">
                        <p className="text-surface-800 font-semibold">{fmt(m.tarifa_total)}</p>
                        <p className="text-[10px] text-amber-600">Efectivo: {fmt(m.efectivo_recibido)}</p>
                        <p className="text-[10px] text-emerald-600">App: {fmt(m.app_acredito)}</p>
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>

            {/* Detalle de viajes con paginación */}
            <div className="card">
              <h2 className="font-semibold text-surface-800 mb-3 flex items-center gap-2">
                <TrendingUp className="w-4 h-4 text-accent-600" /> Viajes recientes
              </h2>
              {data.detalle_viajes.length === 0 ? (
                <p className="text-sm text-surface-400">Sin viajes en el rango</p>
              ) : (
                <>
                  <div className="space-y-2">
                    {pageItems.map((v) => (
                      <div key={v.ride_id} className="flex items-center justify-between px-3 py-2 bg-surface-50 rounded-lg">
                        <div>
                          <p className="text-sm font-medium text-surface-700 capitalize">{v.payment_method} • {statusLabel[v.status] || v.status}</p>
                          <p className="text-xs text-surface-400 truncate max-w-[160px]">{v.destination_address || 'Sin dirección'}</p>
                          <p className="text-[10px] text-surface-400">{new Date(v.created_at).toLocaleDateString('es-VE')}</p>
                        </div>
                        <div className="text-right text-sm">
                          <p className="font-semibold text-surface-800">{fmt(v.final_fare_usd)}</p>
                          {v.cash_received > 0 && <p className="text-[10px] text-amber-600">💵 {fmt(v.cash_received)}</p>}
                          {v.app_credit > 0 && <p className="text-[10px] text-emerald-600">💳 {fmt(v.app_credit)}</p>}
                          <p className="text-[10px] text-red-500">Com. {fmt(v.commission_usd)}</p>
                        </div>
                      </div>
                    ))}
                  </div>
                  <Pagination
                    page={page}
                    totalPages={totalPages}
                    totalItems={data.detalle_viajes.length}
                    pageSize={PAGE_SIZE}
                    onPageChange={setPage}
                  />
                </>
              )}
            </div>
          </>
        )}
      </div>
    </div>
  )
}