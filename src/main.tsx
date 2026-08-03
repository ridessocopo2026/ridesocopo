import React from 'react'
import ReactDOM from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import App from './App'
import './styles/index.css'

// ============================================================
// CAPTURA TEMPRANA del evento beforeinstallprompt
// Chrome lo dispara MUY pronto (antes de que React monte).
// Si lo perdemos, no podemos abrir el diálogo de instalación.
// Exponemos una función global para que InstallAppButton la use.
// ============================================================
interface BeforeInstallPromptLike {
  prompt: () => Promise<void>
  userChoice: Promise<{ outcome: 'accepted' | 'dismissed'; platform: string }>
}

let globalDeferredPrompt: BeforeInstallPromptLike | null = null

window.addEventListener('beforeinstallprompt', (e: Event) => {
  e.preventDefault()
  globalDeferredPrompt = e as unknown as BeforeInstallPromptLike

  // Notificar al componente cuando llega el prompt
  window.dispatchEvent(new Event('app-install-prompt-ready'))
})

// Función global accesible desde InstallAppButton
;(window as any).__getDeferredPrompt = () => globalDeferredPrompt
;(window as any).__clearDeferredPrompt = () => { globalDeferredPrompt = null }

// Registrar el Service Worker al cargar la app.
// Es REQUISITO para que Chrome/Edge disparen "beforeinstallprompt"
// y se pueda instalar la PWA como app.
if ('serviceWorker' in navigator) {
  window.addEventListener('load', () => {
    navigator.serviceWorker.register('/sw.js').catch(() => {})
  })
}

// Si el app ya está instalada, marcar el prompt como usado
if ((window.matchMedia('(display-mode: standalone)').matches as boolean) || (navigator as any).standalone === true) {
  ;(window as any).__clearDeferredPrompt()
}

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <BrowserRouter>
      <App />
    </BrowserRouter>
  </React.StrictMode>
)