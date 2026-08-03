import { useState, useEffect } from 'react'
import { DollarSign, Loader2, Hexagon, Save } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { HexUnderline } from '@/components/ui/HexUnderline'

export function AdminExchangeRate() {
  const [currentRate, setCurrentRate] = useState<number | null>(null)
  const [newRate, setNewRate] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const { user } = useAuth()

  useEffect(() => {
    loadRate()
  }, [])

  const loadRate = async () => {
    const { data, error } = await supabase.rpc('get_active_exchange_rate')
    if (!error && data) {
      setCurrentRate(data)
      setNewRate(data.toString())
    }
    setLoading(false)
  }

  const handleSave = async () => {
    setError('')
    setSaving(true)

    try {
      const { data, error } = await supabase.rpc('update_exchange_rate', {
        p_rate: parseFloat(newRate)
      })

      if (error) throw error

      setCurrentRate(parseFloat(newRate))
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
          <div className="w-10 h-10 bg-primary-600 rounded-xl flex items-center justify-center">
            <Hexagon className="w-5 h-5 text-white" />
          </div>
          <div>
            <h1 className="text-lg font-bold text-surface-800">Tasa de Cambio</h1>
            <p className="text-xs text-surface-500">Configura la tasa Bs./USD</p>
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}
        <HexUnderline />

        <div className="card space-y-4">
          <div className="flex items-center gap-3">
            <div className="w-12 h-12 bg-primary-50 rounded-xl flex items-center justify-center text-primary-600">
              <DollarSign className="w-6 h-6" />
            </div>
            <div>
              <p className="text-sm text-surface-500">Tasa actual</p>
              <p className="text-2xl font-bold text-surface-800">
                {currentRate ? `Bs. ${currentRate.toFixed(2)}` : 'Cargando...'}
              </p>
            </div>
          </div>

          <div>
            <label className="label">Nueva tasa (Bs. por $1)</label>
            <input
              type="number"
              className="input"
              step="0.01"
              min="0"
              value={newRate}
              onChange={(e) => setNewRate(e.target.value)}
            />
          </div>

          <button onClick={handleSave} className="btn-primary w-full" disabled={saving}>
            {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : <><Save className="w-4 h-4" /> Guardar tasa</>}
          </button>
        </div>
      </div>
    </div>
  )
}