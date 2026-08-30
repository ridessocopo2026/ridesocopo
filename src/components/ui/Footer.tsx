import { Link } from 'react-router-dom'

/**
 * Footer con enlaces legales. Se muestra al final de la app.
 */
export function Footer() {
  return (
    <footer className="w-full px-4 py-6 bg-surface-50 border-t border-surface-100">
      <nav className="max-w-md mx-auto flex flex-wrap items-center justify-center gap-x-4 gap-y-2 text-xs text-surface-500">
        <Link to="/politicas-de-privacidad" className="hover:text-primary-600 underline underline-offset-2">
          Políticas de Privacidad
        </Link>
        <Link to="/terminos-y-condiciones" className="hover:text-primary-600 underline underline-offset-2">
          Términos y Condiciones
        </Link>
        <Link to="/sobre-riderflash" className="hover:text-primary-600 underline underline-offset-2">
          Sobre BunRider
        </Link>
      </nav>
      <p className="max-w-md mx-auto text-center text-[11px] text-surface-400 mt-3">
        © {new Date().getFullYear()} BunRider. Hecho en Socopó, Barinas, Venezuela.
      </p>
    </footer>
  )
}
