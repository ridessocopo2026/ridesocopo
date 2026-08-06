import { useState, useEffect } from 'react'
import { Car, Loader2, Save } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { HexUnderline } from '@/components/ui/HexUnderline'
import type { VehicleCategory } from '@/types/database'
import { AppLogo } from '@/components/ui/AppLogo'

export function AdminFares() {
  const [categories, setCategories] = useState<VehicleCategory[]>([])
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const { user } = useAuth()

  useEffect(() => {
    loadCategories()
  }, [])

  const loadCategories = async () => {
    const { data, error } = await supabase
      .from('vehicle_categories')
      .select('*')
      .order('base_fare_usd')

    if (!error && data) {
      setCategories(data as VehicleCategory[])
    }
    setLoading(false)
  }

  const handleUpdateFare = async (id: string, baseFare: number) => {
    setError('')
    setSaving(true)

    const { error } = await supabase
      .from('vehicle_categories')
      .update({ base_fare_usd: baseFare })
      .eq('id', id)

    if (error) {
      setError(error.message)
    }
    setSaving(false)
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center gap-3">
          <AppLogo />
          <div>
            <h1 className="text-lg font-bold text-surface-800">Tarifas por Vehículo</h1>
            <p className="text-xs text-surface-500">Configura las tarifas base</p>
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}
        <HexUnderline />

        <div className="space-y-4">
          {categories.map((cat) => (
            <div key={cat.id} className="card">
              <div className="flex items-center gap-3 mb-4">
                <div className="w-12 h-12 bg-primary-50 rounded-xl flex items-center justify-center text-primary-600">
                  <Car className="w-6 h-6" />
                </div>
                <div className="flex-1">
                  <h3 className="font-semibold text-surface-700">{cat.display_name}</h3>
                  <p className="text-xs text-surface-400">
                    Hasta {cat.max_passengers} pasajeros • {cat.description}
                  </p>
                </div>
              </div>

              <div className="flex items-center gap-3">
                <div className="flex-1">
                  <label className="label">Tarifa base (USD)</label>
                  <input
                    type="number"
                    className="input"
                    step="0.50"
                    min="0"
                    defaultValue={cat.base_fare_usd}
                    onBlur={(e) => {
                      const value = parseFloat(e.target.value)
                      if (value !== cat.base_fare_usd) {
                        handleUpdateFare(cat.id, value)
                      }
                    }}
                  />
                </div>
                <button
                  onClick={() => {
                    const input = document.querySelector(`input[data-cat="${cat.id}"]`) as HTMLInputElement
                    if (input) handleUpdateFare(cat.id, parseFloat(input.value))
                  }}
                  className="btn-primary mt-6"
                  disabled={saving}
                >
                  {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : <Save className="w-4 h-4" />}
                </button>
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}