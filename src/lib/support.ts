import { whatsappNumber } from '@/lib/format'

/** Número público de soporte (respaldo si la ciudad no tiene uno). */
export const DEFAULT_SUPPORT_WHATSAPP = '+584162608950'

export const SUPPORT_WHATSAPP_MESSAGE = 'Hola, necesito ayuda con BunRider.'

/**
 * Enlace de WhatsApp con mensaje precargado.
 * Nunca devuelve null: si el número de la ciudad no es válido usa el de respaldo.
 */
export function supportWhatsAppLink(
  phone?: string | null,
  message: string = SUPPORT_WHATSAPP_MESSAGE
): string {
  const number =
    whatsappNumber(phone) ||
    whatsappNumber(DEFAULT_SUPPORT_WHATSAPP) ||
    '584162608950'
  return `https://wa.me/${number}?text=${encodeURIComponent(message)}`
}