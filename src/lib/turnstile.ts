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

let loader: Promise<TurnstileApi> | null = null

// Site key pública (no es secreta: va en el frontend)
export const turnstileSiteKey = (): string =>
  String(import.meta.env.VITE_TURNSTILE_SITE_KEY || '').trim()

// Si no hay site key configurada, la app funciona igual (sin captcha)
export const turnstileEnabled = (): boolean => turnstileSiteKey().length > 0

export function loadTurnstile(): Promise<TurnstileApi> {
  if (typeof window === 'undefined') {
    return Promise.reject(new Error('Turnstile no está disponible en el servidor'))
  }
  if (window.turnstile) return Promise.resolve(window.turnstile)
  if (loader) return loader

  loader = new Promise<TurnstileApi>((resolve, reject) => {
    const done = () => {
      if (window.turnstile) resolve(window.turnstile)
      else reject(new Error('No se pudo inicializar la verificación'))
    }

    const existing = document.querySelector<HTMLScriptElement>('script[data-turnstile]')
    if (existing) {
      existing.addEventListener('load', done, { once: true })
      existing.addEventListener('error', () => reject(new Error('No se pudo cargar la verificación')), { once: true })
      if (window.turnstile) done()
      return
    }

    const script = document.createElement('script')
    script.src = SCRIPT_SRC
    script.async = true
    script.defer = true
    script.dataset.turnstile = '1'
    script.onload = done
    script.onerror = () => reject(new Error('No se pudo cargar la verificación'))
    document.head.appendChild(script)
  })

  return loader
}
