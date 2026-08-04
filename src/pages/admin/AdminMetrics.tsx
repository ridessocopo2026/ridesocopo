import { useState, useEffect } from 'react'
import { BarChart3, TrendingUp, DollarSign, Users, Car, Calendar, Filter, Loader2, HandCoins, Wallet, CreditCard, AlertTriangle } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { SkeletonList } from '@/components/ui/Skeleton'
import type { Profile } from '@/types/database'

interface AdminMetricsData {
  resumen: {
    ingresos_plataforma: number
    deuda_con_conductores: number
    deuda_conductores: number
    efectivo_conductores: number
    total_recargas: number
    pagos_conductores_plataforma: number
    pagos_plataforma_conductores: number
    total_viajes: number
    viajes_completados: number
    viajes_cancelados: number
    viajes_incidentes: number
    tarifa_promedio: number
  }
  por_metodo: {
    metodo: string
    viajes: number
    completados: number
    tarifa_total: number
    comision_total: number
  }[]
  por_conductor: {
    conductor: string
    viajes: number
    completados: number
    ganado_efectivo: number
    ganado_app: number
    comisiones: number
  }[]
  por_cliente: {
    cliente: string
    viajes: number
    completados: number
    total_gastado: number
  }[]
}

export function AdminMetrics() {
  const [data, setData] = useState<AdminMetricsData | null>(null)
  const [conductores, setConductores] = useState<Profile[]>([])
  const [clientes, setClientes] = useState<Profile[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [fechaInicio, setFechaInicio] = useState<string>(() => {
    const d = new Date()
    d.setDate(d.getDate() - 30)
    return d.toISOString().split('T')[0]
  })
  const [fechaFin, setFechaFin] = useState<string>(() => new Date().toISOString().split('T')[0])
  const [conductorId, setConductorId] = useState('')
  const [clienteId, setClienteId] = useState('')
  const [metodo, setMetodo] = useState('')
  const [applying, setApplying] = useState(false)

  useEffect(() => {
    loadProfiles()
    loadMetrics()
  }, [])

  const loadProfiles = async () => {
    const { data: driversData } = await supabase
      .from('profiles')
      .select('id, full_name')
      .eq('role', 'conductor')
      .order('full_name')
    if (driversData) setConductores(driversData as Profile[])

    const { data: clientsData } = await supabase
      .from('profiles')
      .select('id, full_name')
      .eq('role', 'cliente')
      .order('full_name')
    if (clientsData) setClientes(clientsData as Profile[])
  }

  const loadMetrics = async () => {
    setLoading(true)
    setError('')
    try {
      const { data, error } = await supabase.rpc('get_admin_metrics', {
        p_fecha_inicio: `${fechaInicio}T00:00:00`,
        p_fecha_fin: `${fechaFin}T23:59:59`,
        p_conductor_id: conductorId || null,
        p_cliente_id: clienteId || null,
        p_metodo: metodo || null
      })
      if (error) throw error
      setData(data as AdminMetricsData)
    } catch (err: any) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  const handleApply = async () => {
    setApplying(true)
    await loadMetrics()
    setApplying(false)
  }

  const fmt = (n: number) => `$${Number(n || 0).toFixed(2)}`

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 bg-emerald-600 rounded-xl flex items-center justify-center">
            <BarChart3 className="w-5 h-5 text-white" />
          </div>
          <div>
            <h1 className="text-lg font-bold text-surface-800">Métricas y Finanzas</h1>
            <p className="text-xs text-surface-500">Administración de la plataforma</p>
          </div>
        </div>
      </div>

      <div className="max-w-4xl mx-auto px-4 py-6 space-y-6">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        {/* Filtros */}
        <div className="card space-y-4">
          <h2 className="font-semibold text-surface-800 flex items-center gap-2">
            <Filter className="w-4 h-4 text-primary-600" /> Filtros
          </h2>
          <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
            <div>
              <label className="label">Desde</label>
              <input type="date" className="input" value={fechaInicio} onChange={(e) => setFechaInicio(e.target.value)} />
            </div>
            <div>
              <label className="label">Hasta</label>
              <input type="date" className="input" value={fechaFin} onChange={(e) => setFechaFin(e.target.value)} />
            </div>
            <div>
              <label className="label">Conductor</label>
              <select className="input" value={conductorId} onChange={(e) => setConductorId(e.target.value)}>
                <option value="">Todos</option>
                {conductores.map((c) => (
                  <option key={c.id} value={c.id}>{c.full_name}</option>
                ))}
              </select>
            </div>
            <div>
              <label className="label">Cliente</label>
              <select className="input" value={clienteId} onChange={(e) => setClienteId(e.target.value)}>
                <option value="">Todos</option>
                {clientes.map((c) => (
                  <option key={c.id} value={c.id}>{c.full_name}</option>
                ))}
              </select>
            </div>
          </div>
          <div className="flex items-end gap-3">
            <div>
              <label className="label">Método de pago</label>
              <select className="input" value={metodo} onChange={(e) => setMetodo(e.target.value)}>
                <option value="">Todos</option>
                <option value="efectivo">Efectivo</option>
                <option value="billetera">Billetera</option>
                <option value="pago móvil">Pago Móvil</option>
              </select>
            </div>
            <button onClick={handleApply} className="btn-primary" disabled={applying || loading}>
              {applying || loading ? <Loader2 className="w-4 h-4 animate-spin" /> : <><Calendar className="w-4 h-4" /> Aplicar filtros</>}
            </button>
          </div>
        </div>

        {loading ? (
          <SkeletonList count={4} />
        ) : !data ? (
          <div className="text-center py-10 text-surface-400">Sin datos para mostrar</div>
        ) : (
          <>
            {/* Tarjetas de resumen financiero */}
            <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
              <div className="card p-4 bg-emerald-50 border-emerald-200">
                <p className="text-xs text-emerald-700 flex items-center gap-1 font-semibold">
                  <TrendingUp className="w-4 h-4" /> Ingresos plataforma
                </p>
                <p className="text-2xl font-bold text-emerald-700 mt-1">{fmt(data.resumen.ingresos_plataforma)}</p>
                <p className="text-[10px] text-emerald-600">Comisiones de viajes</p>
              </div>
              <div className="card p-4 bg-blue-50 border-blue-200">
                <p className="text-xs text-blue-700 flex items-center gap-1 font-semibold">
                  <Wallet className="w-4 h-4" /> La app debe a conductores
                </p>
                <p className="text-2xl font-bold text-blue-700 mt-1">{fmt(data.resumen.deuda_con_conductores)}</p>
                <p className="text-[10px] text-blue-600">Saldo positivo de wallets</p>
              </div>
              <div className="card p-4 bg-red-50 border-red-200">
                <p className="text-xs text-red-700 flex items-center gap-1 font-semibold">
                  <AlertTriangle className="w-4 h-4" /> Conductores deben a la app
                </p>
                <p className="text-2xl font-bold text-red-700 mt-1">{fmt(data.resumen.deuda_conductores)}</p>
                <p className="text-[10px] text-red-600">Comisiones pendientes</p>
              </div>
              <div className="card p-4 bg-amber-50 border-amber-200">
                <p className="text-xs text-amber-700 flex items-center gap-1 font-semibold">
                  <HandCoins className="w-4 h-4" /> Efectivo en conductores
                </p>
                <p className="text-2xl font-bold text-amber-700 mt-1">{fmt(data.resumen.efectivo_conductores)}</p>
                <p className="text-[10px] text-amber-600">Ya cobrado por ellos, NO de la app</p>
              </div>
            </div>

            {/* Tarjetas operativas */}
            <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
              <div className="card p-4">
                <p className="text-xs text-surface-500">Recargas de clientes</p>
                <p className="text-2xl font-bold text-surface-800 mt-1">{fmt(data.resumen.total_recargas)}</p>
              </div>
              <div className="card p-4">
                <p className="text-xs text-surface-500">Pagos conductores → plataforma</p>
                <p className="text-2xl font-bold text-surface-800 mt-1">{fmt(data.resumen.pagos_conductores_plataforma)}</p>
              </div>
              <div className="card p-4">
                <p className="text-xs text-surface-500">Pagos plataforma → conductores</p>
                <p className="text-2xl font-bold text-surface-800 mt-1">{fmt(data.resumen.pagos_plataforma_conductores)}</p>
              </div>
              <div className="card p-4">
                <p className="text-xs text-surface-500">Tarifa promedio</p>
                <p className="text-2xl font-bold text-surface-800 mt-1">{fmt(data.resumen.tarifa_promedio)}</p>
              </div>
            </div>

            {/* Viajes */}
            <div className="grid grid-cols-2 md:grid-cols-4 gap-3">
              <div className="card p-4">
                <p className="text-xs text-surface-500">Total viajes</p>
                <p className="text-2xl font-bold text-surface-800 mt-1">{data.resumen.total_viajes}</p>
              </div>
              <div className="card p-4">
                <p className="text-xs text-emerald-600 font-semibold">Completados</p>
                <p className="text-2xl font-bold text-emerald-600 mt-1">{data.resumen.viajes_completados}</p>
              </div>
              <div className="card p-4">
                <p className="text-xs text-red-500 font-semibold">Cancelados</p>
                <p className="text-2xl font-bold text-red-500 mt-1">{data.resumen.viajes_cancelados}</p>
              </div>
              <div className="card p-4">
                <p className="text-xs text-amber-500 font-semibold">Incidentes</p>
                <p className="text-2xl font-bold text-amber-500 mt-1">{data.resumen.viajes_incidentes}</p>
              </div>
            </div>

            {/* Desglose por método */}
            <div className="card">
              <h2 className="font-semibold text-surface-800 mb-3">Por método de pago</h2>
              {data.por_metodo.length === 0 ? (
                <p className="text-sm text-surface-400">Sin datos en el rango seleccionado</p>
              ) : (
                <div className="space-y-2">
                  {data.por_metodo.map((m) => (
                    <div key={m.metodo} className="flex items-center justify-between px-3 py-2 bg-surface-50 rounded-lg">
                      <div>
                        <p className="text-sm font-medium text-surface-700 capitalize">{m.metodo}</p>
                        <p className="text-xs text-surface-400">{m.viajes} viajes • {m.completados} completados</p>
                      </div>
                      <div className="text-right">
                        <p className="text-sm font-semibold text-surface-800">{fmt(m.tarifa_total)}</p>
                        <p className="text-xs text-emerald-600">Comisión {fmt(m.comision_total)}</p>
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>

            {/* Ranking por conductor */}
            <div className="card">
              <h2 className="font-semibold text-surface-800 mb-3 flex items-center gap-2">
                <Car className="w-4 h-4 text-primary-600" /> Ganancias por conductor
              </h2>
              {data.por_conductor.length === 0 ? (
                <p className="text-sm text-surface-400">Sin datos en el rango seleccionado</p>
              ) : (
                <div className="space-y-2">
                  {data.por_conductor.map((c, i) => (
                    <div key={c.conductor || i} className="flex items-center justify-between px-3 py-2 bg-surface-50 rounded-lg">
                      <div className="flex items-center gap-2">
                        <span className="w-6 h-6 rounded-full bg-primary-100 text-primary-600 flex items-center justify-center text-xs font-bold">{i + 1}</span>
                        <div>
                          <p className="text-sm font-medium text-surface-700">{c.conductor}</p>
                          <p className="text-xs text-surface-400">{c.viajes} viajes • {c.completados} completados</p>
                        </div>
                      </div>
                      <div className="text-right text-sm">
                        <p className="text-amber-600 font-medium">💵 {fmt(c.ganado_efectivo)}</p>
                        <p className="text-emerald-600 font-medium">💳 {fmt(c.ganado_app)}</p>
                        <p className="text-red-500 text-xs">Comisiones {fmt(c.comisiones)}</p>
                      </div>
                    </div>
                  ))}
                </div>
              )}
            </div>

            {/* Ranking por cliente */}
            <div className="card">
              <h2 className="font-semibold text-surface-800 mb-3 flex items-center gap-2">
                <Users className="w-4 h-4 text-accent-600" /> Actividad por cliente
              </h2>
              {data.por_cliente.length === 0 ? (
                <p className="text-sm text-surface-400">Sin datos en el rango seleccionado</p>
              ) : (
                <div className="space-y-2">
                  {data.por_cliente.map((c, i) => (
                    <div key={c.cliente || i} className="flex items-center justify-between px-3 py-2 bg-surface-50 rounded-lg">
                      <div className="flex items-center gap-2">
                        <span className="w-6 h-6 rounded-full bg-accent-100 text-accent-600 flex items-center justify-center text-xs font-bold">{i + 1}</span>
                        <div>
                          <p className="text-sm font-medium text-surface-700">{c.cliente}</p>
                          <p className="text-xs text-surface-400">{c.viajes} viajes • {c.completados} completados</p>
                        </div>
                      </div>
                      <p className="text-sm font-semibold text-surface-800">{fmt(c.total_gastado)}</p>
                    </div>
                  ))}
                </div>
              )}
            </div>
          </>
        )}
      </div>
    </div>
  )
}