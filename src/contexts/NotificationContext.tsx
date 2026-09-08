import { createContext, useContext, useEffect, useState, useCallback, useMemo, useRef, ReactNode } from 'react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { subscribeUserToPush } from '@/lib/pushNotifications'
import type { Notification } from '@/types/database'

interface NotificationContextType {
  notifications: Notification[]
  unreadCount: number
  loading: boolean
  hasMore: boolean
  loadingMore: boolean
  markAsRead: (id: string) => Promise<void>
  markAllAsRead: () => Promise<void>
  deleteNotification: (id: string) => Promise<void>
  clearRead: () => Promise<void>
  clearAll: () => Promise<void>
  loadMore: () => Promise<void>
  refreshNotifications: () => Promise<void>
  pushEnabled: boolean
  requestPush: () => Promise<boolean>
}

const NotificationContext = createContext<NotificationContextType | undefined>(undefined)

const POLL_INTERVAL_MS = 60_000 // 1 minuto
const PAGE_SIZE = 25
const MORE_PAGE_SIZE = 20

export function NotificationProvider({ children }: { children: ReactNode }) {
  const { user } = useAuth()
  const [page1, setPage1] = useState<Notification[]>([])
  const [older, setOlder] = useState<Notification[]>([])
  const [unreadCount, setUnreadCount] = useState(0)
  const [hasMore, setHasMore] = useState(true)
  const [loading, setLoading] = useState(false)
  const [loadingMore, setLoadingMore] = useState(false)
  const [pushEnabled, setPushEnabled] = useState(false)
  const timerRef = useRef<number | null>(null)
  const userRef = useRef<string | null>(null)

  // Lista visible = primera página + páginas cargadas (más antiguas), sin duplicados
  const notifications = useMemo(() => {
    const byId = new Map<string, Notification>()
    for (const n of [...page1, ...older]) {
      if (!byId.has(n.id)) byId.set(n.id, n)
    }
    return Array.from(byId.values()).sort(
      (a, b) => b.created_at.localeCompare(a.created_at) || a.id.localeCompare(b.id)
    )
  }, [page1, older])

  const refreshNotifications = useCallback(async () => {
    if (!user) {
      setPage1([])
      setOlder([])
      setUnreadCount(0)
      setHasMore(false)
      return
    }

    try {
      const [{ data: items }, { count }] = await Promise.all([
        supabase
          .from('notifications')
          .select('id, user_id, title, body, type, data, is_read, created_at')
          .eq('user_id', user.id)
          .order('created_at', { ascending: false })
          .limit(PAGE_SIZE),
        supabase
          .from('notifications')
          .select('id', { count: 'exact', head: true })
          .eq('user_id', user.id)
          .eq('is_read', false),
      ])

      // Solo se reemplaza la primera página: las páginas antiguas ya cargadas
      // ("older") se conservan para que el polling no colapse la lista.
      if (items) setPage1(items as Notification[])
      setHasMore(!items || items.length >= PAGE_SIZE)
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
      setPage1([])
      setOlder([])
      setHasMore(true)
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
    // Optimista: actualizar en primera página y en páginas antiguas cargadas
    let wasUnread = false
    for (const n of [...page1, ...older]) {
      if (n.id === id && !n.is_read) {
        wasUnread = true
        break
      }
    }
    if (wasUnread) setUnreadCount((c) => Math.max(0, c - 1))
    setPage1((prev) => prev.map((n) => (n.id === id ? { ...n, is_read: true } : n)))
    setOlder((prev) => prev.map((n) => (n.id === id ? { ...n, is_read: true } : n)))

    const { error } = await supabase.rpc('mark_notification_read', {
      p_notification_id: id,
    })

    if (error) {
      console.error('Error marcando como leída:', error)
      refreshNotifications()
    }
  }, [page1, older, refreshNotifications])

  const markAllAsRead = useCallback(async () => {
    if (!user || unreadCount === 0) return

    // Optimista
    setPage1((prev) => prev.map((n) => ({ ...n, is_read: true })))
    setOlder((prev) => prev.map((n) => ({ ...n, is_read: true })))
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

  const deleteNotification = useCallback(
    async (id: string) => {
      // Optimista: quitar de primera página y de páginas antiguas cargadas
      const target = page1.find((n) => n.id === id) || older.find((n) => n.id === id)
      if (target && !target.is_read) setUnreadCount((c) => Math.max(0, c - 1))
      setPage1((prev) => prev.filter((n) => n.id !== id))
      setOlder((prev) => prev.filter((n) => n.id !== id))

      const { error } = await supabase.rpc('delete_my_notification', {
        p_notification_id: id,
      })

      if (error) {
        console.error('Error eliminando notificación:', error)
        refreshNotifications()
      }
    },
    [page1, older, refreshNotifications]
  )

  const clearRead = useCallback(async () => {
    if (!user) return

    // Optimista: eliminar solo las leídas (el contador no cambia)
    setPage1((prev) => prev.filter((n) => !n.is_read))
    setOlder((prev) => prev.filter((n) => !n.is_read))

    const { error } = await supabase.rpc('clear_read_notifications')

    if (error) {
      console.error('Error borrando notificaciones leídas:', error)
      refreshNotifications()
    }
  }, [user, refreshNotifications])

  const clearAll = useCallback(async () => {
    if (!user) return

    // Optimista: vaciar todo
    setPage1([])
    setOlder([])
    setUnreadCount(0)
    setHasMore(false)

    const { error } = await supabase.rpc('clear_all_notifications')

    if (error) {
      console.error('Error vaciando notificaciones:', error)
      refreshNotifications()
    }
  }, [user, refreshNotifications])

  const loadMore = useCallback(async () => {
    if (!user || loadingMore || !hasMore) return
    const combined = [...page1, ...older]
    if (combined.length === 0) return

    setLoadingMore(true)
    const oldest = combined.reduce(
      (min, n) => (n.created_at < min ? n.created_at : min),
      combined[0].created_at
    )

    try {
      const { data, error } = await supabase
        .from('notifications')
        .select('id, user_id, title, body, type, data, is_read, created_at')
        .eq('user_id', user.id)
        .lt('created_at', oldest)
        .order('created_at', { ascending: false })
        .limit(MORE_PAGE_SIZE)

      if (error) throw error

      const next = (data || []) as Notification[]
      if (next.length < MORE_PAGE_SIZE) setHasMore(false)

      setOlder((prev) => {
        const seen = new Set([...prev, ...page1].map((n) => n.id))
        return [...prev, ...next.filter((n) => !seen.has(n.id))]
      })
    } catch (err) {
      console.error('Error cargando más notificaciones:', err)
    } finally {
      setLoadingMore(false)
    }
  }, [user, loadingMore, hasMore, page1, older])

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
        hasMore,
        loadingMore,
        markAsRead,
        markAllAsRead,
        deleteNotification,
        clearRead,
        clearAll,
        loadMore,
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