import { useState, useEffect, useCallback } from 'react'
import type { FormEvent, ReactNode } from 'react'
import { useNavigate } from 'react-router-dom'
import {
  Wallet, Landmark, AlertTriangle, ArrowDownCircle, ArrowUpCircle,
  Search, Loader2, MessageCircle, Download, X, CheckCircle2,
  Pencil, ChevronRight
} from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { getActiveCities } from '@/lib/cities'
import { fmt, fmtAbs, whatsappNumber } from '@/lib/format'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { EmptyState } from '@/components/ui/EmptyState'
import { SkeletonList } from '@/components/ui/Skeleton'
import { Pagination } from '@/components/ui/Pagination'
import type { TreasuryOverview, DriverAccount, DriverAccountsResponse } from '@/types/database'

type Filtro = 'deben' | 'debo' | 'todos'
type ModalTipo = 'cobrar' | 'pagar'
type Tone = 'red' | 'amber' | 'blue' | 'primary' | 'emerald'

const PAGE_SIZE = 20

const filtroLabels: Record<Filtro, string> = {
  deben: 'Me deben',
  debo: 'Les debo',
  todos: 'Todos con saldo'
}

const tones: Record<Tone, { wrap: string; icon: string; value: string; sub: string }> = {
  red: { wrap: 'bg-red-50 border-red-200', icon: 'text-red-500', value: 'text-red-700', sub: 'text-red-600' },
  amber: { wrap: 'bg-amber-50 border-amber-200', icon: 'text-amber-500', value: 'text-amber-700', sub: 'text-amber-600' },
  blue: { wrap: 'bg-blue-50 border-blue-200', icon: 'text-blue-500', value: 'text-blue-700', sub: 'text-blue-600' },
  primary: { wrap: 'bg-primary-50 border-primary-200', icon: 'text-primary-600', value: 'text-primary-700', sub: 'text-primary-600' },
  emerald: { wrap: 'bg-emerald-50 border-emerald-200', icon: 'text-emerald-600', value: 'text-emerald-700', sub: 'text-emerald-600' }
}

const driverStatusLabels: Record<string, string> = {
  pendiente: 'Pendiente', aprobado: 'Aprobado', rechazado: 'Rechazado', suspendido: 'Suspendido'
}

const accountStatusLabels: Record<string, string> = {
  activo: 'Activo', pausado: 'Pausado', bloqueado: 'Bloqueado', eliminado: 'Eliminado'
}

/**
 * Estado de cuentas / tesorería.
 * La usan el super_admin (todas las ciudades o una) y el encargado
 * (solo la suya: el backend fuerza la zona con caller_zone_id()).
 */
export function EstadoCuentas() {
  const { user } = useAuth()
  const navigate = useNavigate()
  const isEncargado = user?.role === 'encargado'

  const [overview, setOverview] = useState<TreasuryOverview | null>(null)
  const [accounts, setAccounts] = useState<DriverAccountsResponse | null>(null)
  const [loadingOverview, setLoadingOverview] = useState(true)
  const [loadingList, setLoadingList] = useState(true)
  const [error, setError] = useState('')
  const [okMsg, setOkMsg] = useState('')

  // Ciudad
  const [cities, setCities] = useState<{ id: string; name: string }[]>([])
  const [zoneId, setZoneId] = useState('')
  const [zoneName, setZoneName] = useState('')

  // Filtros de la lista
  const [filtro, setFiltro] = useState<Filtro>('deben')
  const [searchInput, setSearchInput] = useState('')
  const [appliedSearch, setAppliedSearch] = useState('')
  const [soloLimite, setSoloLimite] = useState(false)
  const [page, setPage] = useState(1)

  // Métodos de pago para los modales
  const [methods, setMethods] = useState<string[]>([])

  // Modal cobrar / pagar
  const [modal, setModal] = useState<{ tipo: ModalTipo; driver: DriverAccount } | null>(null)
  const [formAmount, setFormAmount] = useState('')
  const [formMethod, setFormMethod] = useState('')
  const [formRef, setFormRef] = useState('')
  const [formNote, setFormNote] = useState('')
  const [modalError, setModalError] = useState('')
  const [saving, setSaving] = useState(false)
  const [exporting, setExporting] = useState(false)

  // Fondo de caja
  const [showFund, setShowFund] = useState(false)
  const [fundAmount, setFundAmount] = useState('')
  const [fundError, setFundError] = useState('')
  const [savingFund, setSavingFund] = useState(false)

  const zoneParam = isEncargado ? null : (zoneId || null)

  // Nombre de la ciudad del encargado
  useEffect(() => {
    if (isEncargado && user?.zone_id) {
      supabase
        .from('zones')
        .select('name')
        .eq('id', user.zone_id)
        .single()
        .then(({ data }) => { if (data) setZoneName(data.name) })
    }
  }, [isEncargado, user?.zone_id])

  // Ciudades que puede elegir el super_admin
  useEffect(() => {
    if (isEncargado) return
    getActiveCities().then(({ data }) => {
      if (Array.isArray(data)) setCities(data as { id: string; name: string }[])
    })
  }, [isEncargado])

  // Para cobrar/pagar dinero real solo sirven efectivo y los métodos de
  // recarga (Pago Móvil / Zelle / banco). "Billetera" no mueve dinero externo.
  useEffect(() => {
    supabase
      .from('payment_methods')
      .select('name, for_recharge')
      .eq('is_active', true)
      .order('name')
      .then(({ data }) => {
        const all = ((data || []) as { name: string; for_recharge?: boolean }[])
        const usable = all
          .filter((m) => /efectivo/i.test(m.name) || m.for_recharge)
          .map((m) => m.name)
        const names = usable.length > 0 ? usable : all.map((m) => m.name)
        setMethods(names)
        if (names.length > 0) {
          setFormMethod((prev) => prev || names.find((n) => /efectivo/i.test(n)) || names[0])
        }
      })
  }, [])

  const loadOverview = useCallback(async () => {
    setLoadingOverview(true)
    const { data, error: rpcError } = await supabase.rpc('get_treasury_overview', { p_zone_id: zoneParam })
    if (rpcError) setError(rpcError.message)
    else {
      setOverview(data as TreasuryOverview)
      setError('')
    }
    setLoadingOverview(false)
  }, [zoneParam])

  const loadAccounts = useCallback(async () => {
    setLoadingList(true)
    const { data, error: rpcError } = await supabase.rpc('get_driver_accounts', {
      p_zone_id: zoneParam,
      p_filtro: filtro,
      p_search: appliedSearch.trim() || null,
      p_solo_limite: soloLimite,
      p_limit: PAGE_SIZE,
      p_offset: (page - 1) * PAGE_SIZE
    })
    if (rpcError) setError(rpcError.message)
    else {
      setAccounts(data as DriverAccountsResponse)
      setError('')
    }
    setLoadingList(false)
  }, [zoneParam, filtro, appliedSearch, soloLimite, page])

  useEffect(() => { loadOverview() }, [loadOverview])
  useEffect(() => { loadAccounts() }, [loadAccounts])

  const reload = async () => {
    await Promise.all([loadOverview(), loadAccounts()])
  }

  const fundZoneId = isEncargado ? (user?.zone_id || null) : (zoneId || null)
  const canEditFund = !!fundZoneId

  const openFund = () => {
    if (!overview || !fundZoneId) return
    setFundAmount(Number(overview.efectivo.fondo_inicial || 0).toFixed(2))
    setFundError('')
    setShowFund(true)
  }

  const closeFund = () => {
    if (savingFund) return
    setShowFund(false)
    setFundError('')
  }

  const saveFund = async () => {
    if (!fundZoneId) return

    const amount = parseFloat(fundAmount.replace(',', '.'))
    if (!Number.isFinite(amount) || amount < 0) {
      setFundError('Escribe un monto válido (0 o mayor)')
      return
    }

    setSavingFund(true)
    setFundError('')
    try {
      const { error: rpcError } = await supabase.rpc('admin_set_cash_opening_balance', {
        p_zone_id: fundZoneId,
        p_amount: amount
      })
      if (rpcError) throw rpcError

      setShowFund(false)
      setOkMsg(`Fondo de caja actualizado a ${fmt(amount)}.`)
      await loadOverview()
    } catch (err: unknown) {
      setFundError(err instanceof Error ? err.message : 'No se pudo guardar el fondo')
    } finally {
      setSavingFund(false)
    }
  }

  const defaultMethod = () => methods.find((m) => /efectivo/i.test(m)) || methods[0] || ''

  const applySearch = (e: FormEvent) => {
    e.preventDefault()
    setPage(1)
    setAppliedSearch(searchInput.trim())
  }

  const clearSearch = () => {
    setSearchInput('')
    setAppliedSearch('')
    setPage(1)
  }

  const changeFiltro = (f: Filtro) => {
    setFiltro(f)
    setPage(1)
  }

  const openModal = (tipo: ModalTipo, driver: DriverAccount) => {
    setModal({ tipo, driver })
    setModalError('')
    setFormRef('')
    setFormNote('')
    setFormMethod(defaultMethod())
    setFormAmount(
      tipo === 'cobrar'
        ? Math.abs(driver.balance_usd).toFixed(2)
        : driver.balance_usd.toFixed(2)
    )
  }

  const closeModal = () => {
    if (saving) return
    setModal(null)
    setModalError('')
  }

  const submitModal = async () => {
    if (!modal) return

    const amount = parseFloat(formAmount.replace(',', '.'))
    const max = modal.tipo === 'cobrar'
      ? Math.abs(modal.driver.balance_usd)
      : modal.driver.balance_usd

    if (!Number.isFinite(amount) || amount <= 0) {
      setModalError('Escribe un monto válido')
      return
    }
    if (amount > max + 0.005) {
      setModalError(`El máximo permitido es ${fmt(max)}`)
      return
    }
    if (!formMethod) {
      setModalError('Selecciona un método de pago')
      return
    }

    setSaving(true)
    setModalError('')
    try {
      if (modal.tipo === 'cobrar') {
        const { data, error: rpcError } = await supabase.rpc('admin_collect_driver_debt', {
          p_driver_id: modal.driver.id,
          p_amount_usd: amount,
          p_payment_method: formMethod,
          p_reference: formRef.trim() || null
        })
        if (rpcError) throw rpcError
        const res = data as { deuda_restante?: number } | null
        setOkMsg(
          `Cobro de ${fmt(amount)} registrado a ${modal.driver.full_name}. ` +
          `Deuda restante: ${fmt(res?.deuda_restante ?? 0)}`
        )
      } else {
        const description = [
          'Pago desde estado de cuentas',
          formMethod,
          formRef.trim() ? `Ref: ${formRef.trim()}` : '',
          formNote.trim()
        ].filter(Boolean).join(' - ')

        const { error: rpcError } = await supabase.rpc('admin_pay_driver_manual', {
          p_driver_id: modal.driver.id,
          p_amount_usd: amount,
          p_description: description,
          p_payment_method: formMethod
        })
        if (rpcError) throw rpcError
        setOkMsg(`Pago de ${fmt(amount)} creado para ${modal.driver.full_name}. Apruébalo en Liquidaciones.`)
      }

      setModal(null)
      await reload()
    } catch (err: unknown) {
      const message = err instanceof Error ? err.message : 'No se pudo completar la operación'
      setModalError(message)
    } finally {
      setSaving(false)
    }
  }

  const exportCsv = async () => {
    if (!accounts || accounts.total === 0 || exporting) return

    setExporting(true)
    try {
      // Exporta TODO el filtro (no solo la página visible), en bloques de 100
      const step = 100
      const all: DriverAccount[] = []
      for (let offset = 0; offset < accounts.total; offset += step) {
        const { data, error: rpcError } = await supabase.rpc('get_driver_accounts', {
          p_zone_id: zoneParam,
          p_filtro: filtro,
          p_search: appliedSearch.trim() || null,
          p_solo_limite: soloLimite,
          p_limit: step,
          p_offset: offset
        })
        if (rpcError) throw rpcError
        const page = data as DriverAccountsResponse
        const pageItems = page.items || []
        all.push(...pageItems)
        if (pageItems.length === 0) break
      }

      const header = [
        'Conductor', 'Telefono', 'Estado', 'Ciudad', 'Saldo USD',
        'Limite deuda USD', 'Supera limite', 'Pendiente por aprobar USD', 'Ultimo movimiento'
      ]
      const rows = all.map((d) => [
        d.full_name,
        d.phone || '',
        driverStatusLabels[d.driver_status || ''] || d.driver_status || '',
        d.zone_name || '',
        Number(d.balance_usd || 0).toFixed(2),
        Number(d.debt_limit_usd || 0).toFixed(2),
        d.excede_limite ? 'SI' : 'NO',
        Number(d.pending_payout_usd || 0).toFixed(2),
        d.last_movement_at ? new Date(d.last_movement_at).toLocaleString('es-VE') : ''
      ])

      const escape = (value: string) => `"${value.replace(/"/g, '""')}"`
      const csv = [header, ...rows].map((row) => row.map(escape).join(';')).join('\r\n')
      const blob = new Blob(['\ufeff' + csv], { type: 'text/csv;charset=utf-8;' })
      const url = URL.createObjectURL(blob)
      const link = document.createElement('a')
      link.href = url
      link.download = `estado-cuentas-${new Date().toISOString().slice(0, 10)}.csv`
      link.click()
      URL.revokeObjectURL(url)
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : 'No se pudo exportar el CSV')
    } finally {
      setExporting(false)
    }
  }

  const totalPages = accounts ? Math.max(1, Math.ceil(accounts.total / PAGE_SIZE)) : 1
  const cityLabel = isEncargado
    ? (zoneName || 'Mi ciudad')
    : (cities.find((c) => c.id === zoneId)?.name || 'Todas las ciudades')

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center justify-between gap-3">
          <div className="flex items-center gap-3 min-w-0">
            <div className="w-10 h-10 rounded-xl bg-primary-50 text-primary-600 flex items-center justify-center flex-shrink-0">
              <Landmark className="w-5 h-5" />
            </div>
            <div className="min-w-0">
              <h1 className="text-lg font-bold text-surface-800">Estado de cuentas</h1>
              <p className="text-xs text-surface-500 truncate">{cityLabel} · efectivo, banco y deudas</p>
            </div>
          </div>
        </div>
      </div>

      <div className="max-w-4xl mx-auto px-4 py-6 space-y-4">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        {okMsg && (
          <div className="bg-emerald-50 border-2 border-emerald-200 rounded-xl p-4 flex items-start gap-3">
            <CheckCircle2 className="w-5 h-5 text-emerald-600 flex-shrink-0 mt-0.5" />
            <p className="text-sm text-emerald-700 flex-1">{okMsg}</p>
            <button onClick={() => setOkMsg('')} className="text-emerald-500 hover:text-emerald-700" aria-label="Cerrar aviso">
              <X className="w-4 h-4" />
            </button>
          </div>
        )}

        {/* Selector de ciudad (solo super_admin) */}
        {!isEncargado && (
          <div className="card p-3">
            <label className="label">Ciudad</label>
            <select
              className="input"
              value={zoneId}
              onChange={(e) => { setZoneId(e.target.value); setPage(1) }}
            >
              <option value="">Todas las ciudades</option>
              {cities.map((c) => <option key={c.id} value={c.id}>{c.name}</option>)}
            </select>
          </div>
        )}

        {/* Resumen */}
        {loadingOverview ? (
          <SkeletonList count={2} />
        ) : !overview ? (
          <div className="card p-4 text-sm text-surface-500">
            No se pudo cargar el resumen. Revisa el aviso de error de arriba.
          </div>
        ) : (
          <>
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
              <SummaryCard
                tone="emerald"
                icon={<Wallet className="w-4 h-4" />}
                title="Efectivo en caja"
                value={overview.efectivo.en_caja_total}
                subtitle={`Fondo ${fmt(overview.efectivo.fondo_inicial)} + movimientos ${fmt(overview.efectivo.en_caja)}`}
              />
              <SummaryCard
                tone="red"
                icon={<AlertTriangle className="w-4 h-4" />}
                title="Efectivo por cobrar"
                value={overview.deudas.conductores_deben}
                subtitle={`${overview.conteos.conductores_con_deuda} conductores con deuda · ${overview.conteos.conductores_sobre_limite} sobre el límite`}
              />
              <SummaryCard
                tone="amber"
                icon={<Landmark className="w-4 h-4" />}
                title="En banco (Pago Móvil/Zelle)"
                value={overview.banco.digital.neto}
                subtitle={
                  `Ingresos ${fmt(overview.banco.digital.ingresos)} · Egresos ${fmt(overview.banco.digital.egresos)}` +
                  (overview.banco.sin_clasificar.neto !== 0
                    ? ` · Sin clasificar ${fmt(overview.banco.sin_clasificar.neto)}`
                    : '')
                }
              />
              <SummaryCard
                tone="blue"
                icon={<Wallet className="w-4 h-4" />}
                title="Debo a conductores"
                value={overview.deudas.app_debe_conductores}
                subtitle={`${overview.conteos.conductores_con_saldo} conductores con saldo a favor`}
              />
            </div>

            {/* Fondo de caja inicial */}
            <div className="card p-3 flex items-center justify-between gap-3">
              <div>
                <p className="text-xs text-surface-500">Fondo de caja inicial</p>
                <p className="font-semibold text-surface-800">{fmt(overview.efectivo.fondo_inicial)}</p>
                {!canEditFund && (
                  <p className="text-[10px] text-surface-400">Selecciona una ciudad para editarlo</p>
                )}
              </div>
              <button
                onClick={openFund}
                disabled={!canEditFund}
                className="btn-outline text-xs px-3 py-1.5 disabled:opacity-40"
              >
                <Pencil className="w-3.5 h-3.5" /> Editar fondo
              </button>
            </div>

            {/* Conciliación */}
            <div className="card p-4 space-y-2">
              <p className="text-xs font-semibold text-surface-600 flex items-center gap-1">
                <Landmark className="w-3.5 h-3.5" /> Conciliación del dinero externo
              </p>
              <div className="grid grid-cols-2 gap-x-3 gap-y-1 text-xs">
                <span className="text-surface-500">Total histórico</span>
                <span className="text-right font-semibold text-surface-800">{fmt(overview.banco.total)}</span>
                <span className="text-surface-500">Efectivo en caja (movimientos)</span>
                <span className="text-right font-semibold text-emerald-700">{fmt(overview.efectivo.en_caja)}</span>
                <span className="text-surface-500">Banco (Pago Móvil/Zelle)</span>
                <span className="text-right font-semibold text-amber-700">{fmt(overview.banco.digital.neto)}</span>
                <span className="text-surface-500">Billetera interno</span>
                <span className="text-right font-semibold text-surface-700">{fmt(overview.banco.billetera.neto)}</span>
                <span className="text-surface-500">Sin clasificar</span>
                <span className={`text-right font-semibold ${overview.banco.sin_clasificar.neto === 0 ? 'text-surface-700' : 'text-red-600'}`}>
                  {fmt(overview.banco.sin_clasificar.neto)}
                </span>
                <span className="text-surface-500">Cuadre</span>
                <span className={`text-right font-semibold ${overview.cuadre_diferencia === 0 ? 'text-emerald-600' : 'text-red-600'}`}>
                  {overview.cuadre_diferencia === 0 ? 'OK' : fmt(overview.cuadre_diferencia)}
                </span>
              </div>
              <button
                onClick={() => navigate(`${isEncargado ? '/encargado' : '/admin'}/transacciones?metodo=sin_clasificar`)}
                className="text-[11px] text-primary-600 hover:underline inline-flex items-center gap-0.5"
              >
                Ver movimientos sin clasificar <ChevronRight className="w-3 h-3" />
              </button>
            </div>

            <div className="card p-3">
              <p className="text-xs font-semibold text-surface-600 flex items-center gap-1">
                <Landmark className="w-3.5 h-3.5" /> Cómo se calcula
              </p>
              <ul className="mt-1 space-y-0.5 text-[11px] text-surface-500 list-disc pl-4">
                <li>Efectivo en caja = fondo inicial + recargas en efectivo + cobros en efectivo − pagos en efectivo.</li>
                <li>En banco = recargas digitales + viajes Pago Móvil aprobados + cobros digitales − pagos digitales.</li>
                <li>Sin clasificar = solo movimientos externos sin método (recargas y liquidaciones). Las comisiones internas no cuentan.</li>
                <li>Efectivo por cobrar = saldo negativo de las billeteras de conductores (comisiones en efectivo).</li>
                <li>
                  Detalle de caja: cobrado {fmt(overview.efectivo.cobrado_conductores)} + recargas {fmt(overview.efectivo.recargas_efectivo)} − pagado {fmt(overview.efectivo.pagado_conductores)}.
                </li>
                {overview.deudas.clientes_deben > 0 && (
                  <li>Clientes con deuda: {fmt(overview.deudas.clientes_deben)} · la app debe a clientes: {fmt(overview.deudas.app_debe_clientes)}.</li>
                )}
              </ul>
            </div>
          </>
        )}

        {/* Filtros de la lista */}
        <div className="card p-4 space-y-3">
          <div className="grid grid-cols-3 gap-1 bg-surface-100 rounded-lg p-1">
            {(['deben', 'debo', 'todos'] as Filtro[]).map((f) => {
              const count = f === 'deben'
                ? overview?.conteos.conductores_con_deuda
                : f === 'debo'
                  ? overview?.conteos.conductores_con_saldo
                  : (overview?.conteos.conductores_con_deuda ?? 0) + (overview?.conteos.conductores_con_saldo ?? 0)
              return (
                <button
                  key={f}
                  onClick={() => changeFiltro(f)}
                  className={`px-2 py-1.5 rounded-md text-[11px] font-semibold transition-colors ${
                    filtro === f ? 'bg-white text-primary-700 shadow-sm' : 'text-surface-500 hover:text-surface-700'
                  }`}
                >
                  {filtroLabels[f]}
                  {count != null && <span className="ml-1 text-[10px] opacity-70">({count})</span>}
                </button>
              )
            })}
          </div>

          <form onSubmit={applySearch} className="flex gap-2">
            <div className="relative flex-1">
              <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-surface-400" />
              <input
                type="text"
                className="input pl-9"
                placeholder="Buscar por nombre, correo o teléfono..."
                value={searchInput}
                onChange={(e) => setSearchInput(e.target.value)}
              />
            </div>
            {appliedSearch && (
              <button type="button" onClick={clearSearch} className="btn-outline px-3" aria-label="Limpiar búsqueda">
                <X className="w-4 h-4" />
              </button>
            )}
            <button type="submit" className="btn-primary px-3" aria-label="Buscar">
              <Search className="w-4 h-4" />
            </button>
          </form>

          <label className="flex items-center gap-2 text-xs text-surface-600">
            <input
              type="checkbox"
              checked={soloLimite}
              onChange={(e) => { setSoloLimite(e.target.checked); setPage(1) }}
            />
            Solo los que superan el límite de deuda
          </label>
        </div>

        {/* Lista de conductores */}
        {loadingList ? (
          <SkeletonList count={4} />
        ) : !accounts || accounts.items.length === 0 ? (
          <EmptyState
            icon={<Wallet className="w-8 h-8" />}
            title={filtro === 'deben' ? 'Nadie debe a la app' : filtro === 'debo' ? 'No hay saldos a favor' : 'Sin saldos pendientes'}
            description="No hay conductores que coincidan con los filtros."
          />
        ) : (
          <>
            <div className="flex items-center justify-between gap-2">
              <p className="text-xs text-surface-500">
                {accounts.total} conductor{accounts.total !== 1 ? 'es' : ''} · debe {fmt(accounts.totales.suma_deben)} · a favor {fmt(accounts.totales.suma_debo)}
              </p>
              <button
                onClick={() => { void exportCsv() }}
                className="btn-outline text-xs px-3 py-1.5"
                disabled={exporting}
              >
                {exporting
                  ? <Loader2 className="w-3.5 h-3.5 animate-spin" />
                  : <Download className="w-3.5 h-3.5" />} CSV
              </button>
            </div>

            <div className="space-y-2">
              {accounts.items.map((d) => {
                const wa = whatsappNumber(d.phone)
                const debt = Math.abs(Number(d.balance_usd || 0))
                const limit = Math.max(Number(d.debt_limit_usd || 0), 0)
                const pct = limit > 0 ? Math.round((debt / limit) * 100) : (debt > 0 ? 100 : 0)
                const status = driverStatusLabels[d.driver_status || ''] || d.driver_status
                const accountStatus = accountStatusLabels[d.account_status || ''] || d.account_status

                return (
                  <div key={d.id} className="card p-4 space-y-2">
                    <div className="flex items-start justify-between gap-3">
                      <div className="flex items-center gap-2 min-w-0">
                        <div className="w-9 h-9 rounded-full bg-primary-50 text-primary-600 flex items-center justify-center font-semibold text-sm flex-shrink-0">
                          {(d.full_name || '?').charAt(0).toUpperCase()}
                        </div>
                        <div className="min-w-0">
                          <p className="font-medium text-surface-800 truncate">{d.full_name}</p>
                          <p className="text-[10px] text-surface-400 truncate">
                            {[status, accountStatus, d.zone_name].filter(Boolean).join(' · ') || 'Conductor'}
                          </p>
                        </div>
                      </div>
                      <div className="text-right flex-shrink-0">
                        <p className={`text-lg font-bold ${d.balance_usd < 0 ? 'text-red-600' : 'text-emerald-600'}`}>
                          {d.balance_usd < 0 ? `−${fmtAbs(d.balance_usd)}` : fmt(d.balance_usd)}
                        </p>
                        <p className="text-[10px] text-surface-400">
                          {d.balance_usd < 0 ? 'Debe a la app' : 'La app le debe'}
                        </p>
                      </div>
                    </div>

                    {d.balance_usd < 0 && (
                      <div>
                        <div className="flex justify-between text-[10px] text-surface-400">
                          <span>Límite {fmt(limit)}</span>
                          <span className={d.excede_limite ? 'text-red-500 font-semibold' : ''}>{pct}% usado</span>
                        </div>
                        <div className="h-1.5 bg-surface-100 rounded-full overflow-hidden mt-1">
                          <div
                            className={`h-full ${d.excede_limite ? 'bg-red-500' : 'bg-amber-400'}`}
                            style={{ width: `${Math.min(pct, 100)}%` }}
                          />
                        </div>
                      </div>
                    )}

                    <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-[10px] text-surface-400">
                      {d.excede_limite && <span className="badge-danger">Supera el límite</span>}
                      {d.last_movement_at && (
                        <span>Últ. movimiento: {new Date(d.last_movement_at).toLocaleDateString('es-VE')}</span>
                      )}
                      {Number(d.pending_payout_usd || 0) > 0 && (
                        <span className="text-amber-600 font-medium">
                          Pendiente por aprobar: {fmt(d.pending_payout_usd)}
                        </span>
                      )}
                    </div>

                    <div className="flex gap-2 pt-1">
                      {wa && (
                        <a
                          href={`https://wa.me/${wa}`}
                          target="_blank"
                          rel="noopener noreferrer"
                          className="btn-outline text-xs flex-1 justify-center"
                        >
                          <MessageCircle className="w-3.5 h-3.5" /> WhatsApp
                        </a>
                      )}
                      {d.balance_usd < 0 && (
                        <button onClick={() => openModal('cobrar', d)} className="btn-primary text-xs flex-1">
                          <ArrowDownCircle className="w-3.5 h-3.5" /> Cobrar
                        </button>
                      )}
                      {d.balance_usd > 0 && (
                        <button onClick={() => openModal('pagar', d)} className="btn-success text-xs flex-1">
                          <ArrowUpCircle className="w-3.5 h-3.5" /> Pagar
                        </button>
                      )}
                    </div>
                  </div>
                )
              })}
            </div>

            <Pagination
              page={page}
              totalPages={totalPages}
              totalItems={accounts.total}
              pageSize={PAGE_SIZE}
              onPageChange={setPage}
            />
          </>
        )}
      </div>

      {/* Modal fondo de caja */}
      {showFund && (
        <div className="fixed inset-0 z-50 bg-black/50 flex items-end sm:items-center justify-center p-0 sm:p-4">
          <div className="bg-white w-full sm:max-w-md rounded-t-2xl sm:rounded-2xl p-5 space-y-3">
            <div className="flex items-start justify-between gap-3">
              <div>
                <h2 className="font-semibold text-surface-800">Fondo de caja inicial</h2>
                <p className="text-xs text-surface-500">{cityLabel}</p>
              </div>
              <button onClick={closeFund} className="text-surface-400 hover:text-surface-600" aria-label="Cerrar">
                <X className="w-5 h-5" />
              </button>
            </div>

            <p className="text-xs text-surface-500">
              Es el efectivo que ya tenías en caja antes de usar la app. Se suma a los movimientos
              para calcular el efectivo en caja.
            </p>

            <div>
              <label className="label">Monto (USD)</label>
              <input
                type="number"
                inputMode="decimal"
                step="0.01"
                min="0"
                className="input"
                value={fundAmount}
                onChange={(e) => setFundAmount(e.target.value)}
              />
            </div>

            {fundError && (
              <p className="text-xs text-red-600 bg-red-50 border border-red-200 rounded-lg px-3 py-2">{fundError}</p>
            )}

            <div className="flex gap-2 pt-1">
              <button onClick={closeFund} className="btn-outline flex-1" disabled={savingFund}>Cancelar</button>
              <button onClick={saveFund} className="btn-primary flex-1" disabled={savingFund}>
                {savingFund ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Guardar fondo'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Modal cobrar / pagar */}
      {modal && (
        <div className="fixed inset-0 z-50 bg-black/50 flex items-end sm:items-center justify-center p-0 sm:p-4">
          <div className="bg-white w-full sm:max-w-md rounded-t-2xl sm:rounded-2xl p-5 max-h-[92vh] overflow-y-auto space-y-3">
            <div className="flex items-start justify-between gap-3">
              <div>
                <h2 className="font-semibold text-surface-800">
                  {modal.tipo === 'cobrar' ? 'Cobrar deuda' : 'Pagar al conductor'}
                </h2>
                <p className="text-xs text-surface-500">{modal.driver.full_name}</p>
              </div>
              <button onClick={closeModal} className="text-surface-400 hover:text-surface-600" aria-label="Cerrar">
                <X className="w-5 h-5" />
              </button>
            </div>

            <div className={`rounded-lg px-3 py-2 text-xs ${
              modal.tipo === 'cobrar' ? 'bg-red-50 text-red-700' : 'bg-emerald-50 text-emerald-700'
            }`}>
              {modal.tipo === 'cobrar'
                ? `Deuda actual: ${fmt(Math.abs(modal.driver.balance_usd))} · límite ${fmt(modal.driver.debt_limit_usd)}`
                : `Saldo a favor: ${fmt(modal.driver.balance_usd)}`}
            </div>

            <div>
              <label className="label">Monto (USD)</label>
              <input
                type="number"
                inputMode="decimal"
                step="0.01"
                min="0.01"
                max={modal.tipo === 'cobrar'
                  ? Math.abs(modal.driver.balance_usd)
                  : modal.driver.balance_usd}
                className="input"
                value={formAmount}
                onChange={(e) => setFormAmount(e.target.value)}
              />
            </div>

            <div>
              <label className="label">Método de pago</label>
              <select className="input" value={formMethod} onChange={(e) => setFormMethod(e.target.value)}>
                {methods.length === 0 && <option value="">Sin métodos activos</option>}
                {methods.map((m) => <option key={m} value={m}>{m}</option>)}
              </select>
            </div>

            <div>
              <label className="label">{modal.tipo === 'cobrar' ? 'Referencia (opcional)' : 'Referencia / nota'}</label>
              <input
                type="text"
                className="input"
                placeholder={modal.tipo === 'cobrar' ? 'Ej: 123456' : 'Ej: pago por Pago Móvil'}
                value={formRef}
                onChange={(e) => setFormRef(e.target.value)}
              />
            </div>

            {modal.tipo === 'pagar' && (
              <>
                <div>
                  <label className="label">Descripción (opcional)</label>
                  <input
                    type="text"
                    className="input"
                    placeholder="Ej: pago de ganancias"
                    value={formNote}
                    onChange={(e) => setFormNote(e.target.value)}
                  />
                </div>
                <p className="text-[11px] text-amber-700 bg-amber-50 border border-amber-200 rounded-lg px-3 py-2">
                  Se creará un pago pendiente. Apruébalo en Liquidaciones y el conductor deberá confirmar que lo recibió.
                </p>
              </>
            )}

            {modalError && (
              <p className="text-xs text-red-600 bg-red-50 border border-red-200 rounded-lg px-3 py-2">{modalError}</p>
            )}

            <div className="flex gap-2 pt-1">
              <button onClick={closeModal} className="btn-outline flex-1" disabled={saving}>Cancelar</button>
              <button
                onClick={submitModal}
                className={modal.tipo === 'cobrar' ? 'btn-primary flex-1' : 'btn-success flex-1'}
                disabled={saving}
              >
                {saving
                  ? <Loader2 className="w-4 h-4 animate-spin" />
                  : modal.tipo === 'cobrar' ? 'Registrar cobro' : 'Crear pago'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}

function SummaryCard({
  tone,
  icon,
  title,
  value,
  subtitle
}: {
  tone: Tone
  icon: ReactNode
  title: string
  value: number
  subtitle?: string
}) {
  const t = tones[tone]
  return (
    <div className={`card p-4 border ${t.wrap}`}>
      <p className={`text-xs font-semibold flex items-center gap-1 ${t.sub}`}>
        {icon} {title}
      </p>
      <p className={`text-2xl font-bold mt-1 ${t.value}`}>{fmt(value)}</p>
      {subtitle && <p className={`text-[10px] mt-0.5 ${t.sub}`}>{subtitle}</p>}
    </div>
  )
}







