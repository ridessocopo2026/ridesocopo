import { useState, useEffect } from 'react'
import { ArrowUpCircle, ArrowDownCircle, Check, X, Loader2, Wallet, ExternalLink } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { EmptyState } from '@/components/ui/EmptyState'
import { SkeletonList } from '@/components/ui/Skeleton'
import type { Payout } from '@/types/database'

export function AdminPayouts() {
  const [payouts, setPayouts] = useState<Payout[]>([])
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [actionLoading, setActionLoading] = useState<string | null>(null)
  const { user } = useAuth()

  useEffect(() => {
    loadPayouts()
  }, [])

  const loadPayouts = async () => {
    const { data, error } = await supabase.rpc('get_payouts')
    if (!error && data) {
      setPayouts(data as Payout[])
    }
    setLoading(false)
  }

  const handleApprove = async (payoutId: string, approve: boolean) => {
    setError('')
    setActionLoading(payoutId)
    try {
      const { error } = await supabase.rpc('approve_payout', {
        p_payout_id: payoutId,
        p_approve: approve
      })
      if (error) throw error
      loadPayouts()
    } catch (err: any) {
      setError(err.message)
    } finally {
      setActionLoading(null)
    }
  }

  const statusBadge: Record<string, React.ReactNode> = {
    pendiente: <span className="badge-warning">Pendiente</span>,
    aprobado: <span className="badge-success">Aprobado</span>,
    rechazado: <span className="badge-danger">Rechazado</span>,
    confirmado: <span className="badge-info">Confirmado</span>
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 bg-primary-600 rounded-xl flex items-center justify-center">
            <Wallet className="w-5 h-5 text-white" />
          </div>
          <div>
            <h1 className="text-lg font-bold text-surface-800">Liquidaciones</h1>
            <p className="text-xs text-surface-500">Pagos entre conductores y plataforma</p>
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        {loading ? (
          <SkeletonList count={3} />
        ) : payouts.length === 0 ? (
          <EmptyState
            icon={<Wallet className="w-8 h-8" />}
            title="Sin liquidaciones"
            description="Los pagos entre conductores y plataforma aparecerán aquí"
          />
        ) : (
          <div className="space-y-3">
            {payouts.map((p) => (
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

                <p className="text-2xl font-bold text-surface-800 mb-2">{p.amount_usd.toFixed(2)}$</p>
                {p.description && <p className="text-sm text-surface-500 mb-2">{p.description}</p>}
                <p className="text-xs text-surface-400 mb-3">
                  {new Date(p.created_at).toLocaleString('es-VE')}
                </p>

                {p.proof_url && (
                  <a
                    href={p.proof_url}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="inline-flex items-center gap-1 text-primary-600 text-sm mb-3 hover:underline"
                  >
                    <ExternalLink className="w-4 h-4" />
                    Ver comprobante
                  </a>
                )}

                {p.status === 'pendiente' && p.type === 'driver_pay_platform' && (
                  <div className="flex gap-2">
                    <button
                      onClick={() => handleApprove(p.id, true)}
                      className="btn-success flex-1"
                      disabled={actionLoading === p.id}
                    >
                      {actionLoading === p.id ? <Loader2 className="w-4 h-4 animate-spin" /> : <><Check className="w-4 h-4" /> Aprobar pago</>}
                    </button>
                    <button
                      onClick={() => handleApprove(p.id, false)}
                      className="btn-danger flex-1"
                      disabled={actionLoading === p.id}
                    >
                      <X className="w-4 h-4" />
                      Rechazar
                    </button>
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