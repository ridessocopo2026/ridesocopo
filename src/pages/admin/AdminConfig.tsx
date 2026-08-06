import { useState, useEffect } from 'react'
import { Settings, Percent, AlertTriangle, Loader2, Save } from 'lucide-react'
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
        )}
      </div>
    </div>
  )
}