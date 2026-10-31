import { Link } from 'react-router-dom'
import { WhatsAppIcon } from '@/components/ui/WhatsAppIcon'
import { supportWhatsAppLink } from '@/lib/support'

/**
 * Footer con enlaces legales. Se muestra al final de la app.
 */
export function Footer() {
  return (
    <footer className="w-full px-4 py-6 bg-surface-50 border-t border-surface-100">
      <nav className="max-w-md mx-auto flex flex-wrap items-center justify-center gap-x-4 gap-y-2 text-xs text-surface-500">
        <a
          href={supportWhatsAppLink()}
          target="_blank"
          rel="noopener noreferrer"
          className="inline-flex items-center gap-1.5 text-emerald-600 hover:text-emerald-700 font-medium"
        >
          <WhatsAppIcon className="w-4 h-4" />
          Soporte por WhatsApp
        </a>
        <Link to="/politicas-de-privacidad" className="hover:text-primary-600 underline underline-offset-2">
          Políticas de Privacidad
        </Link>
        <Link to="/terminos-y-condiciones" className="hover:text-primary-600 underline underline-offset-2">
          Términos y Condiciones
        </Link>
        <Link to="/sobre-bunrider" className="hover:text-primary-600 underline underline-offset-2">
          Sobre BunRider
        </Link>
      </nav>
      <p className="max-w-md mx-auto text-center text-[11px] text-surface-400 mt-3">
        © {new Date().getFullYear()} BunRider. Todos los derechos reservados.
      </p>
    </footer>
  )
}