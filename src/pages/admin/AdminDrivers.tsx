import { useState, useEffect } from 'react'
import { Users, Check, X, Loader2, Eye } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { EmptyState } from '@/components/ui/EmptyState'
import { SkeletonList } from '@/components/ui/Skeleton'
import { HexUnderline } from '@/components/ui/HexUnderline'
import type { Profile, DriverDocument, Vehicle } from '@/types/database'
import { AppLogo } from '@/components/ui/AppLogo'

export function AdminDrivers() {
  const [drivers, setDrivers] = useState<Profile[]>([])
  const [selectedDriver, setSelectedDriver] = useState<Profile | null>(null)
  const [documents, setDocuments] = useState<DriverDocument | null>(null)
  const [vehicles, setVehicles] = useState<Vehicle[]>([])
  const [imageUrls, setImageUrls] = useState<{ [key: string]: string }>({})
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [actionLoading, setActionLoading] = useState(false)
  const { user } = useAuth()

  useEffect(() => {
    loadDrivers()
  }, [])

  const loadDrivers = async () => {
    const { data, error } = await supabase
      .from('profiles')
      .select('*')
      .eq('role', 'conductor')
      .order('created_at', { ascending: false })

    if (!error && data) {
      setDrivers(data as Profile[])
    }
    setLoading(false)
  }

  // Genera URL firmada para archivos en buckets privados
  const getSignedUrl = async (bucket: string, path: string): Promise<string | null> => {
    try {
      // Extraer solo el nombre del archivo si la URL es completa
      let filePath = path
      if (path.includes('/')) {
        const idx = path.indexOf('documents/') >= 0 ? path.indexOf('documents/') + 10
          : path.indexOf('avatars/') >= 0 ? path.indexOf('avatars/') + 8
          : path.indexOf('vehicles/') >= 0 ? path.indexOf('vehicles/') + 9
          : 0
        if (idx > 0) {
          filePath = path.substring(idx)
        }
      }

      // Verificar si es una URL pública del bucket vehicles (ya es público)
      if (bucket === 'vehicles') {
        return path
      }

      const { data, error } = await supabase.storage
        .from(bucket)
        .createSignedUrl(filePath, 3600) // 1 hora

      return error ? null : (data?.signedUrl || null)
    } catch {
      return path // fallback: si no se puede firmar, devolver la URL original
    }
  }

  const loadDriverDetails = async (driver: Profile) => {
    setSelectedDriver(driver)
    setError('')
    setDocuments(null)
    setVehicles([])
    setImageUrls({})

    const [docRes, vehRes] = await Promise.all([
      supabase.from('driver_documents').select('*').eq('driver_id', driver.id).single(),
      supabase.from('vehicles').select('*').eq('driver_id', driver.id)
    ])

    const newDoc = !docRes.error && docRes.data ? (docRes.data as DriverDocument) : null
    const newVeh = !vehRes.error && vehRes.data ? (vehRes.data as Vehicle[]) : []

    setDocuments(newDoc)
    setVehicles(newVeh)

    // Obtener URLs firmadas de las fotos
    const urls: { [key: string]: string } = {}

    if (newDoc?.cedula_photo_url) {
      const url = await getSignedUrl('documents', newDoc.cedula_photo_url)
      if (url) urls.cedula = url
    }

    if (newDoc?.license_photo_url) {
      const url = await getSignedUrl('documents', newDoc.license_photo_url)
      if (url) urls.license = url
    }

    if (newDoc?.profile_photo_url) {
      const url = await getSignedUrl('avatars', newDoc.profile_photo_url)
      if (url) urls.profile = url
    }

    newVeh.forEach((v, i) => {
      if (v.photo_url) {
        const idx = v.photo_url.indexOf('vehicles/')
        const filePath = idx >= 0 ? v.photo_url.substring(idx + 9) : v.photo_url
        const base = v.photo_url.startsWith('http')
          ? v.photo_url
          : `https://inxxhkwybjkcaeyahami.supabase.co/storage/v1/object/public/vehicles/${filePath}`
        urls[`vehicle_${i}`] = base
      }
    })

    setImageUrls(urls)
  }

  const handleReview = async (driverId: string, approve: boolean) => {
    setError('')
    setActionLoading(true)

    try {
      const { error } = await supabase.rpc('review_driver', {
        p_driver_id: driverId,
        p_approve: approve
      })

      if (error) throw error

      setSelectedDriver(null)
      loadDrivers()
    } catch (err: any) {
      setError(err.message)
    } finally {
      setActionLoading(false)
    }
  }

  const handleVehicleReview = async (vehicleId: string, approve: boolean) => {
    setError('')
    setActionLoading(true)

    try {
      const { error } = await supabase.rpc('approve_vehicle', {
        p_vehicle_id: vehicleId,
        p_approve: approve
      })

      if (error) throw error

      // Recargar los vehículos del conductor seleccionado
      if (selectedDriver) {
        loadDriverDetails(selectedDriver)
      }
    } catch (err: any) {
      setError(err.message)
    } finally {
      setActionLoading(false)
    }
  }

  const statusBadge = {
    pendiente: <span className="badge-warning">Pendiente</span>,
    aprobado: <span className="badge-success">Aprobado</span>,
    rechazado: <span className="badge-danger">Rechazado</span>,
    suspendido: <span className="badge-danger">Suspendido</span>
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center gap-3">
          <AppLogo />
          <div>
            <h1 className="text-lg font-bold text-surface-800">Gestión de Conductores</h1>
            <p className="text-xs text-surface-500">Aprobar y revisar solicitudes</p>
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}
        <HexUnderline />

        {loading ? (
          <SkeletonList count={4} />
        ) : drivers.length === 0 ? (
          <EmptyState
            icon={<Users className="w-8 h-8" />}
            title="Sin conductores"
            description="Los conductores registrados aparecerán aquí"
          />
        ) : (
          <div className="space-y-3">
            {drivers.map((driver) => (
              <div key={driver.id} className="card card-hover">
                <div className="flex items-center justify-between mb-3">
                  <div className="flex items-center gap-3">
                    <div className="w-12 h-12 bg-primary-50 rounded-full flex items-center justify-center overflow-hidden">
                      {driver.avatar_url ? (
                        <img src={driver.avatar_url} alt={driver.full_name} className="w-full h-full object-cover" />
                      ) : (
                        <Users className="w-6 h-6 text-primary-600" />
                      )}
                    </div>
                    <div>
                      <p className="font-medium text-surface-700">{driver.full_name}</p>
                      <p className="text-xs text-surface-400">{driver.email}</p>
                    </div>
                  </div>
                  {statusBadge[driver.driver_status || 'pendiente']}
                </div>

                <div className="flex gap-2">
                  <button
                    onClick={() => loadDriverDetails(driver)}
                    className="btn-outline flex-1"
                  >
                    <Eye className="w-4 h-4" />
                    Ver detalles
                  </button>
                  {driver.driver_status === 'pendiente' && (
                    <>
                      <button
                        onClick={() => handleReview(driver.id, true)}
                        className="btn-success flex-1"
                        disabled={actionLoading}
                      >
                        <Check className="w-4 h-4" />
                        Aprobar
                      </button>
                      <button
                        onClick={() => handleReview(driver.id, false)}
                        className="btn-danger flex-1"
                        disabled={actionLoading}
                      >
                        <X className="w-4 h-4" />
                        Rechazar
                      </button>
                    </>
                  )}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Modal de detalles */}
      {selectedDriver && (
        <div className="fixed inset-0 bg-black/40 z-50 flex items-end justify-center" onClick={() => setSelectedDriver(null)}>
          <div className="bottom-sheet max-w-md w-full" onClick={(e) => e.stopPropagation()}>
            <div className="bottom-sheet-handle" />
            <h2 className="text-xl font-bold text-surface-800 mb-4">Detalles del Conductor</h2>

            <div className="space-y-4">
              {/* Información personal */}
              <div className="card">
                <h3 className="font-semibold text-surface-700 mb-3">Información personal</h3>

                <div className="flex items-center gap-4 mb-4">
                  <div className="w-20 h-20 bg-primary-50 rounded-full flex items-center justify-center overflow-hidden flex-shrink-0">
                    {imageUrls.profile ? (
                      <img src={imageUrls.profile} alt={selectedDriver.full_name} className="w-full h-full object-cover" />
                    ) : (
                      <Users className="w-8 h-8 text-primary-600" />
                    )}
                  </div>
                  <div>
                    <p className="font-medium text-surface-800">{selectedDriver.full_name}</p>
                    <p className="text-sm text-surface-500">{selectedDriver.email}</p>
                  </div>
                </div>

                {documents && (
                  <>
                    <p className="text-sm text-surface-600"><strong>Cédula:</strong> {documents.cedula_number}</p>
                    <p className="text-sm text-surface-600"><strong>Licencia:</strong> {documents.license_number}</p>
                    <p className="text-sm text-surface-600">
                      <strong>Vence:</strong> {new Date(documents.license_expiry_date).toLocaleDateString('es-VE')}
                    </p>

                    <div className="mt-4 grid grid-cols-2 gap-3">
                      <div>
                        <p className="text-xs text-surface-400 mb-2">Foto de la Cédula</p>
                        <div className="h-24 rounded-lg overflow-hidden bg-surface-50 flex items-center justify-center">
                          {imageUrls.cedula ? (
                            <a href={imageUrls.cedula} target="_blank" rel="noopener noreferrer" className="block w-full h-full">
                              <img src={imageUrls.cedula} alt="Cédula" className="w-full h-full object-cover" />
                            </a>
                          ) : (
                            <span className="text-xs text-surface-400">Sin foto</span>
                          )}
                        </div>
                      </div>
                      <div>
                        <p className="text-xs text-surface-400 mb-2">Foto de la Licencia</p>
                        <div className="h-24 rounded-lg overflow-hidden bg-surface-50 flex items-center justify-center">
                          {imageUrls.license ? (
                            <a href={imageUrls.license} target="_blank" rel="noopener noreferrer" className="block w-full h-full">
                              <img src={imageUrls.license} alt="Licencia" className="w-full h-full object-cover" />
                            </a>
                          ) : (
                            <span className="text-xs text-surface-400">Sin foto</span>
                          )}
                        </div>
                      </div>
                    </div>
                  </>
                )}
              </div>

              {/* Vehículo */}
              {vehicles.length > 0 && (
                <div className="card">
                  <h3 className="font-semibold text-surface-700 mb-3">Vehículo</h3>
                  {vehicles.map((v, i) => (
                    <div key={v.id}>
                      <div className="flex items-center gap-3 mb-2">
                        <div className="w-16 h-16 rounded-lg overflow-hidden bg-surface-50 flex items-center justify-center flex-shrink-0">
                          {imageUrls[`vehicle_${i}`] ? (
                            <img src={imageUrls[`vehicle_${i}`]} alt={`${v.brand} ${v.model}`} className="w-full h-full object-cover" />
                          ) : (
                            <span className="text-xs text-surface-400">Sin foto</span>
                          )}
                        </div>
                <div className="text-sm text-surface-600">
                          <p><strong>{v.brand} {v.model}</strong> ({v.year})</p>
                          <p>Color: {v.color} • Placa: {v.plate}</p>
                          <p>Categoría: {v.category}</p>
                          <div className="flex items-center gap-2 mt-2">
                            <span className={`badge ${v.is_active_vehicle ? 'badge-success' : v.is_approved ? 'badge-info' : 'badge-warning'}`}>
                              {v.is_active_vehicle ? 'Activo' : v.is_approved ? 'Aprobado' : 'Pendiente'}
                            </span>
                            {!v.is_approved && (
                              <>
                                <button onClick={() => handleVehicleReview(v.id, true)} className="btn-success px-2 py-1 text-xs">Aprobar</button>
                                <button onClick={() => handleVehicleReview(v.id, false)} className="btn-danger px-2 py-1 text-xs">Rechazar</button>
                              </>
                            )}
                          </div>
                        </div>
                      </div>
                    </div>
                  ))}
                </div>
              )}

              {/* Botones de acción */}
              <div className="flex gap-2">
                {selectedDriver.driver_status === 'pendiente' && (
                  <>
                    <button
                      onClick={() => handleReview(selectedDriver.id, true)}
                      className="btn-success flex-1"
                      disabled={actionLoading}
                    >
                      {actionLoading ? <Loader2 className="w-4 h-4 animate-spin" /> : <><Check className="w-4 h-4" /> Aprobar</>}
                    </button>
                    <button
                      onClick={() => handleReview(selectedDriver.id, false)}
                      className="btn-danger flex-1"
                      disabled={actionLoading}
                    >
                      {actionLoading ? <Loader2 className="w-4 h-4 animate-spin" /> : <><X className="w-4 h-4" /> Rechazar</>}
                    </button>
                  </>
                )}
                <button onClick={() => setSelectedDriver(null)} className="btn-outline flex-1">
                  Cerrar
                </button>
              </div>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}