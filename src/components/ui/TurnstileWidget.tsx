import { useEffect, useRef } from 'react'
import { loadTurnstile, turnstileEnabled, turnstileSiteKey } from '@/lib/turnstile'

interface TurnstileWidgetProps {
  /** Recibe el token (string vacío cuando expira o falla) */
  onToken: (token: string) => void
  /** Se llama si no se pudo cargar/ejecutar la verificación */
  onError?: (message: string) => void
  /** Cambiar este número fuerza a pedir un token nuevo (tras un intento fallido) */
  resetKey?: number
  theme?: 'auto' | 'light' | 'dark'
}

/**
 * Widget de Cloudflare Turnstile.
 * - Modo "interaction-only": normalmente invisible; solo pide un clic si
 *   Cloudflare sospecha. No añade fricción al usuario legítimo.
 * - El token dura 300s y es de un solo uso, por eso se reinicia con resetKey.
 */
export function TurnstileWidget({ onToken, onError, resetKey = 0, theme = 'auto' }: TurnstileWidgetProps) {
  const containerRef = useRef<HTMLDivElement | null>(null)
  const widgetIdRef = useRef<string | null>(null)
  const onTokenRef = useRef(onToken)
  const onErrorRef = useRef(onError)

  // Mantener los callbacks actualizados sin re-renderizar el widget
  useEffect(() => { onTokenRef.current = onToken })
  useEffect(() => { onErrorRef.current = onError })

  useEffect(() => {
    if (!turnstileEnabled()) return

    let cancelled = false

    loadTurnstile()
      .then((turnstile) => {
        if (cancelled || !containerRef.current) return
        // Evita duplicar el widget en re-montajes
        turnstile.remove(widgetIdRef.current ?? undefined)
        widgetIdRef.current = turnstile.render(containerRef.current, {
          sitekey: turnstileSiteKey(),
          theme,
          size: 'flexible',
          appearance: 'interaction-only',
          retry: 'auto',
          'refresh-expired': 'auto',
          callback: (token: string) => onTokenRef.current(token),
          'error-callback': () => {
            onTokenRef.current('')
            onErrorRef.current?.('No pudimos verificar que eres humano. Revisa tu conexión e inténtalo de nuevo.')
          },
          'expired-callback': () => onTokenRef.current(''),
          'timeout-callback': () => onTokenRef.current('')
        })
      })
      .catch(() => {
        onTokenRef.current('')
        onErrorRef.current?.('No pudimos cargar la verificación de seguridad. Recarga la página.')
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
  }, [theme])

  // Reinicio explícito (nuevo token) tras un intento fallido
  useEffect(() => {
    if (!resetKey || !widgetIdRef.current || !window.turnstile) return
    try {
      window.turnstile.reset(widgetIdRef.current)
    } catch {
      // ignorar
    }
  }, [resetKey])

  if (!turnstileEnabled()) return null

  return <div ref={containerRef} className="flex justify-center" />
}
