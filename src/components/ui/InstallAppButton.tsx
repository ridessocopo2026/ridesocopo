import { useState, useEffect } from 'react'
import { Download, X } from 'lucide-react'
import { isIOS, isStandalone, isPwaInstalled, markPwaInstalled, getInAppBrowser } from '@/lib/pwaUtils'

// El prompt se captura GLOBALMENTE en main.tsx (antes de que React monte)
// porque Chrome lo dispara muy temprano. Lo accedemos vía window.
interface BeforeInstallPromptEvent {
  prompt: () => Promise<void>
  userChoice: Promise<{ outcome: 'accepted' | 'dismissed'; platform: string }>
}

// Clave para recordar que el usuario ya cerró el aviso en esta visita.
const BANNER_DISMISS_KEY = 'rs_install_banner_dismissed'

// Cada situación tiene sus propias instrucciones (fáciles de entender).
type GuideType = 'android-inapp' | 'ios-inapp' | 'ios-safari' | 'generic'

const INSTALL_GUIDES: Record<GuideType, { title: string; steps: string[]; note?: string }> = {
  // Instagram / Facebook / etc. en Android → no puede instalar, hay que abrir el navegador
  'android-inapp': {
    title: 'Instala BunRider',
    steps: [
      'Toca los 3 puntitos ⋮ arriba a la derecha.',
      'Toca "Abrir en el navegador" (el dibujito del globo 🌐).',
      'Ya en el navegador, toca el botón "Instalar".',
    ],
    note: 'Si no ves "Abrir en el navegador", busca la opción con el icono del globo terráqueo 🌐.',
  },
  // Instagram / Facebook / etc. en iPhone → solo se instala desde Safari
  'ios-inapp': {
    title: 'Instala BunRider',
    steps: [
      'Abre Safari (el icono de la brújula azul).',
      'Busca "BunRider" (o escribe bunrider.com).',
      'Entra a la página y sigue los pasos para añadirla a inicio.',
    ],
    note: 'En el iPhone la app se añade al inicio desde Safari, no desde Instagram o Facebook.',
  },
  // Safari normal en iPhone → añadir a pantalla de inicio
  'ios-safari': {
    title: 'Añade BunRider a tu inicio',
    steps: [
      'Toca el botón Compartir (el cuadro con la flecha hacia arriba ↑).',
      'Desliza hacia abajo y toca "Añadir a pantalla de inicio".',
      'Toca "Añadir" (arriba a la derecha).',
    ],
    note: 'Se crea un acceso directo que abre la app a pantalla completa.',
  },
  // Navegadores sin instalación automática (Firefox, etc.)
  'generic': {
    title: 'Instala BunRider',
    steps: [
      'Toca el menú de tu navegador (los 3 puntitos ⋮ o el símbolo ⚙).',
      'Busca "Instalar app" o "Añadir a pantalla de inicio".',
    ],
    note: 'Si usas Android, puedes instalarla desde Chrome.',
  },
}

export function InstallAppButton() {
  const [guide, setGuide] = useState<GuideType | null>(null)
  const [installed, setInstalled] = useState(false)
  const [dismissed, setDismissed] = useState(false)

  const isiOS = isIOS()
  // Si estamos dentro de Instagram/Facebook/etc. (WebView), no se puede instalar.
  const inApp = getInAppBrowser()

  useEffect(() => {
    // Si la app ya está instalada (modo standalone o localStorage), ocultar el aviso
    if (isPwaInstalled() || isStandalone()) {
      setInstalled(true)
      return
    }

    // El usuario ya cerró el aviso en esta visita → no volver a molestar
    try {
      if (sessionStorage.getItem(BANNER_DISMISS_KEY) === '1') {
        setDismissed(true)
        return
      }
    } catch (_) {
      // sessionStorage no disponible
    }

    window.addEventListener('appinstalled', handleAppInstalled)

    return () => {
      window.removeEventListener('appinstalled', handleAppInstalled)
    }
  }, [])

  const handleAppInstalled = () => {
    setInstalled(true)
    markPwaInstalled()
    ;(window as any).__clearDeferredPrompt?.()
  }

  const handleDismiss = () => {
    try {
      sessionStorage.setItem(BANNER_DISMISS_KEY, '1')
    } catch (_) {
      // sessionStorage no disponible
    }
    setDismissed(true)
  }

  const handleInstall = async () => {
    // 1. Obtener el prompt global capturado en main.tsx
    const deferredPrompt: BeforeInstallPromptEvent | null =
      (window as any).__getDeferredPrompt?.() || null

    // 2. Si hay prompt → ABRIR EL DIÁLOGO NATIVO INMEDIATAMENTE
    //    Este es el único camino para mostrar el aviso de Chrome/Edge
    if (deferredPrompt) {
      await deferredPrompt.prompt()
      const choice = await deferredPrompt.userChoice
      if (choice.outcome === 'accepted') {
        setInstalled(true)
        markPwaInstalled()
      }
      ;(window as any).__clearDeferredPrompt?.()
      setDismissed(true)
      return
    }

    // 3. Navegador in-app (Instagram / Facebook / …): NO se puede instalar la PWA.
    //    Mostramos cómo abrir la página en el navegador real (Android) o en
    //    Safari (iPhone) para poder instalarla.
    if (inApp) {
      setGuide(isiOS ? 'ios-inapp' : 'android-inapp')
      return
    }

    // 4. Safari normal en iPhone: no hay instalación programática → instrucciones
    if (isiOS) {
      setGuide('ios-safari')
      return
    }

    // 5. Otros navegadores sin prompt nativo (Firefox, etc.) → instrucciones genéricas
    setGuide('generic')
  }

  // Si ya está instalada o el usuario cerró el aviso, no mostrar nada
  if (installed || dismissed) return null

  // Texto del banner según la situación
  let bannerTitle = 'Instala BunRider'
  let bannerSubtitle = 'Acceso rápido y directo desde tu dispositivo'
  let bannerCta = 'Instalar'

  if (inApp && isiOS) {
    bannerSubtitle = 'Ábrelo en Safari para instalarlo'
    bannerCta = 'Ver cómo'
  } else if (inApp) {
    bannerSubtitle = 'Ábrelo en tu navegador para instalarlo'
    bannerCta = 'Ver cómo'
  } else if (isiOS) {
    bannerTitle = 'Añade BunRider a tu inicio'
    bannerSubtitle = 'Agrega un acceso rápido a tu pantalla de inicio'
    bannerCta = 'Añadir'
  }

  // El banner SIEMPRE aparece si la app no está instalada
  return (
    <>
      {/* Banner de aviso para instalar la app — siempre visible */}
      <div className="fixed bottom-20 left-4 right-4 z-[9999] max-w-md mx-auto animate-slide-up">
        <div className="bg-white rounded-2xl shadow-lg shadow-primary-600/20 border border-surface-100 p-4 flex items-center gap-3">
          {/* Icono de la app — logo morado transparente */}
          <img
            src="/icons/logo-morado.png"
            alt="BunRider"
            className="w-12 h-12 rounded-xl shadow-sm flex-shrink-0"
          />

          {/* Texto */}
          <div className="flex-1 min-w-0">
            <p className="text-sm font-bold text-surface-800">{bannerTitle}</p>
            <p className="text-xs text-surface-500 leading-tight mt-0.5">{bannerSubtitle}</p>
          </div>

          {/* Botón instalar */}
          <button
            onClick={handleInstall}
            className="flex-shrink-0 flex items-center gap-1.5 bg-primary-600 text-white px-3 py-2 rounded-xl text-xs font-semibold hover:bg-primary-700 active:scale-95 transition-all"
          >
            <Download className="w-4 h-4" />
            {bannerCta}
          </button>

          {/* Cerrar */}
          <button
            onClick={handleDismiss}
            className="flex-shrink-0 p-1.5 text-surface-400 hover:text-surface-600 transition-colors"
            aria-label="Cerrar aviso"
          >
            <X className="w-4 h-4" />
          </button>
        </div>
      </div>

      {/* Modal de instrucciones — se adapta a cada navegador */}
      {guide && (
        <div
          className="fixed inset-0 bg-black/60 z-[10000] flex items-center justify-center p-4"
          onClick={() => setGuide(null)}
        >
          <div
            className="bg-white rounded-2xl max-w-sm w-full p-6 shadow-xl"
            onClick={(e) => e.stopPropagation()}
          >
            <div className="flex items-center justify-between mb-4">
              <h2 className="text-lg font-bold text-surface-800">{INSTALL_GUIDES[guide].title}</h2>
              <button
                onClick={() => setGuide(null)}
                className="p-2 text-surface-400 hover:text-surface-600"
                aria-label="Cerrar"
              >
                <X className="w-5 h-5" />
              </button>
            </div>

            <div className="space-y-3">
              {INSTALL_GUIDES[guide].steps.map((step, i) => (
                <div key={i} className="bg-surface-50 rounded-xl p-4 flex items-start gap-3">
                  <span className="flex-shrink-0 w-6 h-6 rounded-full bg-primary-600 text-white text-xs font-bold flex items-center justify-center mt-0.5">
                    {i + 1}
                  </span>
                  <p className="text-sm text-surface-700">{step}</p>
                </div>
              ))}
              {INSTALL_GUIDES[guide].note && (
                <div className="bg-primary-50 rounded-xl p-3">
                  <p className="text-xs text-primary-700">💡 {INSTALL_GUIDES[guide].note}</p>
                </div>
              )}
            </div>

            <button onClick={() => setGuide(null)} className="btn-primary w-full mt-4">
              Entendido
            </button>
          </div>
        </div>
      )}
    </>
  )
}