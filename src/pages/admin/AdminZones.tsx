import { useState, useEffect, useRef } from 'react'
import { MapContainer, TileLayer, Polygon, useMapEvents } from 'react-leaflet'
import { MapPin, Plus, Save, Trash2, Loader2 } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { HexUnderline } from '@/components/ui/HexUnderline'
import type { Zone } from '@/types/database'
import { AppLogo } from '@/components/ui/AppLogo'

const SOCOPO_CENTER: [number, number] = [8.23293, -70.82228]

function MapClickHandler({ onAddPoint }: { onAddPoint: (lat: number, lng: number) => void }) {
  useMapEvents({
    click(e) {
      onAddPoint(e.latlng.lat, e.latlng.lng)
    }
  })
  return null
}

export function AdminZones() {
  const [zones, setZones] = useState<Zone[]>([])
  const [selectedZone, setSelectedZone] = useState<Zone | null>(null)
  const [drawingPoints, setDrawingPoints] = useState<[number, number][]>([])
  const [zoneName, setZoneName] = useState('')
  const [zoneDesc, setZoneDesc] = useState('')
  const [surcharge, setSurcharge] = useState('')
  const [zoneType, setZoneType] = useState<'cobertura_general' | 'zona_especifica'>('zona_especifica')
  const [centerLat, setCenterLat] = useState('')
  const [centerLng, setCenterLng] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const { user } = useAuth()

  useEffect(() => {
    loadZones()
  }, [])

  const loadZones = async () => {
    const { data, error } = await supabase
      .from('zones')
      .select('*')
      .order('name')

    if (!error && data) {
      setZones(data as Zone[])
    }
    setLoading(false)
  }

  const handleAddPoint = (lat: number, lng: number) => {
    setDrawingPoints([...drawingPoints, [lat, lng]])
  }

  const handleSaveZone = async () => {
    setError('')

    if (!zoneName || !surcharge) {
      setError('Completa el nombre y el recargo')
      return
    }

    if (drawingPoints.length < 3) {
      setError('Dibuja al menos 3 puntos en el mapa para crear el polígono')
      return
    }

    setSaving(true)

    try {
      // Convertir puntos a GeoJSON Polygon
      const polygonCoords = [...drawingPoints.map(p => [p[1], p[0]]), [drawingPoints[0][1], drawingPoints[0][0]]]
      const geojson = {
        type: 'Polygon',
        coordinates: [polygonCoords]
      }

      const { data, error } = await supabase.rpc('upsert_zone', {
        p_name: zoneName,
        p_description: zoneDesc,
        p_surcharge_usd: parseFloat(surcharge),
        p_polygon_geojson: geojson,
        p_zone_id: selectedZone?.id || null,
        p_zone_type: zoneType,
        p_center_lat: centerLat ? parseFloat(centerLat) : null,
        p_center_lng: centerLng ? parseFloat(centerLng) : null
      })

      if (error) throw error

      // Reset
      setZoneName('')
      setZoneDesc('')
      setSurcharge('')
      setZoneType('zona_especifica')
      setCenterLat('')
      setCenterLng('')
      setDrawingPoints([])
      setSelectedZone(null)
      loadZones()
    } catch (err: any) {
      setError(err.message)
    } finally {
      setSaving(false)
    }
  }

  const handleSelectZone = (zone: Zone) => {
    setSelectedZone(zone)
    setZoneName(zone.name)
    setZoneDesc(zone.description || '')
    setSurcharge(zone.surcharge_usd.toString())
    setZoneType(zone.zone_type)
    setCenterLat(zone.center_lat?.toString() || '')
    setCenterLng(zone.center_lng?.toString() || '')

    // Convertir polígono a puntos
    if (zone.polygon) {
      const coords = zone.polygon.coordinates?.[0] || []
      setDrawingPoints(coords.map((c: number[]) => [c[1], c[0]]))
    }
  }

  const handleDeleteZone = async (zoneId: string) => {
    if (!confirm('¿Seguro que deseas eliminar esta zona?')) return

    const { error } = await supabase
      .from('zones')
      .delete()
      .eq('id', zoneId)

    if (!error) {
      loadZones()
    }
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center gap-3">
          <AppLogo />
          <div>
            <h1 className="text-lg font-bold text-surface-800">Editor de Zonas</h1>
            <p className="text-xs text-surface-500">Dibuja polígonos y define recargos</p>
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6 space-y-6">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        {/* Lista de zonas */}
        <div>
          <h2 className="text-lg font-semibold text-surface-800 mb-3">Zonas existentes</h2>
          <HexUnderline />
          <div className="space-y-2">
            {zones.map((zone) => (
              <div key={zone.id} className="card flex items-center justify-between">
                <button onClick={() => handleSelectZone(zone)} className="flex-1 text-left">
                  <p className="font-medium text-surface-700">{zone.name}</p>
                  <p className="text-xs text-surface-400">
                    {zone.zone_type === 'cobertura_general' ? 'Cobertura general' : `Recargo: ${zone.surcharge_usd.toFixed(2)}$`}
                  </p>
                </button>
                {zone.zone_type !== 'cobertura_general' && (
                  <button
                    onClick={() => handleDeleteZone(zone.id)}
                    className="p-2 text-red-400 hover:text-red-600 transition-colors"
                  >
                    <Trash2 className="w-4 h-4" />
                  </button>
                )}
              </div>
            ))}
          </div>
        </div>

        {/* Editor de zona */}
        <div>
          <h2 className="text-lg font-semibold text-surface-800 mb-3">
            {selectedZone ? 'Editar zona' : 'Nueva zona'}
          </h2>
          <HexUnderline />

          <div className="space-y-4">
            <div>
              <label className="label">Nombre de la zona</label>
              <input
                type="text"
                className="input"
                placeholder="Ej: Zona Centro, Bum Bum, Rural"
                value={zoneName}
                onChange={(e) => setZoneName(e.target.value)}
              />
            </div>

            <div>
              <label className="label">Descripción</label>
              <input
                type="text"
                className="input"
                placeholder="Descripción opcional"
                value={zoneDesc}
                onChange={(e) => setZoneDesc(e.target.value)}
              />
            </div>

            <div>
              <label className="label">Recargo en USD ($)</label>
              <input
                type="number"
                className="input"
                placeholder="0.00"
                step="0.50"
                min="0"
                value={surcharge}
                onChange={(e) => setSurcharge(e.target.value)}
              />
            </div>

            <div>
              <label className="label">Tipo de zona</label>
              <select
                className="input"
                value={zoneType}
                onChange={(e) => setZoneType(e.target.value as 'cobertura_general' | 'zona_especifica')}
              >
                <option value="cobertura_general">Ciudad (cobertura general)</option>
                <option value="zona_especifica">Zona específica (recargo)</option>
              </select>
            </div>

            <div className="grid grid-cols-2 gap-3">
              <div>
                <label className="label">Centro latitud (opcional)</label>
                <input
                  type="number"
                  className="input"
                  placeholder="Ej: 8.23293"
                  step="0.00001"
                  value={centerLat}
                  onChange={(e) => setCenterLat(e.target.value)}
                />
              </div>
              <div>
                <label className="label">Centro longitud (opcional)</label>
                <input
                  type="number"
                  className="input"
                  placeholder="Ej: -70.82228"
                  step="0.00001"
                  value={centerLng}
                  onChange={(e) => setCenterLng(e.target.value)}
                />
              </div>
            </div>

            {/* Mapa para dibujar */}
            <div className="h-64 rounded-2xl overflow-hidden shadow-card relative">
              <MapContainer
                center={SOCOPO_CENTER}
                zoom={14}
                className="h-full w-full"
              >
                <TileLayer
                  url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
                  attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
                />
                {drawingPoints.length >= 3 && (
                  <Polygon
                    positions={drawingPoints}
                    pathOptions={{ color: '#7c3aed', fillColor: '#7c3aed', fillOpacity: 0.2 }}
                  />
                )}
                <MapClickHandler onAddPoint={handleAddPoint} />
              </MapContainer>
              <div className="absolute top-3 left-3 bg-white rounded-lg shadow-card px-3 py-1.5 text-xs text-surface-600 z-[1000]">
                <MapPin className="w-3 h-3 inline mr-1" />
                Toca el mapa para agregar puntos ({drawingPoints.length})
              </div>
            </div>

            <div className="flex gap-2">
              <button
                onClick={() => setDrawingPoints([])}
                className="btn-outline flex-1"
                disabled={drawingPoints.length === 0}
              >
                Limpiar
              </button>
              <button
                onClick={handleSaveZone}
                className="btn-primary flex-1"
                disabled={saving}
              >
                {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : <><Save className="w-4 h-4" /> Guardar zona</>}
              </button>
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}