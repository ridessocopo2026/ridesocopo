import { useEffect, useState } from 'react'
import { createPortal } from 'react-dom'
import { MapContainer, TileLayer, Marker, useMap, useMapEvents } from 'react-leaflet'
import L from 'leaflet'
import { MapPin, Maximize2, Minimize2, X } from 'lucide-react'

export type LatLngPoint = { lat: number; lng: number }

interface DestinationPinPickerProps {
  center: LatLngPoint | null
  value: LatLngPoint | null
  onChange: (point: LatLngPoint | null) => void
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
    const t = window.setTimeout(() => map.invalidateSize(), 150)
    return () => window.clearTimeout(t)
    // Solo recentra cuando cambia el sector; no en cada arrastre del pin.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [center.lat, center.lng, map])
  return null
}

function Resize({ expanded }: { expanded: boolean }) {
  const map = useMap()
  useEffect(() => {
    const t = window.setTimeout(() => map.invalidateSize(), 220)
    return () => window.clearTimeout(t)
  }, [expanded, map])
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

export function DestinationPinPicker({ center, value, onChange }: DestinationPinPickerProps) {
  const [expanded, setExpanded] = useState(false)

  if (!center) return null

  const current = value || center
  const marked = !!value

  const map = (
    <MapContainer
      key={expanded ? 'full' : 'compact'}
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
      <Resize expanded={expanded} />
      <TapToPlace onPlace={onChange} />
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
    <div className="rounded-2xl border border-surface-200 overflow-hidden bg-white">
      <div className="flex items-center justify-between gap-2 px-3 py-2 bg-surface-50 border-b border-surface-100">
        <div className="flex items-center gap-1.5 min-w-0">
          <MapPin className="w-4 h-4 text-primary-600 flex-shrink-0" />
          <p className="text-xs font-semibold text-surface-700 truncate">
            Punto exacto <span className="font-normal text-surface-400">(opcional)</span>
          </p>
        </div>
        <div className="flex items-center gap-1 flex-shrink-0">
          {marked && (
            <button
              type="button"
              onClick={() => onChange(null)}
              className="flex items-center gap-1 text-[11px] font-semibold text-surface-500 hover:text-red-600 px-2 py-1 rounded-lg hover:bg-red-50 transition-colors"
            >
              <X className="w-3 h-3" /> Quitar
            </button>
          )}
          <button
            type="button"
            onClick={() => setExpanded((v) => !v)}
            className="p-1.5 rounded-lg text-surface-500 hover:text-primary-600 hover:bg-primary-50 transition-colors"
            aria-label={expanded ? 'Reducir mapa' : 'Ampliar mapa'}
          >
            {expanded ? <Minimize2 className="w-4 h-4" /> : <Maximize2 className="w-4 h-4" />}
          </button>
        </div>
      </div>

      {!expanded && (
        <div className="relative h-[175px]">{map}</div>
      )}

      {expanded && typeof document !== 'undefined' && createPortal(
        <div className="fixed inset-0 z-[4000] bg-white">
          <div className="h-full w-full">{map}</div>
          <button
            type="button"
            onClick={() => setExpanded(false)}
            className="absolute bottom-6 left-1/2 -translate-x-1/2 z-[4100] btn-primary px-8 shadow-lg"
          >
            Listo
          </button>
        </div>,
        document.body
      )}

      <div className="px-3 py-2">
        <p className={`text-[11px] font-medium ${marked ? 'text-emerald-700' : 'text-surface-400'}`}>
          {marked ? '✓ Punto exacto marcado' : 'Usando el sector como referencia'}
        </p>
        <p className="text-[11px] text-surface-400 mt-0.5 leading-snug">
          Arrastra el pin o toca el mapa en la puerta exacta. Si no lo mueves, se usará el sector.
        </p>
      </div>
    </div>
  )
}
