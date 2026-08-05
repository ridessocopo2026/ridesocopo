import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { MapContainer, TileLayer, Marker, useMapEvents, useMap } from 'react-leaflet'
import L from 'leaflet'
import { Navigation, Star, Bike, Car, Truck, Loader2, MapPin, Search, CheckCircle, ChevronDown, Copy, Upload, Check } from 'lucide-react'
import { NotificationBell } from '@/components/ui/NotificationBell'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import type { Banner, FavoritePlace, VehicleCategory, VehicleCategoryType, FareCalculation, Barrio, PaymentMethodConfig, PaymentMethodField } from '@/types/database'

const SOCOPO_CENTER: [number, number] = [8.23293, -70.82228]

const userIcon = L.divIcon({
  className: 'custom-div-icon',
  html: `<div class="w-8 h-8 bg-accent-600 rounded-full border-4 border-white shadow-lg flex items-center justify-center">
    <svg class="w-4 h-4 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17.657 16.657L13.414 20.9a1.998 1.998 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z"/>
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 11a3 3 0 11-6 0 3 3 0 016 0z"/>
    </svg>
  </div>`,
  iconSize: [32, 32],
  iconAnchor: [16, 32]
})

function MapClickHandler({ onSelect }: { onSelect: (lat: number, lng: number) => void }) {
  useMapEvents({
    click(e) {
      onSelect(e.latlng.lat, e.latlng.lng)
    }
  })
  return null
}

// Controlador para centrar/animar el mapa hacia la ubicación del usuario
function MapCenterController({ target }: { target: { lat: number; lng: number } | null }) {
  const map = useMap()

  useEffect(() => {
    if (target) {
      map.flyTo([target.lat, target.lng], 16, { duration: 1.5 })
    }
  }, [target?.lat, target?.lng])

  return null
}

export function ClientHome() {
  const [origin, setOrigin] = useState<{ lat: number; lng: number } | null>(null)
  const [inCoverage, setInCoverage] = useState(false)
  const [originAddress, setOriginAddress] = useState('')
  const [destBarrioId, setDestBarrioId] = useState('')
  const [destAddress, setDestAddress] = useState('')
  const [selectedCategory, setSelectedCategory] = useState<VehicleCategoryType | null>(null)
  const [categories, setCategories] = useState<VehicleCategory[]>([])
  const [barrios, setBarrios] = useState<Barrio[]>([])
  const [favorites, setFavorites] = useState<FavoritePlace[]>([])
  const [banners, setBanners] = useState<Banner[]>([])
  const [fare, setFare] = useState<FareCalculation | null>(null)
  const [couponCode, setCouponCode] = useState('')
  const [hasActiveCoupons, setHasActiveCoupons] = useState(false)
  const [exchangeRate, setExchangeRate] = useState(0)
  const [paymentMethods, setPaymentMethods] = useState<PaymentMethodConfig[]>([])
  const [selectedPaymentMethod, setSelectedPaymentMethod] = useState('')
  const [methodFields, setMethodFields] = useState<Record<string, PaymentMethodField[]>>({})
  const [proofFile, setProofFile] = useState<File | null>(null)
  const [copiedField, setCopiedField] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)
  const [gpsLoading, setGpsLoading] = useState(false)
  const [showFareSheet, setShowFareSheet] = useState(false)
  // Estado del bottom sheet de destino (una sola interacción)
  const [showDestSheet, setShowDestSheet] = useState(false)
  const [sheetBarrioId, setSheetBarrioId] = useState('')
  const [sheetAddress, setSheetAddress] = useState('')
  const { user } = useAuth()
  const navigate = useNavigate()

  useEffect(() => {
    loadCategories()
    loadBarrios()
    loadFavorites()
    loadBanners()
    loadPaymentMethods()
    loadCoupons()
    loadExchangeRate()
  }, [])

  const loadCoupons = async () => {
    const { data } = await supabase
      .from('coupons')
      .select('id')
      .eq('is_active', true)
      .limit(1)
    setHasActiveCoupons(!!(data && data.length > 0))
  }

  const loadExchangeRate = async () => {
    const { data } = await supabase.rpc('get_active_exchange_rate')
    if (data && Number(data) > 0) {
      setExchangeRate(Number(data))
    }
  }

  const loadCategories = async () => {
    const { data, error } = await supabase
      .from('vehicle_categories')
      .select('*')
      .eq('is_active', true)
      .order('base_fare_usd')

    if (!error && data) {
      setCategories(data as VehicleCategory[])
    }
  }

  const loadBarrios = async () => {
    const { data, error } = await supabase
      .from('barrios')
      .select('*')
      .eq('is_active', true)
      .order('name')

    if (!error && data) {
      setBarrios(data as Barrio[])
    }
  }

  const loadFavorites = async () => {
    if (!user) return
    const { data, error } = await supabase
      .from('favorite_places')
      .select('*')
      .eq('user_id', user.id)
      .order('created_at', { ascending: false })
      .limit(5)

    if (!error && data) {
      setFavorites(data as FavoritePlace[])
    }
  }

  const loadPaymentMethods = async () => {
    const { data, error } = await supabase.rpc('get_active_payment_methods')
    if (!error && data) {
      const methods = data as PaymentMethodConfig[]
      setPaymentMethods(methods)
      if (methods.length > 0) {
        setSelectedPaymentMethod(methods[0].name)
        loadFieldsForAll(methods)
      }
    }
  }

  const loadFieldsForAll = async (methods: PaymentMethodConfig[]) => {
    const map: Record<string, PaymentMethodField[]> = {}
    for (const m of methods) {
      const { data: fields } = await supabase
        .from('payment_method_fields')
        .select('*')
        .eq('payment_method_id', m.id)
      if (fields) {
        map[m.id] = fields as PaymentMethodField[]
      }
    }
    setMethodFields(map)
  }

  const handleCopyField = async (value: string) => {
    try {
      await navigator.clipboard.writeText(value)
      setCopiedField(value)
      setTimeout(() => setCopiedField(''), 2000)
    } catch {
      // Fallback
      const el = document.createElement('textarea')
      el.value = value
      document.body.appendChild(el)
      el.select()
      document.execCommand('copy')
      document.body.removeChild(el)
      setCopiedField(value)
      setTimeout(() => setCopiedField(''), 2000)
    }
  }

  const loadBanners = async () => {
    const { data, error } = await supabase
      .from('banners')
      .select('*')
      .eq('is_active', true)
      .order('sort_order')

    if (!error && data) {
      setBanners(data as Banner[])
    }
  }

  const checkCoverage = async (lat: number, lng: number): Promise<boolean> => {
    try {
      const { data, error } = await supabase.rpc('calculate_fare', {
        p_origin_lat: lat,
        p_origin_lng: lng,
        p_dest_lat: lat,
        p_dest_lng: lng,
        p_category: 'moto'
      })

      if (error) {
        return !error.message.includes('fuera del área')
      }

      return data?.in_coverage !== false
    } catch {
      return true
    }
  }

  const getCurrentLocation = () => {
    if (!navigator.geolocation) {
      setError('Tu dispositivo no soporta geolocalización')
      return
    }

    setGpsLoading(true)
    setError('')

    navigator.geolocation.getCurrentPosition(
      async (position) => {
        const { latitude, longitude } = position.coords
        setOrigin({ lat: latitude, lng: longitude })
        setGpsLoading(false)

        const address = await reverseGeocode(latitude, longitude)
        setOriginAddress(address)

        const coverage = await checkCoverage(latitude, longitude)
        setInCoverage(coverage)

        if (!coverage) {
          setError('Tu ubicación está fuera del área de cobertura de Socopó. No puedes solicitar un viaje.')
        } else {
          setError('')
        }
      },
      () => {
        setError('No se pudo obtener tu ubicación. Activa el GPS y permite el acceso a tu ubicación.')
        setGpsLoading(false)
      },
      { enableHighAccuracy: true, timeout: 15000 }
    )
  }

  const reverseGeocode = async (lat: number, lng: number): Promise<string> => {
    try {
      const response = await fetch(
        `https://nominatim.openstreetmap.org/reverse?format=json&lat=${lat}&lon=${lng}&accept-language=es`
      )
      const data = await response.json()
      const parts = data.display_name?.split(',')
      if (parts && parts.length > 1) {
        return `${parts[0]}, ${parts[1]}`.trim()
      }
      return data.display_name || 'Ubicación actual'
    } catch {
      return 'Ubicación actual'
    }
  }

  const handleSelectDestOnMap = async (lat: number, lng: number) => {
    if (!destBarrioId) {
      setError('Primero selecciona el sitio de llegada')
      return
    }

    const address = await reverseGeocode(lat, lng)
    setDestAddress(address)
  }

  const handleSelectFavorite = async (fav: FavoritePlace) => {
    setDestAddress(fav.address || fav.name)
    try {
      const { data, error } = await supabase.rpc('get_nearest_barrio', {
        p_lat: fav.lat,
        p_lng: fav.lng
      })

      if (!error && data?.found) {
        setDestBarrioId(data.id)
      }
    } catch {
      // Usuario selecciona manualmente
    }
  }

  const handleCalculateFare = async () => {
    if (!origin) {
      setError('Primero debes usar tu ubicación actual con GPS')
      return
    }

    if (!inCoverage) {
      setError('Tu ubicación está fuera del área de cobertura de Socopó')
      return
    }

    if (!destBarrioId) {
      setError('Selecciona el sitio de llegada')
      return
    }

    if (!destAddress) {
      setError('Escribe la dirección de destino')
      return
    }

    if (!selectedCategory) {
      setError('Selecciona el tipo de vehículo')
      return
    }

    setError('')
    setLoading(true)

    try {
      const barrio = barrios.find((b) => b.id === destBarrioId)
      if (!barrio?.lat || !barrio?.lng) {
        throw new Error('El sitio seleccionado no tiene ubicación configurada')
      }

      const { data, error } = await supabase.rpc('calculate_fare', {
        p_origin_lat: origin.lat,
        p_origin_lng: origin.lng,
        p_dest_lat: barrio.lat,
        p_dest_lng: barrio.lng,
        p_category: selectedCategory,
        p_coupon_code: couponCode || null
      })

      if (error) throw error

      setFare(data as FareCalculation)
      setShowFareSheet(true)
    } catch (err: any) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  const getSelectedMethod = () => {
    return paymentMethods.find((m) => m.name === selectedPaymentMethod)
  }

  const getSelectedMethodFields = () => {
    const method = getSelectedMethod()
    return method ? (methodFields[method.id] || []) : []
  }

  const handleRequestRide = async () => {
    if (!origin || !destBarrioId || !selectedCategory || !selectedPaymentMethod) return

    if (!user) {
      setError('Debes iniciar sesión para solicitar un viaje')
      return
    }

    setError('')
    setLoading(true)

    try {
      const barrio = barrios.find((b) => b.id === destBarrioId)
      if (!barrio?.lat || !barrio?.lng) {
        throw new Error('El sitio seleccionado no tiene ubicación configurada')
      }

      const method = getSelectedMethod()
      const requiresProof = method?.proof_required

      // Si el método requiere comprobante, subir el archivo y usar RPC con proof
      if (requiresProof) {
        if (!proofFile) {
          throw new Error('Debes subir el comprobante del pago')
        }
        // Subir a Supabase Storage bucket payments
        const { data: uploadData, error: uploadError } = await supabase.storage
          .from('payments')
          .upload(`${user.id}/proofs/${Date.now()}-${proofFile.name}`, proofFile, { upsert: true })
        if (uploadError) throw uploadError

        // Guardar la ruta del archivo (el bucket es privado; se resuelve con URL firmada al visualizar)
        const publicUrl = uploadData.path

        const { data, error } = await supabase.rpc('request_ride_with_proof', {
          p_origin_lat: origin.lat,
          p_origin_lng: origin.lng,
          p_origin_address: originAddress,
          p_dest_lat: barrio.lat,
          p_dest_lng: barrio.lng,
          p_dest_address: destAddress,
          p_category: selectedCategory,
          p_payment_method: selectedPaymentMethod,
          p_proof_url: publicUrl,
          p_coupon_code: couponCode || null
        })
        if (error) throw error
        navigate(`/cliente/viaje/${data}`)
      } else {
        // Método efectivo u otro sin comprobante
        const { data, error } = await supabase.rpc('request_ride', {
          p_origin_lat: origin.lat,
          p_origin_lng: origin.lng,
          p_origin_address: originAddress,
          p_dest_lat: barrio.lat,
          p_dest_lng: barrio.lng,
          p_dest_address: destAddress,
          p_category: selectedCategory,
          p_payment_method: selectedPaymentMethod,
          p_coupon_code: couponCode || null
        })
        if (error) throw error
        navigate(`/cliente/viaje/${data}`)
      }
    } catch (err: any) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }

  const categoryIcons = {
    moto: <Bike className="w-6 h-6" />,
    carro: <Car className="w-6 h-6" />,
    camioneta: <Truck className="w-6 h-6" />
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 bg-primary-600 rounded-xl flex items-center justify-center">
              <MapPin className="w-5 h-5 text-white" />
            </div>
            <div>
              <h1 className="text-lg font-bold text-surface-800">RideSocopó</h1>
              <p className="text-xs text-surface-500">Hola, {user?.full_name?.split(' ')[0]}</p>
            </div>
          </div>
          <NotificationBell />
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-4 space-y-4">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        {banners.length > 0 && (
          <div className="overflow-x-auto -mx-4 px-4">
            <div className="flex gap-3">
              {banners.map((banner) => (
                <div key={banner.id} className="flex-shrink-0 w-64 bg-gradient-to-br from-primary-600 to-accent-600 rounded-2xl p-4 text-white shadow-card">
                  <h3 className="font-semibold">{banner.title}</h3>
                  {banner.subtitle && <p className="text-sm text-white/80 mt-1">{banner.subtitle}</p>}
                </div>
              ))}
            </div>
          </div>
        )}

        {/* Título principal */}
        <h2 className="text-center text-2xl font-bold text-surface-800 pt-2">Iniciar un viaje</h2>

        {/* ¿A dónde te diriges? — una sola interacción */}
        <div className="card space-y-3">
          <h2 className="font-semibold text-surface-800 text-lg">¿A dónde te diriges?</h2>

          {destBarrioId && destAddress ? (
            <button
              onClick={() => { setSheetBarrioId(destBarrioId); setSheetAddress(destAddress); setShowDestSheet(true) }}
              className="w-full text-left card-hover flex items-center gap-3"
            >
              <div className="w-10 h-10 bg-primary-50 rounded-xl flex items-center justify-center text-primary-600">
                <MapPin className="w-5 h-5" />
              </div>
              <div className="flex-1 min-w-0">
                <p className="text-sm font-semibold text-surface-800">
                  {barrios.find((b) => b.id === destBarrioId)?.name || 'Destino'} ({barrios.find((b) => b.id === destBarrioId)?.surcharge_usd.toFixed(2)}$)
                </p>
                <p className="text-xs text-surface-500 truncate">{destAddress}</p>
              </div>
              <span className="text-xs font-medium text-primary-600">Cambiar</span>
            </button>
          ) : (
            <button
              onClick={() => { setSheetBarrioId(''); setSheetAddress(''); setShowDestSheet(true) }}
              className="btn-outline w-full"
            >
              <MapPin className="w-4 h-4" />
              Seleccionar destino
            </button>
          )}
        </div>

        {/* ¿Dónde estás? */}
        <h2 className="font-semibold text-surface-800 text-lg pt-1">¿Dónde estás?</h2>

        {/* Botón compacto de ubicación */}
        <button
          onClick={getCurrentLocation}
          disabled={gpsLoading}
          className={`${origin ? 'btn-outline' : 'btn-primary'} w-full justify-center`}
        >
          {gpsLoading ? (
            <Loader2 className="w-5 h-5 animate-spin" />
          ) : origin ? (
            <CheckCircle className="w-5 h-5 text-emerald-600" />
          ) : (
            <Navigation className="w-5 h-5" />
          )}
          <span>{origin ? 'Ubicación actualizada' : 'Añadir mi ubicación actual'}</span>
        </button>

        {origin && (
          <div className={`flex items-center gap-2 px-3 py-1.5 rounded-full text-xs font-medium w-fit mx-auto ${
            inCoverage ? 'bg-emerald-50 text-emerald-700' : 'bg-red-50 text-red-700'
          }`}>
            {inCoverage ? '✅ Dentro del área de cobertura' : '❌ Fuera del área de cobertura'}
          </div>
        )}

        {/* Mapa */}
        <div className="h-48 rounded-2xl overflow-hidden shadow-card relative">
          <MapContainer
            center={origin || SOCOPO_CENTER}
            zoom={14}
            className="h-full w-full"
          >
          <TileLayer
            url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
            attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
          />
          <MapCenterController target={origin} />
          {origin && <Marker position={[origin.lat, origin.lng]} icon={userIcon} />}
          <MapClickHandler onSelect={(lat, lng) => handleSelectDestOnMap(lat, lng)} />
          </MapContainer>
          <div className="absolute bottom-2 left-2 bg-white/90 rounded-lg px-2 py-1 text-[10px] text-surface-500 z-[1000]">
            Toca el mapa para buscar el punto de destino
          </div>
        </div>

        {favorites.length > 0 && (
          <div>
            <h2 className="text-sm font-semibold text-surface-600 mb-2">Lugares guardados</h2>
            <div className="flex gap-2 overflow-x-auto -mx-4 px-4">
              {favorites.map((fav) => (
                <button
                  key={fav.id}
                  onClick={() => handleSelectFavorite(fav)}
                  className="flex-shrink-0 flex items-center gap-2 bg-white border-2 border-surface-100 rounded-xl px-3 py-2 text-sm text-surface-600 hover:border-primary-300 hover:text-primary-600 transition-colors"
                >
                  <Star className="w-4 h-4 text-amber-400" />
                  {fav.name}
                </button>
              ))}
            </div>
          </div>
        )}

        <div id="vehicles-select">
          <h2 className="text-lg font-semibold text-surface-800 mb-3">Elige tu vehículo</h2>
          <div className="grid grid-cols-3 gap-3">
            {categories.map((cat) => (
              <button
                key={cat.id}
                onClick={() => setSelectedCategory(cat.name)}
                className={`p-4 rounded-2xl border-2 transition-all duration-200 ${
                  selectedCategory === cat.name
                    ? 'border-primary-600 bg-primary-50 shadow-soft'
                    : 'border-surface-200 bg-white hover:border-surface-300'
                }`}
              >
                <div className={`mx-auto mb-2 ${selectedCategory === cat.name ? 'text-primary-600' : 'text-surface-400'}`}>
                  {categoryIcons[cat.name]}
                </div>
                <span className={`block text-sm font-medium ${selectedCategory === cat.name ? 'text-primary-700' : 'text-surface-600'}`}>
                  {cat.display_name}
                </span>
                <span className="block text-xs text-surface-400 mt-1">
                  {cat.base_fare_usd.toFixed(2)}$
                </span>
              </button>
            ))}
          </div>
        </div>

        {hasActiveCoupons && (
          <div>
            <input
              type="text"
              className="input"
              placeholder="Código de cupón (opcional)"
              value={couponCode}
              onChange={(e) => setCouponCode(e.target.value.toUpperCase())}
            />
          </div>
        )}

        <button
          onClick={handleCalculateFare}
          className="btn-primary w-full"
          disabled={loading || !origin || !inCoverage || !destBarrioId || !destAddress || !selectedCategory}
        >
          {loading ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Continuar'}
        </button>
      </div>

      {/* Bottom sheet de destino — UNA sola interacción: sector + dirección integrados */}
      {showDestSheet && (
        <div className="fixed inset-0 bg-black/40 z-50 flex items-end justify-center" onClick={() => setShowDestSheet(false)}>
          <div className="bottom-sheet max-w-md w-full" onClick={(e) => e.stopPropagation()}>
            <div className="bottom-sheet-handle" />
            <h2 className="text-xl font-bold text-surface-800 mb-4">¿A dónde te diriges?</h2>

            {/* Lista de sectores */}
            <div className="space-y-2 mb-4 max-h-[35vh] overflow-y-auto">
              {barrios.map((barrio) => (
                <button
                  key={barrio.id}
                  onClick={() => setSheetBarrioId(barrio.id)}
                  className={`w-full p-3.5 rounded-xl border-2 text-left transition-all ${
                    sheetBarrioId === barrio.id
                      ? 'border-primary-600 bg-primary-50 shadow-soft'
                      : 'border-surface-200 bg-white hover:border-surface-300'
                  }`}
                >
                  <div className="flex items-center justify-between">
                    <span className={`text-sm font-medium ${sheetBarrioId === barrio.id ? 'text-primary-700' : 'text-surface-700'}`}>
                      {barrio.name}
                    </span>
                    <span className="text-sm font-bold text-primary-600">
                      {barrio.surcharge_usd.toFixed(2)}$
                    </span>
                  </div>
                </button>
              ))}
            </div>

            {/* Campo de dirección — aparece en el mismo panel al seleccionar sector */}
            {sheetBarrioId && (
              <div className="animate-slide-up mb-4">
                <div className="relative">
                  <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-5 h-5 text-surface-400" />
                  <input
                    type="text"
                    className="input pl-10"
                    placeholder="Escribe tu dirección exacta..."
                    value={sheetAddress}
                    onChange={(e) => setSheetAddress(e.target.value)}
                  />
                </div>
              </div>
            )}

            <button
              onClick={() => {
                setDestBarrioId(sheetBarrioId)
                setDestAddress(sheetAddress)
                setShowDestSheet(false)
                // Scroll automático a las opciones de vehículo
                setTimeout(() => {
                  document.getElementById('vehicles-select')?.scrollIntoView({ behavior: 'smooth', block: 'start' })
                }, 400)
              }}
              className="btn-primary w-full"
              disabled={!sheetBarrioId || !sheetAddress.trim()}
            >
              Confirmar destino
            </button>
          </div>
        </div>
      )}

      {showFareSheet && fare && (
        <div className="fixed inset-0 bg-black/40 z-50 flex items-end justify-center" onClick={() => setShowFareSheet(false)}>
          <div className="bottom-sheet max-w-md w-full" onClick={(e) => e.stopPropagation()}>
            <div className="bottom-sheet-handle" />
            <h2 className="text-xl font-bold text-surface-800 mb-4">Detalle del viaje</h2>

            <div className="space-y-3 mb-6">
              <div className="flex justify-between text-sm">
                <span className="text-surface-500">Tarifa base</span>
                <span className="font-medium">{fare.base_fare.toFixed(2)}$</span>
              </div>
              <div className="flex justify-between text-sm">
                <span className="text-surface-500">Sitio de llegada</span>
                <span className="font-medium">{fare.destination_surcharge.toFixed(2)}$</span>
              </div>
              {fare.discount > 0 && (
                <div className="flex justify-between text-sm text-emerald-600">
                  <span>Descuento cupón</span>
                  <span>-{fare.discount.toFixed(2)}$</span>
                </div>
              )}
              <div className="border-t border-surface-100 pt-3 flex justify-between">
                <span className="font-semibold text-surface-800">Total</span>
                <span className="text-2xl font-bold text-primary-600">{fare.final_fare.toFixed(2)}$</span>
              </div>

              {/* Total en bolívares si Pago Móvil está seleccionado */}
              {selectedPaymentMethod?.toLowerCase().includes('pago') && exchangeRate > 0 && (
                <div className="bg-surface-50 rounded-xl p-3">
                  <div className="flex justify-between text-sm">
                    <span className="text-surface-500">Total en Bs.</span>
                    <span className="font-bold text-surface-800">Bs. {(fare.final_fare * exchangeRate).toFixed(2)}</span>
                  </div>
                  <p className="text-[10px] text-surface-400 mt-1">Tasa: Bs. {exchangeRate.toFixed(2)} por $1.00</p>
                </div>
              )}

              {/* Método de pago */}
              <div>
                <label className="label">Método de pago *</label>
                <div className="grid grid-cols-2 gap-2">
                  {paymentMethods.map((method) => (
                    <button
                      key={method.id}
                      type="button"
                      onClick={() => setSelectedPaymentMethod(method.name)}
                      className={`p-3 rounded-xl border-2 text-sm font-medium transition-all ${
                        selectedPaymentMethod === method.name
                          ? 'border-primary-600 bg-primary-50 text-primary-700'
                          : 'border-surface-200 text-surface-600'
                      }`}
                    >
                      {method.name}
                    </button>
                  ))}
                </div>
              </div>

              {/* Campos del método seleccionado (con botón copiar) */}
              {getSelectedMethod() && getSelectedMethodFields().length > 0 && (
                <div>
                  <label className="label">Datos para pagar</label>
                  <div className="space-y-2">
                    {getSelectedMethodFields().map((field) => (
                      <div key={field.id} className="flex items-center justify-between bg-surface-50 rounded-lg p-2">
                        <div className="min-w-0">
                          <p className="text-xs text-surface-400">{field.label}</p>
                          <p className="text-sm font-medium text-surface-700 truncate">{field.value}</p>
                        </div>
                        <button
                          type="button"
                          onClick={() => handleCopyField(field.value)}
                          className="ml-2 flex-shrink-0 p-2 rounded-lg text-primary-600 hover:bg-primary-50 transition-colors"
                          aria-label={`Copiar ${field.label}`}
                        >
                          {copiedField === field.value ? (
                            <Check className="w-4 h-4 text-emerald-600" />
                          ) : (
                            <Copy className="w-4 h-4" />
                          )}
                        </button>
                      </div>
                    ))}
                  </div>
                </div>
              )}

              {/* Carga de comprobante si el método lo requiere */}
              {getSelectedMethod()?.proof_required && (
                <div>
                  <label className="label">Comprobante del pago *</label>
                  <label className="flex flex-col items-center justify-center w-full h-24 border-2 border-dashed border-surface-200 rounded-xl cursor-pointer hover:border-primary-400 transition-colors">
                    {proofFile ? (
                      <div className="text-center">
                        <Check className="w-6 h-6 text-emerald-600 mx-auto mb-1" />
                        <span className="text-xs text-surface-600 truncate max-w-[200px] block">{proofFile.name}</span>
                      </div>
                    ) : (
                      <div className="text-center">
                        <Upload className="w-6 h-6 text-surface-400 mx-auto mb-1" />
                        <span className="text-xs text-surface-500">Toca para subir captura del pago</span>
                      </div>
                    )}
                    <input
                      type="file"
                      accept="image/*"
                      className="hidden"
                      onChange={(e) => setProofFile(e.target.files?.[0] || null)}
                    />
                  </label>
                </div>
              )}
            </div>

            <button
              onClick={handleRequestRide}
              className="btn-primary w-full"
              disabled={
                loading ||
                !selectedPaymentMethod ||
                (getSelectedMethod()?.proof_required && !proofFile)
              }
            >
              {loading ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Solicitar viaje'}
            </button>
          </div>
        </div>
      )}
    </div>
  )
}