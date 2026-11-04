import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Loader2, Upload, User, Car, FileText, Shield, CheckCircle, AlertTriangle } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { uploadImageToStorage, prepareImage, type ImagePreset } from '@/lib/uploadImage'
import { formatKb } from '@/lib/imageCompress'
import { useAuth } from '@/contexts/AuthContext';
import { useDriverProfileState } from '@/hooks/useDriverProfileState'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import type { VehicleCategory, VehicleCategoryType } from '@/types/database'
import { AppLogo } from '@/components/ui/AppLogo'

/** Fotos del registro y el preset de compresión que le corresponde */
type PhotoKey = 'profile' | 'cedula' | 'license' | 'vehicle'

const PHOTO_PRESETS: Record<PhotoKey, ImagePreset> = {
  profile: 'avatar',
  cedula: 'document',
  license: 'document',
  vehicle: 'vehicle'
}

const PHOTO_LABELS: Record<PhotoKey, string> = {
  profile: 'perfil',
  cedula: 'cédula',
  license: 'licencia',
  vehicle: 'vehículo'
}

interface PhotoStatus {
  state: 'idle' | 'preparing' | 'ready' | 'error'
  size?: number
  message?: string
}

const EMPTY_PHOTO_STATUS: Record<PhotoKey, PhotoStatus> = {
  profile: { state: 'idle' },
  cedula: { state: 'idle' },
  license: { state: 'idle' },
  vehicle: { state: 'idle' }
}

const ONBOARD_DEFAULT_CATS: VehicleCategory[] = [
  { id: 'o-moto_basica', name: 'moto_basica', display_name: 'Moto Básica', base_fare_usd: 1, max_passengers: 1, icon: '🛵', is_active: true, created_at: '' },
  { id: 'o-moto_lujo', name: 'moto_lujo', display_name: 'Moto de Lujo', base_fare_usd: 1.6, max_passengers: 1, icon: '🏍️', is_active: true, created_at: '' },
  { id: 'o-trimoto', name: 'trimoto', display_name: 'Trimoto', base_fare_usd: 2, max_passengers: 3, icon: '🛺', is_active: true, created_at: '' },
  { id: 'o-moto_carga', name: 'moto_carga', display_name: 'Moto de Carga', base_fare_usd: 1.3, max_passengers: 1, icon: '📦', is_active: true, created_at: '' },
  { id: 'o-carro', name: 'carro', display_name: 'Carro', base_fare_usd: 5, max_passengers: 4, icon: '🚗', is_active: true, created_at: '' },
  { id: 'o-camioneta', name: 'camioneta', display_name: 'Camioneta', base_fare_usd: 8, max_passengers: 6, icon: '🚚', is_active: true, created_at: '' }
]

export function DriverOnboarding() {
  const [step, setStep] = useState(1)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)
  const { user } = useAuth()
  const navigate = useNavigate()
  const { state: driverState, loading: driverStateLoading } = useDriverProfileState()

  // Datos personales
  const [fullName, setFullName] = useState(user?.full_name || '')
  const [phone, setPhone] = useState('')
  const [cedulaNumber, setCedulaNumber] = useState('')
  const [licenseExpiry, setLicenseExpiry] = useState('')

  // Fotos
  const [profilePhoto, setProfilePhoto] = useState<File | null>(null)
  const [cedulaPhoto, setCedulaPhoto] = useState<File | null>(null)
  const [licensePhoto, setLicensePhoto] = useState<File | null>(null)
  const [vehiclePhoto, setVehiclePhoto] = useState<File | null>(null)

  // Datos del vehículo
  const [vehicleTypes, setVehicleTypes] = useState<VehicleCategory[]>([])
  const [vehicleCategory, setVehicleCategory] = useState<VehicleCategoryType>('')
  const [vehicleBrand, setVehicleBrand] = useState('')
  const [vehicleModel, setVehicleModel] = useState('')
  const [vehicleYear, setVehicleYear] = useState('')
  const [vehicleColor, setVehicleColor] = useState('')
  const [vehiclePlate, setVehiclePlate] = useState('')

  // Fotos que ya existen en el servidor (para reenviar sin volver a subirlas)
  const [hasCedulaPhoto, setHasCedulaPhoto] = useState(false)
  const [hasLicensePhoto, setHasLicensePhoto] = useState(false)
  const [hasProfilePhoto, setHasProfilePhoto] = useState(false)
  const [hasVehiclePhoto, setHasVehiclePhoto] = useState(false)

  // Fotos ya comprimidas al elegirlas: evita que el envío falle sin decir cuál es
  // y no repite el trabajo de compresión al enviar.
  const [preparedPhotos, setPreparedPhotos] = useState<Record<PhotoKey, File | null>>({
    profile: null,
    cedula: null,
    license: null,
    vehicle: null
  })
  const [photoStatus, setPhotoStatus] = useState<Record<PhotoKey, PhotoStatus>>(EMPTY_PHOTO_STATUS)

  const rawPhoto = (key: PhotoKey): File | null =>
    key === 'profile'
      ? profilePhoto
      : key === 'cedula'
        ? cedulaPhoto
        : key === 'license'
          ? licensePhoto
          : vehiclePhoto

  const existingPhoto = (key: PhotoKey): boolean =>
    key === 'profile'
      ? hasProfilePhoto
      : key === 'cedula'
        ? hasCedulaPhoto
        : key === 'license'
          ? hasLicensePhoto
          : hasVehiclePhoto

  const setRawPhoto = (key: PhotoKey, file: File | null) => {
    if (key === 'profile') setProfilePhoto(file)
    else if (key === 'cedula') setCedulaPhoto(file)
    else if (key === 'license') setLicensePhoto(file)
    else setVehiclePhoto(file)
  }

  /**
   * Al elegir la foto se comprime y se valida EN EL MOMENTO.
   * Así el conductor sabe exactamente cuál foto falla (y por qué)
   * antes de enviar, y el envío reutiliza el archivo ya comprimido.
   */
  const handlePhotoSelected = async (key: PhotoKey, file: File | null) => {
    setRawPhoto(key, file)
    setPreparedPhotos((prev) => ({ ...prev, [key]: null }))

    if (!file) {
      setPhotoStatus((prev) => ({ ...prev, [key]: { state: 'idle' } }))
      return
    }

    setPhotoStatus((prev) => ({ ...prev, [key]: { state: 'preparing' } }))

    try {
      const optimized = await prepareImage(file, PHOTO_PRESETS[key])
      setPreparedPhotos((prev) => ({ ...prev, [key]: optimized }))
      setPhotoStatus((prev) => ({ ...prev, [key]: { state: 'ready', size: optimized.size } }))
    } catch (err: any) {
      setPhotoStatus((prev) => ({
        ...prev,
        [key]: { state: 'error', message: err?.message || 'No se pudo leer la foto' }
      }))
    }
  }

  /** Devuelve el mensaje de error de la primera foto que no se pudo leer, o null */
  const photoErrorFor = (keys: PhotoKey[]): string | null => {
    const failed = keys.filter((k) => rawPhoto(k) && photoStatus[k].state === 'error')
    if (failed.length === 0) return null
    return (
      `No pudimos leer la foto de ${failed.map((k) => PHOTO_LABELS[k]).join(' y ')}. ` +
      `${photoStatus[failed[0]].message || 'Prueba con otra foto o tómala de nuevo con la cámara.'}`
    )
  }

  useEffect(() => {
    (async () => {
      try {
        const { data } = await supabase
          .from('vehicle_categories')
          .select('*')
          .eq('is_active', true)
          .order('base_fare_usd')
        const list = (data || []) as VehicleCategory[]
        setVehicleTypes(list)
        if (list.length) {
          setVehicleCategory((prev) => (list.some((c) => c.name === prev) ? prev : list[0].name))
        } else {
          setVehicleCategory('moto_basica')
        }
      } catch {
        setVehicleCategory('moto_basica')
      }
    })()
  }, [])

  // Precargar datos ya guardados (para continuar un registro a medias)
  useEffect(() => {
    if (!user?.id) return
    let cancelled = false
    ;(async () => {
      const [{ data: profile }, { data: docs }, { data: vehicles }] = await Promise.all([
        supabase.from('profiles').select('full_name, phone').eq('id', user.id).single(),
        supabase.from('driver_documents').select('*').eq('driver_id', user.id).maybeSingle(),
        supabase.from('vehicles').select('*').eq('driver_id', user.id).order('is_active_vehicle', { ascending: false }).limit(1)
      ])
      if (cancelled) return
      if (profile?.full_name) setFullName((prev) => prev || profile.full_name)
      if (profile?.phone) setPhone((prev) => prev || profile.phone)
      const d = docs as any
      if (d) {
        if (d.cedula_number) setCedulaNumber((prev) => prev || d.cedula_number)
        if (d.license_expiry_date) setLicenseExpiry((prev) => prev || d.license_expiry_date)
        setHasCedulaPhoto(!!d.cedula_photo_url)
        setHasLicensePhoto(!!d.license_photo_url)
        setHasProfilePhoto(!!d.profile_photo_url)
      }
      const v = (vehicles || [])[0] as any
      if (v) {
        if (v.category) setVehicleCategory(v.category)
        if (v.brand) setVehicleBrand((prev) => prev || v.brand)
        if (v.model) setVehicleModel((prev) => prev || v.model)
        if (v.year) setVehicleYear((prev) => prev || String(v.year))
        if (v.color) setVehicleColor((prev) => prev || v.color)
        if (v.plate) setVehiclePlate((prev) => prev || v.plate)
        setHasVehiclePhoto(!!v.photo_url)
      }
    })()
    return () => { cancelled = true }
  }, [user?.id])

  // Comprime y sube el archivo (la foto de una cédula pasa de ~600 KB
  // a ~200 KB, el vehículo de ~900 KB a ~120 KB) en vez de subir la
  // imagen original de 3-5 MB de la cámara.
  const uploadFile = async (
    file: File,
    bucket: string,
    path: string,
    prepared: File | null = null
  ): Promise<string> => {
    const preset: ImagePreset =
      bucket === 'documents' ? 'document' : bucket === 'avatars' ? 'avatar' : 'vehicle'

    const { path: ruta } = await uploadImageToStorage(
      bucket,
      path,
      prepared ?? file,
      preset,
      prepared ? { prepared: true, originalSize: file.size } : {}
    )

    // Los buckets documents/avatars/vehicles son privados (o controlados por RLS).
    // Guardamos la ruta del storage; se resuelve con URL firmada al visualizar.
    return ruta
  }

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setError('')

    // Si alguna foto elegida no se pudo procesar, decir CUÁL es (antes fallaba sin nombre)
    const photosToCheck: PhotoKey[] = ['profile', 'cedula', 'license', 'vehicle']
    const photoError = photoErrorFor(photosToCheck)
    if (photoError) {
      setError(photoError)
      return
    }

    const preparingPhotos = photosToCheck.filter(
      (k) => rawPhoto(k) && photoStatus[k].state === 'preparing'
    )
    if (preparingPhotos.length > 0) {
      setError('Espera un momento: estamos procesando las fotos.')
      return
    }

    // Validación manual de archivos obligatorios
    // (si ya tenía la foto subida de antes, no hace falta volver a subirla)
    if ((!cedulaPhoto && !hasCedulaPhoto) || (!licensePhoto && !hasLicensePhoto)) {
      setError('Debes subir la foto de la cédula y la licencia')
      return
    }

    if (!vehiclePhoto && !hasVehiclePhoto) {
      setError('Debes subir la foto del vehículo')
      return
    }

    setLoading(true)

    try {
      if (!user) throw new Error('Debes iniciar sesión')

      // Subir fotos
      const userId = user.id
      const timestamp = Date.now()

      const profilePhotoUrl = profilePhoto
        ? await uploadFile(profilePhoto, 'avatars', `${userId}/profile-${timestamp}.jpg`, preparedPhotos.profile)
        : null

      const cedulaPhotoUrl = cedulaPhoto
        ? await uploadFile(cedulaPhoto, 'documents', `${userId}/cedula-${timestamp}.jpg`, preparedPhotos.cedula)
        : ''

      const licensePhotoUrl = licensePhoto
        ? await uploadFile(licensePhoto, 'documents', `${userId}/license-${timestamp}.jpg`, preparedPhotos.license)
        : ''

      const vehiclePhotoUrl = vehiclePhoto
        ? await uploadFile(vehiclePhoto, 'vehicles', `${userId}/vehicle-${timestamp}.jpg`, preparedPhotos.vehicle)
        : ''

      // Llamar RPC para registrar onboarding
      const { data: rpcData, error: rpcError } = await supabase.rpc('register_driver_onboarding', {
        p_full_name: fullName,
        p_phone: phone,
        p_cedula_number: cedulaNumber,
        p_cedula_photo_url: cedulaPhotoUrl,
        p_license_number: null,
        p_license_photo_url: licensePhotoUrl,
        p_license_expiry_date: licenseExpiry,
        p_profile_photo_url: profilePhotoUrl,
        p_vehicle_category: vehicleCategory,
        p_vehicle_brand: vehicleBrand,
        p_vehicle_model: vehicleModel,
        p_vehicle_year: parseInt(vehicleYear),
        p_vehicle_color: vehicleColor,
        p_vehicle_plate: vehiclePlate,
        p_vehicle_photo_url: vehiclePhotoUrl
      })

      if (rpcError) throw rpcError

      const newStatus = (rpcData as { status?: string; shared_vehicle?: boolean; message?: string } | null)?.status
      const sharedVehicle = !!(rpcData as { shared_vehicle?: boolean } | null)?.shared_vehicle
      const sharedMessage = (rpcData as { message?: string } | null)?.message
      navigate(newStatus === 'aprobado' ? '/conductor' : '/conductor/pendiente', {
        state: sharedVehicle ? { sharedVehicle: true, message: sharedMessage } : undefined
      })
    } catch (err: any) {
      setError(err.message || 'Error al enviar la solicitud')
      setLoading(false)
    }
  }

  const nextStep = () => {
    setError('')
    if (step === 1) {
      if (!fullName || !phone || !cedulaNumber) {
        setError('Completa todos los campos obligatorios')
        return
      }
    }
    if (step === 2) {
      const photoError = photoErrorFor(['profile', 'cedula', 'license'])
      if (photoError) {
        setError(photoError)
        return
      }
      if ((!cedulaPhoto && !hasCedulaPhoto) || (!licensePhoto && !hasLicensePhoto) || !licenseExpiry) {
        setError('Sube las fotos requeridas')
        return
      }
    }
    if (step === 3) {
      const photoError = photoErrorFor(['vehicle'])
      if (photoError) {
        setError(photoError)
        return
      }
      if (!vehicleCategory || !vehicleBrand || !vehicleModel || !vehicleYear || !vehicleColor || !vehiclePlate) {
        setError('Completa todos los datos del vehículo')
        return
      }
    }
    setStep(step + 1)
  }

  const prevStep = () => setStep(step - 1)

  const FileInput = ({ label, file, onSelect, status, existing = false }: {
    label: string
    file: File | null
    onSelect: (f: File | null) => void
    status: PhotoStatus
    existing?: boolean
  }) => (
    <div>
      <label className="label">{label}</label>
      <label className="flex flex-col items-center justify-center w-full h-32 border-2 border-dashed border-surface-200 rounded-xl cursor-pointer hover:border-primary-400 transition-colors">
        {file ? (
          <div className="text-center px-2">
            <FileText className="w-8 h-8 text-primary-600 mx-auto mb-1" />
            <span className="text-xs text-surface-600 block truncate max-w-[220px]">{file.name}</span>
          </div>
        ) : existing ? (
          <div className="text-center">
            <FileText className="w-8 h-8 text-emerald-600 mx-auto mb-1" />
            <span className="text-xs text-emerald-700">Ya tienes esta foto</span>
            <span className="text-[11px] text-surface-400 block">Toca para cambiarla</span>
          </div>
        ) : (
          <div className="text-center">
            <Upload className="w-8 h-8 text-surface-400 mx-auto mb-1" />
            <span className="text-xs text-surface-500">Toca para subir</span>
          </div>
        )}
        <input
          type="file"
          accept="image/*"
          className="hidden"
          onClick={(e) => { e.currentTarget.value = '' }}
          onChange={(e) => onSelect(e.target.files?.[0] || null)}
        />
      </label>

      {/* Estado de ESTA foto: se valida al elegirla, no al enviar */}
      {status.state === 'preparing' && (
        <p className="text-xs text-surface-500 mt-1 flex items-center gap-1">
          <Loader2 className="w-3.5 h-3.5 animate-spin" /> Procesando foto…
        </p>
      )}
      {status.state === 'ready' && (
        <p className="text-xs text-emerald-600 mt-1 flex items-center gap-1">
          <CheckCircle className="w-3.5 h-3.5" /> Lista ({formatKb(status.size || 0)})
        </p>
      )}
      {status.state === 'error' && (
        <p className="text-xs text-red-600 mt-1 flex items-start gap-1">
          <AlertTriangle className="w-3.5 h-3.5 flex-shrink-0 mt-0.5" />
          <span>{status.message}</span>
        </p>
      )}
    </div>
  )

  if (driverStateLoading) {
    return (
      <div className="min-h-screen bg-surface-50 flex items-center justify-center">
        <Loader2 className="w-8 h-8 animate-spin text-primary-600" />
      </div>
    )
  }

  if (driverState?.approved && driverState.complete) {
    return (
      <div className="min-h-screen bg-surface-50 flex items-center justify-center px-6 py-12">
        <div className="card max-w-md w-full text-center">
          <div className="w-16 h-16 bg-emerald-50 rounded-2xl flex items-center justify-center mx-auto mb-4">
            <Shield className="w-8 h-8 text-emerald-600" />
          </div>
          <h1 className="text-xl font-bold text-surface-800 mb-2">Datos verificados</h1>
          <p className="text-sm text-surface-500 mb-4">
            Tu cuenta está aprobada y tus documentos están completos. Si necesitas corregir algo, solicítalo y el administrador lo revisará.
          </p>
          <button onClick={() => navigate('/conductor/perfil')} className="btn-primary w-full">
            Ir a mi perfil
          </button>
        </div>
      </div>
    )
  }
  return (
    <div className="min-h-screen bg-surface-50 pb-20">
      <div className="bg-primary-600 border-b border-primary-700 px-6 py-4">
        <div className="flex items-center gap-3">
          <AppLogo variant="dark" />
          <div>
            <h1 className="text-lg font-bold text-white">Registro de Conductor</h1>
            <p className="text-xs text-white/80">Paso {step} de 4</p>
          </div>
        </div>
        <div className="h-2 bg-white/20 rounded-full overflow-hidden mt-4">
          <div className="h-full bg-white rounded-full transition-all duration-500" style={{ width: `${(step / 4) * 100}%` }} />
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        <form onSubmit={handleSubmit} className="space-y-6">
          {step === 1 && (
            <div className="space-y-4 animate-fade-in">
              <div className="flex items-center gap-2 mb-4">
                <User className="w-5 h-5 text-primary-600" />
                <h2 className="font-semibold text-surface-800">Datos Personales</h2>
              </div>

              <div>
                <label className="label">Nombre completo *</label>
                <input
                  type="text"
                  className="input"
                  value={fullName}
                  onChange={(e) => setFullName(e.target.value)}
                  required
                />
              </div>

              <div>
                <label className="label">Teléfono *</label>
                <input
                  type="tel"
                  className="input"
                  placeholder="0412-0000000"
                  value={phone}
                  onChange={(e) => setPhone(e.target.value)}
                  required
                />
              </div>

              <div>
                <label className="label">Cédula de Identidad *</label>
                <input
                  type="text"
                  className="input"
                  placeholder="V-00000000"
                  value={cedulaNumber}
                  onChange={(e) => setCedulaNumber(e.target.value)}
                  required
                />
              </div>

              <div>
                <label className="label">Vencimiento de Licencia *</label>
                <input
                  type="date"
                  className="input"
                  value={licenseExpiry}
                  onChange={(e) => setLicenseExpiry(e.target.value)}
                  required
                />
              </div>
            </div>
          )}

          {step === 2 && (
            <div className="space-y-4 animate-fade-in">
              <div className="flex items-center gap-2 mb-4">
                <Shield className="w-5 h-5 text-primary-600" />
                <h2 className="font-semibold text-surface-800">Documentos</h2>
              </div>

              <FileInput
                label="Foto de perfil"
                file={profilePhoto}
                onSelect={(f) => handlePhotoSelected('profile', f)}
                status={photoStatus.profile}
                existing={existingPhoto('profile')}
              />
              <FileInput
                label="Foto de la Cédula *"
                file={cedulaPhoto}
                onSelect={(f) => handlePhotoSelected('cedula', f)}
                status={photoStatus.cedula}
                existing={existingPhoto('cedula')}
              />
              <FileInput
                label="Foto de la Licencia *"
                file={licensePhoto}
                onSelect={(f) => handlePhotoSelected('license', f)}
                status={photoStatus.license}
                existing={existingPhoto('license')}
              />
              <p className="text-[11px] text-surface-400">
                Si tu teléfono guarda las fotos en HEIC o la foto está en la nube, ábrela en
                Galería y descárgala antes de elegirla. Cada foto muestra arriba si quedó lista.
              </p>
            </div>
          )}

          {step === 3 && (
            <div className="space-y-4 animate-fade-in">
              <div className="flex items-center gap-2 mb-4">
                <Car className="w-5 h-5 text-primary-600" />
                <h2 className="font-semibold text-surface-800">Datos del Vehículo</h2>
              </div>

              <div>
                <label className="label">Tipo de vehículo *</label>
                <div className="grid grid-cols-3 gap-2">
                  {(vehicleTypes.length ? vehicleTypes : ONBOARD_DEFAULT_CATS).map((cat) => (
                    <button
                      key={cat.name}
                      type="button"
                      onClick={() => setVehicleCategory(cat.name)}
                      className={`p-3 rounded-xl border-2 text-sm font-medium transition-all ${
                        vehicleCategory === cat.name
                          ? 'border-primary-600 bg-primary-50 text-primary-700'
                          : 'border-surface-200 text-surface-600 hover:border-surface-300'
                      }`}
                    >
                      <span className="block text-xl leading-none mb-1">{cat.icon || '🚗'}</span>
                      <span className="block">{cat.display_name || cat.name}</span>
                    </button>
                  ))}
                </div>
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="label">Marca *</label>
                  <input
                    type="text"
                    className="input"
                    placeholder="Toyota"
                    value={vehicleBrand}
                    onChange={(e) => setVehicleBrand(e.target.value)}
                    required
                  />
                </div>
                <div>
                  <label className="label">Modelo *</label>
                  <input
                    type="text"
                    className="input"
                    placeholder="Corolla"
                    value={vehicleModel}
                    onChange={(e) => setVehicleModel(e.target.value)}
                    required
                  />
                </div>
              </div>

              <div className="grid grid-cols-2 gap-4">
                <div>
                  <label className="label">Año *</label>
                  <input
                    type="number"
                    className="input"
                    placeholder="2020"
                    min="1990"
                    max="2026"
                    value={vehicleYear}
                    onChange={(e) => setVehicleYear(e.target.value)}
                    required
                  />
                </div>
                <div>
                  <label className="label">Color *</label>
                  <input
                    type="text"
                    className="input"
                    placeholder="Blanco"
                    value={vehicleColor}
                    onChange={(e) => setVehicleColor(e.target.value)}
                    required
                  />
                </div>
              </div>

              <div>
                <label className="label">Placa *</label>
                <input
                  type="text"
                  className="input"
                  placeholder="ABC123"
                  value={vehiclePlate}
                  onChange={(e) => setVehiclePlate(e.target.value.toUpperCase())}
                  required
                />
                <p className="text-[11px] text-surface-400 mt-1">
                  Si la placa ya está registrada por otro conductor, enviaremos una solicitud de vehículo compartido al administrador.
                </p>
              </div>
            </div>
          )}

          {step === 4 && (
            <div className="space-y-4 animate-fade-in">
              <div className="flex items-center gap-2 mb-4">
                <Car className="w-5 h-5 text-primary-600" />
                <h2 className="font-semibold text-surface-800">Foto del Vehículo</h2>
              </div>

              <FileInput
                label="Foto real del vehículo *"
                file={vehiclePhoto}
                onSelect={(f) => handlePhotoSelected('vehicle', f)}
                status={photoStatus.vehicle}
                existing={existingPhoto('vehicle')}
              />

              <div className="bg-amber-50 border-2 border-amber-200 rounded-xl p-4">
                <p className="text-sm text-amber-800">
                  <strong>Importante:</strong> Al enviar tu solicitud, tu cuenta quedará en estado
                  <strong> PENDIENTE</strong> hasta que un administrador la apruebe. Te notificaremos
                  cuando sea aprobada.
                </p>
              </div>
            </div>
          )}

          <div className="flex gap-3 pt-4">
            {step > 1 && (
              <button type="button" onClick={prevStep} className="btn-outline flex-1">
                Atrás
              </button>
            )}
            {step < 4 ? (
              <button type="button" onClick={nextStep} className="btn-primary flex-1">
                Siguiente
              </button>
            ) : (
              <button type="submit" className="btn-primary flex-1" disabled={loading}>
                {loading ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Enviar solicitud'}
              </button>
            )}
          </div>
        </form>
      </div>
    </div>
  )
}