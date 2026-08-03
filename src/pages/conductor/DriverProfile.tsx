import { useNavigate } from 'react-router-dom'
import { User, LogOut, Star, Phone, Car, Hexagon } from 'lucide-react'
import { useAuth } from '@/contexts/AuthContext'

export function DriverProfile() {
  const { user, signOut } = useAuth()
  const navigate = useNavigate()

  const handleSignOut = async () => {
    await signOut()
    navigate('/login')
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 bg-primary-600 rounded-xl flex items-center justify-center">
            <Hexagon className="w-5 h-5 text-white" />
          </div>
          <div>
            <h1 className="text-lg font-bold text-surface-800">Mi Perfil</h1>
            <p className="text-xs text-surface-500">Información personal</p>
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6 space-y-4">
        <div className="card flex items-center gap-4">
          <div className="w-16 h-16 bg-primary-50 rounded-full flex items-center justify-center">
            <User className="w-8 h-8 text-primary-600" />
          </div>
          <div className="flex-1">
            <h2 className="font-semibold text-surface-800">{user?.full_name}</h2>
            <p className="text-sm text-surface-500">{user?.email}</p>
            <span className="badge-primary mt-1">Conductor</span>
          </div>
        </div>

        <div className="card">
          <div className="flex items-center justify-between mb-3">
            <span className="text-sm font-medium text-surface-700">Estado de la cuenta</span>
            {user?.driver_status === 'aprobado' ? (
              <span className="badge-success">Aprobado</span>
            ) : (
              <span className="badge-warning">Pendiente</span>
            )}
          </div>
          {user?.phone && (
            <div className="flex items-center gap-2 text-sm text-surface-600">
              <Phone className="w-4 h-4 text-primary-600" />
              {user.phone}
            </div>
          )}
        </div>

        <div className="card">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 bg-amber-50 rounded-full flex items-center justify-center">
              <Star className="w-5 h-5 text-amber-500" />
            </div>
            <div>
              <p className="font-medium text-surface-700">Mi calificación</p>
              <p className="text-xs text-surface-400">Tu promedio como conductor</p>
            </div>
          </div>
        </div>

        <button onClick={handleSignOut} className="btn-danger w-full">
          <LogOut className="w-4 h-4" />
          Cerrar sesión
        </button>
      </div>
    </div>
  )
}