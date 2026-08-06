import { useState, useEffect, useRef } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { MapContainer, TileLayer, Marker, Polyline, Popup } from 'react-leaflet'
import L from 'leaflet'
import { Navigation, Star, Loader2, XCircle, Save, CheckCircle, AlertCircle, ShieldAlert, Upload, AlertTriangle } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { RatingCard } from '@/components/ui/RatingCard'
import { NotificationBanner } from '@/components/ui/NotificationBanner'
import { useRideRealtime, fetchRideById, useRideIncident } from '@/lib/rideRealtime'
import { TripDetailInfo } from '@/components/ride/TripDetailInfo'
import type { Ride, Vehicle, CancellationEstimate, IncidentType } from '@/types/database'
import { AppLogo } from '@/components/ui/AppLogo'

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

const incidentTypes: { value: IncidentType; label: string; emoji: string }[] = [
  { value: 'accidente', label: 'Accidente de tránsito', emoji: '🚨' },
  { value: 'falla_mecanica', label: 'Falla mecánica del vehículo', emoji: '🔧' },
  { value: 'urgencia_medica', label: 'Emergencia médica', emoji: '🏥' },
  { value: 'clima', label: 'Condiciones climáticas', emoji: '🌧️' },
  { value: 'otro', label: 'Otro incidente', emoji: '❓' }
]

const disputeTypes: { value: IncidentType; label: string; emoji: string }[] = [
  { value: 'viaje_no_realizado', label: 'No se realizó el viaje', emoji: '🚫' },
  { value: 'disputa_cobro', label: 'El cobro no corresponde', emoji: '💸' },
  { value: 'otro', label: 'Otro problema', emoji: '❓' }
]

export function ClientActiveRide() {
  const { rideId } = useParams()
  const [ride, setRide] = useState<Ride | null>(null)
  // Incidente/disputa del viaje (se refleja en vivo la resolución del admin)
  const incident = useRideIncident(rideId, ride?.incident_id)
  const [driverName, setDriverName] = useState('')
  const [vehicle, setVehicle] = useState<Vehicle | null>(null)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)
  const [showSaveFavorite, setShowSaveFavorite] = useState(false)
  const [favoriteName, setFavoriteName] = useState('')
  const [cancellationEstimate, setCancellationEstimate] = useState<CancellationEstimate | null>(null)
  const [showCancelConfirm, setShowCancelConfirm] = useState(false)
  const [showIncidentModal, setShowIncidentModal] = useState(false)
  const [incidentType, setIncidentType] = useState<IncidentType>('accidente')
  const [incidentDesc, setIncidentDesc] = useState('')
  const [incidentPhoto, setIncidentPhoto] = useState<File | null>(null)
  const { user } = useAuth()
  const navigate = useNavigate()
  // Ref al bloque de acciones post-viaje (calificar/reportar/guardar) para scroll automático
  const ratingRef = useRef<HTMLDivElement>(null)
  // Evita repetir el scroll en cada actualización de realtime/polling
  const autoScrolledRef = useRef(false)

  useEffect(() => {
    if (rideId) {
      autoScrolledRef.current = false
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

  // Scroll automático (una sola vez) cuando el viaje pasa a completado,
  // para que el cliente vea la calificación sin tener que bajar.
  useEffect(() => {
    if (ride?.status === 'completada' && !autoScrolledRef.current) {
      autoScrolledRef.current = true
      setTimeout(() => {
        ratingRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' })
      }, 150)
    }
  }, [ride?.status])

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
        // Si ya venía completado (ej: abierto desde historial), no hacer scroll automático
        autoScrolledRef.current = true
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

  // Obtener estimación de tarifa de cancelación
  const loadCancellationEstimate = async () => {
    const { data, error } = await supabase.rpc('estimate_cancellation_fee', {
      p_ride_id: rideId
    })
    if (!error && data) {
      setCancellationEstimate(data as CancellationEstimate)
    }
  }

  const handleCancelClick = async () => {
    // Obtener la estimación antes de mostrar el modal de confirmación
    await loadCancellationEstimate()
    setShowCancelConfirm(true)
  }

  const handleCancelRide = async () => {
    setError('')
    setLoading(true)

    try {
      const { data, error } = await supabase.rpc('cancel_ride', {
        p_ride_id: rideId,
        p_reason: ride?.status === 'buscando' ? 'Cancelado por el cliente' : 'Cancelado por el cliente',
        p_at_fault: 'cliente'
      })

      if (error) throw error

      setShowCancelConfirm(false)
      navigate('/cliente')
    } catch (err: any) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  // Reportar incidente
  const handleReportIncident = async () => {
    if (!rideId) return

    setError('')
    setLoading(true)

    try {
      let photoUrls: string[] = []

      // Subir foto si hay una
      if (incidentPhoto && user) {
        const { data: uploadData, error: uploadError } = await supabase.storage
          .from('payments')
          .upload(`${user.id}/incidents/${Date.now()}-${incidentPhoto.name}`, incidentPhoto, { upsert: true })
        if (uploadError) throw uploadError

        // El bucket es privado; guardamos la ruta y se resuelve con URL firmada al visualizar
        const storagePath = uploadData.path

        photoUrls = [storagePath]
      }

      const { data, error } = await supabase.rpc('report_ride_incident', {
        p_ride_id: rideId,
        p_incident_type: incidentType,
        p_description: incidentDesc || null,
        p_photo_urls: JSON.stringify(photoUrls)
      })

      if (error) throw error

      setShowIncidentModal(false)
      // El viaje pasa a estado 'incidente' - cerrar el modal y actualizar
      if (data?.status) {
        setRide(prev => prev ? { ...prev, status: data.status, incident_id: data.incident_id } : prev)
      }
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

  // Si el viaje ya fue completado, el reporte es una DISPUTA post-viaje
  const isDispute = ride.status === 'completada'
  const reportTypes = isDispute ? disputeTypes : incidentTypes

  const statusLabels = {
    buscando: 'Buscando conductor...',
    aceptada: 'Conductor en camino',
    en_ruta: 'En ruta al destino',
    completada: 'Viaje completado',
    cancelada: 'Viaje cancelado',
    incidente: 'Incidente en revisión'
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <NotificationBanner />
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <AppLogo />
            <div>
              <h1 className="text-lg font-bold text-surface-800">Mi viaje</h1>
              <p className="text-xs text-surface-500">{statusLabels[ride.status]}</p>
            </div>
          </div>
          <div className="flex items-center gap-2">
            {ride.tracking_code && (
              <span className="font-mono text-xs font-bold text-primary-600 bg-primary-50 rounded-lg px-2 py-1">
                {ride.tracking_code}
              </span>
            )}
            <span className={`badge ${
              ride.status === 'buscando' ? 'badge-warning' :
              ride.status === 'aceptada' ? 'badge-info' :
              ride.status === 'en_ruta' ? 'badge-primary' :
              ride.status === 'completada' ? 'badge-success' :
              ride.status === 'incidente' ? 'badge-danger' : 'badge-danger'
            }`}>
              {ride.status.toUpperCase()}
            </span>
          </div>
        </div>
      </div>

      {error && (
        <div className="max-w-md mx-auto px-4 mt-4">
          <ErrorMessage message={error} onDismiss={() => setError('')} />
        </div>
      )}

      {/* Banner de incidente */}
      {ride.status === 'incidente' && (
        <div className="max-w-md mx-auto px-4 mt-4">
          <div className="bg-red-50 border border-red-200 rounded-xl p-4 flex items-start gap-3">
            <ShieldAlert className="w-6 h-6 text-red-600 flex-shrink-0" />
            <div>
              <h3 className="font-semibold text-red-700">Incidente reportado</h3>
              <p className="text-sm text-red-600 mt-1">
                Tu reporte está siendo revisado por la plataforma. Se te notificará cuando haya una resolución.
              </p>
            </div>
          </div>
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
            <span className="text-2xl font-bold text-primary-600">${ride.final_fare_usd.toFixed(2)}$</span>
          </div>
        </div>

        {/* Acciones post-viaje: calificar, reportar problema y guardar destino */}
        {ride.status === 'completada' && (
          <div ref={ratingRef} className="space-y-4">
            {/* Calificar al conductor al completar */}
            <RatingCard
              title="Califica a tu conductor"
              subtitle="Tu opinión ayuda a mejorar el servicio"
              onSubmit={handleRateDriver}
              alreadyRated={ride.rating}
              alreadyReviewed={ride.review}
            />

            {/* Disputa de viaje completado: en revisión */}
            {ride.incident_id && incident &&
              (incident.status === 'abierto' || incident.status === 'en_revision') && (
              <div className="bg-amber-50 border border-amber-200 rounded-xl p-4 flex items-start gap-3">
                <AlertCircle className="w-5 h-5 text-amber-600 flex-shrink-0" />
                <div>
                  <h3 className="font-semibold text-amber-700">Disputa en revisión</h3>
                  <p className="text-sm text-amber-600 mt-1">
                    Reportaste un problema con este viaje. La plataforma lo está revisando
                    y se te notificará la resolución.
                  </p>
                </div>
              </div>
            )}

            {/* Disputa de viaje completado: reportar problema */}
            {!ride.incident_id && (
              <button
                onClick={() => {
                  setIncidentType('viaje_no_realizado')
                  setShowIncidentModal(true)
                }}
                className="btn-outline w-full text-red-600 border-red-200 hover:border-red-300"
              >
                <AlertCircle className="w-4 h-4" />
                Reportar un problema con el viaje
              </button>
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
        )}

        {/* Información total del viaje (estado, cancelación, incidentes/resoluciones, desglose) */}
        <TripDetailInfo ride={ride} incident={incident} currentUserId={user?.id} />

        {/* Acciones */}
        {ride.status === 'buscando' && (
          <button onClick={handleCancelClick} className="btn-danger w-full" disabled={loading}>
            <XCircle className="w-4 h-4" />
            Cancelar solicitud
          </button>
        )}

        {ride.status === 'aceptada' && (
          <>
            <button onClick={handleCancelClick} className="btn-danger w-full" disabled={loading}>
              <XCircle className="w-4 h-4" />
              Cancelar viaje
            </button>
            <button
              onClick={() => setShowIncidentModal(true)}
              className="btn-outline w-full text-red-600 border-red-200 hover:border-red-300"
            >
              <ShieldAlert className="w-4 h-4" />
              Reportar incidente / accidente
            </button>
          </>
        )}

        {ride.status === 'en_ruta' && (
          <>
            <button onClick={handleCancelClick} className="btn-danger w-full" disabled={loading}>
              <XCircle className="w-4 h-4" />
              Cancelar viaje
            </button>
            <button
              onClick={() => setShowIncidentModal(true)}
              className="btn-outline w-full text-red-600 border-red-200 hover:border-red-300"
            >
              <ShieldAlert className="w-4 h-4" />
              Reportar incidente / accidente
            </button>
          </>
        )}

      </div>

      {/* Modal de confirmación de cancelación */}
      {showCancelConfirm && (
        <div className="fixed inset-0 bg-black/40 z-50 flex items-center justify-center p-4">
          <div className="bg-white rounded-2xl p-6 max-w-sm w-full">
            <div className="flex items-center gap-3 mb-4">
              <div className="w-10 h-10 bg-red-50 rounded-full flex items-center justify-center">
                <AlertTriangle className="w-5 h-5 text-red-600" />
              </div>
              <h2 className="text-lg font-bold text-surface-800">¿Cancelar viaje?</h2>
            </div>

            {cancellationEstimate && cancellationEstimate.fee > 0 ? (
              <div className="space-y-3 mb-4">
                <p className="text-sm text-surface-600">
                  Al cancelar en este estado se aplicará una tarifa de cancelación:
                </p>
                <div className="bg-red-50 border border-red-200 rounded-xl p-4 space-y-2">
                  <div className="flex justify-between text-sm">
                    <span className="text-surface-600">Tarifa de cancelación</span>
                    <span className="font-bold text-red-600">${cancellationEstimate.fee.toFixed(2)}$</span>
                  </div>
                  <div className="flex justify-between text-sm">
                    <span className="text-surface-600">Compensación al conductor</span>
                    <span className="font-medium text-surface-700">${cancellationEstimate.compensation.toFixed(2)}$</span>
                  </div>
                  {cancellationEstimate.refund > 0 && (
                    <div className="flex justify-between text-sm">
                      <span className="text-surface-600">Reembolso estimado</span>
                      <span className="font-medium text-emerald-600">${cancellationEstimate.refund.toFixed(2)}$</span>
                    </div>
                  )}
                </div>
                <p className="text-xs text-surface-400">
                  La tarifa se cobra porque el conductor ya se desplazó hacia ti o el viaje ya está en curso.
                </p>
              </div>
            ) : (
              <p className="text-sm text-surface-600 mb-4">
                ¿Estás seguro de que deseas cancelar este viaje?
              </p>
            )}

            <div className="flex gap-3">
              <button
                onClick={() => setShowCancelConfirm(false)}
                className="btn-outline flex-1"
              >
                Volver
              </button>
              <button
                onClick={handleCancelRide}
                className="btn-danger flex-1"
                disabled={loading}
              >
                {loading ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Sí, cancelar'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Modal de reporte de incidente / disputa */}
      {showIncidentModal && (
        <div className="fixed inset-0 bg-black/40 z-50 flex items-center justify-center p-4">
          <div className="bg-white rounded-2xl p-6 max-w-md w-full max-h-[90vh] overflow-y-auto">
            <div className="flex items-center gap-3 mb-4">
              <div className="w-10 h-10 bg-red-50 rounded-full flex items-center justify-center">
                <ShieldAlert className="w-5 h-5 text-red-600" />
              </div>
              <div>
                <h2 className="text-lg font-bold text-surface-800">
                  {isDispute ? 'Reportar un problema' : 'Reportar incidente'}
                </h2>
                <p className="text-xs text-surface-500">La plataforma revisará tu reporte</p>
              </div>
            </div>

            <div className="space-y-3 mb-4">
              <div>
                <label className="label">{isDispute ? 'Motivo *' : 'Tipo de incidente *'}</label>
                <div className="space-y-2">
                  {reportTypes.map((type) => (
                    <button
                      key={type.value}
                      type="button"
                      onClick={() => setIncidentType(type.value)}
                      className={`w-full p-3 rounded-xl border-2 text-left transition-all ${
                        incidentType === type.value
                          ? 'border-red-500 bg-red-50'
                          : 'border-surface-200 hover:border-surface-300'
                      }`}
                    >
                      <span className="text-sm font-medium text-surface-700">
                        {type.emoji} {type.label}
                      </span>
                    </button>
                  ))}
                </div>
              </div>

              <div>
                <label className="label">Descripción</label>
                <textarea
                  className="input min-h-[80px]"
                  placeholder="Describe brevemente lo que ocurrió..."
                  value={incidentDesc}
                  onChange={(e) => setIncidentDesc(e.target.value)}
                />
              </div>

              <div>
                <label className="label">Foto (opcional)</label>
                <label className="flex flex-col items-center justify-center w-full h-20 border-2 border-dashed border-surface-200 rounded-xl cursor-pointer hover:border-red-300 transition-colors">
                  {incidentPhoto ? (
                    <div className="text-center">
                      <Upload className="w-5 h-5 text-emerald-600 mx-auto mb-1" />
                      <span className="text-xs text-surface-600 truncate max-w-[220px] block">{incidentPhoto.name}</span>
                    </div>
                  ) : (
                    <div className="text-center">
                      <Upload className="w-5 h-5 text-surface-400 mx-auto mb-1" />
                      <span className="text-xs text-surface-500">Toca para subir una foto</span>
                    </div>
                  )}
                  <input
                    type="file"
                    accept="image/*"
                    className="hidden"
                    onChange={(e) => setIncidentPhoto(e.target.files?.[0] || null)}
                  />
                </label>
              </div>

              <div className={`rounded-xl p-3 ${isDispute ? 'bg-amber-50 border border-amber-200' : 'bg-amber-50 border border-amber-200'}`}>
                <p className="text-xs text-amber-700">
                  {isDispute
                    ? 'Tu reporte será revisado por un administrador. Si el viaje no se realizó o el cobro no corresponde, se te reembolsará el monto pagado.'
                    : 'Al reportar un incidente, el viaje se pausa y un administrador lo revisará. No se cancelará automáticamente.'}
                </p>
              </div>
            </div>

            <div className="flex gap-3">
              <button
                onClick={() => setShowIncidentModal(false)}
                className="btn-outline flex-1"
              >
                Volver
              </button>
              <button
                onClick={handleReportIncident}
                className="btn-danger flex-1"
                disabled={loading}
              >
                {loading ? <Loader2 className="w-4 h-4 animate-spin" /> : (isDispute ? 'Enviar reporte' : 'Reportar')}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}