import { useState, useEffect } from 'react'
import { Receipt, Loader2, Search, Calendar, Filter, ArrowUpRight, ArrowDownRight, Wallet, CreditCard, HandCoins, AlertTriangle } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { fmt, todayVE, daysAgoVE } from '@/lib/format'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { EmptyState } from '@/components/ui/EmptyState'
import { SkeletonList } from '@/components/ui/Skeleton'

interface TransactionItem {
  id: string
  origen: 'transaction' | 'payout'
  fecha: string
  usuario: string | null
  rol: string | null
  usuario_id: string
  tipo: string
  monto: number
  estado: string
  descripcion: string | null
  referencia: string | null
  viaje_id: string | null
  comprobante: string | null
  saldo_resultante: number
}

interface TransactionsResponse {
  total: number
  items: TransactionItem[]
}

const tipoLabels: Record<string, { label: string; color: string }> = {
  recarga: { label: 'Recarga', color: 'bg-emerald-50 text-emerald-600' },
  comision: { label: 'Comisión', color: 'bg-purple-50 text-purple-600' },
  debito: { label: 'Débito', color: 'bg-red-50 text-red-500' },
  credito: { label: 'Crédito', color: 'bg-emerald-50 text-emerald-600' },
  ajuste: { label: 'Ajuste', color: 'bg-amber-50 text-amber-600' },
  driver_pay_platform: { label: 'Conductor → Plataforma', color: 'bg-amber-50 text-amber-600' },
  platform_pay_driver: { label: 'Plataforma → Conductor', color: 'bg-blue-50 text-blue-600' }
}

const estadoLabels: Record<string, string> = {
  pendiente: '⏳ Pendiente',
  aprobado: '✅ Aprobado',
  rechazado: '❌ Rechazado',
  completado: '✅ Completado',
  confirmado: '🔁 Confirmado'
}

const rolLabels: Record<string, string> = {
  cliente: '🟢 Cliente',
  conductor: '🟡 Conductor',
  super_admin: '🔴 Admin',
  encargado: '🟠 Encargado'
}

export function AdminTransactions() {
  const [items, setItems] = useState<TransactionItem[]>([])
  const [total, setTotal] = useState(0)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [page, setPage] = useState(0)
  const [pageSize] = useState(25)
  const [fechaInicio, setFechaInicio] = useState<string>(() => daysAgoVE(30))
  const [fechaFin, setFechaFin] = useState<string>(() => todayVE())
  const [tipo, setTipo] = useState('')
  const [rol, setRol] = useState('')
  const [applying, setApplying] = useState(false)

  useEffect(() => {
    loadTransactions()
  }, [page, pageSize])

  const loadTransactions = async () => {
    setLoading(true)
    setError('')
    try {
      const { data, error } = await supabase.rpc('get_admin_transactions', {
        p_fecha_inicio: `${fechaInicio}T00:00:00`,
        p_fecha_fin: `${fechaFin}T23:59:59`,
        p_tipo: tipo || null,
        p_rol: rol || null,
        p_usuario_id: null,
        p_limit: pageSize,
        p_offset: page * pageSize
      })
      if (error) throw error
      const res = data as TransactionsResponse
      setItems(res.items || [])
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
    await loadTransactions()
    setApplying(false)
  }

  const totalPages = Math.max(1, Math.ceil(total / pageSize))

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 bg-primary-600 rounded-xl flex items-center justify-center">
            <Receipt className="w-5 h-5 text-white" />
          </div>
          <div>
            <h1 className="text-lg font-bold text-surface-800">Transacciones</h1>
            <p className="text-xs text-surface-500">Detalle completo de todos los movimientos de dinero</p>
          </div>
        </div>
      </div>

      <div className="max-w-5xl mx-auto px-4 py-6 space-y-4">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        {/* Filtros */}
        <div className="card p-4 space-y-3">
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
              <label className="label">Tipo</label>
              <select className="input" value={tipo} onChange={(e) => setTipo(e.target.value)}>
                <option value="">Todos</option>
                <option value="recarga">Recarga</option>
                <option value="credito">Crédito</option>
                <option value="debito">Débito</option>
                <option value="comision">Comisión</option>
                <option value="ajuste">Ajuste</option>
                <option value="driver_pay_platform">Conductor → Plataforma</option>
                <option value="platform_pay_driver">Plataforma → Conductor</option>
              </select>
            </div>
            <div>
              <label className="label">Rol</label>
              <select className="input" value={rol} onChange={(e) => setRol(e.target.value)}>
                <option value="">Todos</option>
                <option value="cliente">Cliente</option>
                <option value="conductor">Conductor</option>
                <option value="admin">Admin</option>
              </select>
            </div>
          </div>
          <div className="flex items-center justify-between">
            <p className="text-xs text-surface-400">
              <Filter className="w-3 h-3 inline mr-1" />
              {total} movimientos encontrados
            </p>
            <button onClick={handleApply} className="btn-primary text-sm px-4 py-2" disabled={applying}>
              {applying ? <Loader2 className="w-4 h-4 animate-spin" /> : <><Search className="w-4 h-4" /> Aplicar filtros</>}
            </button>
          </div>
        </div>

        {/* Tabla */}
        {loading ? (
          <SkeletonList count={5} />
        ) : items.length === 0 ? (
          <EmptyState
            icon={<Wallet className="w-8 h-8" />}
            title="Sin transacciones"
            description="No hay movimientos en el rango seleccionado"
          />
        ) : (
          <div className="card overflow-hidden">
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="bg-surface-50 text-left text-xs text-surface-500 uppercase">
                    <th className="px-4 py-3">Fecha</th>
                    <th className="px-4 py-3">Usuario</th>
                    <th className="px-4 py-3">Tipo</th>
                    <th className="px-4 py-3 text-right">Monto</th>
                    <th className="px-4 py-3">Estado</th>
                    <th className="px-4 py-3">Detalle</th>
                  </tr>
                </thead>
                <tbody>
                  {items.map((t) => {
                    const tipoInfo = tipoLabels[t.tipo] || { label: t.tipo, color: 'bg-surface-100 text-surface-600' }
                    const isInflow = t.tipo === 'credito' || t.tipo === 'recarga' || t.tipo === 'driver_pay_platform'
                    return (
                      <tr key={`${t.origen}-${t.id}`} className="border-t border-surface-100 hover:bg-surface-50/50">
                        <td className="px-4 py-3 whitespace-nowrap text-surface-500">
                          {new Date(t.fecha).toLocaleDateString('es-VE', { day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' })}
                        </td>
                        <td className="px-4 py-3">
                          <div className="flex items-center gap-2">
                            <span className={`w-6 h-6 rounded-full flex items-center justify-center text-[10px] ${t.rol === 'conductor' ? 'bg-amber-50 text-amber-600' : t.rol === 'cliente' ? 'bg-emerald-50 text-emerald-600' : 'bg-red-50 text-red-500'}`}>
                              {t.rol === 'conductor' ? '🟡' : t.rol === 'cliente' ? '🟢' : '🔴'}
                            </span>
                            <div>
                              <p className="font-medium text-surface-700">{t.usuario || '—'}</p>
                              <p className="text-[10px] text-surface-400">{rolLabels[t.rol || ''] || t.rol}</p>
                            </div>
                          </div>
                        </td>
                        <td className="px-4 py-3">
                          <span className={`text-[11px] font-medium px-2 py-1 rounded-lg ${tipoInfo.color}`}>
                            {tipoInfo.label}
                          </span>
                        </td>
                        <td className="px-4 py-3 text-right font-bold">
                          <span className={isInflow ? 'text-emerald-600' : 'text-red-500'}>
                            {isInflow ? '+' : '-'}{fmt(t.monto)}
                          </span>
                        </td>
                        <td className="px-4 py-3">
                          <span className="text-xs text-surface-500">{estadoLabels[t.estado] || t.estado}</span>
                        </td>
                        <td className="px-4 py-3 max-w-[180px]">
                          <p className="text-xs text-surface-500 truncate" title={t.descripcion || ''}>
                            {t.descripcion || '—'}
                          </p>
                          {t.referencia && <p className="text-[10px] text-surface-400">Ref: {t.referencia}</p>}
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>

            {/* Paginación */}
            <div className="flex items-center justify-between px-4 py-3 border-t border-surface-100">
              <button
                className="btn-outline text-xs px-3 py-1.5"
                disabled={page === 0}
                onClick={() => setPage(page - 1)}
              >
                ← Anterior
              </button>
              <span className="text-xs text-surface-500">
                Página {page + 1} de {totalPages} • {total} movimientos
              </span>
              <button
                className="btn-outline text-xs px-3 py-1.5"
                disabled={page + 1 >= totalPages}
                onClick={() => setPage(page + 1)}
              >
                Siguiente →
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}