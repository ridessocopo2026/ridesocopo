import { useState, useEffect, useMemo, useRef } from 'react'
import { useNavigate } from 'react-router-dom'
import { Wallet, Loader2, ArrowDownCircle, ArrowUpCircle, Upload, Check, Copy, ArrowUpRight, ArrowDownRight, HandCoins, Smartphone, CreditCard, ReceiptText, BarChart3 } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { fmt } from '@/lib/format'
import { uploadImageToStorage } from '@/lib/uploadImage'
import { useAuth } from '@/contexts/AuthContext'
import { EmptyState } from '@/components/ui/EmptyState'
import { SkeletonList } from '@/components/ui/Skeleton'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import type { Wallet as WalletType, Transaction, Payout, DriverEarningSummary } from '@/types/database'

interface RechargeMethod {
  id: string
  name: string
  description?: string
  icon?: string
  proof_required?: boolean
  fields: { id: string; label: string; value: string }[]
}

const CASH_METHOD: RechargeMethod = {
  id: 'cash',
  name: 'Efectivo',
  description: 'Entrega el efectivo al administrador; quedará pendiente de confirmación.',
  icon: 'cash',
  proof_required: false,
  fields: []
}

export function DriverWallet() {
  const [wallet, setWallet] = useState<WalletType | null>(null)
  const [transactions, setTransactions] = useState<Transaction[]>([])
  const [payouts, setPayouts] = useState<Payout[]>([])
  const [earnings, setEarnings] = useState<DriverEarningSummary[]>([])
  const [loading, setLoading] = useState(true)
  const [showPayForm, setShowPayForm] = useState(false)
  const [payAmount, setPayAmount] = useState('')
  const [payProof, setPayProof] = useState<File | null>(null)
  const [rechargeMethods, setRechargeMethods] = useState<RechargeMethod[]>([])
  const [selectedMethodId, setSelectedMethodId] = useState('')
  const [copiedField, setCopiedField] = useState('')
  const [payReference, setPayReference] = useState('')
  const [exchangeRate, setExchangeRate] = useState(0)
  const [notice, setNotice] = useState('')
  const [error, setError] = useState('')
  const [saving, setSaving] = useState(false)
  const payFormRef = useRef<HTMLDivElement | null>(null)
  const [showWithdrawForm, setShowWithdrawForm] = useState(false)
  const [withdrawAmount, setWithdrawAmount] = useState('')
  const [withdrawDesc, setWithdrawDesc] = useState('')
  const { user } = useAuth()
  const navigate = useNavigate()

  useEffect(() => {
    loadWallet()
  }, [])

  useEffect(() => {
    if (!showPayForm) return
    const timer = window.setTimeout(() => {
      payFormRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' })
    }, 120)
    return () => window.clearTimeout(timer)
  }, [showPayForm])

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
      .select('id, type, description, created_at, amount_usd, status')
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

    // Métodos disponibles para pagar a la plataforma (con sus datos de transferencia)
    const { data: rmData, error: rmError } = await supabase.rpc('get_recharge_payment_methods')
    if (!rmError && rmData && Array.isArray(rmData)) {
      setRechargeMethods(rmData as RechargeMethod[])
      setSelectedMethodId(rmData.length > 0 ? rmData[0].id : CASH_METHOD.id)
    } else {
      setSelectedMethodId(CASH_METHOD.id)
    }

    // Tasa activa para mostrar y convertir Pago Móvil (Bs -> USD)
    const { data: rateData } = await supabase.rpc('get_active_exchange_rate')
    if (rateData != null) setExchangeRate(Number(rateData) || 0)

    setLoading(false)
  }

  const paymentOptions = useMemo(() => {
    const hasCash = rechargeMethods.some((m) => /efectivo/i.test(m.name))
    return hasCash ? rechargeMethods : [...rechargeMethods, CASH_METHOD]
  }, [rechargeMethods])

  const selectedMethod =
    paymentOptions.find((m) => m.id === selectedMethodId) || paymentOptions[0] || null

  const methodName = selectedMethod?.name || ''
  const isCash = selectedMethod?.id === CASH_METHOD.id || /efectivo/i.test(methodName)
  const isBs = !isCash && /pago\s*m[oó]vil/i.test(methodName)
  const proofRequired = !isCash && selectedMethod?.proof_required !== false

  const handleCopyField = (value: string) => {
    navigator.clipboard?.writeText(value).then(() => {
      setCopiedField(value)
      setTimeout(() => setCopiedField(''), 1500)
    }).catch(() => {})
  }

  const handlePayToPlatform = async () => {
    if (!isOwed || availableUsd <= 0) {
      setError('No tienes deuda disponible para pagar')
      return
    }
    if (!selectedMethod) {
      setError('Selecciona un método de pago')
      return
    }
    if (!payAmount || amountValue <= 0) {
      setError('Ingresa un monto válido')
      return
    }
    if (isBs && exchangeRate <= 0) {
      setError('No hay tasa de cambio configurada para Pago Móvil')
      return
    }
    if (overMax) {
      setError(
        isBs
          ? `El monto supera el máximo disponible (Bs. ${maxAmount.toFixed(2)})`
          : `El monto supera el máximo disponible ($${maxAmount.toFixed(2)})`
      )
      return
    }
    if (amountUsd <= 0) {
      setError('El monto en dólares es demasiado bajo')
      return
    }
    if (proofRequired && !payProof) {
      setError('Sube el comprobante de pago')
      return
    }

    setError('')
    setNotice('')
    setSaving(true)

    try {
      if (!user) throw new Error('Debes iniciar sesión')

      let proofPath: string | null = null
      if (!isCash && payProof) {
        const uploadData = await uploadImageToStorage(
          'payments',
          `${user.id}/payments/${Date.now()}-${payProof.name}`,
          payProof,
          'proof'
        )
        proofPath = uploadData.path
      }

      const { error: payError } = await supabase.rpc('driver_pay_to_platform', {
        p_amount_usd: isBs ? null : amountUsd,
        p_proof_url: proofPath,
        p_payment_method: selectedMethod.name,
        p_reference: isCash ? null : (payReference || null),
        p_amount_bs: isBs ? amountValue : null
      })
      if (payError) throw payError

      setShowPayForm(false)
      setPayAmount('')
      setPayProof(null)
      setPayReference('')
      setNotice(
        isCash
          ? 'Pago en efectivo registrado. Queda pendiente de que el administrador confirme que lo recibió.'
          : 'Pago enviado. Queda pendiente de aprobación.'
      )
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

  const totalDebt = isOwed ? Math.abs(wallet?.balance_usd ?? 0) : 0
  const pendingDriverPay = payouts
    .filter((p) => p.type === 'driver_pay_platform' && p.status === 'pendiente')
    .reduce((sum, p) => sum + (p.amount_usd || 0), 0)
  const availableUsd = Math.max(0, Math.round((totalDebt - pendingDriverPay) * 100) / 100)
  const maxBs = exchangeRate > 0
    ? Math.floor(availableUsd * exchangeRate * 100) / 100
    : 0
  const maxAmount = isBs ? maxBs : availableUsd
  const amountValue = parseFloat(payAmount) || 0
  const amountUsd = isBs
    ? (exchangeRate > 0 ? Math.round((amountValue / exchangeRate) * 100) / 100 : 0)
    : Math.round(amountValue * 100) / 100
  const overMax = amountValue > maxAmount + 0.0001
  const canSubmit = isOwed && availableUsd > 0 && amountValue > 0 && amountUsd > 0 && !overMax &&
    (!isBs || exchangeRate > 0) && (!proofRequired || !!payProof)

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
        {notice && (
          <div className="card p-3 bg-emerald-50 border border-emerald-200 text-emerald-700 text-sm">
            {notice}
          </div>
        )}

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
          <div ref={payFormRef} className="card space-y-3 animate-fade-in scroll-mt-4">
            <h2 className="font-semibold text-surface-800">Pagar a la plataforma</h2>
            <p className="text-xs text-surface-500">
              Transfiere a uno de estos métodos y sube el comprobante. El Admin lo aprobará.
            </p>

            {paymentOptions.length > 1 && (
              <div>
                <label className="label">Método de pago</label>
                <div className="space-y-2">
                  {paymentOptions.map((m) => (
                    <button
                      key={m.id}
                      type="button"
                      onClick={() => {
                        setSelectedMethodId(m.id)
                        setPayAmount('')
                        setError('')
                      }}
                      className={`w-full p-3 rounded-xl border-2 text-left transition-all ${
                        selectedMethodId === m.id
                          ? 'border-primary-600 bg-primary-50'
                          : 'border-surface-200 hover:border-surface-300'
                      }`}
                    >
                      <span className="text-sm font-medium text-surface-700">{m.name}</span>
                      {m.description && (
                        <span className="block text-xs text-surface-500 mt-0.5">{m.description}</span>
                      )}
                    </button>
                  ))}
                </div>
              </div>
            )}

            {isCash && (
              <div className="rounded-xl border border-amber-200 bg-amber-50 p-3">
                <p className="text-sm font-medium text-amber-800">Pago en efectivo</p>
                <p className="text-xs text-amber-700 mt-1">
                  Entrega el efectivo al administrador o encargado. El pago quedará pendiente hasta que él lo confirme.
                </p>
              </div>
            )}

            {!isCash && selectedMethod && selectedMethod.fields.length > 0 && (
              <div>
                <label className="label">Datos para pagar a {selectedMethod.name}</label>
                <div className="space-y-2">
                  {selectedMethod.fields.map((field) => (
                    <div key={field.id} className="flex items-center justify-between bg-surface-50 rounded-lg p-2">
                      <div className="min-w-0">
                        <p className="text-xs text-surface-400">{field.label}</p>
                        <p className="text-sm font-medium text-surface-700 truncate">{field.value}</p>
                      </div>
                      <button
                        type="button"
                        onClick={() => handleCopyField(field.value)}
                        className="ml-2 flex-shrink-0 p-2 rounded-lg text-primary-600 hover:bg-primary-50 transition-colors"
                        aria-label={`Copiar ${field.label}`}
                      >
                        {copiedField === field.value ? (
                          <Check className="w-4 h-4 text-emerald-600" />
                        ) : (
                          <Copy className="w-4 h-4" />
                        )}
                      </button>
                    </div>
                  ))}
                </div>
              </div>
            )}
            <div>
              <div className="flex items-center justify-between gap-2">
                <label className="label mb-0">{isBs ? 'Monto a pagar (Bs.)' : 'Monto a pagar ($)'}</label>
                <button
                  type="button"
                  onClick={() => setPayAmount(maxAmount.toFixed(2))}
                  className="text-xs font-semibold text-primary-600 disabled:text-surface-300"
                  disabled={maxAmount <= 0}
                >
                  Pagar total
                </button>
              </div>
              <input
                type="number"
                className="input"
                step="0.01"
                min="0.01"
                max={maxAmount > 0 ? maxAmount.toFixed(2) : undefined}
                placeholder={isBs ? `0.00 Bs. (máx ${maxBs.toFixed(2)})` : `0.00 (máx ${availableUsd.toFixed(2)}$)`}
                value={payAmount}
                onChange={(e) => setPayAmount(e.target.value)}
                disabled={availableUsd <= 0 || (isBs && exchangeRate <= 0)}
              />
              <div className="mt-1 flex flex-wrap items-center justify-between gap-1 text-[11px]">
                {isBs ? (
                  <>
                    <span className="text-surface-400">Máximo: Bs. {maxBs.toFixed(2)}</span>
                    <span className="text-surface-500">
                      Aprox. ${amountUsd.toFixed(2)} · Tasa Bs. {exchangeRate.toFixed(2)}/$
                    </span>
                  </>
                ) : (
                  <>
                    <span className="text-surface-400">Máximo: ${availableUsd.toFixed(2)}</span>
                    <span className="text-surface-500">{isCash ? 'Pago en efectivo' : 'Se registrará en dólares'}</span>
                  </>
                )}
              </div>
              {overMax && (
                <p className="text-[11px] text-red-600 mt-1">El monto supera el máximo disponible.</p>
              )}
              {isBs && exchangeRate <= 0 && (
                <p className="text-[11px] text-red-600 mt-1">No hay tasa de cambio configurada.</p>
              )}
              {availableUsd <= 0 && totalDebt > 0 && (
                <p className="text-[11px] text-amber-700 mt-1">
                  Tienes un pago pendiente por ${pendingDriverPay.toFixed(2)}. No puedes pagar más hasta que el administrador lo revise.
                </p>
              )}
            </div>
            {!isCash && (
              <div>
                <label className="label">Referencia (opcional)</label>
                <input
                  type="text"
                  className="input"
                  placeholder="Número de referencia"
                  value={payReference}
                  onChange={(e) => setPayReference(e.target.value)}
                />
              </div>
            )}
            {proofRequired && (
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
                {!payProof && (
                  <p className="text-[11px] text-surface-400 mt-1">Sube el comprobante para continuar.</p>
                )}
              </div>
            )}
            {!proofRequired && !isCash && (
              <p className="text-[11px] text-surface-400">Este método no requiere comprobante.</p>
            )}
            <button onClick={handlePayToPlatform} className="btn-primary w-full" disabled={saving || !canSubmit}>
              {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : isCash ? 'Registrar pago en efectivo' : 'Enviar pago para aprobación'}
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