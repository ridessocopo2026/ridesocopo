import { useLayoutEffect } from 'react'
import { useLocation } from 'react-router-dom'

/**
 * BUNRIDER - Resetea el scroll al cambiar de ruta.
 *
 * Sin esto, el navegador conserva window.scrollY al navegar entre páginas
 * (ej: Inicio scrolleado a la mitad → Billetera aparece a la mitad).
 *
 * - useLayoutEffect: se ejecuta antes del paint → sin parpadeo.
 * - history.scrollRestoration = 'manual': evita que Chrome/Android
 *   restablezcan el scroll al volver atrás (back/forward).
 */
export function ScrollToTop() {
  const { pathname } = useLocation()

  useLayoutEffect(() => {
    if ('scrollRestoration' in history) {
      history.scrollRestoration = 'manual'
    }
    window.scrollTo(0, 0)
  }, [pathname])

  return null
}
