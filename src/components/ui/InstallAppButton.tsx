import { useState, useEffect } from 'react'
import { Download, X } from 'lucide-react'
import { isIOS, isStandalone, getBrowserName } from '@/lib/pwaUtils'

interface BeforeInstallPromptEvent extends Event {
  prompt: () => Promise<void>
  userChoice: Promise<{ outcome: 'accepted' | 'dismissed'; platform: string }>
}

export function InstallAppButton() {
  const [deferredPrompt, setDeferredPrompt] = useState<BeforeInstallPromptEvent | null>(null)
  const [showInstructions, setShowInstructions] = useState(false)
  const [installed, setInstalled] = useState(false)
  const [dismissed, setDismissed] = useState(false)

  const isiOS = isIOS()
  const browser = getBrowserName()

  useEffect(() => {
    if (isStandalone()) {
      setInstalled(true)
      return
    }

    const handleBeforeInstallPrompt = (e: Event) => {
      e.preventDefault()
      setDeferredPrompt(e as BeforeInstallPromptEvent)
    }

    const handleAppInstalled = () => {
      setInstalled(true)
      setDeferredPrompt(null)
    }

    window.addEventListener('beforeinstallprompt', handleBeforeInstallPrompt)
    window.addEventListener('appinstalled', handleAppInstalled)

    return () => {
      window.removeEventListener('beforeinstallprompt', handleBeforeInstallPrompt)
      window.removeEventListener('appinstalled', handleAppInstalled)
    }
  }, [])

  const handleInstall = async () => {
    if (deferredPrompt) {
      // Chrome/Edge con soporte de instalación nativa → diálogo del navegador
      await deferredPrompt.prompt()
      const choice = await deferredPrompt.userChoice
      if (choice.outcome === 'accepted') setInstalled(true)
      setDeferredPrompt(null)
      setDismissed(true)
    } else {
      // Cualquier otro navegador/dispositivo → instrucciones adaptadas
      setShowInstructions(true)
    }
  }

  // Si ya está instalada o el usuario cerró el aviso, no mostrar nada
  if (installed || dismissed) return null

  // El banner SIEMPRE aparece si la app no está instalada (independiente del navegador)
  const showBanner = true
  if (!showBanner) return null

  return (
    <>
      {/* Banner de aviso para instalar la app — siempre visible */}
      <div className="fixed bottom-20 left-4 right-4 z-[9999] max-w-md mx-auto animate-slide-up">
        <div className="bg-white rounded-2xl shadow-lg shadow-primary-600/20 border border-surface-100 p-4 flex items-center gap-3">
          {/* Icono de la app */}
          <img
            src="/icons/icon-192x192.png"
            alt="RideSocopó"
            className="w-12 h-12 rounded-xl shadow-sm flex-shrink-0"
          />

          {/* Texto */}
          <div className="flex-1 min-w-0">
            <p className="text-sm font-bold text-surface-800">
              {isiOS ? 'Añade RideSocopó a tu inicio' : 'Instala RideSocopó'}
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

      {/* Modal de instrucciones — adaptado al navegador/dispositivo */}
      {showInstructions && (
        <div className="fixed inset-0 bg-black/60 z-50 flex items-center justify-center p-4" onClick={() => setShowInstructions(false)}>
          <div className="bg-white rounded-2xl max-w-sm w-full p-6 shadow-xl" onClick={(e) => e.stopPropagation()}>
            <div className="flex items-center justify-between mb-4">
              <h2 className="text-lg font-bold text-surface-800">
                {isiOS ? 'Añade RideSocopó a tu inicio' : 'Instala RideSocopó'}
              </h2>
              <button onClick={() => setShowInstructions(false)} className="p-2 text-surface-400 hover:text-surface-600">
                <X className="w-5 h-5" />
              </button>
            </div>

            {isiOS ? (
              // ===== INSTRUCCIONES iOS =====
              <div className="space-y-3">
                <div className="bg-surface-50 rounded-xl p-4">
                  <p className="text-sm text-surface-700"><strong>1. Abre Safari</strong> y ve a la página de RideSocopó</p>
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
            ) : browser === 'firefox' ? (
              // ===== INSTRUCCIONES FIREFOX =====
              <div className="space-y-3">
                <div className="bg-amber-50 border border-amber-200 rounded-xl p-3">
                  <p className="text-xs text-amber-700">
                    ⚠️ Firefox no permite instalar PWA's como apps nativas.
                  </p>
                </div>
                <div className="bg-surface-50 rounded-xl p-4">
                  <p className="text-sm text-surface-700"><strong>Opción recomendada:</strong> usa <strong>Chrome</strong> o <strong>Edge</strong> para instalar RideSocopó como app.</p>
                </div>
                <div className="bg-surface-50 rounded-xl p-4">
                  <p className="text-sm text-surface-700">
                    <strong>Alternativa en Android:</strong> Abre el menú (⋮) → <strong>"Añadir a pantalla de inicio"</strong>
                  </p>
                </div>
              </div>
            ) : browser === 'safari' && !isiOS ? (
              // ===== SAFARI ESCRITORIO (Mac) =====
              <div className="space-y-3">
                <div className="bg-surface-50 rounded-xl p-4">
                  <p className="text-sm text-surface-700"><strong>1.</strong> Haz clic en <strong>Archivo</strong> en la barra de menú</p>
                </div>
                <div className="bg-surface-50 rounded-xl p-4">
                  <p className="text-sm text-surface-700"><strong>2.</strong> Elige <strong>"Añadir al Dock"</strong></p>
                </div>
              </div>
            ) : (
              // ===== INSTRUCCIONES GENÉRICAS (Chrome/Edge/otros) =====
              <div className="space-y-3">
                <div className="bg-surface-50 rounded-xl p-4">
                  <p className="text-sm text-surface-700">
                    <strong>Para instalar:</strong>
                  </p>
                  <ol className="list-decimal ml-4 mt-2 text-sm text-surface-600 space-y-1">
                    <li>Haz clic en el <strong>icono de instalación</strong> en la barra de direcciones (monitor con flecha ⭳)</li>
                    <li>O abre el menú del navegador: <strong>⋮</strong> (Chrome) o <strong>⋯</strong> (Edge)</li>
                    <li>Toca <strong>"Instalar app"</strong> o <strong>"Instalar RideSocopó"</strong></li>
                    <li>Confirma en el diálogo</li>
                  </ol>
                </div>
                <div className="bg-primary-50 rounded-xl p-3">
                  <p className="text-xs text-primary-700">
                    💡 En <strong>Android</strong> también puedes ir al menú (⋮) → <strong>"Añadir a pantalla de inicio"</strong>
                  </p>
                </div>
              </div>
            )}

            <button onClick={() => setShowInstructions(false)} className="btn-primary w-full mt-4">
              Entendido
            </button>
          </div>
        </div>
      )}
    </>
  )
}