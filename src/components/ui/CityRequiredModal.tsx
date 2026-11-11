import { useEffect, useState } from 'react'
import { MapPin, Loader2, AlertTriangle } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { getActiveCities, clearActiveCitiesCache } from '@/lib/cities'
import { useAuth } from '@/contexts/AuthContext'

/**
 * Bloquea la app hasta que el usuario elija su ciudad.
 * Se muestra cuando el perfil no tiene zone_id (cuentas creadas antes de que
 * la ciudad fuese obligatoria). Sin ciudad no recibe difusiones ni entra en
 * las tarifas de la ciudad.
 */
export function CityRequiredModal() {
  const { user, refreshProfile } = useAuth()
  const [cities, setCities] = useState<{ id: string; name: string }[]>([])
  const [selected, setSelected] = useState('')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    let cancelled = false
    getActiveCities().then(({ data }) => {
      if (cancelled || !data) return
      const list = data as { id: string; name: string }[]
      setCities(list)
      // Si solo hay una ciudad, se preselecciona (menos fricción)
      if (list.length === 1) setSelected(list[0].id)
    })
    return () => { cancelled = true }
  }, [])

  if (!user || user.zone_id) return null

  const handleSave = async () => {
    if (!selected) {
      setError('Selecciona tu ciudad')
      return
    }
    setSaving(true)
    setError('')
    try {
      const { error: rpcError } = await supabase.rpc('set_my_city', { p_zone_id: selected })
      if (rpcError) throw rpcError
      clearActiveCitiesCache()
      await refreshProfile()
    } catch (err: any) {
      setError(err?.message || 'No se pudo guardar tu ciudad')
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="fixed inset-0 z-[3000] bg-black/60 flex items-center justify-center p-4">
      <div className="w-full max-w-sm rounded-2xl bg-white p-5 shadow-elevated space-y-4">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 rounded-xl bg-primary-600 flex items-center justify-center">
            <MapPin className="w-5 h-5 text-white" />
          </div>
          <div>
            <h2 className="font-bold text-surface-800">¿En qué ciudad estás?</h2>
            <p className="text-xs text-surface-500">La necesitamos para tus tarifas y avisos.</p>
          </div>
        </div>

        <div className="space-y-2">
          {cities.map((c) => (
            <button
              key={c.id}
              type="button"
              onClick={() => setSelected(c.id)}
              className={
                'w-full rounded-xl border-2 px-3 py-3 text-left text-sm font-medium transition-all ' +
                (selected === c.id
                  ? 'border-primary-600 bg-primary-50 text-primary-700'
                  : 'border-surface-200 text-surface-600')
              }
            >
              {c.name}
            </button>
          ))}
          {cities.length === 0 && (
            <p className="text-xs text-surface-400">Cargando ciudades...</p>
          )}
        </div>

        {error && (
          <p className="flex items-start gap-2 rounded-xl border border-red-200 bg-red-50 p-2 text-xs text-red-700">
            <AlertTriangle className="w-4 h-4 flex-shrink-0" /> {error}
          </p>
        )}

        <button
          type="button"
          onClick={handleSave}
          disabled={saving || !selected}
          className="btn-primary w-full"
        >
          {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Guardar ciudad'}
        </button>
      </div>
    </div>
  )
}
