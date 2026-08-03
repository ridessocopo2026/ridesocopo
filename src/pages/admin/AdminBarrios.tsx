import { useState, useEffect } from 'react'
import { MapContainer, TileLayer, Marker, useMapEvents } from 'react-leaflet'
import L from 'leaflet'
import { MapPin, Plus, Save, Trash2, Loader2, Hexagon, Pencil } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { HexUnderline } from '@/components/ui/HexUnderline'
import type { Barrio } from '@/types/database'

const SOCOPO_CENTER: [number, number] = [8.23293, -70.82228]

const barrioIcon = L.divIcon({
  className: 'custom-div-icon',
  html: `<div class="w-8 h-8 bg-primary-600 rounded-full border-4 border-white shadow-lg flex items-center justify-center">
    <svg class="w-4 h-4 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17.657 16.657L13.414 20.9a1.998 1.998 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z"/>
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 11a3 3 0 11-6 0 3 3 0 016 0z"/>
    </svg>
  </div>`,
  iconSize: [32, 32],
  iconAnchor: [16, 16]
})

function MapClickHandler({ onSelect }: { onSelect: (lat: number, lng: number) => void }) {
  useMapEvents({
    click(e) {
      onSelect(e.latlng.lat, e.latlng.lng)
    }
  })
  return null
}

export function AdminBarrios() {
  const [barrios, setBarrios] = useState<Barrio[]>([])
  const [editing, setEditing] = useState<Barrio | null>(null)
  const [name, setName] = useState('')
  const [surcharge, setSurcharge] = useState('')
  const [description, setDescription] = useState('')
  const [lat, setLat] = useState<number | null>(null)
  const [lng, setLng] = useState<number | null>(null)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const { user } = useAuth()

  useEffect(() => {
    loadBarrios()
  }, [])

  const loadBarrios = async () => {
    const { data, error } = await supabase
      .from('barrios')
      .select('*')
      .order('name')

    if (!error && data) {
      setBarrios(data as Barrio[])
    }
    setLoading(false)
  }

  const resetForm = () => {
    setEditing(null)
    setName('')
    setSurcharge('')
    setDescription('')
    setLat(null)
    setLng(null)
  }

  const handleEdit = (barrio: Barrio) => {
    setEditing(barrio)
    setName(barrio.name)
    setSurcharge(barrio.surcharge_usd.toString())
    setDescription(barrio.description || '')
    setLat(barrio.lat || null)
    setLng(barrio.lng || null)
  }

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault()
    setError('')

    if (!name || !surcharge) {
      setError('Completa el nombre y el precio')
      return
    }

    setSaving(true)

    try {
      const { data, error } = await supabase.rpc('upsert_barrio', {
        p_name: name,
        p_surcharge_usd: parseFloat(surcharge),
        p_lat: lat,
        p_lng: lng,
        p_description: description || null,
        p_barrio_id: editing?.id || null
      })

      if (error) throw error

      resetForm()
      loadBarrios()
    } catch (err: any) {
      setError(err.message)
    } finally {
      setSaving(false)
    }
  }

  const handleDelete = async (id: string) => {
    if (!confirm('¿Seguro que deseas eliminar este barrio?')) return

    const { error } = await supabase.from('barrios').delete().eq('id', id)

    if (!error) {
      loadBarrios()
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
            <h1 className="text-lg font-bold text-surface-800">Barrios de Socopó</h1>
            <p className="text-xs text-surface-500">Configura los barrios y sus precios</p>
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6 space-y-6">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        <div>
          <h2 className="text-lg font-semibold text-surface-800 mb-3">Barrios existentes</h2>
          <HexUnderline />
          <div className="space-y-2">
            {barrios.map((barrio) => (
              <div key={barrio.id} className="card flex items-center justify-between">
                <div className="flex-1">
                  <p className="font-medium text-surface-700">{barrio.name}</p>
                  <p className="text-xs text-surface-400">
                    Precio: ${barrio.surcharge_usd.toFixed(2)}
                    {barrio.lat && barrio.lng && ' • Ubicación asignada'}
                  </p>
                </div>
                <div className="flex items-center gap-1">
                  <button
                    onClick={() => handleEdit(barrio)}
                    className="p-2 text-accent-600 hover:bg-accent-50 rounded-lg transition-colors"
                  >
                    <Pencil className="w-4 h-4" />
                  </button>
                  <button
                    onClick={() => handleDelete(barrio.id)}
                    className="p-2 text-red-400 hover:bg-red-50 rounded-lg transition-colors"
                  >
                    <Trash2 className="w-4 h-4" />
                  </button>
                </div>
              </div>
            ))}
          </div>
        </div>

        <div>
          <h2 className="text-lg font-semibold text-surface-800 mb-3">
            {editing ? `Editar: ${editing.name}` : 'Nuevo barrio'}
          </h2>
          <HexUnderline />

          <form onSubmit={handleSave} className="card space-y-4">
            <div>
              <label className="label">Nombre del barrio *</label>
              <input
                type="text"
                className="input"
                placeholder="Ej: Centro, Bum Bum, El Carmen"
                value={name}
                onChange={(e) => setName(e.target.value)}
                required
              />
            </div>

            <div>
              <label className="label">Precio del barrio en USD ($) *</label>
              <input
                type="number"
                className="input"
                step="0.50"
                min="0"
                placeholder="0.00"
                value={surcharge}
                onChange={(e) => setSurcharge(e.target.value)}
                required
              />
            </div>

            <div>
              <label className="label">Descripción</label>
              <input
                type="text"
                className="input"
                placeholder="Descripción opcional"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
              />
            </div>

            <div>
              <label className="label">Ubicación aproximada en el mapa</label>
              <div className="h-48 rounded-xl overflow-hidden shadow-soft relative">
                <MapContainer
                  center={lat && lng ? [lat, lng] : SOCOPO_CENTER}
                  zoom={14}
                  className="h-full w-full"
                >
                  <TileLayer
                    url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
                    attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
                  />
                  {lat && lng && <Marker position={[lat, lng]} icon={barrioIcon} />}
                  <MapClickHandler onSelect={(l, lg) => {
                    setLat(l)
                    setLng(lg)
                  }} />
                </MapContainer>
                <div className="absolute top-2 left-2 bg-white rounded-lg shadow-card px-2 py-1 text-xs text-surface-600 z-[1000]">
                  <MapPin className="w-3 h-3 inline mr-1" />
                  {lat && lng ? 'Ubicación seleccionada' : 'Toca el mapa para marcar'}
                </div>
              </div>
            </div>

            <div className="flex gap-2">
              {editing && (
                <button type="button" onClick={resetForm} className="btn-outline flex-1">
                  Cancelar
                </button>
              )}
              <button type="submit" className="btn-primary flex-1" disabled={saving}>
                {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : <><Save className="w-4 h-4" /> Guardar</>}
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
  )
}