import { useEffect } from 'react'
import { MapContainer, TileLayer, Marker, Polyline, useMap } from 'react-leaflet'
import L from 'leaflet'

export interface LiveRideMapPoint {
  ride_id: string
  status: string
  category: string
  origin_lat: number
  origin_lng: number
  destination_lat: number
  destination_lng: number
  driver_location_lat: number | null
  driver_location_lng: number | null
  origin_barrio_name?: string | null
  destination_barrio_name?: string | null
}

const originIcon = L.divIcon({
  className: '',
  html: '<div style="width:18px;height:18px;border-radius:50%;background:#10b981;border:3px solid #fff;box-shadow:0 1px 4px rgba(0,0,0,.35)"></div>',
  iconSize: [18, 18],
  iconAnchor: [9, 9]
})

const destinationIcon = L.divIcon({
  className: '',
  html: '<div style="width:18px;height:18px;border-radius:50%;background:#ef4444;border:3px solid #fff;box-shadow:0 1px 4px rgba(0,0,0,.35)"></div>',
  iconSize: [18, 18],
  iconAnchor: [9, 9]
})

function driverIconFor(category: string) {
  const emoji = category.includes('moto') ? '🛵' : category.includes('camion') ? '🚚' : '🚗'
  return L.divIcon({
    className: '',
    html: `<div style="width:28px;height:28px;border-radius:50%;background:#2563eb;border:3px solid #fff;box-shadow:0 1px 6px rgba(0,0,0,.35);display:flex;align-items:center;justify-content:center;font-size:14px">${emoji}</div>`,
    iconSize: [28, 28],
    iconAnchor: [14, 14]
  })
}

function FitRide({ points, rideId }: { points: [number, number][]; rideId: string }) {
  const map = useMap()
  useEffect(() => {
    if (!points.length) return
    map.fitBounds(L.latLngBounds(points), { padding: [30, 30], maxZoom: 16 })
    // Solo reencuadra al cambiar de viaje, no en cada actualizacion de GPS.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [rideId, map])
  return null
}

export function LiveRideMap({ ride }: { ride: LiveRideMapPoint | null }) {
  if (!ride) {
    return (
      <div className="card flex h-[300px] items-center justify-center text-sm text-surface-500">
        Selecciona un viaje para ver el mapa
      </div>
    )
  }

  const origin: [number, number] = [Number(ride.origin_lat), Number(ride.origin_lng)]
  const destination: [number, number] = [Number(ride.destination_lat), Number(ride.destination_lng)]
  const driver: [number, number] | null =
    ride.driver_location_lat != null && ride.driver_location_lng != null
      ? [Number(ride.driver_location_lat), Number(ride.driver_location_lng)]
      : null
  const points: [number, number][] = driver ? [origin, destination, driver] : [origin, destination]

  return (
    <div className="card overflow-hidden p-0">
      <MapContainer
        center={origin}
        zoom={13}
        scrollWheelZoom={false}
        className="h-[340px] w-full lg:h-[480px]"
      >
        <TileLayer
          attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
          url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
        />
        <FitRide points={points} rideId={ride.ride_id} />
        <Polyline
          positions={[origin, destination]}
          pathOptions={{ color: '#2563eb', weight: 4, dashArray: '6 8', opacity: 0.8 }}
        />
        <Marker position={origin} icon={originIcon} />
        <Marker position={destination} icon={destinationIcon} />
        {driver && <Marker position={driver} icon={driverIconFor(ride.category)} />}
      </MapContainer>
      <div className="flex flex-wrap items-center gap-x-4 gap-y-1 px-3 py-2 text-[11px] text-surface-500">
        <span className="inline-flex items-center gap-1">
          <span className="h-2.5 w-2.5 rounded-full bg-emerald-500" /> Origen: {ride.origin_barrio_name || '—'}
        </span>
        <span className="inline-flex items-center gap-1">
          <span className="h-2.5 w-2.5 rounded-full bg-red-500" /> Destino: {ride.destination_barrio_name || '—'}
        </span>
        {driver ? (
          <span className="inline-flex items-center gap-1">
            <span className="h-2.5 w-2.5 rounded-full bg-blue-600" /> Conductor
          </span>
        ) : (
          <span className="text-amber-600">Sin ubicación del conductor</span>
        )}
      </div>
    </div>
  )
}