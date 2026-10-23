import { useState, useEffect, useRef } from 'react'
import { useSearchParams } from 'react-router-dom'
import { Users, Check, X, Loader2, Eye, MessageCircle, Search, AlertTriangle } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { whatsappNumber } from '@/lib/format'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { EmptyState } from '@/components/ui/EmptyState'
import { SkeletonList } from '@/components/ui/Skeleton'
import { HexUnderline } from '@/components/ui/HexUnderline'
import type { Profile, DriverDocument, Vehicle } from '@/types/database'
import { AppLogo } from '@/components/ui/AppLogo'
import { resolvePhotoUrl } from '@/lib/photos'

interface DriverChangeRequest {
  id: string
  driver_id: string
  kind: 'documents' | 'vehicle' | 'phone'
  payload: any
  status: string
  created_at: string
}

interface PendingChangeSummary {
  driver_id: string
  kind: 'documents' | 'vehicle' | 'phone'
  created_at: string
}

type DriverFilter = 'all' | 'pending' | 'new' | 'vehicle' | 'change' | 'name' | 'avatar' | 'incomplete'

const DRIVER_FILTERS: { key: DriverFilter; label: string }[] = [
  { key: 'all', label: 'Todos' },
  { key: 'pending', label: 'Solicitudes' },
  { key: 'new', label: 'Nuevos' },
  { key: 'vehicle', label: 'Vehículos' },
  { key: 'change', label: 'Correcciones' },
  { key: 'name', label: 'Nombres' },
  { key: 'avatar', label: 'Fotos' },
  { key: 'incomplete', label: 'Sin datos' },
]

const CHANGE_KIND_LABEL: Record<string, string> = {
  documents: 'documentos',
  vehicle: 'vehículo',
  phone: 'teléfono',
}

export function AdminDrivers() {
  const [drivers, setDrivers] = useState<Profile[]>([])
  const [selectedDriver, setSelectedDriver] = useState<Profile | null>(null)
  const [documents, setDocuments] = useState<DriverDocument | null>(null)
  const [vehicles, setVehicles] = useState<Vehicle[]>([])
  const [imageUrls, setImageUrls] = useState<{ [key: string]: string }>({})
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [actionLoading, setActionLoading] = useState(false)
  const [pendingVeh, setPendingVeh] = useState<Set<string>>(new Set())
  // Conductores que no completaron documentos/vehiculo (no se pueden aprobar)
  const [incompleteDrivers, setIncompleteDrivers] = useState<Set<string>>(new Set())
  const [pendingChanges, setPendingChanges] = useState<Map<string, PendingChangeSummary>>(new Map())
  const [pendingChange, setPendingChange] = useState<DriverChangeRequest | null>(null)
  const [platesByDriver, setPlatesByDriver] = useState<Map<string, string[]>>(new Map())
  const [sharedVehicleDrivers, setSharedVehicleDrivers] = useState<Set<string>>(new Set())
  const [sharedWithNames, setSharedWithNames] = useState<Record<string, string>>({})
  const [filter, setFilter] = useState<DriverFilter>('all')
  const [query, setQuery] = useState('')
  const [searchParams, setSearchParams] = useSearchParams()
  const focusDriverId = searchParams.get('driver')
  const focusType = searchParams.get('focus')
  const openedFocusRef = useRef<string | null>(null)
  const { user } = useAuth()

  useEffect(() => {
    loadDrivers()
  }, [])

  const loadDrivers = async () => {
    // El encargado ve SOLO los conductores de su ciudad (el backend lo impone con RLS)
    const driversQuery = supabase
      .from('profiles')
      .select('*')
      .eq('role', 'conductor')
      .order('created_at', { ascending: false })
    const { data, error } = user?.role === 'encargado' && user.zone_id
      ? await driversQuery.eq('zone_id', user.zone_id)
      : await driversQuery

    if (!error && data) {
      setDrivers(data as Profile[])
    }

    const { data: changeRows } = await supabase
      .from('driver_change_requests')
      .select('driver_id, kind, created_at')
      .eq('status', 'pendiente')
    const changeMap = new Map<string, PendingChangeSummary>()
    for (const r of (changeRows || [])) changeMap.set(r.driver_id, r as PendingChangeSummary)
    setPendingChanges(changeMap)

    // Conductores sin documentos o sin vehiculo (no se pueden aprobar) + placas
    const [{ data: docsRows }, { data: vehRows }] = await Promise.all([
      supabase.from('driver_documents').select('driver_id'),
      supabase.from('vehicles').select('driver_id, plate, is_approved, shared_with_vehicle_id')
    ])
    const withDocs = new Set<string>((docsRows || []).map((r: any) => r.driver_id))
    const pendingVehicleIds = new Set<string>()
    const plates = new Map<string, string[]>()
    const sharedDrivers = new Set<string>()
    for (const r of (vehRows || [])) {
      if (!r.is_approved) pendingVehicleIds.add(r.driver_id)
      if (r.shared_with_vehicle_id && !r.is_approved) sharedDrivers.add(r.driver_id)
      const list = plates.get(r.driver_id) || []
      list.push(r.plate)
      plates.set(r.driver_id, list)
    }
    setPendingVeh(pendingVehicleIds)
    setSharedVehicleDrivers(sharedDrivers)
    setPlatesByDriver(plates)
    const withVeh = new Set<string>((vehRows || []).map((r: any) => r.driver_id))
    const incomplete = new Set<string>()
    for (const d of (data || [])) {
      if (!withDocs.has(d.id) || !withVeh.has(d.id) || !d.phone || !String(d.phone).trim()) incomplete.add(d.id)
    }
    setIncompleteDrivers(incomplete)

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
    setPendingChange(null)
    setSharedWithNames({})

    const [docRes, vehRes] = await Promise.all([
      supabase.from('driver_documents').select('*').eq('driver_id', driver.id).single(),
      supabase.from('vehicles').select('*').eq('driver_id', driver.id)
    ])

    const newDoc = !docRes.error && docRes.data ? (docRes.data as DriverDocument) : null
    const newVeh = !vehRes.error && vehRes.data ? (vehRes.data as Vehicle[]) : []

    setDocuments(newDoc)
    setVehicles(newVeh)

    // Nombre del companero de vehiculo compartido (principal <-> compartida)
    try {
      const ownIds = newVeh.map((v) => v.id)
      const primaryIds = [...new Set(newVeh.map((v) => v.shared_with_vehicle_id).filter(Boolean))] as string[]
      let primaries: any[] = []
      let secondaries: any[] = []

      if (primaryIds.length > 0) {
        const { data } = await supabase
          .from('vehicles')
          .select('id, driver_id')
          .in('id', primaryIds)
        primaries = data || []
      }

      if (ownIds.length > 0) {
        const { data } = await supabase
          .from('vehicles')
          .select('id, driver_id, shared_with_vehicle_id')
          .in('shared_with_vehicle_id', ownIds)
        secondaries = data || []
      }

      const partnerByVehicle: Record<string, string> = {}
      for (const v of newVeh) {
        if (v.shared_with_vehicle_id) {
          const primary = primaries.find((p: any) => p.id === v.shared_with_vehicle_id)
          if (primary) partnerByVehicle[v.id] = primary.driver_id
        } else {
          const secondary = secondaries.find((s: any) => s.shared_with_vehicle_id === v.id)
          if (secondary) partnerByVehicle[v.id] = secondary.driver_id
        }
      }

      const partnerIds = [...new Set(Object.values(partnerByVehicle))]
      if (partnerIds.length > 0) {
        const { data: partnerProfiles } = await supabase
          .from('profiles')
          .select('id, full_name')
          .in('id', partnerIds)
        const nameById = new Map((partnerProfiles || []).map((p: any) => [p.id, p.full_name]))
        const names: Record<string, string> = {}
        for (const [vehicleId, driverId] of Object.entries(partnerByVehicle)) {
          names[vehicleId] = nameById.get(driverId) || ''
        }
        setSharedWithNames(names)
      }
    } catch {
      // si falla el detalle de la pareja, el panel sigue funcionando
    }

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

    const { data: changeData } = await supabase
      .from('driver_change_requests')
      .select('*')
      .eq('driver_id', driver.id)
      .eq('status', 'pendiente')
      .maybeSingle()

    const change = (changeData as DriverChangeRequest | null) || null
    setPendingChange(change)

    if (change?.kind === 'documents') {
      const pendingUrls: { [key: string]: string } = {}
      if (change.payload?.cedula_photo_url) {
        const u = await getSignedUrl('documents', change.payload.cedula_photo_url)
        if (u) pendingUrls.cedulaPending = u
      }
      if (change.payload?.license_photo_url) {
        const u = await getSignedUrl('documents', change.payload.license_photo_url)
        if (u) pendingUrls.licensePending = u
      }
      if (Object.keys(pendingUrls).length) {
        setImageUrls((prev) => ({ ...prev, ...pendingUrls }))
      }
    }
  }

  const closeDriverDetails = () => {
    setSelectedDriver(null)
    openedFocusRef.current = null
    if (focusDriverId || focusType) {
      setSearchParams({}, { replace: true })
    }
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

      closeDriverDetails()
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

  const handleChangeReview = async (approve: boolean) => {
    if (!selectedDriver || !pendingChange) return
    setError('')
    setActionLoading(true)
    try {
      const { error } = await supabase.rpc('review_driver_change', {
        p_request_id: pendingChange.id,
        p_approve: approve,
        p_reason: approve ? null : 'Rechazada por el administrador'
      })
      if (error) throw error
      setPendingChange(null)
      await loadDriverDetails(selectedDriver)
      await loadDrivers()
    } catch (err: any) {
      setError(err.message)
    } finally {
      setActionLoading(false)
    }
  }

  const handleNameReview = async (approve: boolean) => {
    if (!selectedDriver) return
    setError('')
    setActionLoading(true)
    try {
      const { error } = await supabase.rpc('review_name_change', {
        p_driver_id: selectedDriver.id,
        p_approve: approve
      })
      if (error) throw error

      const updated: Profile = {
        ...selectedDriver,
        full_name: approve ? (selectedDriver.full_name_pending || selectedDriver.full_name) : selectedDriver.full_name,
        full_name_pending: null
      }
      setSelectedDriver(updated)
      setDrivers((prev) => prev.map((d) => (d.id === updated.id ? updated : d)))
    } catch (err: any) {
      setError(err.message)
    } finally {
      setActionLoading(false)
    }
  }

  const handleAvatarReview = async (approve: boolean) => {
    if (!selectedDriver) return
    setError('')
    setActionLoading(true)

    try {
      const { error } = await supabase.rpc('review_avatar', {
        p_driver_id: selectedDriver.id,
        p_approve: approve
      })

      if (error) throw error

      closeDriverDetails()
      loadDrivers()
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

  // Solo se puede aprobar si completo documentos y tiene vehiculo
  const canApproveSelected = !!selectedDriver && !!documents && vehicles.length > 0 && !!selectedDriver.phone && !!selectedDriver.phone.trim()

  const pendingTypes = (d: Profile): string[] => {
    const types: string[] = []
    if (d.driver_status === 'pendiente') types.push('Conductor nuevo')
    if (pendingVeh.has(d.id)) types.push('Vehículo')
    if (sharedVehicleDrivers.has(d.id)) types.push('Vehículo compartido')
    const change = pendingChanges.get(d.id)
    if (change) types.push(`Corrección: ${CHANGE_KIND_LABEL[change.kind] || change.kind}`)
    if (d.full_name_pending) types.push('Nombre')
    if (d.avatar_pending_url) types.push('Foto')
    return types
  }

  const counts: Record<DriverFilter, number> = {
    all: drivers.length,
    pending: drivers.filter((d) => pendingTypes(d).length > 0).length,
    new: drivers.filter((d) => d.driver_status === 'pendiente').length,
    vehicle: drivers.filter((d) => pendingVeh.has(d.id)).length,
    change: drivers.filter((d) => pendingChanges.has(d.id)).length,
    name: drivers.filter((d) => !!d.full_name_pending).length,
    avatar: drivers.filter((d) => !!d.avatar_pending_url).length,
    incomplete: drivers.filter((d) => incompleteDrivers.has(d.id)).length,
  }

  const normalizedQuery = query.trim().toLowerCase()
  const visibleDrivers = drivers
    .filter((d) => {
      if (filter === 'pending' && pendingTypes(d).length === 0) return false
      if (filter === 'new' && d.driver_status !== 'pendiente') return false
      if (filter === 'vehicle' && !pendingVeh.has(d.id)) return false
      if (filter === 'change' && !pendingChanges.has(d.id)) return false
      if (filter === 'name' && !d.full_name_pending) return false
      if (filter === 'avatar' && !d.avatar_pending_url) return false
      if (filter === 'incomplete' && !incompleteDrivers.has(d.id)) return false
      if (!normalizedQuery) return true
      const plates = (platesByDriver.get(d.id) || []).join(' ').toLowerCase()
      return [d.full_name, d.email, d.phone, plates]
        .filter(Boolean)
        .some((value) => String(value).toLowerCase().includes(normalizedQuery))
    })
    .sort((a, b) => {
      const aPending = pendingTypes(a).length > 0 ? 0 : 1
      const bPending = pendingTypes(b).length > 0 ? 0 : 1
      if (aPending !== bPending) return aPending - bPending
      return new Date(b.created_at).getTime() - new Date(a.created_at).getTime()
    })

  useEffect(() => {
    if (!focusDriverId || loading) return
    if (openedFocusRef.current === focusDriverId) return
    const driver = drivers.find((d) => d.id === focusDriverId)
    if (!driver) return
    openedFocusRef.current = focusDriverId
    void loadDriverDetails(driver)
  }, [focusDriverId, loading, drivers])

  useEffect(() => {
    if (!selectedDriver || !focusType) return
    const cardIds: Record<string, string> = {
      change: 'card-change',
      vehicle: 'card-vehicle',
      name: 'card-name',
      avatar: 'card-avatar',
      pending: 'card-actions',
    }
    const cardId = cardIds[focusType]
    if (!cardId) return
    const timer = window.setTimeout(() => {
      document.getElementById(cardId)?.scrollIntoView({ behavior: 'smooth', block: 'center' })
    }, 300)
    return () => window.clearTimeout(timer)
  }, [selectedDriver, focusType, pendingChange, documents, vehicles])

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
            {counts.pending > 0 && (
              <button
                onClick={() => setFilter('pending')}
                className="w-full flex items-center gap-3 rounded-2xl border-2 border-amber-200 bg-amber-50 p-3 text-left"
              >
                <AlertTriangle className="w-5 h-5 text-amber-600 flex-shrink-0" />
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-semibold text-amber-800">
                    {counts.pending} solicitud{counts.pending === 1 ? '' : 'es'} pendiente{counts.pending === 1 ? '' : 's'}
                  </p>
                  <p className="text-xs text-amber-700">Revisa conductores nuevos, vehículos, correcciones, nombres o fotos.</p>
                </div>
                <span className="text-xs font-bold text-amber-700">Ver →</span>
              </button>
            )}

            <div className="relative">
              <Search className="w-4 h-4 text-surface-400 absolute left-3 top-1/2 -translate-y-1/2" />
              <input
                className="input pl-9"
                placeholder="Buscar por nombre, teléfono, correo o placa"
                value={query}
                onChange={(e) => setQuery(e.target.value)}
              />
            </div>

            <div className="flex gap-2 overflow-x-auto pb-1 -mx-1 px-1">
              {DRIVER_FILTERS.map((f) => (
                <button
                  key={f.key}
                  onClick={() => setFilter(f.key)}
                  className={`whitespace-nowrap rounded-full px-3 py-1.5 text-xs font-semibold border transition-colors ${
                    filter === f.key
                      ? 'bg-primary-600 text-white border-primary-600'
                      : f.key === 'pending' && counts.pending > 0
                        ? 'bg-amber-50 text-amber-700 border-amber-200'
                        : 'bg-white text-surface-600 border-surface-200'
                  }`}
                >
                  {f.label} ({counts[f.key]})
                </button>
              ))}
            </div>

            <p className="text-xs text-surface-400">
              {visibleDrivers.length} conductor{visibleDrivers.length === 1 ? '' : 'es'}
              {filter !== 'all' ? ` en “${DRIVER_FILTERS.find((f) => f.key === filter)?.label}”` : ''}
            </p>

            {visibleDrivers.length === 0 ? (
              <EmptyState
                icon={<Users className="w-8 h-8" />}
                title="Sin resultados"
                description="No hay conductores que coincidan con la búsqueda o el filtro."
              />
            ) : (
              <div className="space-y-2">
                {visibleDrivers.map((driver) => {
                  const types = pendingTypes(driver)
                  const isFocused = focusDriverId === driver.id
                  const plates = platesByDriver.get(driver.id) || []
                  return (
                    <div
                      key={driver.id}
                      className={`card p-3 ${types.length > 0 ? 'border-l-4 border-l-amber-400' : ''} ${isFocused ? 'ring-2 ring-amber-400 bg-amber-50/40' : ''}`}
                    >
                      <div className="flex items-start gap-3">
                        <div className="w-11 h-11 bg-primary-50 rounded-full flex items-center justify-center overflow-hidden flex-shrink-0">
                          {driver.avatar_url ? (
                            <img src={resolvePhotoUrl(driver.avatar_url, 'avatars')} alt={driver.full_name} loading="lazy" decoding="async" className="w-full h-full object-cover" />
                          ) : (
                            <Users className="w-5 h-5 text-primary-600" />
                          )}
                        </div>
                        <div className="flex-1 min-w-0">
                          <div className="flex items-start justify-between gap-2">
                            <div className="min-w-0">
                              <p className="font-medium text-surface-800 truncate">{driver.full_name}</p>
                              <p className="text-xs text-surface-400 truncate">{driver.phone || 'Sin teléfono'} • {driver.email}</p>
                              {plates.length > 0 && (
                                <p className="text-xs text-surface-400 truncate">Placa: {plates.join(', ')}</p>
                              )}
                            </div>
                            <div className="flex flex-col items-end gap-1 flex-shrink-0">
                              {statusBadge[driver.driver_status || 'pendiente']}
                            </div>
                          </div>
                          {(types.length > 0 || incompleteDrivers.has(driver.id)) && (
                            <div className="flex flex-wrap gap-1 mt-1">
                              {types.map((t) => (
                                <span key={t} className="badge-warning text-[10px]">{t}</span>
                              ))}
                              {incompleteDrivers.has(driver.id) && (
                                <span className="badge-danger text-[10px]" title="No completó teléfono/documentos/vehículo">Sin datos</span>
                              )}
                            </div>
                          )}
                        </div>
                      </div>
                      <div className="flex items-center gap-2 mt-2 flex-wrap">
                        <button onClick={() => loadDriverDetails(driver)} className="btn-outline flex-1 py-1.5 text-xs whitespace-nowrap">
                          <Eye className="w-3.5 h-3.5" />
                          Revisar
                        </button>
                        {driver.driver_status === 'pendiente' && (
                          <>
                            <button
                              onClick={() => handleReview(driver.id, true)}
                              className="btn-success px-3 py-1.5 text-xs"
                              disabled={actionLoading || incompleteDrivers.has(driver.id)}
                              title={incompleteDrivers.has(driver.id) ? 'No completó teléfono/documentos/vehículo' : 'Aprobar conductor'}
                            >
                              <Check className="w-3.5 h-3.5" /> Aprobar
                            </button>
                            <button
                              onClick={() => handleReview(driver.id, false)}
                              className="btn-danger px-3 py-1.5 text-xs"
                              disabled={actionLoading}
                            >
                              <X className="w-3.5 h-3.5" /> Rechazar
                            </button>
                          </>
                        )}
                      </div>
                    </div>
                  )
                })}
              </div>
            )}
          </div>
        )}
      </div>

      {/* Modal de detalles */}
      {selectedDriver && (
        <div className="fixed inset-0 bg-black/40 z-50 flex items-end justify-center" onClick={closeDriverDetails}>
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
                    {selectedDriver.phone && (
                      <div className="flex items-center gap-2 mt-1">
                        <span className="text-sm text-surface-600">{selectedDriver.phone}</span>
                        {whatsappNumber(selectedDriver.phone) && (
                          <a
                            href={`https://wa.me/${whatsappNumber(selectedDriver.phone)}`}
                            target="_blank"
                            rel="noopener noreferrer"
                            className="inline-flex items-center gap-1 text-xs font-medium text-emerald-600 hover:text-emerald-700"
                          >
                            <MessageCircle className="w-3.5 h-3.5" /> WhatsApp
                          </a>
                        )}
                      </div>
                    )}
                  </div>
                </div>

                {documents && (
                  <>
                    <p className="text-sm text-surface-600"><strong>Cédula:</strong> {documents.cedula_number}</p>
                    <p className="text-sm text-surface-600"><strong>Licencia:</strong> {documents.license_number || '—'}</p>
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

              {pendingChange && (
                <div id="card-change" className={`card border-2 border-amber-200 ${focusType === 'change' ? 'ring-2 ring-amber-400' : ''}`}>
                  <h3 className="font-semibold text-surface-700 mb-3">Solicitud de corrección</h3>
                  <p className="text-xs text-surface-500 mb-2">
                    Tipo: {pendingChange.kind === 'documents' ? 'Documentos' : pendingChange.kind === 'vehicle' ? 'Vehículo' : 'Teléfono'}
                  </p>
                  <div className="text-sm text-surface-600 space-y-1">
                    {pendingChange.kind === 'phone' && (
                      <p><strong>Nuevo teléfono:</strong> {pendingChange.payload?.phone}</p>
                    )}
                    {pendingChange.kind === 'documents' && (
                      <>
                        <p><strong>Cédula:</strong> {pendingChange.payload?.cedula_number}</p>
                        <p><strong>Licencia:</strong> {pendingChange.payload?.license_number || '—'}</p>
                        <p><strong>Vence:</strong> {pendingChange.payload?.license_expiry_date}</p>
                        {imageUrls.cedulaPending && (
                          <a href={imageUrls.cedulaPending} target="_blank" rel="noopener noreferrer" className="text-xs text-primary-600 underline">Ver nueva foto de cédula</a>
                        )}
                        {imageUrls.licensePending && (
                          <a href={imageUrls.licensePending} target="_blank" rel="noopener noreferrer" className="text-xs text-primary-600 underline">Ver nueva foto de licencia</a>
                        )}
                      </>
                    )}
                    {pendingChange.kind === 'vehicle' && (
                      <>
                        <p><strong>Vehículo:</strong> {pendingChange.payload?.brand} {pendingChange.payload?.model} ({pendingChange.payload?.year})</p>
                        <p><strong>Placa:</strong> {pendingChange.payload?.plate}</p>
                        <p><strong>Tipo:</strong> {pendingChange.payload?.category}</p>
                        <p><strong>Color:</strong> {pendingChange.payload?.color}</p>
                      </>
                    )}
                  </div>
                  <div className="grid grid-cols-2 gap-2 mt-3">
                    <button onClick={() => handleChangeReview(true)} className="btn-success" disabled={actionLoading}>
                      {actionLoading ? <Loader2 className="w-4 h-4 animate-spin" /> : <><Check className="w-4 h-4" /> Aprobar</>}
                    </button>
                    <button onClick={() => handleChangeReview(false)} className="btn-danger" disabled={actionLoading}>
                      {actionLoading ? <Loader2 className="w-4 h-4 animate-spin" /> : <><X className="w-4 h-4" /> Rechazar</>}
                    </button>
                  </div>
                </div>
              )}

              {/* Cambio de foto de perfil pendiente de aprobación */}
              {selectedDriver.avatar_pending_url && (
                <div id="card-avatar" className={`card ${focusType === 'avatar' ? 'ring-2 ring-amber-400' : ''}`}>
                  <h3 className="font-semibold text-surface-700 mb-3">Cambio de foto de perfil</h3>
                  <div className="flex items-center gap-3">
                    <div className="flex-1 text-center">
                      <p className="text-[10px] text-surface-400 mb-1">Actual (en uso)</p>
                      <div className="w-14 h-14 mx-auto rounded-full bg-primary-50 overflow-hidden flex items-center justify-center">
                        {selectedDriver.avatar_url ? (
                          <img src={resolvePhotoUrl(selectedDriver.avatar_url, 'avatars')} alt="Foto actual" className="w-full h-full object-cover" />
                        ) : (
                          <Users className="w-6 h-6 text-primary-600" />
                        )}
                      </div>
                    </div>
                    <span className="text-surface-300 font-bold">→</span>
                    <div className="flex-1 text-center">
                      <p className="text-[10px] text-surface-400 mb-1">Nueva (por aprobar)</p>
                      <div className="w-14 h-14 mx-auto rounded-full bg-amber-50 overflow-hidden flex items-center justify-center border-2 border-amber-200">
                        <img
                          src={resolvePhotoUrl(selectedDriver.avatar_pending_url, 'avatars')}
                          alt="Nueva foto"
                          className="w-full h-full object-cover"
                        />
                      </div>
                    </div>
                  </div>
                  <div className="flex gap-2 mt-4">
                    <button
                      onClick={() => handleAvatarReview(true)}
                      className="btn-success flex-1"
                      disabled={actionLoading}
                    >
                      {actionLoading ? <Loader2 className="w-4 h-4 animate-spin" /> : <><Check className="w-4 h-4" /> Aprobar</>}
                    </button>
                    <button
                      onClick={() => handleAvatarReview(false)}
                      className="btn-danger flex-1"
                      disabled={actionLoading}
                    >
                      {actionLoading ? <Loader2 className="w-4 h-4 animate-spin" /> : <><X className="w-4 h-4" /> Rechazar</>}
                    </button>
                  </div>
                </div>
              )}

              {/* Cambio de nombre solicitado */}
              {selectedDriver.full_name_pending && (
                <div id="card-name" className={`card border-2 border-amber-200 bg-amber-50/50 ${focusType === 'name' ? 'ring-2 ring-amber-400' : ''}`}>
                  <h3 className="font-semibold text-surface-700 mb-2">Cambio de nombre solicitado</h3>
                  <p className="text-sm text-surface-600">Actual: <strong>{selectedDriver.full_name}</strong></p>
                  <p className="text-sm text-surface-600">Nuevo: <strong>{selectedDriver.full_name_pending}</strong></p>
                  <div className="flex gap-2 mt-3">
                    <button onClick={() => handleNameReview(true)} className="btn-success flex-1" disabled={actionLoading}>Aprobar</button>
                    <button onClick={() => handleNameReview(false)} className="btn-danger flex-1" disabled={actionLoading}>Rechazar</button>
                  </div>
                </div>
              )}

              {/* Vehículo */}
              {vehicles.length > 0 && (
                <div id="card-vehicle" className={`card ${focusType === 'vehicle' ? 'ring-2 ring-amber-400' : ''}`}>
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
                          <p>Capacidad: {v.max_passengers || 1} pasajero{(v.max_passengers || 1) === 1 ? '' : 's'}</p>
                          <div className="flex flex-wrap items-center gap-2 mt-2">
                            <span className={`badge ${v.is_active_vehicle ? 'badge-success' : v.is_approved ? 'badge-info' : 'badge-warning'}`}>
                              {v.is_active_vehicle ? 'Activo' : v.is_approved ? 'Aprobado' : 'Pendiente'}
                            </span>
                            {sharedWithNames[v.id] !== undefined && (
                              <span className="badge-info">
                                Compartido{sharedWithNames[v.id] ? ` con ${sharedWithNames[v.id]}` : ''}
                              </span>
                            )}
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
              {selectedDriver.driver_status === 'pendiente' && !canApproveSelected && (
                <div className="bg-amber-50 border border-amber-200 rounded-xl p-3">
                  <p className="text-xs text-amber-800">
                    Este conductor no completó su registro (falta teléfono, documentos y/o vehículo). Pídele que complete sus datos antes de aprobarlo.
                  </p>
                </div>
              )}
              <div id="card-actions" className={`grid grid-cols-2 gap-2 ${focusType === 'pending' ? 'ring-2 ring-amber-400 rounded-xl p-1' : ''}`}>
                {selectedDriver.driver_status === 'pendiente' && (
                  <>
                    <button
                      onClick={() => handleReview(selectedDriver.id, true)}
                      className="btn-success"
                      disabled={actionLoading || !canApproveSelected}
                    >
                      {actionLoading ? <Loader2 className="w-4 h-4 animate-spin" /> : <><Check className="w-4 h-4" /> Aprobar</>}
                    </button>
                    <button
                      onClick={() => handleReview(selectedDriver.id, false)}
                      className="btn-danger"
                      disabled={actionLoading}
                    >
                      {actionLoading ? <Loader2 className="w-4 h-4 animate-spin" /> : <><X className="w-4 h-4" /> Rechazar</>}
                    </button>
                  </>
                )}
                <button onClick={closeDriverDetails} className="btn-outline col-span-2">
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