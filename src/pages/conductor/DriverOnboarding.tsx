import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Loader2, Upload, User, Car, FileText, Shield } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import type { VehicleCategoryType } from '@/types/database'
import { AppLogo } from '@/components/ui/AppLogo'

export function DriverOnboarding() {
  const [step, setStep] = useState(1)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)
  const { user } = useAuth()
  const navigate = useNavigate()

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
  const [vehicleCategory, setVehicleCategory] = useState<VehicleCategoryType>('moto')
  const [vehicleBrand, setVehicleBrand] = useState('')
  const [vehicleModel, setVehicleModel] = useState('')
  const [vehicleYear, setVehicleYear] = useState('')
  const [vehicleColor, setVehicleColor] = useState('')
  const [vehiclePlate, setVehiclePlate] = useState('')

  const uploadFile = async (file: File, bucket: string, path: string): Promise<string> => {
    const { data, error } = await supabase.storage
      .from(bucket)
      .upload(path, file, { upsert: true })

    if (error) throw error

    // Los buckets documents/avatars/vehicles son privados (o controlados por RLS).
    // Guardamos la ruta del storage; se resuelve con URL firmada al visualizar.
    return data.path
  }

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setError('')

    // Validación manual de archivos obligatorios
    if (!cedulaPhoto || !licensePhoto) {
      setError('Debes subir la foto de la cédula y la licencia')
      return
    }

    if (!vehiclePhoto) {
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
        ? await uploadFile(profilePhoto, 'avatars', `${userId}/profile-${timestamp}.jpg`)
        : null

      const cedulaPhotoUrl = cedulaPhoto
        ? await uploadFile(cedulaPhoto, 'documents', `${userId}/cedula-${timestamp}.jpg`)
        : ''

      const licensePhotoUrl = licensePhoto
        ? await uploadFile(licensePhoto, 'documents', `${userId}/license-${timestamp}.jpg`)
        : ''

      const vehiclePhotoUrl = vehiclePhoto
        ? await uploadFile(vehiclePhoto, 'vehicles', `${userId}/vehicle-${timestamp}.jpg`)
        : ''

      // Llamar RPC para registrar onboarding
      const { error: rpcError } = await supabase.rpc('register_driver_onboarding', {
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

      navigate('/conductor/pendiente')
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
      if (!cedulaPhoto || !licensePhoto || !licenseExpiry) {
        setError('Sube las fotos requeridas')
        return
      }
    }
    if (step === 3) {
      if (!vehicleBrand || !vehicleModel || !vehicleYear || !vehicleColor || !vehiclePlate) {
        setError('Completa todos los datos del vehículo')
        return
      }
    }
    setStep(step + 1)
  }

  const prevStep = () => setStep(step - 1)

  const FileInput = ({ label, file, setFile }: {
    label: string
    file: File | null
    setFile: (f: File | null) => void
  }) => (
    <div>
      <label className="label">{label}</label>
      <label className="flex flex-col items-center justify-center w-full h-32 border-2 border-dashed border-surface-200 rounded-xl cursor-pointer hover:border-primary-400 transition-colors">
        {file ? (
          <div className="text-center">
            <FileText className="w-8 h-8 text-primary-600 mx-auto mb-1" />
            <span className="text-xs text-surface-600">{file.name}</span>
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
          onChange={(e) => setFile(e.target.files?.[0] || null)}
        />
      </label>
    </div>
  )

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

              <FileInput label="Foto de perfil" file={profilePhoto} setFile={setProfilePhoto} />
              <FileInput label="Foto de la Cédula *" file={cedulaPhoto} setFile={setCedulaPhoto} />
              <FileInput label="Foto de la Licencia *" file={licensePhoto} setFile={setLicensePhoto} />
            </div>
          )}

          {step === 3 && (
            <div className="space-y-4 animate-fade-in">
              <div className="flex items-center gap-2 mb-4">
                <Car className="w-5 h-5 text-primary-600" />
                <h2 className="font-semibold text-surface-800">Datos del Vehículo</h2>
              </div>

              <div>
                <label className="label">Categoría *</label>
                <div className="grid grid-cols-3 gap-2">
                  {(['moto', 'carro', 'camioneta'] as VehicleCategoryType[]).map((cat) => (
                    <button
                      key={cat}
                      type="button"
                      onClick={() => setVehicleCategory(cat)}
                      className={`p-3 rounded-xl border-2 text-sm font-medium transition-all ${
                        vehicleCategory === cat
                          ? 'border-primary-600 bg-primary-50 text-primary-700'
                          : 'border-surface-200 text-surface-600 hover:border-surface-300'
                      }`}
                    >
                      {cat === 'moto' ? 'Moto' : cat === 'carro' ? 'Carro' : 'Camioneta'}
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
              </div>
            </div>
          )}

          {step === 4 && (
            <div className="space-y-4 animate-fade-in">
              <div className="flex items-center gap-2 mb-4">
                <Car className="w-5 h-5 text-primary-600" />
                <h2 className="font-semibold text-surface-800">Foto del Vehículo</h2>
              </div>

              <FileInput label="Foto real del vehículo *" file={vehiclePhoto} setFile={setVehiclePhoto} />

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