/**
 * Format helpers for the app
 * Moneda: formato venezolano con $ al final — 1,00$
 * Fecha: zona horaria de Venezuela (UTC-4, America/Caracas)
 */

/** Formatea un número como moneda con $ al final: 1,00$ */
export function fmt(n: number | null | undefined): string {
  const v = Number(n || 0)
  // Usar coma como separador decimal (estilo venezolano)
  return `${v.toFixed(2).replace('.', ',')}$`
}

/** Formatea con signo + para ingresos: +1,00$ */
export function fmtSigned(n: number | null | undefined): string {
  const v = Number(n || 0)
  const s = v >= 0 ? '+' : '-'
  return `${s}${Math.abs(v).toFixed(2).replace('.', ',')}$`
}

/** Formatea para mostrar montos absolutos sin signo */
export function fmtAbs(n: number | null | undefined): string {
  const v = Math.abs(Number(n || 0))
  return `${v.toFixed(2).replace('.', ',')}$`
}

/** Fecha de hoy en Venezuela (UTC-4) como YYYY-MM-DD */
export function todayVE(): string {
  const d = new Date()
  // Convertir a hora de Venezuela (UTC-4)
  const ve = new Date(d.getTime() - (d.getTimezoneOffset() + 240) * 60000)
  return ve.toISOString().split('T')[0]
}

/** Fecha de hace N días en Venezuela como YYYY-MM-DD */
export function daysAgoVE(days: number): string {
  const d = new Date()
  d.setDate(d.getDate() - days)
  const ve = new Date(d.getTime() - (d.getTimezoneOffset() + 240) * 60000)
  return ve.toISOString().split('T')[0]
}

/** Timestamp de inicio del día en Venezuela (UTC-4): YYYY-MM-DDT00:00:00-04:00 */
export function fechaInicioVE(dateStr: string): string {
  return `${dateStr}T00:00:00-04:00`
}

/** Timestamp de fin del día en Venezuela (UTC-4): YYYY-MM-DDT23:59:59-04:00 */
export function fechaFinVE(dateStr: string): string {
  return `${dateStr}T23:59:59-04:00`
}

/** Normaliza un teléfono venezolano a dígitos internacionales para WhatsApp (wa.me).
 *  Acepta: 0412-1234567, +58 412 1234567, 4121234567, 58412...
 *  Devuelve solo dígitos (sin '+'): '584121234567' o null si no es válido. */
export function whatsappNumber(phone: string | null | undefined): string | null {
  if (!phone) return null
  const digits = phone.replace(/\D/g, '')
  if (!digits) return null

  let number: string | null
  if (digits.startsWith('58')) {
    number = digits.length >= 12 ? digits : null
  } else if (digits.startsWith('0')) {
    number = '58' + digits.slice(1)
  } else if (digits.length === 10 || digits.length === 11) {
    number = '58' + digits
  } else {
    number = null
  }

  return number && number.length >= 11 && number.length <= 15 ? number : null
}
