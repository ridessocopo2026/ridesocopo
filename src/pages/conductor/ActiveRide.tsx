import { useState, useEffect } from 'react'
import { useParams, useNavigate } from 'react-router-dom'
import { MapContainer, TileLayer, Marker, Polyline, Popup } from 'react-leaflet'
import L from 'leaflet'
import { Navigation, XCircle, Loader2, Hexagon, CheckCircle, AlertCircle, ShieldAlert, Upload, AlertTriangle } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { RatingCard } from '@/components/ui/RatingCard'
import type { Ride, CancellationEstimate, IncidentType } from '@/types/database'

// Iconos personalizados
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

const clientIcon = L.divIcon({
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

export function ActiveRide() {
  const { rideId } = useParams()
  const [ride, setRide] = useState<Ride | null>(null)
  const trackingBadge = ride?.tracking_code ? (
    <span className="font-mono text-xs font-bold text-primary-600 bg-primary-50 rounded-lg px-2 py-1">
      {ride.tracking_code}
    </span>
  ) : null
  const [clientName, setClientName] = useState('')
  const [vehiclePos, setVehiclePos] = useState<[number, number] | null>(null)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)
  const [cancellationEstimate, setCancellationEstimate] = useState<CancellationEstimate | null>(null)
  const [showCancelConfirm, setShowCancelConfirm] = useState(false)
  const [showIncidentModal, setShowIncidentModal] = useState(false)
  const [incidentType, setIncidentType] = useState<IncidentType>('accidente')
  const [incidentDesc, setIncidentDesc] = useState('')
  const [incidentPhoto, setIncidentPhoto] = useState<File | null>(null)
  const { user } = useAuth()
  const navigate = useNavigate()

  useEffect(() => {
    if (rideId) {
      loadRide()
      // Suscribirse a cambios en tiempo real
      const subscription = supabase
        .channel(`ride-${rideId}`)
        .on('postgres_changes', {
          event: 'UPDATE',
          schema: 'public',
          table: 'rides',
          filter: `id=eq.${rideId}`
        }, (payload) => {
          setRide(payload.new as Ride)
        })
        .subscribe()

      return () => {
        supabase.removeChannel(subscription)
      }
    }
  }, [rideId])

  const loadRide = async () => {
    const { data, error } = await supabase
      .from('rides')
      .select('*')
      .eq('id', rideId)
      .single()

    if (!error && data) {
      setRide(data as Ride)
      // Obtener nombre del cliente (solo visible durante viaje activo)
      const { data: clientData } = await supabase
        .from('profiles')
        .select('full_name')
        .eq('id', data.client_id)
        .single()

      if (clientData) {
        setClientName(clientData.full_name)
      }
    }
  }

  // Iniciar seguimiento GPS del vehículo
  useEffect(() => {
    if (!ride || ride.status === 'completada' || ride.status === 'cancelada' || ride.status === 'incidente') return

    if (!navigator.geolocation) return

    const watchId = navigator.geolocation.watchPosition(
      (position) => {
        const pos: [number, number] = [position.coords.latitude, position.coords.longitude]
        setVehiclePos(pos)

        // Enviar ubicación al servidor con throttling (solo en viaje activo)
        supabase.rpc('update_driver_location', {
          p_ride_id: rideId,
          p_lat: position.coords.latitude,
          p_lng: position.coords.longitude
        })
      },
      (err) => console.error('Error de geolocalización:', err),
      { enableHighAccuracy: true, maximumAge: 20000, timeout: 30000 }
    )

    return () => navigator.geolocation.clearWatch(watchId)
  }, [ride?.status, rideId])

  const handleConfirmStart = async () => {
    setError('')
    setLoading(true)

    try {
      const { data, error } = await supabase.rpc('confirm_ride_start', {
        p_ride_id: rideId
      })

      if (error) throw error

      // Actualizar el estado local INMEDIATAMENTE
      setRide(prev => prev ? {
        ...prev,
        driver_start_confirmed: true,
        status: data?.both_confirmed ? 'en_ruta' : prev.status,
        client_start_confirmed: data?.client_confirmed ?? prev.client_start_confirmed
      } : prev)
    } catch (err: any) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  const handleRateClient = async (rating: number, review: string) => {
    const { error } = await supabase.rpc('rate_client', {
      p_ride_id: rideId,
      p_rating: rating,
      p_review: review || null
    })
    if (error) throw error
  }

  const handleCompleteRide = async () => {
    setError('')
    setLoading(true)

    try {
      const { error } = await supabase.rpc('complete_ride', {
        p_ride_id: rideId
      })

      if (error) throw error

      navigate('/conductor')
    } catch (err: any) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  const handleCancelClick = async () => {
    const { data } = await supabase.rpc('estimate_cancellation_fee', {
      p_ride_id: rideId
    })
    if (data) {
      setCancellationEstimate(data as CancellationEstimate)
    }
    setShowCancelConfirm(true)
  }

  const handleCancelRide = async () => {
    setError('')
    setLoading(true)

    try {
      const { error } = await supabase.rpc('cancel_ride', {
        p_ride_id: rideId,
        p_reason: 'Cancelado por el conductor',
        p_at_fault: 'conductor'
      })

      if (error) throw error

      setShowCancelConfirm(false)
      navigate('/conductor')
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
      // El viaje pasa a estado 'incidente'
      if (data?.status) {
        setRide(prev => prev ? { ...prev, status: data.status, incident_id: data.incident_id } : prev)
      }
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
  const driverPos: [number, number] | null = vehiclePos || (ride.driver_location_lat && ride.driver_location_lng
    ? [ride.driver_location_lat, ride.driver_location_lng]
    : null)

  const driverConfirmed = ride.driver_start_confirmed
  const clientConfirmed = ride.client_start_confirmed
  const bothConfirmed = driverConfirmed && clientConfirmed

  const statusLabels = {
    buscando: 'Buscando conductor...',
    aceptada: 'Dirígete al cliente',
    en_ruta: 'En ruta al destino',
    completada: 'Viaje completado',
    cancelada: 'Viaje cancelado',
    incidente: 'Incidente en revisión'
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 bg-primary-600 rounded-xl flex items-center justify-center">
              <Hexagon className="w-5 h-5 text-white" />
            </div>
            <div>
              <h1 className="text-lg font-bold text-surface-800">Viaje en curso</h1>
              <p className="text-xs text-surface-500">{statusLabels[ride.status]}</p>
            </div>
          </div>
          <span className={`badge ${
            ride.status === 'aceptada' ? 'badge-warning' :
            ride.status === 'en_ruta' ? 'badge-primary' :
            ride.status === 'incidente' ? 'badge-danger' : 'badge-success'
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

      {/* Banner de incidente */}
      {ride.status === 'incidente' && (
        <div className="max-w-md mx-auto px-4 mt-4 space-y-3">
          <div className="bg-red-50 border border-red-200 rounded-xl p-4 flex items-start gap-3">
            <ShieldAlert className="w-6 h-6 text-red-600 flex-shrink-0" />
            <div>
              <h3 className="font-semibold text-red-700">Incidente reportado</h3>
              <p className="text-sm text-red-600 mt-1">
                El incidente está siendo revisado por la plataforma. Puedes seguir recibiendo viajes mientras tanto.
              </p>
            </div>
          </div>
          <button
            onClick={() => navigate('/conductor')}
            className="btn-outline w-full"
          >
            Volver al panel de viajes
          </button>
        </div>
      )}

      {/* Mapa */}
      <div className="h-[45vh] relative">
        <MapContainer
          center={origin}
          zoom={15}
          className="h-full w-full"
        >
          <TileLayer
            url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
            attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
          />
          {/* Vehículo del conductor */}
          {driverPos && (
            <Marker position={driverPos} icon={vehicleIcon}>
              <Popup>Tu vehículo</Popup>
            </Marker>
          )}
          {/* Ubicación del cliente */}
          <Marker position={origin} icon={clientIcon}>
            <Popup>Cliente</Popup>
          </Marker>
          <Marker position={destination} icon={destIcon}>
            <Popup>Destino: {ride.destination_barrio_name || ''}</Popup>
          </Marker>
          <Polyline
            positions={[origin, destination]}
            pathOptions={{ color: '#7c3aed', weight: 3, dashArray: '8, 8' }}
          />
        </MapContainer>
      </div>

      {/* Detalles del viaje */}
      <div className="max-w-md mx-auto px-4 py-6 space-y-4">
        {/* Confirmación mutua */}
        {ride.status === 'aceptada' && (
          <div className="card border-2 border-primary-100 bg-primary-50">
            <h2 className="font-semibold text-surface-800 mb-3 flex items-center gap-2">
              <AlertCircle className="w-5 h-5 text-primary-600" />
              Confirmación de inicio
            </h2>
            <p className="text-sm text-surface-600 mb-4">
              Cuando recojas al cliente, **ambos** deben confirmar que el viaje inicia.
            </p>

            <div className="space-y-2 mb-4">
              <div className="flex items-center justify-between">
                <span className="text-sm text-surface-600">Tu confirmación (Conductor)</span>
                {driverConfirmed ? (
                  <span className="badge-success flex items-center gap-1">
                    <CheckCircle className="w-3 h-3" /> Confirmado
                  </span>
                ) : (
                  <span className="badge-warning">Pendiente</span>
                )}
              </div>
              <div className="flex items-center justify-between">
                <span className="text-sm text-surface-600">Confirmación del cliente</span>
                {clientConfirmed ? (
                  <span className="badge-success flex items-center gap-1">
                    <CheckCircle className="w-3 h-3" /> Confirmado
                  </span>
                ) : (
                  <span className="badge-warning">Pendiente</span>
                )}
              </div>
            </div>

            {!driverConfirmed ? (
              <button onClick={handleConfirmStart} className="btn-success w-full" disabled={loading}>
                {loading ? <Loader2 className="w-4 h-4 animate-spin" /> : <><CheckCircle className="w-4 h-4" /> Confirmar que recogí al cliente</>}
              </button>
            ) : (
              <div className="bg-emerald-50 border border-emerald-200 rounded-lg p-3 text-center">
                <p className="text-sm text-emerald-700">
                  {bothConfirmed ? '✅ Viaje iniciado. ¡Buen viaje!' : '⏳ Esperando que el cliente confirme...'}
                </p>
              </div>
            )}
          </div>
        )}

        {/* Info cliente */}
        <div className="card">
          <div className="flex items-center justify-between mb-4">
            <div>
              <h2 className="font-semibold text-surface-800">Cliente</h2>
              <p className="text-sm text-surface-500">{clientName || 'Cargando...'}</p>
            </div>
            <div className="w-12 h-12 bg-accent-50 rounded-full flex items-center justify-center">
              <Navigation className="w-6 h-6 text-accent-600" />
            </div>
          </div>

          <div className="space-y-3">
            <div className="flex items-start gap-3">
              <div className="w-2 h-2 bg-accent-600 rounded-full mt-1.5 flex-shrink-0" />
              <div>
                <p className="text-xs text-surface-400">Origen</p>
                <p className="text-sm text-surface-700">{ride.origin_address || 'Ubicación actual'}</p>
              </div>
            </div>
            <div className="flex items-start gap-3">
              <div className="w-2 h-2 bg-primary-600 rounded-full mt-1.5 flex-shrink-0" />
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
          <div className="flex items-center justify-between mb-3">
            <div className="flex items-center gap-2">
              <span className="text-sm text-surface-500">Tarifa del viaje</span>
              {trackingBadge}
            </div>
            <span className="text-2xl font-bold text-primary-600">${ride.final_fare_usd.toFixed(2)}</span>
          </div>
          <div className="flex items-center justify-between text-sm">
            <span className="text-surface-500">Comisión de la app</span>
            <span className="text-surface-600">${ride.commission_usd.toFixed(2)}</span>
          </div>
        </div>

        {/* Calificar al cliente al completar */}
        {ride.status === 'completada' && (
          <RatingCard
            title="Califica al cliente"
            subtitle="Tu opinión ayuda a la comunidad"
            onSubmit={handleRateClient}
            alreadyRated={ride.client_rating}
            alreadyReviewed={ride.client_review}
          />
        )}

        {/* Acciones */}
        <div className="space-y-3">
          {ride.status === 'en_ruta' && (
            <button onClick={handleCompleteRide} className="btn-success w-full" disabled={loading}>
              {loading ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Completar viaje'}
            </button>
          )}

          {(ride.status === 'aceptada' || ride.status === 'en_ruta') && (
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

            {cancellationEstimate?.note ? (
              <p className="text-sm text-surface-600 mb-4">{cancellationEstimate.note}</p>
            ) : (
              <p className="text-sm text-surface-600 mb-4">
                ¿Estás seguro de que deseas cancelar este viaje? Al cancelar, puedes perder la comisión de la app.
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

      {/* Modal de reporte de incidente */}
      {showIncidentModal && (
        <div className="fixed inset-0 bg-black/40 z-50 flex items-center justify-center p-4">
          <div className="bg-white rounded-2xl p-6 max-w-md w-full max-h-[90vh] overflow-y-auto">
            <div className="flex items-center gap-3 mb-4">
              <div className="w-10 h-10 bg-red-50 rounded-full flex items-center justify-center">
                <ShieldAlert className="w-5 h-5 text-red-600" />
              </div>
              <div>
                <h2 className="text-lg font-bold text-surface-800">Reportar incidente</h2>
                <p className="text-xs text-surface-500">La plataforma revisará tu reporte</p>
              </div>
            </div>

            <div className="space-y-3 mb-4">
              <div>
                <label className="label">Tipo de incidente *</label>
                <div className="space-y-2">
                  {incidentTypes.map((type) => (
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

              <div className="bg-amber-50 border border-amber-200 rounded-xl p-3">
                <p className="text-xs text-amber-700">
                  Al reportar un incidente, el viaje se pausa y un administrador lo revisará.
                  No se cancelará automáticamente.
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
                {loading ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Reportar'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
