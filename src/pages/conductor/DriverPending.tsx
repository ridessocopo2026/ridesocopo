import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Clock, ShieldCheck, LogOut, ClipboardList } from 'lucide-react'
import { useAuth } from '@/contexts/AuthContext'
import { supabase } from '@/lib/supabase'
import { HexUnderline } from '@/components/ui/HexUnderline'

export function DriverPending() {
  const { user, signOut } = useAuth()
  const navigate = useNavigate()
  const [loadingDocs, setLoadingDocs] = useState(true)
  const [incomplete, setIncomplete] = useState(false)

  useEffect(() => {
    if (!user?.id) return
    let cancelled = false
    ;(async () => {
      const [{ data: docs }, { data: vehicles }] = await Promise.all([
        supabase.from('driver_documents').select('cedula_photo_url, license_photo_url').eq('driver_id', user.id).maybeSingle(),
        supabase.from('vehicles').select('id').eq('driver_id', user.id).limit(1)
      ])
      if (cancelled) return
      const d = docs as { cedula_photo_url?: string | null; license_photo_url?: string | null } | null
      const hasDocs = !!d && !!d.cedula_photo_url && !!d.license_photo_url
      const hasVehicle = (vehicles || []).length > 0
      const hasPhone = !!user.phone && !!user.phone.trim()
      setIncomplete(!hasDocs || !hasVehicle || !hasPhone)
      setLoadingDocs(false)
    })()
    return () => { cancelled = true }
  }, [user?.id, user?.phone])

  const handleSignOut = async () => {
    await signOut()
    navigate('/login')
  }

  return (
    <div className="min-h-screen bg-white flex flex-col items-center justify-center px-6 py-12">
      <div className="w-full max-w-sm text-center">
        <div className="w-20 h-20 bg-amber-50 rounded-2xl flex items-center justify-center mx-auto mb-6 border-2 border-amber-200">
          <Clock className="w-10 h-10 text-amber-500" />
        </div>

        <h1 className="text-2xl font-bold text-surface-800 mb-2">
          {incomplete ? 'Completa tus datos' : 'Cuenta en Revisión'}
        </h1>
        <HexUnderline />

        <div className="pending-banner mb-6">
          <ShieldCheck className="w-5 h-5 text-amber-500 flex-shrink-0 mt-0.5" />
          <div className="text-left">
            <p className="text-sm font-medium text-amber-800">
              {incomplete ? 'Aún no has completado tu registro de conductor.' : 'Tu cuenta está en revisión.'}
            </p>
            <p className="text-xs text-amber-700 mt-1">
              {incomplete
                ? 'Sube tus documentos y los datos de tu vehículo para que podamos revisarte.'
                : 'Te notificaremos cuando sea aprobada. Este proceso puede tomar hasta 24 horas.'}
            </p>
          </div>
        </div>

        {!loadingDocs && incomplete && (
          <button onClick={() => navigate('/conductor/onboarding')} className="btn-primary w-full mb-3">
            <ClipboardList className="w-4 h-4" />
            Completar mis datos
          </button>
        )}

        <div className="card mb-6">
          <div className="flex items-center justify-between mb-4">
            <span className="text-sm text-surface-500">Estado</span>
            <span className="badge-warning">PENDIENTE</span>
          </div>

          <div className="flex items-center justify-between">
            <span className="text-sm text-surface-500">Disponibilidad</span>
            <div className="flex items-center gap-2">
              <span className="text-sm text-surface-400">En línea</span>
              <div className="w-12 h-7 bg-surface-200 rounded-full flex items-center px-1 opacity-40">
                <div className="w-5 h-5 bg-white rounded-full shadow" />
              </div>
            </div>
          </div>
        </div>

        <div className="bg-surface-50 rounded-xl p-4 mb-6">
          <p className="text-sm text-surface-600">
            <strong>¿Qué sigue?</strong>
            <br />
            Un administrador revisará tus documentos y datos del vehículo.
            Una vez aprobado, podrás comenzar a recibir solicitudes de viaje.
          </p>
        </div>

        {!loadingDocs && !incomplete && (
          <button onClick={() => navigate('/conductor/onboarding')} className="btn-outline w-full mb-3">
            <ClipboardList className="w-4 h-4" />
            Actualizar mis datos
          </button>
        )}

        <button onClick={handleSignOut} className="btn-outline w-full">
          <LogOut className="w-4 h-4" />
          Cerrar sesión
        </button>
      </div>
    </div>
  )
}