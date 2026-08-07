import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { Wallet, Loader2, ArrowDownCircle, ArrowUpCircle, Upload, Check, ArrowUpRight, ArrowDownRight, HandCoins, Smartphone, CreditCard, ReceiptText, BarChart3 } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { fmt } from '@/lib/format'
import { useAuth } from '@/contexts/AuthContext'
import { EmptyState } from '@/components/ui/EmptyState'
import { SkeletonList } from '@/components/ui/Skeleton'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import type { Wallet as WalletType, Transaction, Payout, DriverEarningSummary } from '@/types/database'

export function DriverWallet() {
  const [wallet, setWallet] = useState<WalletType | null>(null)
  const [transactions, setTransactions] = useState<Transaction[]>([])
  const [payouts, setPayouts] = useState<Payout[]>([])
  const [earnings, setEarnings] = useState<DriverEarningSummary[]>([])
  const [loading, setLoading] = useState(true)
  const [showPayForm, setShowPayForm] = useState(false)
  const [payAmount, setPayAmount] = useState('')
  const [payProof, setPayProof] = useState<File | null>(null)
  const [error, setError] = useState('')
  const [saving, setSaving] = useState(false)
  const [showWithdrawForm, setShowWithdrawForm] = useState(false)
  const [withdrawAmount, setWithdrawAmount] = useState('')
  const [withdrawDesc, setWithdrawDesc] = useState('')
  const { user } = useAuth()
  const navigate = useNavigate()

  useEffect(() => {
    loadWallet()
  }, [])

  const loadWallet = async () => {
    if (!user) return
    const { data, error } = await supabase
      .from('wallets')
      .select('*')
      .eq('user_id', user.id)
      .single()

    if (!error && data) {
      setWallet(data as WalletType)
    }

    const { data: txnData } = await supabase
      .from('transactions')
      .select('*')
      .eq('user_id', user.id)
      .order('created_at', { ascending: false })
      .limit(20)

    if (txnData) {
      setTransactions(txnData as Transaction[])
    }

    const { data: payoutData } = await supabase.rpc('get_payouts')
    if (payoutData) {
      setPayouts(payoutData as Payout[])
    }

    // Historial exacto de ganancias por viaje
    const { data: earningData } = await supabase.rpc('get_driver_earnings')
    if (earningData) {
      setEarnings(earningData as DriverEarningSummary[])
    }

    setLoading(false)
  }

  const handlePayToPlatform = async () => {
    if (!payAmount || parseFloat(payAmount) <= 0) {
      setError('Ingresa un monto válido')
      return
    }
    if (!payProof) {
      setError('Sube el comprobante de pago')
      return
    }

    setError('')
    setSaving(true)

    try {
      if (!user) throw new Error('Debes iniciar sesión')

      const { data: uploadData, error: uploadError } = await supabase.storage
        .from('payments')
        .upload(`${user.id}/payments/${Date.now()}-${payProof.name}`, payProof, { upsert: true })
      if (uploadError) throw uploadError

      // El bucket es privado; guardamos la ruta y se resuelve con URL firmada al visualizar
      const publicUrl = uploadData.path

      const { error } = await supabase.rpc('driver_pay_to_platform', {
        p_amount_usd: parseFloat(payAmount),
        p_proof_url: publicUrl
      })
      if (error) throw error

      setShowPayForm(false)
      setPayAmount('')
      setPayProof(null)
      loadWallet()
    } catch (err: any) {
      setError(err.message)
    } finally {
      setSaving(false)
    }
  }

  const handleConfirmPayout = async (payoutId: string) => {
    setError('')
    setSaving(true)
    try {
      const { data, error } = await supabase.rpc('driver_confirm_payout', {
        p_payout_id: payoutId
      })
      if (error) throw error
      loadWallet()
    } catch (err: any) {
      setError(err.message)
    } finally {
      setSaving(false)
    }
  }

  const handleRequestPayout = async () => {
    if (!withdrawAmount || parseFloat(withdrawAmount) <= 0) {
      setError('Ingresa un monto válido')
      return
    }

    setError('')
    setSaving(true)

    try {
      const { data, error } = await supabase.rpc('driver_request_payout', {
        p_amount_usd: parseFloat(withdrawAmount),
        p_description: withdrawDesc || null
      })
      if (error) throw error

      setShowWithdrawForm(false)
      setWithdrawAmount('')
      setWithdrawDesc('')
      loadWallet()
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

  const txnBadge: Record<string, React.ReactNode> = {
    pendiente: <span className="badge-warning">Pendiente</span>,
    aprobado: <span className="badge-success">Aprobado</span>,
    rechazado: <span className="badge-danger">Rechazado</span>,
    completado: <span className="badge-info">Completado</span>
  }

  const paymentIcon = (method: string) => {
    if (method === 'Efectivo') return <HandCoins className="w-4 h-4 text-amber-600" />
    if (method === 'Billetera') return <Wallet className="w-4 h-4 text-emerald-600" />
    return <Smartphone className="w-4 h-4 text-blue-600" />
  }

  // Totales informativos (NO son saldo — el saldo real es wallet.balance_usd)
  const totalCash = earnings.reduce((sum, e) => sum + (e.cash_received_usd || 0), 0)
  // Comisiones de viajes en efectivo — se pagan aparte, no descuentan del saldo app
  const cashCommission = earnings
    .filter(e => e.payment_method?.toLowerCase() === 'efectivo')
    .reduce((sum, e) => sum + (e.commission_usd || 0), 0)
  const isOwed = (wallet?.balance_usd ?? 0) < 0
  const oweText = isOwed ? `Debes ${fmt(Math.abs(wallet?.balance_usd ?? 0))} a la plataforma` : `La app te debe ${fmt(wallet?.balance_usd ?? 0)}`

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-primary-600 border-b border-primary-700 px-6 py-4">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 bg-white/15 rounded-xl flex items-center justify-center">
            <Wallet className="w-5 h-5 text-white" />
          </div>
          <div>
            <h1 className="text-lg font-bold text-white">Mi Billetera</h1>
            <p className="text-xs text-white/80">Saldo, ganancias y liquidaciones</p>
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6 space-y-6">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        {/* Saldo principal de la app (solo digital) */}
        <div className="card bg-gradient-to-br from-primary-600 to-primary-800 text-white border-0">
          <div className="flex items-center gap-2 mb-2">
            <Wallet className="w-5 h-5" />
            <span className="text-sm font-medium">Saldo en la app (solo digital)</span>
          </div>
          <p className="text-3xl font-bold">{fmt(wallet?.balance_usd)}</p>
          <p className="text-sm text-white/70 mt-1">
            Créditos por Billetera y Pago Móvil. El dinero en efectivo que ya cobraste NO está aquí.
          </p>
        </div>

        {/* Bloque informativo: Efectivo + Comisiones pendientes (NO es saldo) */}
        {earnings.length > 0 && (
          <div className="grid grid-cols-2 gap-2">
            <div className="card p-3 bg-amber-50 border-amber-200">
              <p className="text-[10px] uppercase tracking-wide text-amber-700 flex items-center gap-1 font-semibold">
                <HandCoins className="w-3 h-3" /> Efectivo recibido
              </p>
              <p className="text-xl font-bold text-amber-600 mt-1">{fmt(totalCash)}</p>
              <p className="text-[10px] text-amber-500">Ya lo tienes del cliente, no es saldo app</p>
            </div>
            <div className="card p-3 bg-orange-50 border-orange-200">
              <p className="text-[10px] uppercase tracking-wide text-orange-700 flex items-center gap-1 font-semibold">
                <CreditCard className="w-3 h-3" /> Comisiones efectivo
              </p>
              <p className="text-xl font-bold text-orange-600 mt-1">{fmt(cashCommission)}</p>
              <p className="text-[10px] text-orange-500">Úsalas para pagar a la plataforma</p>
            </div>
          </div>
        )}

        {/* Estado real: la app te debe o le debes */}
        {wallet && (
          <div className={`card p-4 ${isOwed ? 'bg-red-50 border-red-300' : 'bg-emerald-50 border-emerald-300'}`}>
            <p className="text-xs font-semibold text-surface-600 mb-1">Estado de tu cuenta con la plataforma</p>
            <p className={`text-lg font-bold ${isOwed ? 'text-red-600' : 'text-emerald-600'}`}>{oweText}</p>
            {!isOwed && wallet.balance_usd > 0 && (
              <p className="text-xs text-surface-500 mt-1">Este es el dinero que la app te adeuda por viajes pagados digitalmente.</p>
            )}
            {isOwed && (
              <button
                onClick={() => setShowPayForm(!showPayForm)}
                className="mt-3 btn-primary w-full"
              >
                {showPayForm ? 'Cerrar' : 'Pagar a la plataforma'}
              </button>
            )}
          </div>
        )}

        {/* Acceso a mis métricas */}
        <button
          onClick={() => navigate('/conductor/metricas')}
          className="card card-hover w-full flex items-center gap-4"
        >
          <div className="w-12 h-12 bg-emerald-50 rounded-xl flex items-center justify-center text-emerald-600">
            <BarChart3 className="w-6 h-6" />
          </div>
          <div className="flex-1 text-left">
            <p className="font-medium text-surface-700">Mis métricas</p>
            <p className="text-xs text-surface-400">Viajes, ganancias y comisiones con filtros de fecha</p>
          </div>
        </button>

        {/* Solicitar retiro (solo si saldo > 0) */}
        {wallet && wallet.balance_usd > 0 && (
          <button
            onClick={() => setShowWithdrawForm(!showWithdrawForm)}
            className="btn-outline w-full"
          >
            {showWithdrawForm ? 'Cancelar' : `Solicitar retiro (disponible ${fmt(wallet.balance_usd)})`}
          </button>
        )}

        {showWithdrawForm && wallet && (
          <div className="card space-y-3 animate-fade-in">
            <h2 className="font-semibold text-surface-800">Solicitar retiro</h2>
            <p className="text-xs text-surface-500">
              El Admin aprobará tu solicitud y luego confirmarás que recibiste el dinero.
            </p>
            <div>
              <label className="label">Monto ($)</label>
              <input
                type="number"
                className="input"
                step="0.01"
                min="0.01"
                max={wallet.balance_usd}
                placeholder={`0.00 (máx ${wallet.balance_usd.toFixed(2)}$)`}
                value={withdrawAmount}
                onChange={(e) => setWithdrawAmount(e.target.value)}
              />
            </div>
            <div>
              <label className="label">Observación (opcional)</label>
              <input
                type="text"
                className="input"
                placeholder="Ej: Pago a mi Pago Móvil 0412..."
                value={withdrawDesc}
                onChange={(e) => setWithdrawDesc(e.target.value)}
              />
            </div>
            <button onClick={handleRequestPayout} className="btn-primary w-full" disabled={saving}>
              {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Solicitar retiro'}
            </button>
          </div>
        )}

        {showPayForm && (
          <div className="card space-y-3 animate-fade-in">
            <h2 className="font-semibold text-surface-800">Pagar a la plataforma</h2>
            <p className="text-xs text-surface-500">
              Realiza el pago por Pago Móvil o Zelle y sube el comprobante para que el Admin lo apruebe.
            </p>
            <div>
              <label className="label">Monto ($)</label>
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
              <label className="label">Comprobante *</label>
              <label className="flex flex-col items-center justify-center w-full h-24 border-2 border-dashed border-surface-200 rounded-xl cursor-pointer hover:border-primary-400 transition-colors">
                {payProof ? (
                  <div className="text-center">
                    <Check className="w-6 h-6 text-emerald-600 mx-auto mb-1" />
                    <span className="text-xs text-surface-600 truncate max-w-[200px] block">{payProof.name}</span>
                  </div>
                ) : (
                  <div className="text-center">
                    <Upload className="w-6 h-6 text-surface-400 mx-auto mb-1" />
                    <span className="text-xs text-surface-500">Toca para subir captura del pago</span>
                  </div>
                )}
                <input
                  type="file"
                  accept="image/*"
                  className="hidden"
                  onChange={(e) => setPayProof(e.target.files?.[0] || null)}
                />
              </label>
            </div>
            <button onClick={handlePayToPlatform} className="btn-primary w-full" disabled={saving}>
              {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Enviar pago para aprobación'}
            </button>
          </div>
        )}

        {/* Payouts */}
        {payouts.length > 0 && (
          <div>
            <h2 className="text-lg font-semibold text-surface-800 mb-3">Liquidaciones</h2>
            <div className="space-y-2">
              {payouts.map((p) => (
                <div key={p.id} className="card flex items-center justify-between">
                  <div className="flex items-center gap-3">
                    <div className={`w-10 h-10 rounded-full flex items-center justify-center ${
                      p.type === 'driver_pay_platform' ? 'bg-amber-50 text-amber-600' : 'bg-emerald-50 text-emerald-600'
                    }`}>
                      {p.type === 'driver_pay_platform' ? <ArrowUpRight className="w-5 h-5" /> : <ArrowDownRight className="w-5 h-5" />}
                    </div>
                    <div>
                      <p className="text-sm font-medium text-surface-700">
                        {p.type === 'driver_pay_platform' ? 'Pago a plataforma' : 'Pago de la plataforma'}
                      </p>
                      <p className="text-xs text-surface-400">{new Date(p.created_at).toLocaleDateString('es-VE')}</p>
                    </div>
                  </div>
                  <div className="text-right">
                    <p className="font-semibold text-surface-800">{p.amount_usd.toFixed(2)}$</p>
                    {statusBadge[p.status]}
                    {p.status === 'aprobado' && p.type === 'platform_pay_driver' && (
                      <button
                        onClick={() => handleConfirmPayout(p.id)}
                        className="btn-success mt-1 text-xs px-2 py-1"
                        disabled={saving}
                      >
                        ✅ Confirmar recibo
                      </button>
                    )}
                    {p.status === 'pendiente' && p.type === 'platform_pay_driver' && (
                      <p className="text-[10px] text-amber-600 mt-1">Esperando aprobación del admin</p>
                    )}
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Historial de ganancias por viaje */}
        <div>
          <h2 className="text-lg font-semibold text-surface-800 mb-3 flex items-center gap-2">
            <ReceiptText className="w-5 h-5 text-primary-600" />
            Ganancias por viaje
          </h2>
          <p className="text-xs text-surface-400 mb-3">
            Desglose exacto de lo que cobraste en efectivo, lo que la app te acredita y las comisiones.
          </p>
          {loading ? (
            <SkeletonList count={3} />
          ) : earnings.length === 0 ? (
            <EmptyState
              icon={<ReceiptText className="w-8 h-8" />}
              title="Sin ganancias registradas"
              description="Cuando completes viajes, aquí verás el desglose exacto de tus ganancias"
            />
          ) : (
            <div className="space-y-2">
              {earnings.map((e) => (
                <div key={e.ride_id} className="card p-4">
                  <div className="flex items-center justify-between mb-2">
                    <div className="flex items-center gap-2">
                      {paymentIcon(e.payment_method)}
                      <span className="text-sm font-medium text-surface-700">{e.payment_method}</span>
                    </div>
                    <span className="text-sm font-bold text-surface-800">{e.fare_usd.toFixed(2)}$</span>
                  </div>

                  <p className="text-xs text-surface-400 truncate mb-2">
                    {e.destination || 'Viaje completado'}
                  </p>

                  <div className="grid grid-cols-3 gap-2 text-xs">
                    <div className={`rounded-lg p-2 ${e.cash_received_usd > 0 ? 'bg-amber-50' : 'bg-surface-50'}`}>
                      <p className="text-surface-400 flex items-center gap-1">
                        <HandCoins className="w-3 h-3" /> Efectivo
                      </p>
                      <p className="font-semibold text-amber-600 mt-0.5">
                        {e.cash_received_usd > 0 ? `+${e.cash_received_usd.toFixed(2)}$` : '0.00$'}
                      </p>
                      {e.cash_received_usd > 0 && (
                        <p className="text-[10px] text-amber-500">Ya lo recibiste del cliente</p>
                      )}
                    </div>
                    <div className={`rounded-lg p-2 ${e.app_credit_usd > 0 ? 'bg-emerald-50' : 'bg-surface-50'}`}>
                      <p className="text-surface-400 flex items-center gap-1">
                        <Wallet className="w-3 h-3" /> App te acredita
                      </p>
                      <p className="font-semibold text-emerald-600 mt-0.5">
                        {e.app_credit_usd > 0 ? `+${e.app_credit_usd.toFixed(2)}$` : '0.00$'}
                      </p>
                      {e.app_credit_usd > 0 && (
                        <p className="text-[10px] text-emerald-500">Sumado a tu saldo app</p>
                      )}
                    </div>
                    <div className="rounded-lg p-2 bg-surface-50">
                      <p className="text-surface-400 flex items-center gap-1">
                        <CreditCard className="w-3 h-3" /> Comisión app
                      </p>
                      <p className="font-semibold text-red-500 mt-0.5">
                        -{e.commission_usd.toFixed(2)}$
                      </p>
                      <p className="text-[10px] text-surface-400">Para la plataforma</p>
                    </div>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>

        {/* Movimientos (transacciones de wallet) */}
        <div>
          <h2 className="text-lg font-semibold text-surface-800 mb-3">Movimientos de saldo</h2>
          {loading ? (
            <SkeletonList count={3} />
          ) : transactions.length === 0 ? (
            <EmptyState
              icon={<Wallet className="w-8 h-8" />}
              title="Sin movimientos"
              description="Tus comisiones, ajustes y ganancias de la app aparecerán aquí"
            />
          ) : (
            <div className="space-y-2">
              {transactions.map((txn) => (
                <div key={txn.id} className="card flex items-center justify-between">
                  <div className="flex items-center gap-3">
                    <div className={`w-10 h-10 rounded-full flex items-center justify-center ${
                      txn.amount_usd > 0 ? 'bg-emerald-50 text-emerald-600' : 'bg-red-50 text-red-500'
                    }`}>
                      {txn.amount_usd > 0 ? <ArrowDownCircle className="w-5 h-5" /> : <ArrowUpCircle className="w-5 h-5" />}
                    </div>
                    <div>
                      <p className="text-sm font-medium text-surface-700">{txn.description}</p>
                      <p className="text-xs text-surface-400">{new Date(txn.created_at).toLocaleDateString('es-VE')}</p>
                    </div>
                  </div>
                  <div className="text-right">
                    <p className={`font-semibold ${txn.amount_usd > 0 ? 'text-emerald-600' : 'text-red-500'}`}>
                      {txn.amount_usd > 0 ? '+' : ''}{txn.amount_usd.toFixed(2)}$</p>
                    {txnBadge[txn.status]}
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  )
}