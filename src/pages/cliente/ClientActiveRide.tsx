import { useState, useEffect } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { MapContainer, TileLayer, Marker, Polyline, Popup } from 'react-leaflet'
import L from 'leaflet'
import { Navigation, Star, Loader2, Hexagon, XCircle, Save, CheckCircle, AlertCircle } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { RatingCard } from '@/components/ui/RatingCard'
import { NotificationBanner } from '@/components/ui/NotificationBanner'
import { useRideRealtime, fetchRideById } from '@/lib/rideRealtime'
import type { Ride, Vehicle } from '@/types/database'

const vehicleIcon = L.divIcon({
  className: 'custom-div-icon',
  html: `<div class="w-10 h-10 bg-primary-600 rounded-full border-4 border-white shadow-lg flex items-center justify-center">
    <svg class="w-5 h-5 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M13 16V6a1 1 0 00-1-1H4a1 1 0 00-1 1v10a1 1 0 001 1h1m8-1a1 1 0 01-1 1H9m4-1V8a1 1 0 011-1h2.586a1 1 0 01.707.293l3.414 3.414a1 1 0 01.293.707V16a1 1 0 01-1 1h-1m-6-1a1 1 0 001 1h1M5 17a2 2 0 104 0m-4 0a2 2 0 114 0m6 0a2 2 0 104 0m-4 0a2 2 0 114 0"/>
    </svg>
  </div>`,
  iconSize: [40, 40],
  iconAnchor: [20, 20]
})

const originIcon = L.divIcon({
  className: 'custom-div-icon',
  html: `<div class="w-8 h-8 bg-accent-600 rounded-full border-4 border-white shadow-lg flex items-center justify-center">
    <svg class="w-4 h-4 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z"/>
    </svg>
  </div>`,
  iconSize: [32, 32],
  iconAnchor: [16, 32]
})

const destIcon = L.divIcon({
  className: 'custom-div-icon',
  html: `<div class="w-8 h-8 bg-red-500 rounded-full border-4 border-white shadow-lg flex items-center justify-center">
    <svg class="w-4 h-4 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17.657 16.657L13.414 20.9a1.998 1.998 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z"/>
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 11a3 3 0 11-6 0 3 3 0 016 0z"/>
    </svg>
  </div>`,
  iconSize: [32, 32],
  iconAnchor: [16, 32]
})

export function ClientActiveRide() {
  const { rideId } = useParams()
  const [ride, setRide] = useState<Ride | null>(null)
  const [driverName, setDriverName] = useState('')
  const [vehicle, setVehicle] = useState<Vehicle | null>(null)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)
  const [showSaveFavorite, setShowSaveFavorite] = useState(false)
  const [favoriteName, setFavoriteName] = useState('')
  const { user } = useAuth()
  const navigate = useNavigate()

  useEffect(() => {
    if (rideId) {
      loadRide()
    }
  }, [rideId])

  // Tiempo real optimizado: Realtime + polling de respaldo cada 6s
  useRideRealtime(
    rideId,
    (newRide) => {
      const ride = newRide as Ride
      setRide(ride)
      if (ride.status === 'completada') {
        setShowSaveFavorite(true)
      }
    },
    async () => {
      if (!rideId) return null
      return fetchRideById(rideId)
    }
  )

  const loadRide = async () => {
    const { data, error } = await supabase
      .from('rides')
      .select('*')
      .eq('id', rideId)
      .single()

    if (!error && data) {
      setRide(data as Ride)

      if (data.driver_id) {
        const { data: driverData } = await supabase
          .from('profiles')
          .select('full_name, avatar_url')
          .eq('id', data.driver_id)
          .maybeSingle()

        if (driverData) {
          setDriverName(driverData.full_name)
        }

        if (data.vehicle_id) {
          const { data: vehicleData } = await supabase
            .from('vehicles')
            .select('*')
            .eq('id', data.vehicle_id)
            .maybeSingle()

          if (vehicleData) {
            setVehicle(vehicleData as Vehicle)
          }
        }
      }

      if (data.status === 'completada') {
        setShowSaveFavorite(true)
      }
    }
  }

  const handleConfirmStart = async () => {
    setError('')
    setLoading(true)

    try {
      const { data, error } = await supabase.rpc('confirm_ride_start', {
        p_ride_id: rideId
      })

      if (error) throw error

      setRide({ ...ride!, ...data } as Ride)
    } catch (err: any) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  const handleCancelRide = async () => {
    setError('')
    setLoading(true)

    try {
      const { error } = await supabase.rpc('cancel_ride', {
        p_ride_id: rideId,
        p_reason: 'Cancelado por el cliente'
      })

      if (error) throw error

      navigate('/cliente')
    } catch (err: any) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  const handleRateDriver = async (rating: number, review: string) => {
    const { error } = await supabase.rpc('rate_driver', {
      p_ride_id: rideId,
      p_rating: rating,
      p_review: review || null
    })
    if (error) throw error
  }

  const handleSaveFavorite = async () => {
    if (!ride || !favoriteName) return

    setError('')
    setLoading(true)

    try {
      const { error } = await supabase.rpc('save_favorite_place', {
        p_name: favoriteName,
        p_address: ride.destination_address,
        p_lat: ride.destination_lat,
        p_lng: ride.destination_lng
      })

      if (error) throw error

      setShowSaveFavorite(false)
      navigate('/cliente')
    } catch (err: any) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  if (!ride) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <Loader2 className="w-8 h-8 animate-spin text-primary-600" />
      </div>
    )
  }

  const origin: [number, number] = [ride.origin_lat, ride.origin_lng]
  const destination: [number, number] = [ride.destination_lat, ride.destination_lng]
  const driverPos: [number, number] | null = ride.driver_location_lat && ride.driver_location_lng
    ? [ride.driver_location_lat, ride.driver_location_lng]
    : null

  const driverConfirmed = ride.driver_start_confirmed
  const clientConfirmed = ride.client_start_confirmed
  const bothConfirmed = driverConfirmed && clientConfirmed

  const statusLabels = {
    buscando: 'Buscando conductor...',
    aceptada: 'Conductor en camino',
    en_ruta: 'En ruta al destino',
    completada: 'Viaje completado',
    cancelada: 'Viaje cancelado'
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <NotificationBanner />
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 bg-primary-600 rounded-xl flex items-center justify-center">
              <Hexagon className="w-5 h-5 text-white" />
            </div>
            <div>
              <h1 className="text-lg font-bold text-surface-800">Mi viaje</h1>
              <p className="text-xs text-surface-500">{statusLabels[ride.status]}</p>
            </div>
          </div>
          <span className={`badge ${
            ride.status === 'buscando' ? 'badge-warning' :
            ride.status === 'aceptada' ? 'badge-info' :
            ride.status === 'en_ruta' ? 'badge-primary' :
            ride.status === 'completada' ? 'badge-success' : 'badge-danger'
          }`}>
            {ride.status.toUpperCase()}
          </span>
        </div>
      </div>

      {error && (
        <div className="max-w-md mx-auto px-4 mt-4">
          <ErrorMessage message={error} onDismiss={() => setError('')} />
        </div>
      )}

      {/* Mapa */}
      <div className="h-[40vh] relative">
        <MapContainer
          center={origin}
          zoom={15}
          className="h-full w-full"
        >
          <TileLayer
            url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
            attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
          />
          <Marker position={origin} icon={originIcon}>
            <Popup>Tu ubicación</Popup>
          </Marker>
          <Marker position={destination} icon={destIcon}>
            <Popup>Destino</Popup>
          </Marker>
          {driverPos && (
            <Marker position={driverPos} icon={vehicleIcon}>
              <Popup>Conductor</Popup>
            </Marker>
          )}
          <Polyline
            positions={[origin, destination]}
            pathOptions={{ color: '#7c3aed', weight: 3, dashArray: '8, 8' }}
          />
        </MapContainer>
      </div>

      {/* Detalles */}
      <div className="max-w-md mx-auto px-4 py-6 space-y-4">
        {/* Confirmación mutua */}
        {ride.status === 'aceptada' && (
          <div className="card border-2 border-primary-100 bg-primary-50">
            <h2 className="font-semibold text-surface-800 mb-3 flex items-center gap-2">
              <AlertCircle className="w-5 h-5 text-primary-600" />
              Confirmación de inicio
            </h2>
            <p className="text-sm text-surface-600 mb-4">
              Cuando el conductor te recoja, **confirma** que el viaje inicia.
            </p>

            <div className="space-y-2 mb-4">
              <div className="flex items-center justify-between">
                <span className="text-sm text-surface-600">Tu confirmación (Pasajero)</span>
                {clientConfirmed ? (
                  <span className="badge-success flex items-center gap-1">
                    <CheckCircle className="w-3 h-3" /> Confirmado
                  </span>
                ) : (
                  <span className="badge-warning">Pendiente</span>
                )}
              </div>
              <div className="flex items-center justify-between">
                <span className="text-sm text-surface-600">Confirmación del conductor</span>
                {driverConfirmed ? (
                  <span className="badge-success flex items-center gap-1">
                    <CheckCircle className="w-3 h-3" /> Confirmado
                  </span>
                ) : (
                  <span className="badge-warning">Pendiente</span>
                )}
              </div>
            </div>

            {!clientConfirmed ? (
              <button onClick={handleConfirmStart} className="btn-success w-full" disabled={loading}>
                {loading ? <Loader2 className="w-4 h-4 animate-spin" /> : <><CheckCircle className="w-4 h-4" /> Confirmar inicio del viaje</>}
              </button>
            ) : (
              <div className="bg-emerald-50 border border-emerald-200 rounded-lg p-3 text-center">
                <p className="text-sm text-emerald-700">
                  {bothConfirmed ? '✅ Viaje iniciado. ¡Buen viaje!' : '⏳ Esperando que el conductor confirme...'}
                </p>
              </div>
            )}
          </div>
        )}

        {/* Conductor info */}
        {ride.driver_id && (
          <div className="card">
            <div className="flex items-center gap-4">
              <div className="w-14 h-14 bg-primary-50 rounded-full flex items-center justify-center">
                <Navigation className="w-7 h-7 text-primary-600" />
              </div>
              <div className="flex-1">
                <h2 className="font-semibold text-surface-800">{driverName || 'Conductor'}</h2>
                {vehicle && (
                  <p className="text-sm text-surface-500">
                    {vehicle.brand} {vehicle.model} • {vehicle.color} • {vehicle.plate}
                  </p>
                )}
              </div>
            </div>
          </div>
        )}

        {/* Ruta */}
        <div className="card">
          <div className="space-y-3">
            <div className="flex items-start gap-3">
              <div className="w-2 h-2 bg-accent-600 rounded-full mt-1.5 flex-shrink-0" />
              <div>
                <p className="text-xs text-surface-400">Origen</p>
                <p className="text-sm text-surface-700">{ride.origin_address || 'Ubicación actual'}</p>
              </div>
            </div>
            <div className="flex items-start gap-3">
              <div className="w-2 h-2 bg-red-500 rounded-full mt-1.5 flex-shrink-0" />
              <div>
                <p className="text-xs text-surface-400">Destino</p>
                <p className="text-sm text-surface-700">{ride.destination_address || 'Destino'}</p>
                {ride.destination_barrio_name && (
                  <span className="badge-primary mt-1">{ride.destination_barrio_name}</span>
                )}
              </div>
            </div>
          </div>
        </div>

        {/* Tarifa */}
        <div className="card">
          <div className="flex items-center justify-between">
            <span className="text-sm text-surface-500">Tarifa</span>
            <span className="text-2xl font-bold text-primary-600">${ride.final_fare_usd.toFixed(2)}</span>
          </div>
        </div>

        {/* Acciones */}
        {ride.status === 'buscando' && (
          <button onClick={handleCancelRide} className="btn-danger w-full" disabled={loading}>
            <XCircle className="w-4 h-4" />
            Cancelar solicitud
          </button>
        )}

        {ride.status === 'aceptada' && (
          <button onClick={handleCancelRide} className="btn-danger w-full" disabled={loading}>
            <XCircle className="w-4 h-4" />
            Cancelar viaje
          </button>
        )}

        {/* Calificar al conductor al completar */}
        {ride.status === 'completada' && (
          <RatingCard
            title="Califica a tu conductor"
            subtitle="Tu opinión ayuda a mejorar el servicio"
            onSubmit={handleRateDriver}
            alreadyRated={ride.rating}
            alreadyReviewed={ride.review}
          />
        )}

        {/* Guardar favorito al completar */}
        {showSaveFavorite && (
          <div className="card bg-primary-50 border-primary-200">
            <div className="flex items-center gap-2 mb-3">
              <Star className="w-5 h-5 text-amber-400" />
              <h3 className="font-semibold text-surface-800">Guardar destino</h3>
            </div>
            <p className="text-sm text-surface-600 mb-3">
              ¿Quieres guardar este destino en tus lugares favoritos?
            </p>
            <div className="flex gap-2">
              <input
                type="text"
                className="input flex-1"
                placeholder="Ej: Casa, Trabajo, Taller"
                value={favoriteName}
                onChange={(e) => setFavoriteName(e.target.value)}
              />
              <button
                onClick={handleSaveFavorite}
                className="btn-primary"
                disabled={loading || !favoriteName}
              >
                <Save className="w-4 h-4" />
                Guardar
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}