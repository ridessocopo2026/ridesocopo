import { useState } from 'react'
import { Users, Loader2, X } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import type { Vehicle } from '@/types/database'

const MOTOS = ['moto', 'moto_basica', 'moto_lujo', 'moto_carga']

/** Boton + modal para cambiar la capacidad de pasajeros de un vehiculo. */
export function VehiclePassengersEditor({ vehicle, onSaved }: { vehicle: Vehicle; onSaved?: () => void }) {
  const [open, setOpen] = useState(false)
  const [value, setValue] = useState(String(vehicle.max_passengers || 1))
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')
  const isMoto = MOTOS.includes(vehicle.category)

  const save = async () => {
    setErr('')
    setBusy(true)
    try {
      const n = isMoto ? 1 : Math.max(1, Number(value) || 1)
      const { error } = await supabase.rpc('set_vehicle_passengers', {
        p_vehicle_id: vehicle.id,
        p_max_passengers: n
      })
      if (error) throw error
      setOpen(false)
      onSaved?.()
    } catch (e: any) {
      setErr(e?.message || 'No se pudo guardar')
    } finally {
      setBusy(false)
    }
  }

  return (
    <>
      <button onClick={() => setOpen(true)} className="p-2 rounded-lg text-primary-500 hover:text-primary-700 hover:bg-primary-50 transition-colors" title="Editar pasajeros" aria-label="Editar pasajeros">
        <Users className="w-4 h-4" />
      </button>
      {open && (
        <div className="fixed inset-0 bg-black/50 z-[15000] flex items-center justify-center p-4" onClick={() => setOpen(false)}>
          <div className="bg-white rounded-2xl p-5 max-w-xs w-full" onClick={(e) => e.stopPropagation()}>
            <div className="flex items-center justify-between mb-3">
              <h3 className="font-bold text-surface-800">Pasajeros</h3>
              <button onClick={() => setOpen(false)} className="p-1 text-surface-400" aria-label="Cerrar">
                <X className="w-4 h-4" />
              </button>
            </div>
            <p className="text-xs text-surface-500 mb-3">{vehicle.brand} {vehicle.model} • {vehicle.plate}</p>
            {err && <p className="text-xs text-red-600 mb-2">{err}</p>}
            <input
              type="number"
              className="input"
              min={1}
              max={isMoto ? 1 : 10}
              value={value}
              disabled={isMoto}
              onChange={(e) => setValue(e.target.value)}
            />
            <p className="text-[11px] text-surface-400 mt-1">
              {isMoto ? 'Las motos son para 1 solo pasajero.' : 'La capacidad se limita según la categoría.'}
            </p>
            <button onClick={save} disabled={busy} className="btn-primary w-full mt-3">
              {busy ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Guardar'}
            </button>
          </div>
        </div>
      )}
    </>
  )
}