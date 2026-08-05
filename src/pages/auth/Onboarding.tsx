import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { User, Car, MapPin, Loader2, Hexagon } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { HexUnderline } from '@/components/ui/HexUnderline'
import type { Zone } from '@/types/database'

export function Onboarding() {
  const [role, setRole] = useState<'cliente' | 'conductor'>('cliente')
  const [zones, setZones] = useState<Zone[]>([])
  const [selectedZone, setSelectedZone] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)
  const { user, refreshProfile } = useAuth()
  const navigate = useNavigate()

  useEffect(() => {
    loadZones()
  }, [])

  const loadZones = async () => {
    const { data, error } = await supabase
      .from('zones')
      .select('*')
      .eq('is_active', true)
      .order('name')

    if (!error && data) {
      setZones(data as Zone[])
    }
  }

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setError('')
    setLoading(true)

    if (!user) {
      setError('Debes iniciar sesión primero')
      setLoading(false)
      return
    }

    const { error: updateError } = await supabase
      .from('profiles')
      .update({
        role,
        zone_id: selectedZone || null,
        onboarding_completed: true
      })
      .eq('id', user.id)

    if (updateError) {
      setError(updateError.message)
      setLoading(false)
      return
    }

    await refreshProfile()

    if (role === 'conductor') {
      navigate('/conductor/onboarding')
    } else {
      navigate('/cliente')
    }
  }

  return (
    <div className="min-h-screen bg-white flex flex-col items-center justify-center px-6 py-12">
      <div className="w-full max-w-md">
        <div className="flex flex-col items-center mb-8">
          <div className="w-16 h-16 bg-primary-600 rounded-2xl flex items-center justify-center mb-4 shadow-elevated">
            <Hexagon className="w-8 h-8 text-white" />
          </div>
          <h1 className="text-2xl font-bold text-surface-800">Bienvenido a RideSocopó</h1>
          <p className="text-sm text-surface-500 mt-1">¿Cómo deseas usar la app?</p>
          <HexUnderline />
        </div>

        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        <form onSubmit={handleSubmit} className="space-y-6">
          {/* Selección de rol */}
          <div className="grid grid-cols-2 gap-4">
            <button
              type="button"
              onClick={() => setRole('cliente')}
              className={`p-4 rounded-2xl border-2 transition-all duration-200 ${
                role === 'cliente'
                  ? 'border-primary-600 bg-primary-50 shadow-soft'
                  : 'border-surface-200 hover:border-surface-300'
              }`}
            >
              <User className={`w-8 h-8 mx-auto mb-2 ${role === 'cliente' ? 'text-primary-600' : 'text-surface-400'}`} />
              <span className={`block font-medium ${role === 'cliente' ? 'text-primary-700' : 'text-surface-600'}`}>
                Pasajero
              </span>
              <span className="text-xs text-surface-400">Solicitar viajes</span>
            </button>

            <button
              type="button"
              onClick={() => setRole('conductor')}
              className={`p-4 rounded-2xl border-2 transition-all duration-200 ${
                role === 'conductor'
                  ? 'border-primary-600 bg-primary-50 shadow-soft'
                  : 'border-surface-200 hover:border-surface-300'
              }`}
            >
              <Car className={`w-8 h-8 mx-auto mb-2 ${role === 'conductor' ? 'text-primary-600' : 'text-surface-400'}`} />
              <span className={`block font-medium ${role === 'conductor' ? 'text-primary-700' : 'text-surface-600'}`}>
                Conductor
              </span>
              <span className="text-xs text-surface-400">Ofrecer viajes</span>
            </button>
          </div>

          {/* Selección de zona */}
          <div>
            <label className="label">Zona predeterminada</label>
            <div className="relative">
              <MapPin className="absolute left-3 top-1/2 -translate-y-1/2 w-5 h-5 text-surface-400" />
              <select
                className="input pl-10 appearance-none"
                value={selectedZone}
                onChange={(e) => setSelectedZone(e.target.value)}
              >
                <option value="">Selecciona tu zona</option>
                {zones.map((zone) => (
                  <option key={zone.id} value={zone.id}>
                    {zone.name}
                    {zone.zone_type === 'cobertura_general' ? ' (Toda Socopó)' : ''}
                  </option>
                ))}
              </select>
            </div>
          </div>

          <button type="submit" className="btn-primary w-full" disabled={loading}>
            {loading ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Continuar'}
          </button>
        </form>
      </div>
    </div>
  )
}