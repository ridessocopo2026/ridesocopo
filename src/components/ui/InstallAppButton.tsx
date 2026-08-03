import { useState, useEffect } from 'react'
import { Download, X } from 'lucide-react'
import { isIOS, isStandalone } from '@/lib/pwaUtils'

interface BeforeInstallPromptEvent extends Event {
  prompt: () => Promise<void>
  userChoice: Promise<{ outcome: 'accepted' | 'dismissed'; platform: string }>
}

export function InstallAppButton() {
  const [deferredPrompt, setDeferredPrompt] = useState<BeforeInstallPromptEvent | null>(null)
  const [showIOSInstructions, setShowIOSInstructions] = useState(false)
  const [installed, setInstalled] = useState(false)

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
      await deferredPrompt.prompt()
      const choice = await deferredPrompt.userChoice
      if (choice.outcome === 'accepted') setInstalled(true)
      setDeferredPrompt(null)
    } else {
      setShowIOSInstructions(true)
    }
  }

  if (installed) return null
  const showButton = deferredPrompt !== null || isIOS()
  if (!showButton) return null

  return (
    <>
      <button
        onClick={handleInstall}
        className="fixed bottom-20 left-1/2 -translate-x-1/2 z-50 flex items-center gap-2 bg-primary-600 text-white px-5 py-3 rounded-full shadow-lg shadow-primary-600/30 hover:bg-primary-700 active:scale-95 transition-all animate-slide-up"
      >
        <Download className="w-5 h-5" />
        <span className="text-sm font-semibold">
          {isIOS() ? 'Instalar en iPhone/iPad' : 'Instalar App'}
        </span>
      </button>

      {showIOSInstructions && (
        <div className="fixed inset-0 bg-black/60 z-50 flex items-center justify-center p-4" onClick={() => setShowIOSInstructions(false)}>
          <div className="bg-white rounded-2xl max-w-sm w-full p-6 shadow-xl" onClick={(e) => e.stopPropagation()}>
            <div className="flex items-center justify-between mb-4">
              <h2 className="text-lg font-bold text-surface-800">Instala RideSocopó</h2>
              <button onClick={() => setShowIOSInstructions(false)} className="p-2 text-surface-400 hover:text-surface-600">
                <X className="w-5 h-5" />
              </button>
            </div>

            {isIOS() ? (
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
                  <p className="text-sm text-surface-700"><strong>4. Toca "Añadir"</strong> (arriba a la derecha). ¡Listo!</p>
                </div>
                <div className="bg-primary-50 rounded-xl p-3">
                  <p className="text-xs text-primary-700">💡 Ábrela desde el icono en tu pantalla de inicio. Se verá como una app nativa.</p>
                </div>
              </div>
            ) : (
              <div className="space-y-3">
                <div className="bg-surface-50 rounded-xl p-4">
                  <p className="text-sm text-surface-700"><strong>Para Android/Windows:</strong></p>
                  <ol className="list-decimal ml-4 mt-2 text-sm text-surface-600 space-y-1">
                    <li>Abre el menú del navegador (⋮ en Chrome o ⋯ en Edge)</li>
                    <li>Toca <strong>"Instalar app"</strong> o <strong>"Instalar RideSocopó"</strong></li>
                    <li>Confirma en el diálogo</li>
                  </ol>
                </div>
                <div className="bg-surface-50 rounded-xl p-4">
                  <p className="text-sm text-surface-700"><strong>Alternativa:</strong> Usa el botón de descarga en la barra del navegador.</p>
                </div>
              </div>
            )}

            <button onClick={() => setShowIOSInstructions(false)} className="btn-primary w-full mt-4">
              Entendido
            </button>
          </div>
        </div>
      )}
    </>
  )
}