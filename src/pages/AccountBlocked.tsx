import { useEffect, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { ShieldAlert, PauseCircle, UserX, MessageCircle, LogOut, RefreshCw } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { whatsappNumber } from '@/lib/format'
import { HexUnderline } from '@/components/ui/HexUnderline'

/**
 * Pantalla que ve un usuario cuya cuenta NO está activa
 * (pausada, bloqueada o eliminada por el administrador).
 *
 * Importante: el backend ya le impide operar (get_user_role → null,
 * guard_rate_limit corta las RPC y no puede auto-desbloquearse), pero
 * SÍ puede leer su propio perfil: por eso aquí se le puede mostrar el
 * motivo en lugar de una pantalla rota.
 */
export function AccountBlocked() {
  const { user, signOut, refreshProfile } = useAuth()
  const navigate = useNavigate()
  const [phone, setPhone] = useState<string | null>(null)
  const [revisando, setRevisando] = useState(false)

  useEffect(() => {
    supabase.rpc('get_my_support').then(({ data }) => {
      const p = (data as { phone?: string } | null)?.phone || null
      if (p) setPhone(p)
    })
  }, [])

  const estado = user?.status || 'bloqueado'

  const config = {
    pausado: {
      titulo: 'Cuenta pausada',
      texto: 'Tu cuenta está pausada temporalmente: no puedes pedir viajes ni trabajar, pero tu dinero y tu historial siguen guardados.',
      Icon: PauseCircle,
      color: 'text-amber-500',
      bg: 'bg-amber-50',
      borde: 'border-amber-200',
      badge: 'badge-warning'
    },
    bloqueado: {
      titulo: 'Cuenta bloqueada',
      texto: 'Tu cuenta está bloqueada y no puedes operar en la app. Si crees que es un error, contacta a soporte.',
      Icon: ShieldAlert,
      color: 'text-red-500',
      bg: 'bg-red-50',
      borde: 'border-red-200',
      badge: 'badge-danger'
    },
    eliminado: {
      titulo: 'Cuenta eliminada',
      texto: 'Esta cuenta fue eliminada. Puedes contactar a soporte si necesitas más información.',
      Icon: UserX,
      color: 'text-surface-500',
      bg: 'bg-surface-100',
      borde: 'border-surface-200',
      badge: 'badge-danger'
    }
  }[estado === 'pausado' ? 'pausado' : estado === 'eliminado' ? 'eliminado' : 'bloqueado']

  const { Icon } = config

  const handleSignOut = async () => {
    await signOut()
    navigate('/login')
  }

  const handleRevisar = async () => {
    setRevisando(true)
    await refreshProfile()
    setRevisando(false)
  }

  const wa = whatsappNumber(phone)

  return (
    <div className="min-h-screen bg-white flex flex-col items-center justify-center px-6 py-12">
      <div className="w-full max-w-sm text-center">
        <div className={`w-20 h-20 ${config.bg} rounded-2xl flex items-center justify-center mx-auto mb-6 border-2 ${config.borde}`}>
          <Icon className={`w-10 h-10 ${config.color}`} />
        </div>

        <h1 className="text-2xl font-bold text-surface-800 mb-2">{config.titulo}</h1>
        <HexUnderline />

        <p className="text-sm text-surface-600 mt-4 mb-6 text-left">{config.texto}</p>

        <div className="card mb-6 text-left space-y-3">
          <div className="flex items-center justify-between">
            <span className="text-sm text-surface-500">Estado</span>
            <span className={config.badge}>{estado.toUpperCase()}</span>
          </div>

          {user?.status_reason && (
            <div>
              <span className="text-sm text-surface-500">Motivo</span>
              <p className="text-sm text-surface-700 mt-1">{user.status_reason}</p>
            </div>
          )}

          {estado === 'pausado' && user?.status_until && (
            <div className="flex items-center justify-between">
              <span className="text-sm text-surface-500">Vuelve a estar activa</span>
              <span className="text-sm font-medium text-surface-700">
                {new Date(user.status_until).toLocaleDateString('es-VE', { day: '2-digit', month: 'long', year: 'numeric' })}
              </span>
            </div>
          )}
        </div>

        {wa ? (
          <a
            href={`https://wa.me/${wa}`}
            target="_blank"
            rel="noopener noreferrer"
            className="btn-primary w-full mb-3"
          >
            <MessageCircle className="w-4 h-4" />
            Contactar a soporte
          </a>
        ) : (
          <a href="/sobre-bunrider" className="btn-outline w-full mb-3">
            <MessageCircle className="w-4 h-4" />
            Ver información de contacto
          </a>
        )}

        <button onClick={handleRevisar} className="btn-outline w-full mb-3" disabled={revisando}>
          <RefreshCw className={`w-4 h-4 ${revisando ? 'animate-spin' : ''}`} />
          Ya me reactivaron, revisar de nuevo
        </button>

        <button onClick={handleSignOut} className="btn-outline w-full">
          <LogOut className="w-4 h-4" />
          Cerrar sesión
        </button>
      </div>
    </div>
  )
}