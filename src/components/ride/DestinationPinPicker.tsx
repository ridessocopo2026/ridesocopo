import { useEffect, useState } from 'react'
import { createPortal } from 'react-dom'
import { MapContainer, TileLayer, Marker, Polygon, CircleMarker, useMap, useMapEvents } from 'react-leaflet'
import L from 'leaflet'
import { Check, MapPin, X } from 'lucide-react'
import { geoJsonToLeafletRings } from '@/lib/geo'

export type LatLngPoint = { lat: number; lng: number }

export interface PinPickerHint {
  text: string
  tone: 'muted' | 'ok' | 'warn' | 'error'
}

interface DestinationPinPickerProps {
  center: LatLngPoint | null
  value: LatLngPoint | null
  onChange: (point: LatLngPoint | null) => void
  hint?: PinPickerHint | null
  coveragePolygon?: any
  blocked?: boolean
}

const pinIcon = L.divIcon({
  className: 'custom-div-icon',
  html: `<div style="width:34px;height:34px;border-radius:50%;background:#7c3aed;border:4px solid #fff;box-shadow:0 2px 10px rgba(0,0,0,.35);display:flex;align-items:center;justify-content:center">
    <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="#fff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
      <path d="M12 21s-7-6.2-7-11a7 7 0 1114 0c0 4.8-7 11-7 11z"/>
      <circle cx="12" cy="10" r="2.5"/>
    </svg>
  </div>`,
  iconSize: [34, 34],
  iconAnchor: [17, 34]
})

function Recenter({ center, focus }: { center: LatLngPoint; focus: LatLngPoint }) {
  const map = useMap()
  useEffect(() => {
    map.setView([focus.lat, focus.lng], map.getZoom() || 16)
    const timer = window.setTimeout(() => map.invalidateSize(), 180)
    return () => window.clearTimeout(timer)
    // Solo recentra al abrir; no en cada arrastre del pin.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [center.lat, center.lng, map])
  return null
}

function TapToPlace({ onPlace }: { onPlace: (point: LatLngPoint) => void }) {
  useMapEvents({
    click(e) {
      onPlace({ lat: e.latlng.lat, lng: e.latlng.lng })
    }
  })
  return null
}

export function DestinationPinPicker({ center, value, onChange, hint, coveragePolygon, blocked = false }: DestinationPinPickerProps) {
  const [open, setOpen] = useState(false)

  if (!center) return null

  const current = value || center
  const marked = !!value
  const coverageRings = geoJsonToLeafletRings(coveragePolygon)
  const toneClass =
    hint?.tone === 'error'
      ? 'text-red-600'
      : hint?.tone === 'ok'
        ? 'text-emerald-700'
        : hint?.tone === 'warn'
          ? 'text-amber-700'
          : 'text-surface-400'
  const statusText = marked
    ? (hint?.text || '✓ Punto exacto marcado')
    : 'Usando el sector como referencia'

  const map = (
    <MapContainer
      key="pin-picker"
      center={[current.lat, current.lng]}
      zoom={16}
      className="h-full w-full"
      scrollWheelZoom={false}
    >
      <TileLayer
        url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
        attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
      />
      <Recenter center={center} focus={current} />
      <TapToPlace onPlace={onChange} />
      {/* Polígono de cobertura de la ciudad */}
      {coverageRings.map((ring, index) => (
        <Polygon
          key={`coverage-${index}`}
          positions={ring}
          pathOptions={{ color: '#059669', weight: 2, fillColor: '#10b981', fillOpacity: 0.05 }}
        />
      ))}
      {/* Referencia del sector elegido */}
      <CircleMarker
        center={[center.lat, center.lng]}
        radius={7}
        pathOptions={{ color: '#64748b', fillColor: '#cbd5e1', fillOpacity: 0.9, weight: 2 }}
      />
      <Marker
        position={[current.lat, current.lng]}
        icon={pinIcon}
        draggable
        eventHandlers={{
          dragend: (e) => {
            const p = e.target.getLatLng()
            onChange({ lat: p.lat, lng: p.lng })
          }
        }}
      />
    </MapContainer>
  )

  return (
    <>
      <div className="rounded-2xl border border-surface-200 bg-white px-3 py-2.5">
        <div className="flex items-start gap-2">
          <div className="w-8 h-8 rounded-full bg-primary-50 flex items-center justify-center flex-shrink-0">
            <MapPin className="w-4 h-4 text-primary-600" />
          </div>
          <div className="flex-1 min-w-0">
            <p className="text-xs font-semibold text-surface-700">
              Punto exacto <span className="font-normal text-surface-400">(opcional)</span>
            </p>
            <p className={`text-[11px] leading-snug ${marked ? toneClass : 'text-surface-400'}`}>
              {statusText}
            </p>
          </div>
          {marked && (
            <button
              type="button"
              onClick={() => onChange(null)}
              className="p-1.5 rounded-lg text-surface-400 hover:text-red-600 hover:bg-red-50 transition-colors"
              aria-label="Quitar pin"
            >
              <X className="w-4 h-4" />
            </button>
          )}
        </div>

        <button
          type="button"
          onClick={() => setOpen(true)}
          className="mt-2 w-full btn-outline py-1.5 text-xs"
        >
          <MapPin className="w-3.5 h-3.5" />
          {marked ? 'Cambiar pin en el mapa' : 'Colocar pin en el mapa'}
        </button>
      </div>

      {open && typeof document !== 'undefined' && createPortal(
        <div className="fixed inset-0 z-[4000] bg-white flex flex-col">
          <div className="px-4 py-3 border-b border-surface-100">
            <div className="flex items-start justify-between gap-3">
              <div className="min-w-0">
                <p className="text-sm font-bold text-surface-800">Punto exacto de ida</p>
                <p className={`text-[11px] leading-snug ${marked ? toneClass : 'text-surface-400'}`}>
                  {marked ? (hint?.text || '✓ Punto exacto marcado') : 'Arrastra el pin o toca el mapa en la puerta exacta.'}
                </p>
              </div>
              <button
                type="button"
                onClick={() => setOpen(false)}
                className="p-2 text-surface-400"
                aria-label="Cerrar"
              >
                <X className="w-5 h-5" />
              </button>
            </div>
            <div className="flex items-center gap-3 mt-2 text-[10px] text-surface-400">
              <span className="flex items-center gap-1">
                <span className="w-2 h-2 rounded-full bg-slate-400 inline-block" /> Referencia del sector
              </span>
              <span className="flex items-center gap-1">
                <span className="w-2 h-2 rounded-full bg-primary-600 inline-block" /> Tu pin
              </span>
              {coverageRings.length > 0 && (
                <span className="flex items-center gap-1">
                  <span className="w-2 h-2 rounded-full bg-emerald-600 inline-block" /> Área de cobertura
                </span>
              )}
            </div>
          </div>

          <div className="flex-1 relative min-h-0">{map}</div>

          <div className="flex gap-2 px-4 py-3 border-t border-surface-100 bg-white">
            <button
              type="button"
              onClick={() => { onChange(null); setOpen(false) }}
              className="btn-outline flex-1"
            >
              Usar el sector
            </button>
            <button
              type="button"
              onClick={() => setOpen(false)}
              className="btn-primary flex-1"
              disabled={blocked}
            >
              <Check className="w-4 h-4" /> {blocked ? 'Fuera de cobertura' : 'Listo'}
            </button>
          </div>
        </div>,
        document.body
      )}
    </>
  )
}
