// ============================================================
// RIDERFLASSHI - Service Worker
// Maneja notificaciones push + precache de la PWA.
// ============================================================

// Marca usada por vite-plugin-pwa para inyectar el precache manifest
self.__WB_MANIFEST

// Instalar: precachear los archivos inyectados por vite-plugin-pwa
self.addEventListener('install', (event) => {
  const preCacheName = 'riderflasshi-precache-v1'
  self.skipWaiting()

  event.waitUntil(
    caches.open(preCacheName).then((cache) => {
      const urls = (self.__WB_MANIFEST || []).map((entry) => entry.url)
      return cache.addAll(urls).catch(() => {})
    })
  )
})

// Activar: limpiar caches viejos
self.addEventListener('activate', (event) => {
  const cacheNames = ['riderflasshi-precache-v1', 'riderflasshi-pages-v1']
  event.waitUntil(
    caches.keys().then((keys) =>
      Promise.all(
        keys
          .filter((k) => !cacheNames.includes(k))
          .map((k) => caches.delete(k))
      )
    ).then(() => self.clients.claim())
  )
})

// Estrategia: network-first para navegación, cache-first para estáticos
self.addEventListener('fetch', (event) => {
  if (event.request.method !== 'GET') return

  const url = new URL(event.request.url)
  if (url.origin !== self.location.origin) return
  if (url.pathname.startsWith('/api')) return

  // Navegación SPA: network-first con fallback a cache/index
  if (event.request.mode === 'navigate') {
    event.respondWith(
      fetch(event.request)
        .then((response) => {
          const copy = response.clone()
          caches.open('riderflasshi-pages-v1').then((cache) => cache.put('/index.html', copy))
          return response
        })
        .catch(() => caches.match('/index.html'))
    )
    return
  }

  // Estáticos: cache-first con revalidación en background
  event.respondWith(
    caches.match(event.request).then((cached) => {
      if (cached) {
        // Revalidar en background
        fetch(event.request).then((response) => {
          if (response.ok) {
            caches.open('riderflasshi-precache-v1').then((cache) => cache.put(event.request, response))
          }
        }).catch(() => {})
        return cached
      }

      return fetch(event.request).then((response) => {
        if (response.ok) {
          const copy = response.clone()
          caches.open('riderflasshi-precache-v1').then((cache) => cache.put(event.request, copy))
        }
        return response
      })
    })
  )
})

// ============================================================
// NOTIFICACIONES PUSH
// ============================================================

self.addEventListener('push', (event) => {
  let data = {
    title: 'RiderFlasshi',
    body: 'Tienes una nueva notificación',
    icon: '/icons/notification-icon-192.png',
    badge: '/icons/notification-icon-192.png',
    data: { url: '/' },
  }

  try {
    if (event.data) {
      const parsed = event.data.json()
      data = { ...data, ...parsed }
    }
  } catch (_) {
    // Payload inválido o no JSON: usar valores por defecto
  }

  event.waitUntil(
    self.registration.showNotification(data.title, {
      body: data.body,
      icon: data.icon,
      badge: data.badge,
      data: data.data,
      vibrate: [200, 100, 200],
      tag: data.data?.url || 'riderflasshi',
      renotify: true,
    })
  )
})

self.addEventListener('notificationclick', (event) => {
  event.notification.close()

  const url = event.notification.data?.url || '/'

  event.waitUntil(
    self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then((clientList) => {
      for (const client of clientList) {
        if ('focus' in client) {
          client.navigate(url)
          return client.focus()
        }
      }
      return self.clients.openWindow(url)
    })
  )
})

self.addEventListener('notificationclose', (event) => {
  event.notification.close()
})