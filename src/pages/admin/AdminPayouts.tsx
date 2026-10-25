import { useState, useEffect } from 'react'
import { ArrowUpCircle, ArrowDownCircle, Check, X, Loader2, Wallet, ExternalLink, User, Send } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { EmptyState } from '@/components/ui/EmptyState'
import { SkeletonList } from '@/components/ui/Skeleton'
import { resolveProofUrl } from '@/lib/storageUtils'
import type { Payout, Profile, Wallet as WalletType } from '@/types/database'

interface DriverWithWallet {
  id: string
  full_name: string
  balance_usd: number
}

export function AdminPayouts() {
  const [payouts, setPayouts] = useState<Payout[]>([])
  const [proofUrls, setProofUrls] = useState<Record<string, string | null>>({})
  const [driverNames, setDriverNames] = useState<Record<string, string>>({})
  const [drivers, setDrivers] = useState<DriverWithWallet[]>([])
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [actionLoading, setActionLoading] = useState<string | null>(null)
  const [showPayDriver, setShowPayDriver] = useState(false)
  const [selectedDriver, setSelectedDriver] = useState('')
  const [payAmount, setPayAmount] = useState('')
  const [payDesc, setPayDesc] = useState('')
  const [saving, setSaving] = useState(false)
  const [methods, setMethods] = useState<string[]>([])
  const [payMethod, setPayMethod] = useState('')
  const [approveMethods, setApproveMethods] = useState<Record<string, string>>({})
  const { user } = useAuth()
  const isEncargado = user?.role === 'encargado'
  const [zoneName, setZoneName] = useState('')

  // El encargado trabaja SOLO con su ciudad (el backend también lo impone)
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

  // Resolver URLs firmadas de comprobantes (bucket payments es privado)
  const resolveProofs = async (items: Payout[]) => {
    const urls: Record<string, string | null> = {}
    for (const p of items) {
      if (p.proof_url) {
        urls[p.id] = await resolveProofUrl(p.proof_url)
      }
    }
    setProofUrls(urls)
  }

  useEffect(() => {
    loadAll()
  }, [])

  // Métodos válidos para mover dinero real (efectivo + recarga)
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
        setPayMethod((prev) => prev || names.find((n) => /efectivo/i.test(n)) || names[0] || '')
      })
  }, [])

  const defaultMethod = methods.find((m) => /efectivo/i.test(m)) || methods[0] || ''

  const loadAll = async () => {
    setLoading(true)

    const { data: payoutData, error } = await supabase.rpc('get_payouts')
    if (!error && payoutData) {
      const items = payoutData as Payout[]
      setPayouts(items)
      resolveProofs(items)

      // Identificar al conductor de cada pago. get_payouts ya limita los
      // pagos por rol/ciudad, así que esta consulta respeta la misma RLS.
      const payoutDriverIds = Array.from(new Set(items.map((p) => p.driver_id)))
      if (payoutDriverIds.length > 0) {
        const { data: payoutDriversData } = await supabase
          .from('profiles')
          .select('id, full_name')
          .in('id', payoutDriverIds)

        const namesMap: Record<string, string> = {}
        const payoutDrivers = payoutDriversData as Pick<Profile, 'id' | 'full_name'>[] | null
        payoutDrivers?.forEach((d) => {
          namesMap[d.id] = d.full_name
        })
        setDriverNames(namesMap)
      } else {
        setDriverNames({})
      }
    }

    // Cargar conductores con saldo (el encargado solo los de su ciudad)
    const driversQuery = supabase
      .from('profiles')
      .select('id, full_name')
      .eq('role', 'conductor')
      .eq('driver_status', 'aprobado')
      .order('full_name')
    const { data: driversData } = isEncargado && user?.zone_id
      ? await driversQuery.eq('zone_id', user.zone_id)
      : await driversQuery

    if (driversData) {
      // Cargar wallets de cada conductor
      const ids = (driversData as Profile[]).map((d) => d.id)
      const { data: walletsData } = await supabase
        .from('wallets')
        .select('user_id, balance_usd')
        .in('user_id', ids)

      const walletsMap: Record<string, number> = {}
      if (walletsData) {
        (walletsData as WalletType[]).forEach((w) => {
          walletsMap[w.user_id] = w.balance_usd
        })
      }

      // Solo conductores con saldo > 0 (se les puede pagar)
      const withBalance = (driversData as Profile[])
        .filter((d) => (walletsMap[d.id] || 0) > 0)
        .map((d) => ({
          id: d.id,
          full_name: d.full_name,
          balance_usd: walletsMap[d.id] || 0
        }))
      setDrivers(withBalance)
    }

    setLoading(false)
  }

  const handleApprove = async (payoutId: string, approve: boolean, method?: string | null) => {
    setError('')
    setActionLoading(payoutId)
    try {
      const { error } = await supabase.rpc('approve_payout', {
        p_payout_id: payoutId,
        p_approve: approve,
        p_payment_method: method || null
      })
      if (error) throw error
      loadAll()
    } catch (err: any) {
      setError(err.message)
    } finally {
      setActionLoading(null)
    }
  }

  const handlePayDriver = async () => {
    if (!selectedDriver) {
      setError('Selecciona un conductor')
      return
    }
    if (!payAmount || parseFloat(payAmount) <= 0) {
      setError('Ingresa un monto válido')
      return
    }
    if (!payMethod) {
      setError('Selecciona el método de pago')
      return
    }
    const driver = drivers.find((d) => d.id === selectedDriver)
    if (driver && parseFloat(payAmount) > driver.balance_usd) {
      setError(`El conductor solo tiene ${driver.balance_usd.toFixed(2)}$ disponible`)
      return
    }

    setError('')
    setSaving(true)
    try {
      const { data, error } = await supabase.rpc('admin_pay_driver_manual', {
        p_driver_id: selectedDriver,
        p_amount_usd: parseFloat(payAmount),
        p_description: payDesc || null,
        p_payment_method: payMethod
      })
      if (error) throw error

      setShowPayDriver(false)
      setSelectedDriver('')
      setPayAmount('')
      setPayDesc('')
      loadAll()
    } catch (err: any) {
      setError(err.message)
    } finally {
      setSaving(false)
    }
  }

  const statusBadge: Record<string, React.ReactNode> = {
    pendiente: <span className="badge-warning">Pendiente</span>,
    aprobado: <span className="badge-success">Aprobado</span>,
    rechazado: <span className="badge-danger">Rechazado</span>,
    confirmado: <span className="badge-info">Confirmado</span>
  }

  // Agrupar por tipo: pendientes primero
  const sorted = [...payouts].sort((a, b) => {
    const order = { pendiente: 0, aprobado: 1, confirmado: 2, rechazado: 3 }
    return (order[a.status] ?? 4) - (order[b.status] ?? 4)
  })

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 bg-primary-600 rounded-xl flex items-center justify-center">
              <Wallet className="w-5 h-5 text-white" />
            </div>
            <div>
              <h1 className="text-lg font-bold text-surface-800">Liquidaciones</h1>
              <p className="text-xs text-surface-500">
                {isEncargado
                  ? `${zoneName || 'Mi ciudad'} — pagos entre tus conductores y la plataforma`
                  : 'Pagos entre conductores y plataforma'}
              </p>
            </div>
          </div>
          <button
            onClick={() => setShowPayDriver(!showPayDriver)}
            className={`${showPayDriver ? 'btn-outline' : 'btn-primary'} text-sm px-3 py-2 flex items-center gap-1`}
          >
            <Send className="w-4 h-4" />
            {showPayDriver ? 'Cancelar' : 'Pagar a conductor'}
          </button>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6 space-y-6">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        {/* Formulario: pagar a conductor */}
        {showPayDriver && (
          <div className="card space-y-3">
            <h2 className="font-semibold text-surface-800 flex items-center gap-2">
              <User className="w-4 h-4 text-primary-600" /> Pagar a un conductor
            </h2>
            <div>
              <label className="label">Conductor *</label>
              <select className="input" value={selectedDriver} onChange={(e) => setSelectedDriver(e.target.value)}>
                <option value="">Seleccionar conductor...</option>
                {drivers.map((d) => (
                  <option key={d.id} value={d.id}>
                    {d.full_name} — disponible {d.balance_usd.toFixed(2)}$
                  </option>
                ))}
              </select>
              {drivers.length === 0 && (
                <p className="text-xs text-amber-600 mt-1">Ningún conductor tiene saldo disponible para pagar.</p>
              )}
            </div>
            <div>
              <label className="label">Monto ($) *</label>
              <input
                type="number"
                className="input"
                step="0.01"
                min="0.01"
                placeholder="0.00"
                value={payAmount}
                onChange={(e) => setPayAmount(e.target.value)}
              />
            </div>
            <div>
              <label className="label">Método de pago *</label>
              <select className="input" value={payMethod} onChange={(e) => setPayMethod(e.target.value)}>
                {methods.length === 0 && <option value="">Sin métodos activos</option>}
                {methods.map((m) => <option key={m} value={m}>{m}</option>)}
              </select>
            </div>
            <div>
              <label className="label">Descripción (opcional)</label>
              <input
                type="text"
                className="input"
                placeholder="Ej: Retiro efectivo"
                value={payDesc}
                onChange={(e) => setPayDesc(e.target.value)}
              />
            </div>
            <button onClick={handlePayDriver} className="btn-primary w-full" disabled={saving}>
              {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : <><Send className="w-4 h-4" /> Crear pago para conductor</>}
            </button>
            <p className="text-xs text-surface-400">
              El conductor deberá confirmar que recibió el dinero (doble confirmación).
            </p>
          </div>
        )}

        {loading ? (
          <SkeletonList count={3} />
        ) : sorted.length === 0 ? (
          <EmptyState
            icon={<Wallet className="w-8 h-8" />}
            title="Sin liquidaciones"
            description="Los pagos entre conductores y plataforma aparecerán aquí"
          />
        ) : (
          <div className="space-y-3">
            {sorted.map((p) => (
              <div key={p.id} className="card">
                <div className="flex items-center justify-between mb-3">
                  <div className="flex items-center gap-2">
                    {p.type === 'driver_pay_platform' ? (
                      <ArrowUpCircle className="w-5 h-5 text-amber-500" />
                    ) : (
                      <ArrowDownCircle className="w-5 h-5 text-emerald-600" />
                    )}
                    <span className="font-medium text-surface-700">
                      {p.type === 'driver_pay_platform' ? 'Conductor → Plataforma' : 'Plataforma → Conductor'}
                    </span>
                  </div>
                  {statusBadge[p.status]}
                </div>

                <p className="text-sm text-surface-600 mb-2 flex items-center gap-1.5">
                  <User className="w-4 h-4 text-surface-400 flex-shrink-0" />
                  <span>
                    <span className="text-surface-400">Conductor: </span>
                    <span className="font-medium text-surface-700">
                      {driverNames[p.driver_id] || 'No identificado'}
                    </span>
                  </span>
                </p>
                <p className="text-2xl font-bold text-surface-800 mb-2">{p.amount_usd.toFixed(2)}$</p>
                <div className="mb-2">
                  <span className={`text-[11px] font-medium px-2 py-1 rounded-lg ${
                    p.payment_method
                      ? (/efectivo/i.test(p.payment_method)
                          ? 'bg-amber-50 text-amber-700'
                          : 'bg-blue-50 text-blue-700')
                      : 'bg-surface-100 text-surface-500'
                  }`}>
                    {p.payment_method || 'Sin clasificar'}
                  </span>
                </div>
                {p.description && <p className="text-sm text-surface-500 mb-2">{p.description}</p>}
                <p className="text-xs text-surface-400 mb-3">
                  {new Date(p.created_at).toLocaleString('es-VE')}
                </p>

                {proofUrls[p.id] && (
                  <a
                    href={proofUrls[p.id]!}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="inline-flex items-center gap-1 text-primary-600 text-sm mb-3 hover:underline"
                  >
                    <ExternalLink className="w-4 h-4" />
                    Ver comprobante
                  </a>
                )}

                {p.status === 'pendiente' && p.type === 'platform_pay_driver' && (
                  <div className="mb-2">
                    <label className="label">Método con el que pagaste</label>
                    <select
                      className="input"
                      value={approveMethods[p.id] ?? p.payment_method ?? defaultMethod}
                      onChange={(e) => setApproveMethods((prev) => ({ ...prev, [p.id]: e.target.value }))}
                    >
                      {methods.length === 0 && <option value="">Sin métodos activos</option>}
                      {methods.map((m) => <option key={m} value={m}>{m}</option>)}
                    </select>
                  </div>
                )}

                {p.status === 'pendiente' && (
                  <div className="flex gap-2">
                    <button
                      onClick={() => handleApprove(
                        p.id,
                        true,
                        p.type === 'platform_pay_driver'
                          ? (approveMethods[p.id] ?? p.payment_method ?? defaultMethod)
                          : p.payment_method
                      )}
                      className="btn-success flex-1"
                      disabled={actionLoading === p.id}
                    >
                      {actionLoading === p.id ? <Loader2 className="w-4 h-4 animate-spin" /> : (
                        <>
                          <Check className="w-4 h-4" />
                          {p.type === 'platform_pay_driver' ? 'Aprobar (ya pagaste)' : 'Aprobar pago'}
                        </>
                      )}
                    </button>
                    <button
                      onClick={() => handleApprove(p.id, false, null)}
                      className="btn-danger flex-1"
                      disabled={actionLoading === p.id}
                    >
                      <X className="w-4 h-4" />
                      Rechazar
                    </button>
                  </div>
                )}

                {p.status === 'aprobado' && p.type === 'platform_pay_driver' && (
                  <div className="mt-2 bg-emerald-50 border border-emerald-200 rounded-lg px-3 py-2">
                    <p className="text-xs text-emerald-700">
                      ✅ Aprobado — esperando que el conductor confirme que recibió el dinero.
                    </p>
                  </div>
                )}
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}