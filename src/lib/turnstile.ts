// ============================================================
// CLOUDFLARE TURNSTILE (verificación humana)
// ------------------------------------------------------------
// El script se carga SOLO cuando una página de autenticación lo
// pide (login / registro / recuperar contraseña), así el HTML
// público sigue liviano y Googlebot no se ve afectado.
// ============================================================

const SCRIPT_SRC = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit'

export interface TurnstileApi {
  render: (el: string | HTMLElement, opts: Record<string, unknown>) => string
  reset: (widgetId?: string) => void
  remove: (widgetId?: string) => void
  getResponse: (widgetId?: string) => string | undefined
  isExpired: (widgetId?: string) => boolean
}

declare global {
  interface Window {
    turnstile?: TurnstileApi
  }
}

// Tiempo máximo de espera de la primera carga (redes móviles muy lentas)
const LOAD_TIMEOUT_MS = 10000
// Pequeña espera antes del reintento automático (parpadeo de red)
const RETRY_DELAY_MS = 600

// Solo se recuerda el ÉXITO: si antes falló, el siguiente intento vuelve a
// intentarlo de verdad (antes el error se guardaba para siempre y había que
// recargar la página entera para poder iniciar sesión).
let ready: TurnstileApi | null = null
let inFlight: Promise<TurnstileApi> | null = null

// Site key pública (no es secreta: va en el frontend)
export const turnstileSiteKey = (): string =>
  String(import.meta.env.VITE_TURNSTILE_SITE_KEY || '').trim()

// Si no hay site key configurada, la app funciona igual (sin captcha)
export const turnstileEnabled = (): boolean => turnstileSiteKey().length > 0

function removeScriptTags(): void {
  document.querySelectorAll('script[data-turnstile]').forEach((el) => {
    try {
      el.parentNode?.removeChild(el)
    } catch {
      // ignorar
    }
  })
}

/**
 * Pizarra limpia: quita el script (cargado o fallido) y olvida la API.
 * Se usa al reintentar para que un script muerto no deje el login bloqueado.
 */
export function resetTurnstile(): void {
  if (typeof window === 'undefined') return
  ready = null
  inFlight = null
  removeScriptTags()
  try {
    delete window.turnstile
  } catch {
    window.turnstile = undefined
  }
}

/** Inyecta el script una vez y espera a que la API quede disponible. */
function injectScript(): Promise<TurnstileApi> {
  return new Promise<TurnstileApi>((resolve, reject) => {
    let settled = false
    const finish = (fn: () => void) => {
      if (settled) return
      settled = true
      window.clearTimeout(timer)
      fn()
    }

    const timer = window.setTimeout(
      () => finish(() => reject(new Error('La verificación tardó demasiado'))),
      LOAD_TIMEOUT_MS
    )

    const script = document.createElement('script')
    script.src = SCRIPT_SRC
    script.async = true
    script.defer = true
    script.dataset.turnstile = '1'
    script.onload = () =>
      finish(() => {
        if (window.turnstile) resolve(window.turnstile)
        else reject(new Error('No se pudo inicializar la verificación'))
      })
    script.onerror = () =>
      finish(() => {
        script.dataset.failed = '1'
        reject(new Error('No se pudo cargar la verificación'))
      })
    document.head.appendChild(script)
  })
}

/**
 * Carga el script de Turnstile.
 * - Nunca espera un `<script>` muerto de un intento anterior.
 * - Si falla, limpia y reintenta UNA vez (parpadeos de red).
 * - Si vuelve a fallar, el error NO queda pegado: se puede reintentar luego.
 */
export function loadTurnstile(): Promise<TurnstileApi> {
  if (typeof window === 'undefined') {
    return Promise.reject(new Error('Turnstile no está disponible en el servidor'))
  }
  if (window.turnstile) {
    ready = window.turnstile
    return Promise.resolve(window.turnstile)
  }
  if (ready) return Promise.resolve(ready)
  if (inFlight) return inFlight

  removeScriptTags()

  inFlight = injectScript()
    .catch(
      () =>
        new Promise<void>((resolve) => window.setTimeout(resolve, RETRY_DELAY_MS)).then(() => {
          removeScriptTags()
          return injectScript()
        })
    )
    .then((api) => {
      ready = api
      inFlight = null
      return api
    })
    .catch((err) => {
      inFlight = null
      throw err
    })

  return inFlight
}
