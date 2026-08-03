import { useState } from 'react'
import { BellRing, X } from 'lucide-react'
import { useNotifications } from '@/contexts/NotificationContext'
import { isPushSupported } from '@/lib/pushNotifications'
import { isStandalone } from '@/lib/pwaUtils'

/**
 * Banner superior para activar notificaciones push.
 * No es flotante — se muestra como barra fija debajo del header.
 */
export function NotificationBanner() {
  const { pushEnabled, requestPush } = useNotifications()
  const [dismissed, setDismissed] = useState(false)
  const [loading, setLoading] = useState(false)

  // No mostrar si ya están activadas, no soporta push, la app está
  // instalada (standalone) o el usuario cerró el aviso.
  if (pushEnabled || dismissed || !isPushSupported() || isStandalone()) return null

  const handleActivate = async () => {
    setLoading(true)
    const ok = await requestPush()
    setLoading(false)
    if (ok) {
      // Al activarse, pushEnabled se vuelve true → banner desaparece
    }
  }

  return (
    <div className="bg-primary-600 text-white px-4 py-2.5 flex items-center gap-3 z-[9990]">
      <BellRing className="w-4 h-4 flex-shrink-0 animate-pulse" />
      <p className="text-xs font-medium flex-1 leading-tight">
        Activa las notificaciones para recibir alertas de tu viaje
      </p>
      <button
        onClick={handleActivate}
        disabled={loading}
        className="flex-shrink-0 bg-white text-primary-700 text-xs font-bold px-3 py-1.5 rounded-lg hover:bg-primary-50 active:scale-95 transition-all disabled:opacity-50"
      >
        {loading ? '...' : 'Activar'}
      </button>
      <button
        onClick={() => setDismissed(true)}
        className="flex-shrink-0 p-1 text-white/70 hover:text-white transition-colors"
        aria-label="Cerrar aviso"
      >
        <X className="w-4 h-4" />
      </button>
    </div>
  )
}