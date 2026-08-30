import { useState, useEffect, useRef } from 'react'
import { useNavigate } from 'react-router-dom'
import { MapContainer, TileLayer, Marker, Polyline, Popup } from 'react-leaflet'
import L from 'leaflet'
import { MapPin, Navigation, Wallet, LogOut, Loader2, Car, Map as MapIcon, X, AlertTriangle, HandCoins, Smartphone } from 'lucide-react'
import { NotificationBell } from '@/components/ui/NotificationBell'
import { PushNotificationCard } from '@/components/ui/PushNotificationCard'
import { supabase } from '@/lib/supabase'
import { fmt } from '@/lib/format'
import { useAuth } from '@/contexts/AuthContext'
import { Switch } from '@/components/ui/Switch'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { SkeletonList } from '@/components/ui/Skeleton'
import { EmptyState } from '@/components/ui/EmptyState'
import { HexUnderline } from '@/components/ui/HexUnderline'
import { useAvailableRidesPolling } from '@/lib/rideRealtime'
import type { Ride, Wallet as WalletType, Vehicle } from '@/types/database'
import { AppLogo } from '@/components/ui/AppLogo'

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

// Insignia del método de pago: el conductor debe saber si cobra en efectivo
// o si la plataforma ya cobró al pasajero digitalmente.
const paymentBadge = (method?: string) => {
  const m = (method || 'efectivo').toLowerCase()
  if (m === 'efectivo') {
    return (
      <span className="badge-warning">
        <HandCoins className="w-3 h-3" /> Efectivo · cobra tú al cliente
      </span>
    )
  }
  return (
    <span className="badge-info">
      <Smartphone className="w-3 h-3" /> {method} · la plataforma ya cobró
    </span>
  )
}

export function DriverDashboard() {
  const [isOnline, setIsOnline] = useState(false)
  const [wallet, setWallet] = useState<WalletType | null>(null)
  const [availableRides, setAvailableRides] = useState<Ride[]>([])
  const [activeRide, setActiveRide] = useState<Ride | null>(null)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)
  const [showRideAlert, setShowRideAlert] = useState(false)
  const [mapRide, setMapRide] = useState<Ride | null>(null)
  const { user, signOut } = useAuth()
  const navigate = useNavigate()
  const watchIdRef = useRef<number | null>(null)

  const [activeVehicle, setActiveVehicle] = useState<Vehicle | null>(null)

  useEffect(() => {
    loadWallet()
    checkActiveRide()
    // Vehículo activo para mostrar en Disponibilidad
    const loadVehicle = async () => {
      if (!user) return
      const { data } = await supabase.rpc('get_driver_vehicles')
      const veh = Array.isArray(data) ? data.find((x: Vehicle) => x.is_active_vehicle) : null
      if (veh) setActiveVehicle(veh as Vehicle)
    }
    // Cargar el estado REAL de disponibilidad del perfil
    const loadOnlineState = async () => {
      if (!user) return
      const { data } = await supabase
        .from('profiles')
        .select('is_online')
        .eq('id', user.id)
        .maybeSingle()
      if (data) setIsOnline(data.is_online)
    }
    loadVehicle()
    loadOnlineState()
  }, [user?.id])

  useEffect(() => {
    if (isOnline) {
      loadAvailableRides()
      startLocationTracking()
    } else {
      stopLocationTracking()
    }
  }, [isOnline])

  // Aviso de error SIEMPRE visible sin scroll: llevar atención al banner
  useEffect(() => {
    if (error) {
      const t = setTimeout(() => {
        document.getElementById('driver-error-banner')?.scrollIntoView({ behavior: 'smooth', block: 'center' })
      }, 100)
      return () => clearTimeout(t)
    }
  }, [error])

  const loadWallet = async () => {
    if (!user) return
    const { data, error } = await supabase
      .from('wallets')
      .select('*')
      .eq('user_id', user.id)
      .single()

    if (!error && data) {
      setWallet(data as WalletType)
    }
  }

  const checkActiveRide = async () => {
    const { data, error } = await supabase.rpc('get_driver_active_ride')
    if (!error && data && data.length > 0) {
      setActiveRide(data[0] as Ride)
    }
  }

  const loadAvailableRides = async () => {
    try {
      const { data, error } = await supabase.rpc('get_available_rides')
      if (!error && data) {
        setAvailableRides(data as Ride[])
      }
    } catch (err: any) {
      setError(err.message)
    }
  }

  // Polling ligero cada 6s de viajes disponibles (tiempo real barato)
  useAvailableRidesPolling(isOnline, loadAvailableRides)

  const startLocationTracking = () => {
    if (!navigator.geolocation) return

    watchIdRef.current = navigator.geolocation.watchPosition(
      (position) => {
        // Solo transmitir si hay viaje activo
        if (activeRide) {
          supabase.rpc('update_driver_location', {
            p_ride_id: activeRide.id,
            p_lat: position.coords.latitude,
            p_lng: position.coords.longitude
          })
        }
      },
      (err) => console.error('Error de geolocalización:', err),
      { enableHighAccuracy: true, maximumAge: 20000, timeout: 30000 }
    )
  }

  const stopLocationTracking = () => {
    if (watchIdRef.current !== null) {
      navigator.geolocation.clearWatch(watchIdRef.current)
      watchIdRef.current = null
    }
  }

  const handleToggleOnline = async (checked: boolean) => {
    setError('')
    setLoading(true)

    try {
      const { data, error } = await supabase.rpc('toggle_driver_online', { p_online: checked })

      if (error) throw error

      if (data?.success) {
        setIsOnline(checked)
      } else if (data?.error) {
        setError(data.message || 'Error al cambiar estado')
      }
    } catch (err: any) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  const handleAcceptRide = async (rideId: string) => {
    setError('')
    setLoading(true)

    try {
      const { data, error } = await supabase.rpc('accept_ride', { p_ride_id: rideId })

      if (error) throw error

      if (data?.success) {
        setShowRideAlert(false)
        setActiveRide(data.ride_id)
        navigate(`/conductor/viaje/${data.ride_id}`)
      } else if (data?.error === 'SALDO_INSUFICIENTE' || data?.error === 'DEUDA_EXCEDIDA') {
        setError(data.message)
        setShowRideAlert(false)
      } else if (!data?.success) {
        // El viaje ya no está disponible: otro conductor lo tomó
        setAvailableRides((prev) => prev.filter((r) => r.id !== rideId))
        setError('⚠️ Otro conductor ya tomó este viaje. Buscando otros disponibles...')
        setShowRideAlert(false)
      }
    } catch (err: any) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  const handleSignOut = async () => {
    await signOut()
    navigate('/login')
  }

  // Deuda que supera el límite permitido (bloqueo real en toggle_driver_online / accept_ride)
  const debtExceeded = !!wallet && wallet.balance_usd < -wallet.debt_limit_usd

  // Si hay viaje activo, redirigir
  if (activeRide) {
    navigate(`/conductor/viaje/${activeRide.id}`)
    return null
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      {/* Header */}
      <div className="bg-primary-600 border-b border-primary-700 px-6 py-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <AppLogo variant="dark" />
            <div>
              <h1 className="text-lg font-bold text-white">Panel del Conductor</h1>
              <p className="text-xs text-white/80">Hola, {user?.full_name?.split(' ')[0]}</p>
            </div>
          </div>
          <div className="flex items-center gap-1">
            <NotificationBell className="p-2 text-white hover:text-white/70 transition-colors" />
            <button onClick={handleSignOut} className="p-2 text-white/80 hover:text-white transition-colors">
              <LogOut className="w-5 h-5" />
            </button>
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6 space-y-6">
        {error && <ErrorMessage id="driver-error-banner" message={error} onDismiss={() => setError('')} />}

        {/* Activar notificaciones push (si no están activas) */}
        <PushNotificationCard />

        {/* Estado en línea */}
        <div className="card">
          <div className="flex items-center justify-between">
            <div>
              <h2 className="font-semibold text-surface-800">Disponibilidad</h2>
              <p className="text-sm text-surface-500 mt-1">
                {isOnline ? 'Recibiendo solicitudes' : 'Desconectado'}
              </p>
            </div>
            <Switch
              checked={isOnline}
              onChange={handleToggleOnline}
              disabled={loading || user?.driver_status !== 'aprobado'}
              label="Disponible"
            />
          </div>

          {user?.driver_status !== 'aprobado' && (
            <div className="mt-4 bg-amber-50 border border-amber-200 rounded-lg p-3">
              <p className="text-xs text-amber-700">
                Tu cuenta está en revisión. El switch estará disponible cuando un administrador te apruebe.
              </p>
            </div>
          )}
          {activeVehicle && (
            <div className="mt-4 bg-surface-50 rounded-lg p-3 flex items-center gap-2">
              <Car className="w-4 h-4 text-primary-600" />
              <span className="text-xs text-surface-600">
                <strong>Vehículo activo:</strong> {activeVehicle.brand} {activeVehicle.model} ({activeVehicle.category}) • {activeVehicle.plate}
              </span>
            </div>
          )}
        </div>

        {/* Billetera */}
        <div className={`card ${wallet && wallet.balance_usd < 0 ? 'bg-gradient-to-br from-red-600 to-red-800' : 'bg-gradient-to-br from-primary-600 to-primary-800'} text-white border-0`}>
          <div className="flex items-center justify-between mb-4">
            <div className="flex items-center gap-2">
              <Wallet className="w-5 h-5" />
              <span className="text-sm font-medium">{wallet && wallet.balance_usd < 0 ? 'Deuda' : 'Billetera'}</span>
            </div>
            <span className="text-xs bg-white/20 rounded-full px-3 py-1">Comisión 10%</span>
          </div>
          <p className="text-3xl font-bold">{wallet?.balance_usd?.toFixed(2) || '0.00'}$</p>
          <p className="text-sm text-white/70 mt-1">
            {wallet && wallet.balance_usd < 0 ? 'Debes esta cantidad a la plataforma' : 'Tu comisión se descuenta de la carrera'}
          </p>
        </div>

        {/* Aviso de deuda superada — visible sin scroll, junto a la billetera */}
        {debtExceeded && (
          <div className="bg-red-50 border-2 border-red-200 rounded-xl p-4 flex items-start gap-3 animate-fade-in" role="alert">
            <AlertTriangle className="w-5 h-5 text-red-600 flex-shrink-0 mt-0.5" />
            <div className="flex-1">
              <p className="text-sm font-medium text-red-700">Límite de deuda superado</p>
              <p className="text-xs text-red-600 mt-0.5">
                Tu deuda es de {fmt(Math.abs(wallet?.balance_usd ?? 0))} y el límite es {fmt(wallet?.debt_limit_usd ?? 0)}.
                Recarga tu billetera o contacta al administrador para poder aceptar viajes.
              </p>
            </div>
          </div>
        )}

        {/* Viajes disponibles */}
        <div>
          <h2 className="text-lg font-semibold text-surface-800 mb-3">Viajes disponibles</h2>
          <HexUnderline />

          {loading ? (
            <SkeletonList count={2} />
          ) : availableRides.length === 0 ? (
            <EmptyState
              icon={<Car className="w-8 h-8" />}
              title="Sin viajes disponibles"
              description={isOnline ? 'Esperando solicitudes de pasajeros...' : 'Activa tu disponibilidad para recibir solicitudes'}
            />
          ) : (
            <div className="space-y-3">
              {availableRides.map((ride) => (
                <div key={ride.id} className="card card-hover">
                  <div className="flex items-start justify-between mb-3">
                    <div>
                      <span className="badge-primary">{ride.category}</span>
                      <p className="text-sm text-surface-500 mt-2">
                        {ride.origin_address || 'Origen no especificado'}
                      </p>
                    </div>
                    <div className="text-right">
                      <span className="text-lg font-bold text-primary-600">
                        {ride.final_fare_usd.toFixed(2)}$
                      </span>
                      <div className="mt-1 flex justify-end">{paymentBadge(ride.payment_method)}</div>
                    </div>
                  </div>

                  <div className="flex items-center gap-2 text-sm text-surface-500 mb-3">
                    <Navigation className="w-4 h-4 text-accent-600" />
                    <span className="truncate">{ride.destination_address || 'Destino no especificado'}</span>
                  </div>
                  {ride.destination_barrio_name && (
                    <span className="badge-primary mb-3">{ride.destination_barrio_name}</span>
                  )}

                  <div className="flex gap-2">
                    <button
                      onClick={() => setMapRide(ride)}
                      className="btn-outline flex-1"
                    >
                      <MapIcon className="w-4 h-4" />
                      Ver mapa
                    </button>
                    <button
                      onClick={() => handleAcceptRide(ride.id)}
                      className="btn-primary flex-1"
                      disabled={loading}
                    >
                      {loading ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Aceptar viaje'}
                    </button>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      {/* Modal de mapa */}
      {mapRide && (
        <div className="fixed inset-0 bg-black/40 z-50 flex items-end justify-center" onClick={() => setMapRide(null)}>
          <div className="bottom-sheet max-w-md w-full" onClick={(e) => e.stopPropagation()}>
            <div className="bottom-sheet-handle" />
            <div className="flex items-center justify-between mb-4">
              <h2 className="text-xl font-bold text-surface-800">Ubicación del cliente</h2>
              <button onClick={() => setMapRide(null)} className="p-2 text-surface-400 hover:text-surface-600">
                <X className="w-5 h-5" />
              </button>
            </div>

            <div className="h-64 rounded-2xl overflow-hidden shadow-card mb-4">
              <MapContainer
                center={[mapRide.origin_lat, mapRide.origin_lng]}
                zoom={15}
                className="h-full w-full"
              >
                <TileLayer
                  url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
                  attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
                />
                <Marker position={[mapRide.origin_lat, mapRide.origin_lng]} icon={clientIcon}>
                  <Popup>Cliente</Popup>
                </Marker>
                <Marker position={[mapRide.destination_lat, mapRide.destination_lng]} icon={destIcon}>
                  <Popup>{mapRide.destination_barrio_name || 'Destino'}</Popup>
                </Marker>
                <Polyline
                  positions={[[mapRide.origin_lat, mapRide.origin_lng], [mapRide.destination_lat, mapRide.destination_lng]]}
                  pathOptions={{ color: '#7c3aed', weight: 3, dashArray: '8, 8' }}
                />
              </MapContainer>
            </div>

            <div className="space-y-2 mb-4">
              <div className="flex items-start gap-2">
                <div className="w-2 h-2 bg-accent-600 rounded-full mt-1.5 flex-shrink-0" />
                <div>
                  <p className="text-xs text-surface-400">Origen (Cliente)</p>
                  <p className="text-sm text-surface-700">{mapRide.origin_address || 'Ubicación GPS'}</p>
                </div>
              </div>
              <div className="flex items-start gap-2">
                <div className="w-2 h-2 bg-red-500 rounded-full mt-1.5 flex-shrink-0" />
                <div>
                  <p className="text-xs text-surface-400">Destino</p>
                  <p className="text-sm text-surface-700">{mapRide.destination_address || 'Destino'}</p>
                  {mapRide.destination_barrio_name && (
                    <span className="badge-primary mt-1">{mapRide.destination_barrio_name}</span>
                  )}
                </div>
              </div>

              <div className="flex items-center justify-between bg-surface-50 rounded-lg p-2">
                <span className="text-xs text-surface-400">Método de pago</span>
                {paymentBadge(mapRide.payment_method)}
              </div>
            </div>

            {/* Aviso de error del viaje aquí mismo (saldo/deuda insuficiente) — sin scroll */}
            {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

            <div className="flex gap-2">
              <button onClick={() => setMapRide(null)} className="btn-outline flex-1">
                Cerrar
              </button>
              <button
                onClick={() => { setMapRide(null); handleAcceptRide(mapRide.id) }}
                className="btn-primary flex-1"
                disabled={loading}
              >
                {loading ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Aceptar viaje'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
