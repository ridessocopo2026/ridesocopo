import { useEffect } from 'react'
import { X } from 'lucide-react'

interface ImageLightboxProps {
  /** URL de la imagen; si es null/undefined no se renderiza nada */
  src?: string | null
  /** Texto alternativo (accesibilidad) */
  alt?: string
  /** Texto que se muestra abajo (ej: nombre del conductor) */
  title?: string
  onClose: () => void
}

/**
 * Visor de imagen a pantalla completa.
 *
 * Optimizado a propósito:
 *  - Mientras está cerrado no renderiza NADA (coste 0 de DOM y red).
 *  - Usa la MISMA url que la miniatura ya cargada, así el navegador
 *    la saca de caché: abrir la foto no gasta datos ni egress.
 *  - No agrega dependencias ni librerías de zoom.
 *
 * Se cierra de 3 formas: botón X, tocando el fondo o con Escape.
 */
export function ImageLightbox({ src, alt = 'Foto', title, onClose }: ImageLightboxProps) {
  useEffect(() => {
    if (!src) return

    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    document.addEventListener('keydown', onKey)

    // Evita que el fondo haga scroll mientras la foto está abierta
    const overflowPrevio = document.body.style.overflow
    document.body.style.overflow = 'hidden'

    return () => {
      document.removeEventListener('keydown', onKey)
      document.body.style.overflow = overflowPrevio
    }
  }, [src, onClose])

  if (!src) return null

  return (
    <div
      role="dialog"
      aria-modal="true"
      aria-label={title || alt}
      className="fixed inset-0 z-[60] bg-black/85 backdrop-blur-sm flex items-center justify-center p-4 animate-fade-in"
      onClick={onClose}
    >
      <button
        type="button"
        onClick={onClose}
        aria-label="Cerrar imagen"
        className="absolute top-4 right-4 w-11 h-11 rounded-full bg-white/15 text-white flex items-center justify-center hover:bg-white/25 active:scale-95 transition"
      >
        <X className="w-6 h-6" />
      </button>

      <img
        src={src}
        alt={alt}
        decoding="async"
        className="max-h-[85vh] max-w-full rounded-2xl object-contain shadow-elevated select-none"
        onClick={(e) => e.stopPropagation()}
      />

      {title && (
        <p className="absolute bottom-6 left-0 right-0 text-center text-sm text-white/90 px-6">
          {title}
        </p>
      )}
    </div>
  )
}
