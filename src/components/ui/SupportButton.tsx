import { useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { WhatsAppIcon } from '@/components/ui/WhatsAppIcon'
import { DEFAULT_SUPPORT_WHATSAPP, supportWhatsAppLink } from '@/lib/support'

/**
 * Botón de soporte por WhatsApp.
 * variant='icon': botón verde circular para el encabezado (junto a la campana).
 * variant='card': tarjeta para el perfil / inicio del invitado.
 *
 * Funciona también sin sesión: usa `get_public_support` (p_zone_id) y, si
 * esa RPC aún no está disponible, cae al número público de respaldo.
 * El botón se muestra desde el primer render para que nunca desaparezca.
 */
export function SupportButton({
  variant = 'icon',
  className = '',
  zoneId = null
}: {
  variant?: 'icon' | 'card'
  className?: string
  /** Ciudad seleccionada (para invitados) y así mostrar el número de esa zona */
  zoneId?: string | null
}) {
  const [phone, setPhone] = useState(DEFAULT_SUPPORT_WHATSAPP)

  useEffect(() => {
    let cancelled = false

    const apply = (p?: string | null) => {
      if (!cancelled && p) setPhone(p)
    }

    supabase
      .rpc('get_public_support', { p_zone_id: zoneId })
      .then(({ data, error }) => {
        if (cancelled) return
        if (!error && data) {
          apply((data as { phone?: string | null }).phone)
          return
        }
        // Compatibilidad si la migración aún no está aplicada
        supabase
          .rpc('get_my_support')
          .then(({ data: d }) => apply((d as { phone?: string | null } | null)?.phone), () => {})
      }, () => { /* silencioso: se queda el número de respaldo */ })

    return () => { cancelled = true }
  }, [zoneId])

  const href = supportWhatsAppLink(phone)

  if (variant === 'card') {
    return (
      <a
        href={href}
        target="_blank"
        rel="noopener noreferrer"
        className={`card flex items-center gap-3 p-4 border-emerald-200 bg-emerald-50/60 hover:border-emerald-300 transition-colors ${className}`}
      >
        <div className="w-11 h-11 bg-[#25D366] rounded-full flex items-center justify-center text-white shadow-sm flex-shrink-0">
          <WhatsAppIcon className="w-6 h-6" />
        </div>
        <div className="flex-1 min-w-0">
          <p className="font-semibold text-surface-800">¿Tienes dudas? Escríbenos</p>
          <p className="text-xs text-surface-500">
            Soporte por WhatsApp · te ayudamos a pedir tu primer viaje
          </p>
        </div>
      </a>
    )
  }

  return (
    <a
      href={href}
      target="_blank"
      rel="noopener noreferrer"
      className={`flex items-center justify-center w-9 h-9 rounded-full bg-[#25D366] text-white shadow-sm hover:bg-[#1ebe5b] active:scale-95 transition-all ${className}`}
      aria-label="Escríbenos por WhatsApp"
      title="Escríbenos por WhatsApp"
    >
      <WhatsAppIcon className="w-5 h-5" />
    </a>
  )
}