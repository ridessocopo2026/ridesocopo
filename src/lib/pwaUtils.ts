/**
 * Utilidades para detectar plataforma y estado de instalación PWA.
 */

export function isIOS(): boolean {
  if (typeof navigator === 'undefined') return false
  const ua = navigator.userAgent

  // iPhone / iPod
  if (/iPhone|iPod/.test(ua)) return true

  // iPad con iOS 12 o anterior
  if (/iPad/.test(ua)) return true

  // iPadOS 13+: el UA de Safari es como "Macintosh" pero con pantalla táctil.
  // Para NO confundir con Windows táctil, verificamos que NO sea Windows y que
  // el navegador no sea Chrome/Edge de escritorio en modo emulación.
  const isMacUA = /Macintosh/.test(ua)
  const hasTouch = navigator.maxTouchPoints > 1
  const isWindows = /Windows|Win64|Win32/.test(ua)

  return isMacUA && hasTouch && !isWindows
}

export function isAndroid(): boolean {
  if (typeof navigator === 'undefined') return false
  return /Android/i.test(navigator.userAgent)
}

export function isStandalone(): boolean {
  if (typeof window === 'undefined') return false
  return (
    window.matchMedia('(display-mode: standalone)').matches ||
    (navigator as any).standalone === true
  )
}

// Marca en localStorage para recordar que la PWA fue instalada.
// Así no mostramos el aviso "Instalar" aunque abras desde el navegador.
const PWA_INSTALLED_KEY = 'rs_pwa_installed'

export function markPwaInstalled(): void {
  try {
    localStorage.setItem(PWA_INSTALLED_KEY, '1')
  } catch (_) {
    // localStorage no disponible
  }
}

export function isPwaInstalled(): boolean {
  if (isStandalone()) return true
  try {
    return localStorage.getItem(PWA_INSTALLED_KEY) === '1'
  } catch (_) {
    return false
  }
}

export type BrowserName = 'chrome' | 'edge' | 'firefox' | 'safari' | 'other'

export function getBrowserName(): BrowserName {
  if (typeof navigator === 'undefined') return 'other'
  const ua = navigator.userAgent

  if (/Edg\//.test(ua)) return 'edge'
  if (/Chrome\/|Chromium\//.test(ua)) return 'chrome'
  if (/Firefox\//.test(ua)) return 'firefox'
  if (/Safari\//.test(ua)) return 'safari'
  return 'other'
}

export function isDesktopWindows(): boolean {
  if (typeof navigator === 'undefined') return false
  const ua = navigator.userAgent
  return /Windows|Win64|Win32/.test(ua)
}