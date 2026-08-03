import { createContext, useContext, useEffect, useState, useCallback, useRef, ReactNode } from 'react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { subscribeUserToPush } from '@/lib/pushNotifications'
import type { Notification } from '@/types/database'

interface NotificationContextType {
  notifications: Notification[]
  unreadCount: number
  loading: boolean
  markAsRead: (id: string) => Promise<void>
  markAllAsRead: () => Promise<void>
  refreshNotifications: () => Promise<void>
  pushEnabled: boolean
  requestPush: () => Promise<boolean>
}

const NotificationContext = createContext<NotificationContextType | undefined>(undefined)

const POLL_INTERVAL_MS = 60_000 // 1 minuto
const MAX_NOTIFICATIONS = 50

export function NotificationProvider({ children }: { children: ReactNode }) {
  const { user } = useAuth()
  const [notifications, setNotifications] = useState<Notification[]>([])
  const [unreadCount, setUnreadCount] = useState(0)
  const [loading, setLoading] = useState(false)
  const [pushEnabled, setPushEnabled] = useState(false)
  const timerRef = useRef<number | null>(null)
  const userRef = useRef<string | null>(null)

  const refreshNotifications = useCallback(async () => {
    if (!user) {
      setNotifications([])
      setUnreadCount(0)
      return
    }

    try {
      const [{ data: items }, { count }] = await Promise.all([
        supabase
          .from('notifications')
          .select('*')
          .eq('user_id', user.id)
          .order('created_at', { ascending: false })
          .limit(MAX_NOTIFICATIONS),
        supabase
          .from('notifications')
          .select('id', { count: 'exact', head: true })
          .eq('user_id', user.id)
          .eq('is_read', false),
      ])

      if (items) setNotifications(items as Notification[])
      setUnreadCount(count || 0)
    } catch (err) {
      console.error('Error cargando notificaciones:', err)
    } finally {
      setLoading(false)
    }
  }, [user])

  // Cargar al cambiar usuario + polling cada minuto
  useEffect(() => {
    if (user?.id !== userRef.current) {
      userRef.current = user?.id || null
      setLoading(true)
      refreshNotifications()
    }
  }, [user?.id, refreshNotifications])

  // Polling
  useEffect(() => {
    if (!user) return

    // Actualizar inmediatamente cuando la app vuelve a primer plano
    const onVisible = () => {
      if (document.visibilityState === 'visible') {
        refreshNotifications()
      }
    }
    document.addEventListener('visibilitychange', onVisible)

    timerRef.current = window.setInterval(refreshNotifications, POLL_INTERVAL_MS)

    return () => {
      document.removeEventListener('visibilitychange', onVisible)
      if (timerRef.current) {
        window.clearInterval(timerRef.current)
      }
    }
  }, [user, refreshNotifications])

  // Intentar suscripción push automática (silenciosa) al iniciar sesión
  useEffect(() => {
    if (!user) {
      setPushEnabled(false)
      return
    }

    // Solo preguntar si el permiso aún no ha sido decidido
    const checkAndSubscribe = async () => {
      if (!('Notification' in window)) return
      if (Notification.permission === 'granted') {
        const ok = await subscribeUserToPush()
        setPushEnabled(ok)
      } else if (Notification.permission === 'default') {
        // No molestar: esperar a que el usuario toque la campana
        setPushEnabled(false)
      }
    }

    checkAndSubscribe()
  }, [user])

  const markAsRead = useCallback(async (id: string) => {
    // Optimista
    setNotifications((prev) =>
      prev.map((n) => (n.id === id ? { ...n, is_read: true } : n))
    )
    setUnreadCount((c) => Math.max(0, c - 1))

    const { error } = await supabase.rpc('mark_notification_read', {
      p_notification_id: id,
    })

    if (error) {
      console.error('Error marcando como leída:', error)
      refreshNotifications()
    }
  }, [refreshNotifications])

  const markAllAsRead = useCallback(async () => {
    if (!user || unreadCount === 0) return

    // Optimista
    setNotifications((prev) => prev.map((n) => ({ ...n, is_read: true })))
    setUnreadCount(0)

    const { error } = await supabase
      .from('notifications')
      .update({ is_read: true })
      .eq('user_id', user.id)
      .eq('is_read', false)

    if (error) {
      console.error('Error marcando todas como leídas:', error)
      refreshNotifications()
    }
  }, [user, unreadCount, refreshNotifications])

  const requestPush = useCallback(async () => {
    const ok = await subscribeUserToPush()
    setPushEnabled(ok)
    return ok
  }, [])

  return (
    <NotificationContext.Provider
      value={{
        notifications,
        unreadCount,
        loading,
        markAsRead,
        markAllAsRead,
        refreshNotifications,
        pushEnabled,
        requestPush,
      }}
    >
      {children}
    </NotificationContext.Provider>
  )
}

export function useNotifications() {
  const context = useContext(NotificationContext)
  if (context === undefined) {
    throw new Error('useNotifications debe usarse dentro de NotificationProvider')
  }
  return context
}