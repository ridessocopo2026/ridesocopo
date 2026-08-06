import { useNavigate } from 'react-router-dom'
import { Clock, ShieldCheck, LogOut } from 'lucide-react'
import { useAuth } from '@/contexts/AuthContext'
import { HexUnderline } from '@/components/ui/HexUnderline'

export function DriverPending() {
  const { user, signOut } = useAuth()
  const navigate = useNavigate()

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
          Cuenta en Revisión
        </h1>
        <HexUnderline />

        {/* Banner fijo de estado pendiente */}
        <div className="pending-banner mb-6">
          <ShieldCheck className="w-5 h-5 text-amber-500 flex-shrink-0 mt-0.5" />
          <div className="text-left">
            <p className="text-sm font-medium text-amber-800">
              Tu cuenta está en revisión.
            </p>
            <p className="text-xs text-amber-700 mt-1">
              Te notificaremos cuando sea aprobada. Este proceso puede tomar hasta 24 horas.
            </p>
          </div>
        </div>

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

        <button onClick={handleSignOut} className="btn-outline w-full">
          <LogOut className="w-4 h-4" />
          Cerrar sesión
        </button>
      </div>
    </div>
  )
}