import { useEffect, useState } from 'react'
import { AlertTriangle, Loader2, UserCog, X } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { uploadImageToStorage, uploadImageToExternalHost } from '@/lib/uploadImage'
import type { Vehicle, VehicleCategory, VehicleCategoryType } from '@/types/database'
import type { DriverProfileState } from '@/hooks/useDriverProfileState'

type Kind = 'documents' | 'vehicle' | 'phone'

interface Props {
  state: DriverProfileState
  vehicles: Vehicle[]
  categories: VehicleCategory[]
  onRequested: () => void
}

export function DriverCorrectionRequest({ state, vehicles, categories, onRequested }: Props) {
  const { user } = useAuth()
  const [open, setOpen] = useState(false)
  const [kind, setKind] = useState<Kind>('vehicle')
  const [busy, setBusy] = useState(false)
  const [err, setErr] = useState('')

  const [cedulaNumber, setCedulaNumber] = useState(state.documents?.cedula_number || '')
  const [licenseNumber, setLicenseNumber] = useState(state.documents?.license_number || '')
  const [licenseExpiry, setLicenseExpiry] = useState(state.documents?.license_expiry_date || '')
  const [cedulaFile, setCedulaFile] = useState<File | null>(null)
  const [licenseFile, setLicenseFile] = useState<File | null>(null)

  const [phone, setPhone] = useState(state.phone || '')

  const first = vehicles[0]
  const [vehicleId, setVehicleId] = useState(first?.id || '')
  const [vCategory, setVCategory] = useState<VehicleCategoryType>(first?.category || categories[0]?.name || 'moto_basica')
  const [vBrand, setVBrand] = useState(first?.brand || '')
  const [vModel, setVModel] = useState(first?.model || '')
  const [vYear, setVYear] = useState(first ? String(first.year) : '')
  const [vColor, setVColor] = useState(first?.color || '')
  const [vPlate, setVPlate] = useState(first?.plate || '')
  const [vehiclePhoto, setVehiclePhoto] = useState<File | null>(null)

  useEffect(() => {
    if (!vehicleId && vehicles[0]) {
      const v = vehicles[0]
      setVehicleId(v.id)
      setVCategory(v.category)
      setVBrand(v.brand)
      setVModel(v.model)
      setVYear(String(v.year))
      setVColor(v.color)
      setVPlate(v.plate)
    }
  }, [vehicles, vehicleId])

  const selectedVehicle = vehicles.find((v) => v.id === vehicleId)

  const reset = () => {
    setErr('')
    setKind('vehicle')
    setCedulaFile(null)
    setLicenseFile(null)
    setVehiclePhoto(null)
  }

  const submit = async () => {
    if (!user) return
    setErr('')
    setBusy(true)
    try {
      if (kind === 'documents') {
        const ts = Date.now()
        const cedulaUrl = cedulaFile
          ? (await uploadImageToStorage('documents', `${user.id}/cedula-${ts}.jpg`, cedulaFile, 'document')).path
          : state.documents?.cedula_photo_url || ''
        const licenseUrl = licenseFile
          ? (await uploadImageToStorage('documents', `${user.id}/license-${ts}.jpg`, licenseFile, 'document')).path
          : state.documents?.license_photo_url || ''

        const { error } = await supabase.rpc('request_driver_change', {
          p_kind: 'documents',
          p_payload: {
            cedula_number: cedulaNumber,
            cedula_photo_url: cedulaUrl,
            license_number: licenseNumber || null,
            license_photo_url: licenseUrl,
            license_expiry_date: licenseExpiry
          }
        })
        if (error) throw error
      } else if (kind === 'phone') {
        const { error } = await supabase.rpc('request_driver_change', {
          p_kind: 'phone',
          p_payload: { phone }
        })
        if (error) throw error
      } else {
        if (!selectedVehicle) throw new Error('Selecciona un vehículo')
        const photo = vehiclePhoto
          ? (await uploadImageToExternalHost(vehiclePhoto, 'vehicle')).url
          : selectedVehicle.photo_url || null

        const { error } = await supabase.rpc('request_driver_change', {
          p_kind: 'vehicle',
          p_payload: {
            vehicle_id: selectedVehicle.id,
            category: vCategory,
            brand: vBrand,
            model: vModel,
            year: vYear,
            color: vColor,
            plate: vPlate,
            photo_url: photo
          }
        })
        if (error) throw error
      }

      reset()
      setOpen(false)
      onRequested()
    } catch (e: any) {
      setErr(e?.message || 'No se pudo enviar la solicitud')
    } finally {
      setBusy(false)
    }
  }
  if (state.pending_request) {
    return (
      <div className="card flex items-center gap-3">
        <div className="w-10 h-10 bg-amber-50 rounded-full flex items-center justify-center flex-shrink-0">
          <AlertTriangle className="w-5 h-5 text-amber-600" />
        </div>
        <div className="flex-1 min-w-0">
          <p className="font-medium text-surface-700">Corrección en revisión</p>
          <p className="text-xs text-surface-400">El administrador revisará los datos que enviaste.</p>
        </div>
      </div>
    )
  }

  return (
    <>
      <button type="button" onClick={() => { reset(); setOpen(true) }} className="card w-full flex items-center gap-3 p-4 text-left hover:border-primary-300 transition-colors">
        <div className="w-10 h-10 bg-primary-50 rounded-full flex items-center justify-center flex-shrink-0">
          <UserCog className="w-5 h-5 text-primary-600" />
        </div>
        <div className="flex-1 min-w-0">
          <p className="font-medium text-surface-700">Solicitar corrección</p>
          <p className="text-xs text-surface-400">Documentos, vehículo o teléfono (con aprobación)</p>
        </div>
      </button>

      {open && (
        <div className="fixed inset-0 bg-black/50 z-[15000] flex items-center justify-center p-4" onClick={() => setOpen(false)}>
          <div className="bg-white rounded-2xl p-5 max-w-lg w-full max-h-[90vh] overflow-y-auto" onClick={(e) => e.stopPropagation()}>
            <div className="flex items-center justify-between mb-3">
              <h3 className="font-bold text-surface-800">Solicitar corrección</h3>
              <button type="button" onClick={() => setOpen(false)} className="p-1 text-surface-400" aria-label="Cerrar">
                <X className="w-4 h-4" />
              </button>
            </div>

            <div className="grid grid-cols-3 gap-2 mb-4">
              {(['documents', 'vehicle', 'phone'] as Kind[]).map((k) => (
                <button
                  key={k}
                  type="button"
                  onClick={() => { setKind(k); setErr('') }}
                  className={`p-2 rounded-xl border-2 text-xs font-medium transition-all ${kind === k ? 'border-primary-600 bg-primary-50 text-primary-700' : 'border-surface-200 text-surface-600'}`}
                >
                  {k === 'documents' ? 'Documentos' : k === 'vehicle' ? 'Vehículo' : 'Teléfono'}
                </button>
              ))}
            </div>

            {err && <p className="text-xs text-red-600 mb-2">{err}</p>}

            {kind === 'documents' && (
              <div className="space-y-3">
                <div>
                  <label className="label">Cédula *</label>
                  <input className="input" value={cedulaNumber} onChange={(e) => setCedulaNumber(e.target.value)} />
                </div>
                <div>
                  <label className="label">Licencia (opcional)</label>
                  <input className="input" value={licenseNumber} onChange={(e) => setLicenseNumber(e.target.value)} />
                </div>
                <div>
                  <label className="label">Vencimiento de la licencia *</label>
                  <input type="date" className="input" value={licenseExpiry} onChange={(e) => setLicenseExpiry(e.target.value)} />
                </div>
                <div>
                  <label className="label">Foto de cédula {state.documents?.cedula_photo_url ? '(mantener la actual)' : '*'}</label>
                  <input type="file" accept="image/*" onChange={(e) => setCedulaFile(e.target.files?.[0] || null)} />
                </div>
                <div>
                  <label className="label">Foto de licencia {state.documents?.license_photo_url ? '(mantener la actual)' : '*'}</label>
                  <input type="file" accept="image/*" onChange={(e) => setLicenseFile(e.target.files?.[0] || null)} />
                </div>
              </div>
            )}

            {kind === 'vehicle' && (
              <div className="space-y-3">
                <div>
                  <label className="label">Vehículo *</label>
                  <select
                    className="input"
                    value={vehicleId}
                    onChange={(e) => {
                      const id = e.target.value
                      setVehicleId(id)
                      const v = vehicles.find((x) => x.id === id)
                      if (v) {
                        setVCategory(v.category)
                        setVBrand(v.brand)
                        setVModel(v.model)
                        setVYear(String(v.year))
                        setVColor(v.color)
                        setVPlate(v.plate)
                        setVehiclePhoto(null)
                      }
                    }}
                  >
                    {vehicles.map((v) => (
                      <option key={v.id} value={v.id}>{v.brand} {v.model} • {v.plate}</option>
                    ))}
                  </select>
                </div>
                <div className="grid grid-cols-2 gap-3">
                  <div>
                    <label className="label">Tipo *</label>
                    <select className="input" value={vCategory} onChange={(e) => setVCategory(e.target.value as VehicleCategoryType)}>
                      {categories.map((c) => <option key={c.id} value={c.name}>{c.display_name}</option>)}
                    </select>
                  </div>
                  <div>
                    <label className="label">Año *</label>
                    <input type="number" className="input" value={vYear} onChange={(e) => setVYear(e.target.value)} />
                  </div>
                  <div>
                    <label className="label">Marca *</label>
                    <input className="input" value={vBrand} onChange={(e) => setVBrand(e.target.value)} />
                  </div>
                  <div>
                    <label className="label">Modelo *</label>
                    <input className="input" value={vModel} onChange={(e) => setVModel(e.target.value)} />
                  </div>
                  <div>
                    <label className="label">Color *</label>
                    <input className="input" value={vColor} onChange={(e) => setVColor(e.target.value)} />
                  </div>
                  <div>
                    <label className="label">Placa *</label>
                    <input className="input" value={vPlate} onChange={(e) => setVPlate(e.target.value.toUpperCase())} />
                  </div>
                </div>
                <div>
                  <label className="label">Foto (opcional)</label>
                  <input type="file" accept="image/*" onChange={(e) => setVehiclePhoto(e.target.files?.[0] || null)} />
                </div>
              </div>
            )}

            {kind === 'phone' && (
              <div>
                <label className="label">Teléfono *</label>
                <input className="input" value={phone} onChange={(e) => setPhone(e.target.value)} />
                <p className="text-[11px] text-surface-400 mt-1">El cambio se aplica cuando el administrador lo apruebe.</p>
              </div>
            )}

            <button type="button" onClick={submit} disabled={busy} className="btn-primary w-full mt-4">
              {busy ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Enviar solicitud'}
            </button>
          </div>
        </div>
      )}
    </>
  )
}