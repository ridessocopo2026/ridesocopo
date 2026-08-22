import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { ClipboardCheck, ShieldAlert, Users, UserCheck, Receipt, MapPin, LogOut } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { AppLogo } from '@/components/ui/AppLogo'

const modules = [
  { to: '/encargado/comprobantes', icon: <ClipboardCheck className="w-6 h-6" />, title: 'Comprobantes', desc: 'Verificar pagos y recargas' },
  { to: '/encargado/incidentes', icon: <ShieldAlert className="w-6 h-6" />, title: 'Incidentes', desc: 'Atender incidentes de viajes' },
  { to: '/encargado/conductores', icon: <Users className="w-6 h-6" />, title: 'Conductores', desc: 'Aprobar y gestionar' },
  { to: '/encargado/usuarios', icon: <UserCheck className="w-6 h-6" />, title: 'Usuarios', desc: 'Pasajeros y conductores' },
  { to: '/encargado/transacciones', icon: <Receipt className="w-6 h-6" />, title: 'Transacciones', desc: 'Movimientos de dinero' }
]

export function EncargadoDashboard() {
  const { user, signOut } = useAuth()
  const navigate = useNavigate()
  const [zoneName, setZoneName] = useState('')

  useEffect(() => {
    if (user?.zone_id) {
      supabase
        .from('zones')
        .select('name')
        .eq('id', user.zone_id)
        .single()
        .then(({ data }) => { if (data) setZoneName(data.name) })
    }
  }, [user?.zone_id])

  const handleSignOut = async () => {
    await signOut()
    navigate('/login')
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-primary-600 border-b border-primary-700 px-6 py-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <AppLogo variant="dark" />
            <div>
              <h1 className="text-lg font-bold text-white">Panel del Encargado</h1>
              <p className="text-xs text-white/80 flex items-center gap-1">
                <MapPin className="w-3 h-3" /> {zoneName || 'Tu ciudad'}
              </p>
            </div>
          </div>
          <button onClick={handleSignOut} className="p-2 text-white/80 hover:text-white transition-colors">
            <LogOut className="w-5 h-5" />
          </button>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6 space-y-4">
        <div className="grid grid-cols-2 gap-3">
          {modules.map((m) => (
            <button
              key={m.to}
              onClick={() => navigate(m.to)}
              className="card card-hover p-4 text-left"
            >
              <div className="w-11 h-11 bg-primary-50 rounded-xl flex items-center justify-center text-primary-600 mb-2">
                {m.icon}
              </div>
              <p className="font-semibold text-surface-800">{m.title}</p>
              <p className="text-xs text-surface-400 mt-0.5">{m.desc}</p>
            </button>
          ))}
        </div>
      </div>
    </div>
  )
}
