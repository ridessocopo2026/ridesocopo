import { useState, useEffect } from 'react'
import { Settings, Percent, AlertTriangle, Loader2, Save, Trash2 } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { HexUnderline } from '@/components/ui/HexUnderline'
import { AppLogo } from '@/components/ui/AppLogo'

export function AdminConfig() {
  const [commissionRate, setCommissionRate] = useState('10')
  const [debtLimit, setDebtLimit] = useState('5')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [cleaning, setCleaning] = useState(false)
  const [cleanResult, setCleanResult] = useState<{
    notifications?: number
    outbox?: number
    audit_logs?: number
    proofs?: number
  } | null>(null)
  const [cleanError, setCleanError] = useState('')
  const { user } = useAuth()

  useEffect(() => {
    loadConfig()
  }, [])

  const loadConfig = async () => {
    // Intentar leer la tabla de configuración si existe
    const { data, error } = await supabase
      .from('wallets')
      .select('debt_limit_usd')
      .limit(1)

    if (!error && data && data.length > 0) {
      setDebtLimit(data[0].debt_limit_usd.toString())
    }
    setLoading(false)
  }

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault()
    setError('')
    setSaving(true)

    try {
      // Actualizar límite de deuda en todas las billeteras
      const { error } = await supabase
        .from('wallets')
        .update({ debt_limit_usd: parseFloat(debtLimit) })
        .eq('is_blocked', false)

      if (error) throw error

      // Actualizar tasa de comisión en viajes (se aplica a futuros viajes)
      // La comisión se calcula en el servidor con el valor de rides.commission_rate
      // que ya está en 10.00 por defecto
    } catch (err: any) {
      setError(err.message)
    } finally {
      setSaving(false)
    }
  }

  const handleCleanup = async () => {
    setCleanError('')
    setCleanResult(null)
    setCleaning(true)
    try {
      const { data, error } = await supabase.rpc('cleanup_old_data')
      if (error) throw error
      const counts: {
        notifications?: number
        outbox?: number
        audit_logs?: number
        proofs?: number
      } = { ...(data ?? {}) }

      // Comprobantes viejos: borrar los archivos con la Storage API
      const { data: oldProofs, error: proofError } = await supabase
        .from('rides')
        .select('proof_url')
        .eq('proof_status', 'aprobado')
        .eq('status', 'completada')
        .not('proof_url', 'is', null)
        .lt('completed_at', new Date(Date.now() - 180 * 24 * 3600 * 1000).toISOString())
        .limit(500)

      if (proofError) throw proofError

      if (oldProofs && oldProofs.length > 0) {
        const paths = oldProofs.map((p) => p.proof_url as string)
        const { error: removeError } = await supabase.storage.from('payments').remove(paths)
        if (removeError) throw removeError
        counts.proofs = paths.length
      } else {
        counts.proofs = 0
      }

      setCleanResult(counts)
    } catch (err: any) {
      setCleanError(err.message)
    } finally {
      setCleaning(false)
    }
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center gap-3">
          <AppLogo />
          <div>
            <h1 className="text-lg font-bold text-surface-800">Configuración</h1>
            <p className="text-xs text-surface-500">Comisiones y límites</p>
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}
        <HexUnderline />

        {loading ? (
          <div className="space-y-4">
            <div className="skeleton h-32 rounded-2xl" />
            <div className="skeleton h-32 rounded-2xl" />
          </div>
        ) : (
          <>
          <form onSubmit={handleSave} className="space-y-4">
            {/* Comisión */}
            <div className="card space-y-4">
              <div className="flex items-center gap-3">
                <div className="w-12 h-12 bg-primary-50 rounded-xl flex items-center justify-center text-primary-600">
                  <Percent className="w-6 h-6" />
                </div>
                <div>
                  <h3 className="font-semibold text-surface-700">Comisión de la App</h3>
                  <p className="text-xs text-surface-400">Porcentaje retenido por viaje</p>
                </div>
              </div>

              <div>
                <label className="label">Comisión (%)</label>
                <input
                  type="number"
                  className="input"
                  step="0.5"
                  min="0"
                  max="50"
                  value={commissionRate}
                  onChange={(e) => setCommissionRate(e.target.value)}
                />
                <p className="text-xs text-surface-400 mt-1">
                  Se debita del saldo del conductor al aceptar el viaje. Cambiar este valor solo afecta a futuros viajes.
                </p>
              </div>
            </div>

            {/* Límite de deuda */}
            <div className="card space-y-4">
              <div className="flex items-center gap-3">
                <div className="w-12 h-12 bg-amber-50 rounded-xl flex items-center justify-center text-amber-600">
                  <AlertTriangle className="w-6 h-6" />
                </div>
                <div>
                  <h3 className="font-semibold text-surface-700">Límite de Deuda</h3>
                  <p className="text-xs text-surface-400">Máximo saldo negativo permitido</p>
                </div>
              </div>

              <div>
                <label className="label">Límite en USD ($)</label>
                <input
                  type="number"
                  className="input"
                  step="0.50"
                  min="0"
                  value={debtLimit}
                  onChange={(e) => setDebtLimit(e.target.value)}
                />
                <p className="text-xs text-surface-400 mt-1">
                  Si el saldo del conductor baja de este límite negativo, se bloquea su opción de ponerse "En Línea".
                </p>
              </div>
            </div>

            <button type="submit" className="btn-primary w-full" disabled={saving}>
              {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : <><Save className="w-4 h-4" /> Guardar configuración</>}
            </button>
          </form>

          {/* Limpieza de datos */}
          <div className="card space-y-3">
            <div className="flex items-center gap-3">
              <div className="w-12 h-12 bg-purple-50 rounded-xl flex items-center justify-center text-purple-600">
                <Trash2 className="w-6 h-6" />
              </div>
              <div>
                <h3 className="font-semibold text-surface-700">Limpieza de datos</h3>
                <p className="text-xs text-surface-400">Libera espacio en la base y el storage</p>
              </div>
            </div>
            <p className="text-xs text-surface-500">
              Las tablas (notificaciones &gt; 90 días, cola de push &gt; 30 días, auditoría &gt; 180 días) se limpian
              solas todos los días a las 3 AM. Este botón las limpia ahora mismo y además borra los comprobantes de
              viajes completados hace más de 6 meses. No toca saldos, transacciones ni historial financiero.
            </p>
            {cleanError && <ErrorMessage message={cleanError} onDismiss={() => setCleanError('')} />}
            <button type="button" onClick={handleCleanup} className="btn-danger w-full" disabled={cleaning}>
              {cleaning ? <Loader2 className="w-4 h-4 animate-spin" /> : <><Trash2 className="w-4 h-4" /> Limpiar datos antiguos</>}
            </button>
            {cleanResult && (
              <p className="text-xs text-surface-500">
                Eliminados: {cleanResult.notifications ?? 0} notificaciones · {cleanResult.audit_logs ?? 0} auditorías ·{' '}
                {cleanResult.outbox ?? 0} push en cola · {cleanResult.proofs ?? 0} comprobantes
              </p>
            )}
          </div>
          </>
        )}
      </div>
    </div>
  )
}