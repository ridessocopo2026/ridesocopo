import { useState, useEffect } from 'react'
import { Wallet, Loader2, ArrowDownCircle, ArrowUpCircle, Upload, Check, ArrowUpRight, ArrowDownRight } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { EmptyState } from '@/components/ui/EmptyState'
import { SkeletonList } from '@/components/ui/Skeleton'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import type { Wallet as WalletType, Transaction, Payout } from '@/types/database'

export function DriverWallet() {
  const [wallet, setWallet] = useState<WalletType | null>(null)
  const [transactions, setTransactions] = useState<Transaction[]>([])
  const [payouts, setPayouts] = useState<Payout[]>([])
  const [loading, setLoading] = useState(true)
  const [showPayForm, setShowPayForm] = useState(false)
  const [payAmount, setPayAmount] = useState('')
  const [payProof, setPayProof] = useState<File | null>(null)
  const [error, setError] = useState('')
  const [saving, setSaving] = useState(false)
  const { user } = useAuth()

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

      // Subir comprobante a payments
      const { data: uploadData, error: uploadError } = await supabase.storage
        .from('payments')
        .upload(`${user.id}/payments/${Date.now()}-${payProof.name}`, payProof, { upsert: true })
      if (uploadError) throw uploadError

      const { data: { publicUrl } } = supabase.storage
        .from('payments')
        .getPublicUrl(uploadData.path)

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
      const { error } = await supabase.rpc('driver_confirm_payout', {
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

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 bg-primary-600 rounded-xl flex items-center justify-center">
            <Wallet className="w-5 h-5 text-white" />
          </div>
          <div>
            <h1 className="text-lg font-bold text-surface-800">Mi Billetera</h1>
            <p className="text-xs text-surface-500">Saldo, ganancias y liquidaciones</p>
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6 space-y-6">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        <div className={`card ${wallet && wallet.balance_usd < 0 ? 'bg-gradient-to-br from-red-600 to-red-800' : 'bg-gradient-to-br from-primary-600 to-primary-800'} text-white border-0`}>
          <div className="flex items-center gap-2 mb-2">
            <Wallet className="w-5 h-5" />
            <span className="text-sm font-medium">{wallet && wallet.balance_usd < 0 ? 'Deuda con la plataforma' : 'Saldo pendiente por cobrar'}</span>
          </div>
          <p className="text-3xl font-bold">${wallet?.balance_usd?.toFixed(2) || '0.00'}</p>
          <p className="text-sm text-white/70 mt-1">
            {wallet && wallet.balance_usd < 0
              ? `Debes ${Math.abs(wallet.balance_usd).toFixed(2)}$ • Límite: ${wallet.debt_limit_usd.toFixed(2)}$`
              : 'Lo que la plataforma te debe o has pagado'
            }
          </p>
          {wallet && wallet.balance_usd < 0 && (
            <button
              onClick={() => setShowPayForm(!showPayForm)}
              className="mt-3 bg-white/20 hover:bg-white/30 rounded-xl px-4 py-2 text-sm font-medium transition-colors"
            >
              Pagar a la plataforma
            </button>
          )}
        </div>

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
                    {p.status === 'pendiente' && p.type === 'platform_pay_driver' && (
                      <button
                        onClick={() => handleConfirmPayout(p.id)}
                        className="btn-success mt-1 text-xs px-2 py-1"
                        disabled={saving}
                      >
                        Confirmar
                      </button>
                    )}
                  </div>
                </div>
              ))}
            </div>
          </div>
        )}

        <div>
          <h2 className="text-lg font-semibold text-surface-800 mb-3">Movimientos</h2>
          {loading ? (
            <SkeletonList count={3} />
          ) : transactions.length === 0 ? (
            <EmptyState
              icon={<Wallet className="w-8 h-8" />}
              title="Sin movimientos"
              description="Tus comisiones, ajustes y ganancias aparecerán aquí"
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