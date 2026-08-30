import { useState, useEffect, useRef } from 'react'
import { Download, X } from 'lucide-react'
import { isIOS, isStandalone, isPwaInstalled, markPwaInstalled } from '@/lib/pwaUtils'

// El prompt se captura GLOBALMENTE en main.tsx (antes de que React monte)
// porque Chrome lo dispara muy temprano. Lo accedemos vía window.
interface BeforeInstallPromptEvent {
  prompt: () => Promise<void>
  userChoice: Promise<{ outcome: 'accepted' | 'dismissed'; platform: string }>
}

export function InstallAppButton() {
  const [showIOSInstructions, setShowIOSInstructions] = useState(false)
  const [installed, setInstalled] = useState(false)
  const [dismissed, setDismissed] = useState(false)
  const [promptAvailable, setPromptAvailable] = useState(false)

  const isiOS = isIOS()

  // Comprobar si ya hay un prompt capturado globalmente
  const updatePromptState = () => {
    const hasPrompt = !!(window as any).__getDeferredPrompt?.()
    setPromptAvailable(hasPrompt)
  }

  useEffect(() => {
    // Si la app ya está instalada (modo standalone o localStorage), ocultar el aviso
    if (isPwaInstalled() || isStandalone()) {
      setInstalled(true)
      return
    }

    // Estado inicial: puede que Chrome ya haya disparado el prompt antes de montar
    updatePromptState()

    // Escuchar cuando main.tsx captura el prompt
    window.addEventListener('app-install-prompt-ready', updatePromptState)
    window.addEventListener('appinstalled', handleAppInstalled)

    return () => {
      window.removeEventListener('app-install-prompt-ready', updatePromptState)
      window.removeEventListener('appinstalled', handleAppInstalled)
    }
  }, [])

    const handleAppInstalled = () => {
      setInstalled(true)
      markPwaInstalled()
      ;(window as any).__clearDeferredPrompt?.()
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

    // 3. iOS no permite instalación programática — SOLO instrucciones
    if (isiOS) {
      setShowIOSInstructions(true)
      return
    }

    // 4. Sin prompt aún (Chrome puede tardar en dar el permisos de nuevo).
    //    NO mostramos ningún modal falso. El banner sigue visible y
    //    el usuario puede tocar de nuevo en unos segundos.
    //    Nota: Chrome solo permite pedir instalación 1 vez por visita.
  }

  // Si ya está instalada o el usuario cerró el aviso, no mostrar nada
  if (installed || dismissed) return null

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
            <p className="text-sm font-bold text-surface-800">
              {isiOS ? 'Añade BunRider a tu inicio' : 'Instala BunRider'}
            </p>
            <p className="text-xs text-surface-500 leading-tight mt-0.5">
              {isiOS
                ? 'Agrega un acceso rápido a tu pantalla de inicio'
                : 'Acceso rápido y directo desde tu dispositivo'}
            </p>
          </div>

          {/* Botón instalar */}
          <button
            onClick={handleInstall}
            className="flex-shrink-0 flex items-center gap-1.5 bg-primary-600 text-white px-3.5 py-2 rounded-xl text-sm font-semibold hover:bg-primary-700 active:scale-95 transition-all"
          >
            <Download className="w-4 h-4" />
            {isiOS ? 'Añadir' : 'Instalar'}
          </button>

          {/* Cerrar */}
          <button
            onClick={() => setDismissed(true)}
            className="flex-shrink-0 p-1.5 text-surface-400 hover:text-surface-600 transition-colors"
            aria-label="Cerrar aviso"
          >
            <X className="w-4 h-4" />
          </button>
        </div>
      </div>

      {/* Modal de instrucciones — SOLO para iOS */}
      {showIOSInstructions && isiOS && (
        <div className="fixed inset-0 bg-black/60 z-50 flex items-center justify-center p-4" onClick={() => setShowIOSInstructions(false)}>
          <div className="bg-white rounded-2xl max-w-sm w-full p-6 shadow-xl" onClick={(e) => e.stopPropagation()}>
            <div className="flex items-center justify-between mb-4">
              <h2 className="text-lg font-bold text-surface-800">Añade BunRider a tu inicio</h2>
              <button onClick={() => setShowIOSInstructions(false)} className="p-2 text-surface-400 hover:text-surface-600">
                <X className="w-5 h-5" />
              </button>
            </div>

            <div className="space-y-3">
              <div className="bg-surface-50 rounded-xl p-4">
                <p className="text-sm text-surface-700"><strong>1. Abre Safari</strong> y ve a la página de BunRider</p>
              </div>
              <div className="bg-surface-50 rounded-xl p-4">
                <p className="text-sm text-surface-700"><strong>2. Toca el botón Compartir</strong> (cuadro con flecha ↑) en la parte inferior</p>
              </div>
              <div className="bg-surface-50 rounded-xl p-4">
                <p className="text-sm text-surface-700"><strong>3. Desliza hacia abajo</strong> y toca <strong>"Añadir a pantalla de inicio"</strong></p>
              </div>
              <div className="bg-surface-50 rounded-xl p-4">
                <p className="text-sm text-surface-700"><strong>4. Toca "Añadir"</strong> (arriba a la derecha)</p>
              </div>
              <div className="bg-primary-50 rounded-xl p-3">
                <p className="text-xs text-primary-700">
                  💡 En iOS la app no se instala como en Android — se agrega un acceso directo a tu pantalla de inicio que se abre a pantalla completa.
                </p>
              </div>
            </div>

            <button onClick={() => setShowIOSInstructions(false)} className="btn-primary w-full mt-4">
              Entendido
            </button>
          </div>
        </div>
      )}
    </>
  )
}