import { useCallback, useEffect, useState } from 'react'
import { MapPin, Loader2, X, CheckCircle, AlertTriangle } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { getCurrentPositionOnce, type GeoFix } from '@/lib/geolocation'
import type { Ride } from '@/types/database'

interface ExactLocationModalProps {
  ride: Ride
  onClose: () => void
  onSaved: (rideId: string) => void
}

/** Después de esta cantidad de horas se avisa que el punto puede no ser exacto */
const AVISO_HORAS = 2

export function ExactLocationModal({ ride, onClose, onSaved }: ExactLocationModalProps) {
  const [fix, setFix] = useState<GeoFix | null>(null)
  const [getting, setGetting] = useState(false)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const [saveAsFavorite, setSaveAsFavorite] = useState(false)
  const [name, setName] = useState(ride.destination_barrio_name || 'Mi destino')

  // Horas desde que terminó el viaje (para el aviso)
  const referencia = ride.completed_at || ride.created_at
  const horasDesde = referencia
    ? (Date.now() - new Date(referencia).getTime()) / 3600000
    : 0

  const obtenerUbicacion = useCallback(async () => {
    setError('')
    setGetting(true)
    try {
      setFix(await getCurrentPositionOnce())
    } catch (err: any) {
      setFix(null)
      setError(err?.message || 'No pudimos obtener tu ubicación')
    } finally {
      setGetting(false)
    }
  }, [])

  // Se intenta leer el GPS al abrir: el punto debe ser el de AHORA
  useEffect(() => {
    obtenerUbicacion()
  }, [obtenerUbicacion])

  const handleSave = async () => {
    if (!fix) return
    if (saveAsFavorite && !name.trim()) {
      setError('Escribe un nombre para el lugar')
      return
    }

    setSaving(true)
    setError('')

    try {
      const params = saveAsFavorite
        ? supabase.rpc('save_ride_place', {
            p_ride_id: ride.id,
            p_name: name.trim(),
            p_lat: fix.lat,
            p_lng: fix.lng,
            p_accuracy_m: fix.accuracy
          })
        : supabase.rpc('set_ride_exact_destination', {
            p_ride_id: ride.id,
            p_lat: fix.lat,
            p_lng: fix.lng
          })

      const { error: rpcError } = await params
      if (rpcError) throw rpcError

      onSaved(ride.id)
      onClose()
    } catch (err: any) {
      setError(err?.message || 'No se pudo guardar la ubicación')
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="fixed inset-0 z-[3000] flex items-end justify-center bg-black/60 p-0 sm:items-center sm:p-4">
      <div className="w-full max-w-md rounded-t-2xl bg-white p-5 shadow-elevated space-y-4 sm:rounded-2xl">
        <div className="flex items-start justify-between gap-3">
          <div className="flex items-center gap-3">
            <div className="flex h-10 w-10 items-center justify-center rounded-xl bg-primary-600">
              <MapPin className="h-5 w-5 text-white" />
            </div>
            <div>
              <h2 className="font-bold text-surface-800">Fijar destino exacto</h2>
              <p className="text-xs text-surface-500">
                {ride.destination_barrio_name || ride.destination_address || 'Este viaje'}
              </p>
            </div>
          </div>
          <button
            type="button"
            onClick={onClose}
            className="rounded-full p-2 text-surface-400 hover:bg-surface-50 hover:text-surface-600"
            aria-label="Cerrar"
          >
            <X className="h-5 w-5" />
          </button>
        </div>

        <div className="rounded-xl border border-primary-100 bg-primary-50 p-3 text-xs text-primary-800">
          Se guardará <strong>tu ubicación actual</strong> como el punto donde te bajaste en este viaje.
          Hazlo ahora, mientras sigues en el lugar: si te vas, el punto no será exacto.
        </div>

        {horasDesde >= AVISO_HORAS && (
          <p className="flex items-start gap-2 rounded-xl border border-amber-200 bg-amber-50 p-2 text-[11px] text-amber-800">
            <AlertTriangle className="h-4 w-4 flex-shrink-0" />
            Han pasado {horasDesde < 24
              ? `${Math.round(horasDesde)} horas`
              : `${Math.round(horasDesde / 24)} días`} desde el viaje. Si ya no estás en el lugar,
            este punto no será el correcto.
          </p>
        )}

        {/* Ubicación actual */}
        <div className="space-y-2">
          {getting && (
            <p className="flex items-center gap-2 text-xs text-surface-500">
              <Loader2 className="h-4 w-4 animate-spin" /> Obteniendo tu ubicación…
            </p>
          )}

          {!getting && fix && (
            <p className="flex items-center gap-2 text-xs text-emerald-700">
              <CheckCircle className="h-4 w-4" /> Ubicación lista{fix.accuracy > 0 ? ` · precisión ±${fix.accuracy} m` : ''}
            </p>
          )}

          {!getting && !fix && (
            <button type="button" onClick={obtenerUbicacion} className="btn-outline w-full text-xs py-2">
              <MapPin className="h-4 w-4" /> Reintentar ubicación
            </button>
          )}

          {error && (
            <p className="rounded-xl border border-red-200 bg-red-50 p-2 text-[11px] text-red-700">{error}</p>
          )}
        </div>

        {/* También guardar como lugar favorito */}
        <div className="space-y-2 rounded-xl border border-surface-200 p-3">
          <label className="flex items-center gap-2 text-sm text-surface-700">
            <input
              type="checkbox"
              className="h-4 w-4"
              checked={saveAsFavorite}
              onChange={(e) => setSaveAsFavorite(e.target.checked)}
            />
            Guardar también como lugar favorito
          </label>
          {saveAsFavorite && (
            <input
              type="text"
              className="input"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Nombre del lugar (Casa, Trabajo…)"
              maxLength={40}
            />
          )}
        </div>

        <div className="flex gap-2">
          <button type="button" onClick={onClose} className="btn-outline flex-1" disabled={saving}>
            Cancelar
          </button>
          <button
            type="button"
            onClick={handleSave}
            className="btn-primary flex-1"
            disabled={saving || getting || !fix}
          >
            {saving ? <Loader2 className="h-4 w-4 animate-spin" /> : <CheckCircle className="h-4 w-4" />}
            Usar esta ubicación
          </button>
        </div>
      </div>
    </div>
  )
}
