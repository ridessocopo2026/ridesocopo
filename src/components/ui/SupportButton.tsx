import { useEffect, useState } from 'react'
import { MessageCircle } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { whatsappNumber } from '@/lib/format'

/**
 * Boton de soporte por WhatsApp.
 * variant='icon': icono para el encabezado (junto a la campana).
 * variant='card': tarjeta para el perfil.
 * Lee el numero de soporte actual cada vez que se monta (sin cache),
 * para que los cambios en la ciudad se reflejen de inmediato.
 */
export function SupportButton({
  variant = 'icon',
  className = ''
}: {
  variant?: 'icon' | 'card'
  className?: string
}) {
  const [phone, setPhone] = useState('')

  useEffect(() => {
    let cancelled = false
    supabase.rpc('get_my_support').then(({ data }) => {
      if (cancelled) return
      const p = (data as { phone?: string | null } | null)?.phone || ''
      if (p) setPhone(p)
    }, () => { /* silencioso */ })
    return () => { cancelled = true }
  }, [])

  const wa = whatsappNumber(phone)
  if (!wa) return null

  if (variant === 'card') {
    return (
      <a
        href={`https://wa.me/${wa}`}
        target="_blank"
        rel="noopener noreferrer"
        className="card flex items-center gap-3 p-4 hover:border-emerald-300 transition-colors"
      >
        <div className="w-10 h-10 bg-emerald-50 rounded-full flex items-center justify-center">
          <MessageCircle className="w-5 h-5 text-emerald-600" />
        </div>
        <div className="flex-1">
          <p className="font-medium text-surface-700">Soporte</p>
          <p className="text-xs text-surface-400">Escribenos por WhatsApp</p>
        </div>
      </a>
    )
  }

  return (
    <a
      href={`https://wa.me/${wa}`}
      target="_blank"
      rel="noopener noreferrer"
      className={`p-2 text-white hover:text-white/70 transition-colors ${className}`}
      aria-label="Soporte por WhatsApp"
      title="Soporte por WhatsApp"
    >
      <MessageCircle className="w-5 h-5" />
    </a>
  )
}