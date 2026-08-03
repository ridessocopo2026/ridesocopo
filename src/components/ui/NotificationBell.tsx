import { Bell } from 'lucide-react'
import { useNavigate } from 'react-router-dom'
import { useNotifications } from '@/contexts/NotificationContext'

interface NotificationBellProps {
  className?: string
}

export function NotificationBell({ className = 'p-2 text-surface-400 hover:text-primary-600 transition-colors' }: NotificationBellProps) {
  const { unreadCount } = useNotifications()
  const navigate = useNavigate()

  return (
    <button
      className={`relative ${className}`}
      onClick={() => navigate('/notificaciones')}
      aria-label={`Notificaciones${unreadCount > 0 ? ` (${unreadCount} sin leer)` : ''}`}
    >
      <Bell className="w-5 h-5" />
      {unreadCount > 0 && (
        <>
          <span className="absolute -top-0.5 -right-0.5 min-w-[18px] h-[18px] px-1 rounded-full bg-red-500 text-white text-[10px] font-bold flex items-center justify-center animate-pulse">
            {unreadCount > 99 ? '99+' : unreadCount}
          </span>
        </>
      )}
    </button>
  )
}