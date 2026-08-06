import { useState } from 'react'
import { BellOff } from 'lucide-react'
import { useNotifications } from '@/contexts/NotificationContext'
import { useAuth } from '@/contexts/AuthContext'
import { isPushSupported } from '@/lib/pushNotifications'

/**
 * Tarjeta para activar las notificaciones push (mismo estilo que la página
 * de Notificaciones). Se muestra cuando el usuario está logueado y no tiene
 * activadas las notificaciones. A diferencia del banner, NO se oculta en modo
 * instalado (standalone): el push funciona igual con la app instalada.
 */
export function PushNotificationCard() {
  const { pushEnabled, requestPush } = useNotifications()
  const { user } = useAuth()
  const [loading, setLoading] = useState(false)

  // Solo cuando el usuario está logueado, no las tiene activas y el navegador las soporta
  if (!user || pushEnabled || !isPushSupported()) return null

  const handleActivate = async () => {
    setLoading(true)
    await requestPush()
    setLoading(false)
  }

  return (
    <div className="card p-4 flex items-center justify-between gap-3">
      <div className="flex items-center gap-3 min-w-0">
        <BellOff className="w-5 h-5 text-surface-400 flex-shrink-0" />
        <div className="min-w-0">
          <p className="text-sm font-medium text-surface-700">Activa las notificaciones push</p>
          <p className="text-xs text-surface-400">
            Te avisaremos de viajes, pagos y mensajes importantes
          </p>
        </div>
      </div>
      <button
        onClick={handleActivate}
        disabled={loading}
        className="btn-primary px-4 py-2 text-sm flex-shrink-0"
      >
        {loading ? '...' : 'Activar'}
      </button>
    </div>
  )
}
