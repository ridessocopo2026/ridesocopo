import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { Wallet, Upload, Loader2, ArrowDownCircle, ArrowUpCircle, Hexagon } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { EmptyState } from '@/components/ui/EmptyState'
import { SkeletonList } from '@/components/ui/Skeleton'
import { HexUnderline } from '@/components/ui/HexUnderline'
import type { Wallet as WalletType, Transaction } from '@/types/database'

export function ClientWallet() {
  const [wallet, setWallet] = useState<WalletType | null>(null)
  const [transactions, setTransactions] = useState<Transaction[]>([])
  const [showRecharge, setShowRecharge] = useState(false)
  const [amount, setAmount] = useState('')
  const [reference, setReference] = useState('')
  const [proofFile, setProofFile] = useState<File | null>(null)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)
  const { user } = useAuth()
  const navigate = useNavigate()

  useEffect(() => {
    loadWallet()
    loadTransactions()
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
  }

  const loadTransactions = async () => {
    if (!user) return
    const { data, error } = await supabase
      .from('transactions')
      .select('*')
      .eq('user_id', user.id)
      .order('created_at', { ascending: false })
      .limit(20)

    if (!error && data) {
      setTransactions(data as Transaction[])
    }
  }

  const handleRecharge = async (e: React.FormEvent) => {
    e.preventDefault()
    setError('')

    if (!amount || parseFloat(amount) <= 0) {
      setError('Ingresa un monto válido')
      return
    }

    if (!proofFile) {
      setError('Sube el comprobante de pago')
      return
    }

    setLoading(true)

    try {
      if (!user) throw new Error('Debes iniciar sesión')

      // Subir comprobante
      const timestamp = Date.now()
      const { data: uploadData, error: uploadError } = await supabase.storage
        .from('payments')
        .upload(`${user.id}/proof-${timestamp}.jpg`, proofFile, { upsert: true })

      if (uploadError) throw uploadError

      // El bucket es privado; guardamos la ruta y se resuelve con URL firmada al visualizar
      const publicUrl = uploadData.path

      // Solicitar recarga
      const { data, error: rpcError } = await supabase.rpc('request_wallet_recharge', {
        p_amount_usd: parseFloat(amount),
        p_proof_url: publicUrl,
        p_reference: reference || null
      })

      if (rpcError) throw rpcError

      setShowRecharge(false)
      setAmount('')
      setReference('')
      setProofFile(null)
      loadTransactions()
    } catch (err: any) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  const statusBadge = {
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
            <Hexagon className="w-5 h-5 text-white" />
          </div>
          <div>
            <h1 className="text-lg font-bold text-surface-800">Mi Billetera</h1>
            <p className="text-xs text-surface-500">Saldo y transacciones</p>
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6 space-y-6">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        {/* Saldo */}
        <div className="card bg-gradient-to-br from-primary-600 to-primary-800 text-white border-0">
          <div className="flex items-center gap-2 mb-4">
            <Wallet className="w-5 h-5" />
            <span className="text-sm font-medium">Saldo disponible</span>
          </div>
          <p className="text-4xl font-bold">${wallet?.balance_usd?.toFixed(2) || '0.00'}</p>
          <button
            onClick={() => setShowRecharge(!showRecharge)}
            className="mt-4 bg-white/20 hover:bg-white/30 rounded-xl px-4 py-2 text-sm font-medium transition-colors"
          >
            Recargar saldo
          </button>
        </div>

        {/* Formulario de recarga */}
        {showRecharge && (
          <form onSubmit={handleRecharge} className="card space-y-4 animate-fade-in">
            <h2 className="font-semibold text-surface-800">Recargar saldo</h2>
            <p className="text-sm text-surface-500">
              Realiza un Pago Móvil o Zelle y sube el comprobante. Un administrador lo aprobará.
            </p>

            <div>
              <label className="label">Monto en USD ($)</label>
              <input
                type="number"
                className="input"
                placeholder="10.00"
                step="0.01"
                min="1"
                value={amount}
                onChange={(e) => setAmount(e.target.value)}
                required
              />
            </div>

            <div>
              <label className="label">Referencia (opcional)</label>
              <input
                type="text"
                className="input"
                placeholder="Número de referencia"
                value={reference}
                onChange={(e) => setReference(e.target.value)}
              />
            </div>

            <div>
              <label className="label">Comprobante de pago *</label>
              <label className="flex flex-col items-center justify-center w-full h-32 border-2 border-dashed border-surface-200 rounded-xl cursor-pointer hover:border-primary-400 transition-colors">
                {proofFile ? (
                  <div className="text-center">
                    <Upload className="w-8 h-8 text-primary-600 mx-auto mb-1" />
                    <span className="text-xs text-surface-600">{proofFile.name}</span>
                  </div>
                ) : (
                  <div className="text-center">
                    <Upload className="w-8 h-8 text-surface-400 mx-auto mb-1" />
                    <span className="text-xs text-surface-500">Toca para subir comprobante</span>
                  </div>
                )}
                <input
                  type="file"
                  accept="image/*"
                  className="hidden"
                  onChange={(e) => setProofFile(e.target.files?.[0] || null)}
                  required
                />
              </label>
            </div>

            <button type="submit" className="btn-primary w-full" disabled={loading}>
              {loading ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Enviar solicitud de recarga'}
            </button>
          </form>
        )}

        {/* Transacciones */}
        <div>
          <h2 className="text-lg font-semibold text-surface-800 mb-3">Historial de transacciones</h2>
          <HexUnderline />

          {loading ? (
            <SkeletonList count={3} />
          ) : transactions.length === 0 ? (
            <EmptyState
              icon={<Wallet className="w-8 h-8" />}
              title="Sin transacciones"
              description="Tus recargas y movimientos aparecerán aquí"
            />
          ) : (
            <div className="space-y-2">
              {transactions.map((txn) => (
                <div key={txn.id} className="card flex items-center justify-between">
                  <div className="flex items-center gap-3">
                    <div className={`w-10 h-10 rounded-full flex items-center justify-center ${
                      txn.type === 'recarga' ? 'bg-emerald-50 text-emerald-600' : 'bg-primary-50 text-primary-600'
                    }`}>
                      {txn.type === 'recarga' ? (
                        <ArrowDownCircle className="w-5 h-5" />
                      ) : (
                        <ArrowUpCircle className="w-5 h-5" />
                      )}
                    </div>
                    <div>
                      <p className="text-sm font-medium text-surface-700">{txn.description}</p>
                      <p className="text-xs text-surface-400">
                        {new Date(txn.created_at).toLocaleDateString('es-VE', {
                          day: 'numeric',
                          month: 'short',
                          hour: '2-digit',
                          minute: '2-digit'
                        })}
                      </p>
                    </div>
                  </div>
                  <div className="text-right">
                    <p className={`font-semibold ${
                      txn.type === 'recarga' ? 'text-emerald-600' : 'text-red-500'
                    }`}>
                      {txn.type === 'recarga' ? '+' : '-'}${txn.amount_usd.toFixed(2)}
                    </p>
                    {statusBadge[txn.status]}
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