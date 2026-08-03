import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { Bell, CheckCheck, Car, Wallet, MapPin, User, Banknote, ClipboardCheck, Star, Info, ChevronRight, RefreshCw, BellOff, BellRing } from 'lucide-react'
import { useNotifications } from '@/contexts/NotificationContext'
import { useAuth } from '@/contexts/AuthContext'
import { SkeletonList } from '@/components/ui/Skeleton'
import { EmptyState } from '@/components/ui/EmptyState'
import type { Notification } from '@/types/database'

const typeIcons: Record<string, React.ReactNode> = {
  ride_available: <MapPin className="w-4 h-4" />,
  ride_accepted: <Car className="w-4 h-4" />,
  ride_started: <Car className="w-4 h-4" />,
  ride_completed: <CheckCheck className="w-4 h-4" />,
  ride_cancelled: <Info className="w-4 h-4" />,
  driver_rated: <Star className="w-4 h-4" />,
  client_rated: <Star className="w-4 h-4" />,
  driver_review: <User className="w-4 h-4" />,
  driver_pending: <User className="w-4 h-4" />,
  recharge_approved: <Wallet className="w-4 h-4" />,
  recharge_rejected: <Wallet className="w-4 h-4" />,
  recharge_pending: <Wallet className="w-4 h-4" />,
  proof_pending: <ClipboardCheck className="w-4 h-4" />,
  proof_reviewed: <ClipboardCheck className="w-4 h-4" />,
  payout_driver_pay: <Banknote className="w-4 h-4" />,
  payout_platform_pay: <Banknote className="w-4 h-4" />,
  payout_approved: <Banknote className="w-4 h-4" />,
  payout_rejected: <Banknote className="w-4 h-4" />,
  payout_confirmed: <Banknote className="w-4 h-4" />,
  debt_adjustment: <Wallet className="w-4 h-4" />,
  admin_broadcast: <Bell className="w-4 h-4" />,
}

const typeColors: Record<string, string> = {
  ride_available: 'bg-blue-100 text-blue-600',
  ride_accepted: 'bg-emerald-100 text-emerald-600',
  ride_started: 'bg-emerald-100 text-emerald-600',
  ride_completed: 'bg-emerald-100 text-emerald-600',
  ride_cancelled: 'bg-red-100 text-red-500',
  driver_rated: 'bg-amber-100 text-amber-600',
  client_rated: 'bg-amber-100 text-amber-600',
  driver_review: 'bg-primary-100 text-primary-600',
  driver_pending: 'bg-primary-100 text-primary-600',
  recharge_approved: 'bg-emerald-100 text-emerald-600',
  recharge_rejected: 'bg-red-100 text-red-500',
  recharge_pending: 'bg-amber-100 text-amber-600',
  proof_pending: 'bg-amber-100 text-amber-600',
  proof_reviewed: 'bg-emerald-100 text-emerald-600',
  payout_driver_pay: 'bg-primary-100 text-primary-600',
  payout_platform_pay: 'bg-primary-100 text-primary-600',
  payout_approved: 'bg-emerald-100 text-emerald-600',
  payout_rejected: 'bg-red-100 text-red-500',
  payout_confirmed: 'bg-emerald-100 text-emerald-600',
  debt_adjustment: 'bg-amber-100 text-amber-600',
  admin_broadcast: 'bg-primary-100 text-primary-600',
}

function getNotificationUrl(n: Notification): string {
  const data = n.data || {}
  if (data.url) return data.url as string
  if (n.type?.startsWith('ride_')) {
    const rideId = data.ride_id as string
    if (rideId) {
      if (n.type?.includes('available')) return '/conductor'
      return `/cliente/viaje/${rideId}`
    }
  }
  return '/'
}

function formatTime(date: string): string {
  const d = new Date(date)
  const now = new Date()
  const diffMin = Math.floor((now.getTime() - d.getTime()) / 60000)
  const diffHr = Math.floor(diffMin / 60)
  const diffDays = Math.floor(diffHr / 24)

  if (diffMin < 1) return 'Ahora'
  if (diffMin < 60) return `Hace ${diffMin} min`
  if (diffHr < 24) return `Hace ${diffHr} h`
  if (diffDays < 7) {
    return d.toLocaleDateString('es-VE', { weekday: 'short', hour: '2-digit', minute: '2-digit' })
  }
  return d.toLocaleDateString('es-VE', { day: 'numeric', month: 'short', year: 'numeric' })
}

export function NotificationsPage() {
  const {
    notifications,
    unreadCount,
    loading,
    markAsRead,
    markAllAsRead,
    refreshNotifications,
    pushEnabled,
    requestPush,
  } = useNotifications()
  const { user } = useAuth()
  const navigate = useNavigate()
  const [refreshing, setRefreshing] = useState(false)

  const handleRefresh = async () => {
    setRefreshing(true)
    await refreshNotifications()
    setTimeout(() => setRefreshing(false), 500)
  }

  const handleClickNotification = async (n: Notification) => {
    if (!n.is_read) {
      await markAsRead(n.id)
    }
    navigate(getNotificationUrl(n))
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      {/* Header */}
      <div className="bg-white border-b border-surface-100 px-6 py-4 sticky top-0 z-10">
        <div className="flex items-center justify-between max-w-md mx-auto">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 bg-primary-600 rounded-xl flex items-center justify-center">
              <Bell className="w-5 h-5 text-white" />
            </div>
            <div>
              <h1 className="text-lg font-bold text-surface-800">Notificaciones</h1>
              <p className="text-xs text-surface-500">
                {unreadCount > 0 ? `${unreadCount} sin leer` : 'Todo al día'}
              </p>
            </div>
          </div>

          <div className="flex items-center gap-1">
            <button
              onClick={handleRefresh}
              className="p-2 text-surface-400 hover:text-primary-600 transition-colors"
              aria-label="Actualizar"
            >
              <RefreshCw className={`w-5 h-5 ${refreshing ? 'animate-spin' : ''}`} />
            </button>
            {unreadCount > 0 && (
              <button
                onClick={markAllAsRead}
                className="flex items-center gap-1 px-3 py-1.5 text-xs font-medium text-primary-600 bg-primary-50 hover:bg-primary-100 rounded-lg transition-colors"
              >
                <CheckCheck className="w-3.5 h-3.5" />
                Leer todo
              </button>
            )}
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6 space-y-4">
        {/* Estado de push */}
        {user && (
          <div className={`card p-4 flex items-center justify-between ${pushEnabled ? 'border-emerald-200 bg-emerald-50/50' : ''}`}>
            <div className="flex items-center gap-3">
              {pushEnabled ? (
                <BellRing className="w-5 h-5 text-emerald-600" />
              ) : (
                <BellOff className="w-5 h-5 text-surface-400" />
              )}
              <div>
                <p className="text-sm font-medium text-surface-700">
                  {pushEnabled ? 'Notificaciones push activadas' : 'Activa las notificaciones push'}
                </p>
                <p className="text-xs text-surface-400">
                  {pushEnabled
                    ? 'Recibirás alertas en tu móvil incluso con la app cerrada'
                    : 'Te avisaremos de viajes, pagos y mensajes importantes'}
                </p>
              </div>
            </div>

            {!pushEnabled && (
              <button onClick={requestPush} className="btn-primary px-4 py-2 text-sm flex-shrink-0">
                Activar
              </button>
            )}
          </div>
        )}

        {/* Lista de notificaciones */}
        {loading ? (
          <SkeletonList count={4} />
        ) : notifications.length === 0 ? (
          <EmptyState
            icon={<Bell className="w-8 h-8" />}
            title="Sin notificaciones"
            description="Aquí verás tus notificaciones de viajes, pagos y mensajes."
          />
        ) : (
          <div className="space-y-2">
            {notifications.map((n) => (
              <button
                key={n.id}
                onClick={() => handleClickNotification(n)}
                className={`card card-hover w-full text-left flex items-start gap-3 p-4 transition-all ${
                  !n.is_read ? 'bg-primary-50/50 border-primary-200' : 'opacity-90'
                }`}
              >
                <div className={`flex-shrink-0 w-9 h-9 rounded-full flex items-center justify-center ${typeColors[n.type || ''] || 'bg-surface-100 text-surface-500'}`}>
                  {typeIcons[n.type || ''] || <Bell className="w-4 h-4" />}
                </div>

                <div className="flex-1 min-w-0">
                  <div className="flex items-start justify-between gap-2">
                    <p className={`text-sm font-semibold ${n.is_read ? 'text-surface-600' : 'text-surface-800'}`}>
                      {n.title}
                    </p>
                    <span className="text-[10px] text-surface-400 whitespace-nowrap mt-0.5">
                      {formatTime(n.created_at)}
                    </span>
                  </div>
                  {n.body && (
                    <p className="text-xs text-surface-500 mt-0.5 line-clamp-2">{n.body}</p>
                  )}
                </div>

                {!n.is_read && <span className="w-2 h-2 rounded-full bg-red-500 flex-shrink-0 mt-1.5" />}
                <ChevronRight className="w-4 h-4 text-surface-300 flex-shrink-0 mt-1" />
              </button>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}