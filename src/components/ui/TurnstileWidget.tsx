import { useCallback, useEffect, useRef, useState } from 'react'
import { Loader2, RotateCw, ShieldCheck } from 'lucide-react'
import { loadTurnstile, resetTurnstile, turnstileEnabled, turnstileSiteKey } from '@/lib/turnstile'

export type TurnstileStatus = 'loading' | 'ready' | 'error'

interface TurnstileWidgetProps {
  /** Recibe el token (string vacío cuando expira o falla) */
  onToken: (token: string) => void
  /** Avisa el estado de la verificación para que el formulario espere */
  onStatus?: (status: TurnstileStatus) => void
  /** Cambiar este número fuerza a pedir un token nuevo (tras un intento fallido) */
  resetKey?: number
  theme?: 'auto' | 'light' | 'dark'
}

/**
 * Widget de Cloudflare Turnstile.
 * - Modo "interaction-only": Cloudflare no pide clic salvo que sospeche.
 * - Aunque el widget sea invisible, el ESTADO sí se ve: mientras verifica
 *   ("Verificando que eres humano…"), cuando está listo ("Verificación lista")
 *   y si falla, con un botón Reintentar. Así nadie toca "Iniciar sesión"
 *   antes de tiempo y cree que la app no funciona.
 * - El token dura 300s y es de un solo uso, por eso se reinicia con resetKey.
 */
export function TurnstileWidget({ onToken, onStatus, resetKey = 0, theme = 'auto' }: TurnstileWidgetProps) {
  const containerRef = useRef<HTMLDivElement | null>(null)
  const widgetIdRef = useRef<string | null>(null)
  const onTokenRef = useRef(onToken)
  const onStatusRef = useRef(onStatus)
  const [status, setStatus] = useState<TurnstileStatus>(turnstileEnabled() ? 'loading' : 'ready')
  const statusRef = useRef<TurnstileStatus>(turnstileEnabled() ? 'loading' : 'ready')
  const [message, setMessage] = useState('')
  const [attempt, setAttempt] = useState(0)

  // Mantener los callbacks actualizados sin re-renderizar el widget
  useEffect(() => { onTokenRef.current = onToken })
  useEffect(() => { onStatusRef.current = onStatus })

  const update = useCallback((next: TurnstileStatus, msg = '') => {
    statusRef.current = next
    setStatus(next)
    setMessage(msg)
    onStatusRef.current?.(next)
  }, [])

  useEffect(() => {
    if (!turnstileEnabled()) return

    let cancelled = false
    update('loading')

    loadTurnstile()
      .then((turnstile) => {
        if (cancelled || !containerRef.current) return
        // Evita duplicar el widget en re-montajes
        try {
          turnstile.remove(widgetIdRef.current ?? undefined)
        } catch {
          // ignorar
        }
        if (containerRef.current) containerRef.current.innerHTML = ''
        widgetIdRef.current = turnstile.render(containerRef.current, {
          sitekey: turnstileSiteKey(),
          theme,
          size: 'flexible',
          appearance: 'interaction-only',
          retry: 'auto',
          'refresh-expired': 'auto',
          callback: (token: string) => {
            onTokenRef.current(token)
            if (token) update('ready')
          },
          'error-callback': () => {
            onTokenRef.current('')
            update('error', 'No pudimos verificar que eres humano. Revisa tu conexión e inténtalo de nuevo.')
          },
          'expired-callback': () => {
            onTokenRef.current('')
            update('loading')
          },
          'timeout-callback': () => {
            onTokenRef.current('')
            update('loading')
          }
        })
      })
      .catch(() => {
        if (cancelled) return
        onTokenRef.current('')
        update('error', 'No pudimos cargar la verificación de seguridad.')
      })

    return () => {
      cancelled = true
      try {
        if (widgetIdRef.current && window.turnstile) window.turnstile.remove(widgetIdRef.current)
      } catch {
        // ignorar
      }
      widgetIdRef.current = null
    }
  }, [theme, attempt, update])

  // Reinicio explícito (nuevo token) tras un intento fallido
  useEffect(() => {
    if (!resetKey) return
    // Si la verificación falló se deja a la vista el aviso con "Reintentar"
    if (statusRef.current === 'error') return
    onTokenRef.current('')
    update('loading')
    if (!widgetIdRef.current || !window.turnstile) return
    try {
      window.turnstile.reset(widgetIdRef.current)
    } catch {
      // ignorar
    }
  }, [resetKey, update])

  // Reintento manual: si el script sí cargó solo se reinicia el reto (no
  // descarga nada); si no cargó, se limpia el script muerto y se reintenta.
  const handleRetry = useCallback(() => {
    onTokenRef.current('')
    update('loading')
    if (window.turnstile && widgetIdRef.current) {
      try {
        window.turnstile.reset(widgetIdRef.current)
        return
      } catch {
        // se cae al reintento completo
      }
    }
    resetTurnstile()
    setAttempt((a) => a + 1)
  }, [update])

  if (!turnstileEnabled()) return null

  return (
    <div className="space-y-2">
      <div ref={containerRef} className="flex justify-center" />

      {status === 'loading' && (
        <p className="flex items-center justify-center gap-1.5 text-xs text-surface-500" role="status">
          <Loader2 className="w-3.5 h-3.5 animate-spin" />
          Verificando que eres humano…
        </p>
      )}

      {status === 'ready' && (
        <p className="flex items-center justify-center gap-1.5 text-xs font-medium text-emerald-600" role="status">
          <ShieldCheck className="w-3.5 h-3.5" />
          Verificación lista
        </p>
      )}

      {status === 'error' && (
        <div className="rounded-xl border border-amber-200 bg-amber-50 px-3 py-2 text-center">
          <p className="text-xs text-amber-700">
            {message || 'No pudimos completar la verificación de seguridad.'}
          </p>
          <p className="mt-1 text-[11px] leading-snug text-amber-600">
            Si usas bloqueador de anuncios, VPN o abriste la página dentro de otra app, desactívalo o ábrela en el navegador.
          </p>
          <button
            type="button"
            onClick={handleRetry}
            className="mt-2 inline-flex items-center gap-1.5 text-xs font-semibold text-amber-800 underline underline-offset-2"
          >
            <RotateCw className="w-3.5 h-3.5" />
            Reintentar
          </button>
        </div>
      )}
    </div>
  )
}
