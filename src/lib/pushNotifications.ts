// ============================================================
// RIDESOCOPÓ - Utilidades de Notificaciones Push
// ============================================================
import { supabase } from '@/lib/supabase'

const VAPID_PUBLIC_KEY = import.meta.env.VITE_VAPID_PUBLIC_KEY as string | undefined

/**
 * Verifica si el navegador soporta Notification API y Service Workers.
 */
export function isPushSupported(): boolean {
  return (
    'serviceWorker' in navigator &&
    'PushManager' in window &&
    'Notification' in window
  )
}

/**
 * Solicita permiso de notificaciones al usuario.
 */
export async function requestNotificationPermission(): Promise<boolean> {
  if (!isPushSupported()) return false

  try {
    const permission = await Notification.requestPermission()
    return permission === 'granted'
  } catch {
    return false
  }
}

/**
 * Obtiene el Service Worker registrado. Si no existe, lo registra.
 */
async function getServiceWorker(): Promise<ServiceWorkerRegistration | null> {
  if (!('serviceWorker' in navigator)) return null

  try {
    // Si no hay SW registrado, registrar el de la PWA
    if (!navigator.serviceWorker.controller) {
      await navigator.serviceWorker.register('/sw.js')
    }
    return await navigator.serviceWorker.ready
  } catch {
    return null
  }
}

/**
 * Intenta suscribir el dispositivo actual al push.
 * Usa la VAPID public key del entorno para generar una suscripción.
 */
export async function subscribeUserToPush(): Promise<boolean> {
  if (!isPushSupported()) return false

  if (!VAPID_PUBLIC_KEY) {
    console.warn('VITE_VAPID_PUBLIC_KEY no configurado. No se puede suscribir a push.')
    return false
  }

  const permission = await requestNotificationPermission()
  if (!permission) return false

  const sw = await getServiceWorker()
  if (!sw) return false

  try {
    // Obtener suscripción existente si la hay
    let subscription = await sw.pushManager.getSubscription()

    // Si no existe, crear una nueva
    if (!subscription) {
      try {
        subscription = await sw.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC_KEY).buffer as ArrayBuffer,
        })
      } catch {
        // Puede fallar si ya existía una con otro applicationServerKey
        const existing = await sw.pushManager.getSubscription()
        if (existing) {
          await existing.unsubscribe()
        }
        subscription = await sw.pushManager.subscribe({
          userVisibleOnly: true,
          applicationServerKey: urlBase64ToUint8Array(VAPID_PUBLIC_KEY).buffer as ArrayBuffer,
        })
      }
    }

    // Guardar la suscripción en Supabase
    const { error } = await supabase.rpc('get_or_create_push_subscription', {
      p_endpoint: subscription.endpoint,
      p_p256dh: subscription.getKey('p256dh') ? arrayBufferToBase64Url(subscription.getKey('p256dh')!) : '',
      p_auth: subscription.getKey('auth') ? arrayBufferToBase64Url(subscription.getKey('auth')!) : '',
      p_user_agent: navigator.userAgent,
    })

    if (error) {
      console.error('Error guardando suscripción en Supabase:', error)
      return false
    }

    return true
  } catch (err) {
    console.error('Error al suscribir a push:', err)
    return false
  }
}

/**
 * Desuscribe el dispositivo actual del push y borra la suscripción en Supabase.
 */
export async function unsubscribeUserFromPush(): Promise<boolean> {
  if (!isPushSupported()) return false

  try {
    const sw = await getServiceWorker()
    if (!sw) return false

    const subscription = await sw.pushManager.getSubscription()
    if (subscription) {
      await supabase.rpc('delete_push_subscription', {
        p_endpoint: subscription.endpoint,
      })

      await subscription.unsubscribe()
    }

    return true
  } catch (err) {
    console.error('Error al desuscribir:', err)
    return false
  }
}

/**
 * Obtiene la suscripción push actual del dispositivo.
 */
export async function getCurrentPushSubscription(): Promise<PushSubscription | null> {
  if (!isPushSupported()) return null

  const sw = await getServiceWorker()
  if (!sw) return null

  return sw.pushManager.getSubscription()
}

/**
 * Convierte una cadena base64url a Uint8Array (para applicationServerKey).
 */
function urlBase64ToUint8Array(base64String: string): Uint8Array {
  const padding = '='.repeat((4 - (base64String.length % 4)) % 4)
  const base64 = (base64String + padding).replace(/-/g, '+').replace(/_/g, '/')
  const rawData = atob(base64)
  const outputArray = new Uint8Array(rawData.length)
  for (let i = 0; i < rawData.length; ++i) {
    outputArray[i] = rawData.charCodeAt(i)
  }
  return outputArray
}

/**
 * Convierte ArrayBuffer a base64url (para las claves de la suscripción).
 */
function arrayBufferToBase64Url(buffer: ArrayBuffer): string {
  const bytes = new Uint8Array(buffer)
  let binary = ''
  for (let i = 0; i < bytes.byteLength; i++) {
    binary += String.fromCharCode(bytes[i])
  }
  return btoa(binary).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}