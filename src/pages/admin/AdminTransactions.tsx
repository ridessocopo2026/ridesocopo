import { useState, useEffect } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'
import { Receipt, Loader2, Search, Calendar, Filter, ArrowUpRight, ArrowDownRight, Wallet, CreditCard, HandCoins, AlertTriangle, CheckCircle, XCircle, RefreshCw } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { fmt, todayVE, daysAgoVE, fechaInicioVE, fechaFinVE } from '@/lib/format'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { EmptyState } from '@/components/ui/EmptyState'
import { SkeletonList } from '@/components/ui/Skeleton'
import { useAuth } from '@/contexts/AuthContext'

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
  metodo: string | null
}

interface TransactionsResponse {
  total: number
  items: TransactionItem[]
}

interface PendingRefund {
  transaction_id: string
  cliente_id: string
  cliente: string | null
  telefono: string | null
  amount_usd: number
  created_at: string
  ride_id: string | null
  tracking_code: string | null
  payment_method: string | null
  ride_status: string | null
  final_fare_usd: number
  tiene_incidente_abierto: boolean
  puede_procesar: boolean
  motivo_bloqueo: string | null
}

interface PendingRefundsResponse {
  total: number
  items: PendingRefund[]
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
  const [busqueda, setBusqueda] = useState('')
  const [applying, setApplying] = useState(false)
  const navigate = useNavigate()
  const [searchParams] = useSearchParams()
  const [metodo, setMetodo] = useState(() => searchParams.get('metodo') || '')
  const [methods, setMethods] = useState<string[]>([])
  const usuarioId = searchParams.get('usuario_id') || null
  const usuarioName = searchParams.get('usuario') || ''

  const { user } = useAuth()
  const isEncargado = user?.role === 'encargado'

  // Reembolsos manuales pendientes (Pago Móvil / heredados)
  const [refunds, setRefunds] = useState<PendingRefund[]>([])
  const [refundsLoading, setRefundsLoading] = useState(true)
  const [refundAction, setRefundAction] = useState<{ item: PendingRefund; approve: boolean } | null>(null)
  const [refundNote, setRefundNote] = useState('')
  const [refundBusy, setRefundBusy] = useState(false)
  const [success, setSuccess] = useState('')

  // Al cambiar el usuario filtrado (desde la lista de usuarios), volver a la página 1
  useEffect(() => {
    setPage(0)
  }, [usuarioId])

  useEffect(() => {
    loadTransactions()
  }, [page, pageSize, usuarioId])

  useEffect(() => {
    loadPendingRefunds()
  }, [])

  useEffect(() => {
    supabase
      .from('payment_methods')
      .select('name')
      .eq('is_active', true)
      .order('name')
      .then(({ data }) => {
        setMethods(((data || []) as { name: string }[]).map((m) => m.name))
      })
  }, [])

  const loadTransactions = async () => {
    setLoading(true)
    setError('')
    try {
      const { data, error } = await supabase.rpc('get_admin_transactions', {
        p_fecha_inicio: fechaInicioVE(fechaInicio),
        p_fecha_fin: fechaFinVE(fechaFin),
        p_tipo: tipo || null,
        p_rol: rol || null,
        p_usuario_id: usuarioId,
        p_busqueda: busqueda.trim() || null,
        p_limit: pageSize,
        p_offset: page * pageSize,
        p_metodo: metodo || null
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

  // Reembolsos manuales pendientes de aprobar/rechazar
  const loadPendingRefunds = async () => {
    setRefundsLoading(true)
    try {
      const { data, error } = await supabase.rpc('get_pending_refunds')
      if (error) throw error
      const res = data as PendingRefundsResponse
      setRefunds(res?.items || [])
    } catch (err: any) {
      setError(err.message)
    } finally {
      setRefundsLoading(false)
    }
  }

  const openRefundAction = (item: PendingRefund, approve: boolean) => {
    setError('')
    setSuccess('')
    setRefundNote('')
    setRefundAction({ item, approve })
  }

  const handleProcessRefund = async () => {
    if (!refundAction) return
    if (!refundAction.approve && !refundNote.trim()) {
      setError('Escribe el motivo del rechazo')
      return
    }

    setRefundBusy(true)
    setError('')

    try {
      const { data, error } = await supabase.rpc('admin_process_refund', {
        p_transaction_id: refundAction.item.transaction_id,
        p_approve: refundAction.approve,
        p_note: refundNote.trim() || null
      })
      if (error) throw error

      const res = data as { already_processed?: boolean }
      setSuccess(
        res?.already_processed
          ? 'Ese reembolso ya había sido procesado.'
          : refundAction.approve
            ? `Reembolso de ${fmt(refundAction.item.amount_usd)} aprobado y acreditado.`
            : `Reembolso de ${fmt(refundAction.item.amount_usd)} rechazado.`
      )
      setRefundAction(null)
      setRefundNote('')
      await Promise.all([loadPendingRefunds(), loadTransactions()])
    } catch (err: any) {
      setError(err.message)
    } finally {
      setRefundBusy(false)
    }
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

        {success && (
          <div className="bg-emerald-50 border border-emerald-200 rounded-xl px-4 py-3 flex items-start justify-between gap-3">
            <p className="text-sm text-emerald-700">{success}</p>
            <button onClick={() => setSuccess('')} className="text-xs text-emerald-700 font-medium">✕</button>
          </div>
        )}

        {/* Reembolsos manuales pendientes */}
        {refunds.length > 0 && (
          <div className="card border-2 border-amber-200 bg-amber-50">
            <div className="flex items-center justify-between gap-3 mb-3">
              <div className="flex items-center gap-2">
                <AlertTriangle className="w-5 h-5 text-amber-600" />
                <div>
                  <h2 className="font-semibold text-amber-800">Reembolsos pendientes</h2>
                  <p className="text-xs text-amber-700">{refunds.length} por procesar</p>
                </div>
              </div>
              <button
                onClick={loadPendingRefunds}
                className="btn-outline text-xs px-3 py-1.5"
                disabled={refundsLoading}
                title="Actualizar reembolsos"
              >
                {refundsLoading
                  ? <Loader2 className="w-3.5 h-3.5 animate-spin" />
                  : <RefreshCw className="w-3.5 h-3.5" />}
              </button>
            </div>

            <div className="space-y-2">
              {refunds.map((r) => (
                <div key={r.transaction_id} className="bg-white rounded-xl p-3 border border-amber-100">
                  <div className="flex items-start justify-between gap-3">
                    <div className="min-w-0">
                      <p className="text-sm font-semibold text-surface-800">
                        {fmt(r.amount_usd)} · {r.cliente || 'Cliente'}
                      </p>
                      <p className="text-xs text-surface-500">
                        {r.payment_method || 'Método no especificado'}
                        {r.tracking_code ? ` · ${r.tracking_code}` : ''}
                        {' · '}
                        {new Date(r.created_at).toLocaleDateString('es-VE', {
                          day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit'
                        })}
                      </p>
                      {r.motivo_bloqueo && (
                        <p className="text-[11px] text-amber-700 mt-1">{r.motivo_bloqueo}</p>
                      )}
                    </div>

                    <div className="flex gap-2 flex-shrink-0">
                      <button
                        onClick={() => openRefundAction(r, true)}
                        disabled={!r.puede_procesar}
                        className="btn-success text-xs px-3 py-1.5 disabled:opacity-40"
                        title={r.motivo_bloqueo || 'Aprobar y acreditar a la billetera'}
                      >
                        <CheckCircle className="w-3.5 h-3.5" /> Aprobar
                      </button>
                      <button
                        onClick={() => openRefundAction(r, false)}
                        disabled={r.tiene_incidente_abierto}
                        className="btn-danger text-xs px-3 py-1.5 disabled:opacity-40"
                        title={r.tiene_incidente_abierto ? (r.motivo_bloqueo || '') : 'Rechazar reembolso'}
                      >
                        <XCircle className="w-3.5 h-3.5" /> Rechazar
                      </button>
                    </div>
                  </div>

                  {r.tiene_incidente_abierto && (
                    <a
                      href={isEncargado ? '/encargado/incidentes' : '/admin/incidentes'}
                      className="text-[11px] text-primary-700 underline mt-2 inline-block"
                    >
                      Resolver en Incidentes
                    </a>
                  )}
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Filtros */}
        <div className="card p-4 space-y-3">
          <div className="relative">
            <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-surface-400" />
            <input
              type="text"
              className="input pl-9"
              placeholder="Buscar por código de viaje (RS-XXXXXX), nombre, correo o referencia..."
              value={busqueda}
              onChange={(e) => setBusqueda(e.target.value)}
              onKeyDown={(e) => { if (e.key === 'Enter') handleApply() }}
            />
          </div>
          <div className="grid grid-cols-2 md:grid-cols-5 gap-3">
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
            <div>
              <label className="label">Método</label>
              <select className="input" value={metodo} onChange={(e) => setMetodo(e.target.value)}>
                <option value="">Todos</option>
                {methods.map((m) => <option key={m} value={m}>{m}</option>)}
                <option value="sin_clasificar">Sin clasificar (externo)</option>
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

        {/* Filtro de usuario (desde la lista de usuarios) */}
        {usuarioId && (
          <div className="bg-primary-50 border border-primary-200 rounded-xl px-4 py-3 flex items-center justify-between">
            <p className="text-xs text-primary-700">
              <Filter className="w-3 h-3 inline mr-1" />
              Mostrando transacciones de: <strong>{usuarioName || 'usuario seleccionado'}</strong>
            </p>
            <button
              onClick={() => navigate('/admin/transacciones')}
              className="text-xs font-medium text-primary-700 hover:text-primary-900 transition-colors"
            >
              ✕ Quitar filtro
            </button>
          </div>
        )}

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
                    <th className="px-4 py-3">Método</th>
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
                        <td className="px-4 py-3">
                          <span className={`text-[10px] font-medium px-2 py-1 rounded-lg ${
                            t.metodo
                              ? (/efectivo/i.test(t.metodo)
                                  ? 'bg-amber-50 text-amber-700'
                                  : 'bg-blue-50 text-blue-700')
                              : 'bg-surface-100 text-surface-500'
                          }`}>
                            {t.metodo || (t.origen === 'payout' ? 'Sin clasificar' : '—')}
                          </span>
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

      {/* Modal de confirmación de reembolso */}
      {refundAction && (
        <div className="fixed inset-0 bg-black/40 z-50 flex items-center justify-center p-4">
          <div className="bg-white rounded-2xl p-6 max-w-md w-full">
            <div className="flex items-center gap-3 mb-4">
              <div className={`w-10 h-10 rounded-full flex items-center justify-center ${
                refundAction.approve ? 'bg-emerald-50 text-emerald-600' : 'bg-red-50 text-red-600'
              }`}>
                {refundAction.approve
                  ? <CheckCircle className="w-5 h-5" />
                  : <XCircle className="w-5 h-5" />}
              </div>
              <div>
                <h2 className="text-lg font-bold text-surface-800">
                  {refundAction.approve ? 'Aprobar reembolso' : 'Rechazar reembolso'}
                </h2>
                <p className="text-xs text-surface-500">{refundAction.item.cliente || 'Cliente'}</p>
              </div>
            </div>

            <div className="bg-surface-50 rounded-xl p-4 space-y-1 mb-4 text-sm">
              <div className="flex justify-between">
                <span className="text-surface-500">Monto</span>
                <span className="font-bold text-surface-800">{fmt(refundAction.item.amount_usd)}</span>
              </div>
              <div className="flex justify-between">
                <span className="text-surface-500">Método</span>
                <span className="font-medium text-surface-700">{refundAction.item.payment_method || '—'}</span>
              </div>
              {refundAction.item.tracking_code && (
                <div className="flex justify-between">
                  <span className="text-surface-500">Viaje</span>
                  <span className="font-mono text-surface-700">{refundAction.item.tracking_code}</span>
                </div>
              )}
            </div>

            <p className="text-xs text-surface-500 mb-3">
              {refundAction.approve
                ? 'Se acreditará el monto a la billetera del cliente y la transacción quedará completada.'
                : 'La transacción quedará rechazada y no se acreditará dinero.'}
            </p>

            <div>
              <label className="label">
                {refundAction.approve ? 'Nota (opcional)' : 'Motivo del rechazo *'}
              </label>
              <textarea
                className="input min-h-[70px]"
                maxLength={500}
                value={refundNote}
                onChange={(e) => setRefundNote(e.target.value)}
                placeholder={refundAction.approve
                  ? 'Ej: verificado con el banco'
                  : 'Ej: el comprobante no corresponde'}
              />
            </div>

            <div className="flex gap-3 mt-4">
              <button
                onClick={() => setRefundAction(null)}
                className="btn-outline flex-1"
                disabled={refundBusy}
              >
                Volver
              </button>
              <button
                onClick={handleProcessRefund}
                className={`${refundAction.approve ? 'btn-success' : 'btn-danger'} flex-1`}
                disabled={refundBusy}
              >
                {refundBusy
                  ? <Loader2 className="w-4 h-4 animate-spin" />
                  : 'Confirmar'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}