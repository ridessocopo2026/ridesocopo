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

/** Desfase de Venezuela respecto a UTC en minutos (UTC-4). */
const VE_OFFSET_MIN = 240

/** Fecha de hoy en Venezuela (UTC-4) como YYYY-MM-DD.
 * Se resta SOLO el desfase fijo de Venezuela: así el resultado no depende de
 * la zona horaria del dispositivo. Antes se restaba también
 * getTimezoneOffset(), y con el equipo en Venezuela eso corría 4 h la fecha:
 * entre las 00:00 y las 04:00 el "hoy" era AYER, por lo que los viajes recién
 * hechos quedaban fuera del rango y no aparecían en los listados (viajes,
 * métricas, transacciones). */
export function todayVE(): string {
  return new Date(Date.now() - VE_OFFSET_MIN * 60000).toISOString().slice(0, 10)
}

/** Fecha de hace N días en Venezuela como YYYY-MM-DD */
export function daysAgoVE(days: number): string {
  return new Date(Date.now() - VE_OFFSET_MIN * 60000 - days * 86400000).toISOString().slice(0, 10)
}

/** Timestamp de inicio del día en Venezuela (UTC-4): YYYY-MM-DDT00:00:00-04:00 */
export function fechaInicioVE(dateStr: string): string {
  return `${dateStr}T00:00:00-04:00`
}

/** Timestamp de fin del día en Venezuela (UTC-4): YYYY-MM-DDT23:59:59-04:00 */
export function fechaFinVE(dateStr: string): string {
  return `${dateStr}T23:59:59-04:00`
}

/** Zona horaria de referencia para mostrar fechas en la UI. */
const VE_TZ = 'America/Caracas'

// Instancias Intl reutilizadas: construirlas es caro y se usan una vez por fila
// en listas, así que se crean una sola vez a nivel de módulo.
const FMT_FECHA_HORA_CORTA = new Intl.DateTimeFormat('es-VE', {
  timeZone: VE_TZ,
  day: '2-digit',
  month: '2-digit',
  hour: '2-digit',
  minute: '2-digit',
  hour12: true
})

const FMT_FECHA_HORA = new Intl.DateTimeFormat('es-VE', {
  timeZone: VE_TZ,
  day: '2-digit',
  month: '2-digit',
  year: 'numeric',
  hour: '2-digit',
  minute: '2-digit',
  hour12: true
})

const FMT_HORA = new Intl.DateTimeFormat('es-VE', {
  timeZone: VE_TZ,
  hour: '2-digit',
  minute: '2-digit',
  hour12: true
})

/** Devuelve un Date válido o null (acepta ISO string, timestamp o Date). */
function toValidDate(value: string | Date | null | undefined): Date | null {
  if (!value) return null
  const d = typeof value === 'string' ? new Date(value) : value
  return Number.isNaN(d.getTime()) ? null : d
}

/** Fecha y hora cortas en hora de Venezuela: "10/11, 02:37 a. m." */
export function fmtFechaHoraCortaVE(value: string | Date | null | undefined): string {
  const d = toValidDate(value)
  return d ? FMT_FECHA_HORA_CORTA.format(d) : '—'
}

/** Fecha y hora completas en hora de Venezuela: "10/11/2026, 02:37 a. m." */
export function fmtFechaHoraVE(value: string | Date | null | undefined): string {
  const d = toValidDate(value)
  return d ? FMT_FECHA_HORA.format(d) : '—'
}

/** Solo la hora en Venezuela: "02:37 a. m." */
export function fmtHoraVE(value: string | Date | null | undefined): string {
  const d = toValidDate(value)
  return d ? FMT_HORA.format(d) : '—'
}

/** Duración legible entre dos instantes: "16 min", "1 h 05 min".
 *  Devuelve null si falta algún dato, es inválido o el orden no tiene sentido. */
export function fmtDuracion(
  inicio: string | Date | null | undefined,
  fin: string | Date | null | undefined
): string | null {
  const a = toValidDate(inicio)
  const b = toValidDate(fin)
  if (!a || !b) return null
  const ms = b.getTime() - a.getTime()
  if (ms <= 0) return null
  const min = Math.round(ms / 60000)
  if (min < 1) return 'menos de 1 min'
  if (min < 60) return `${min} min`
  const h = Math.floor(min / 60)
  const m = min % 60
  return m === 0 ? `${h} h` : `${h} h ${String(m).padStart(2, '0')} min`
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

/**
 * Enlace de WhatsApp con mensaje precargado.
 * Devuelve null si el teléfono no es válido (así la UI puede ocultar el botón).
 *
 * @param phone   teléfono en cualquier formato venezolano (0412..., +58...)
 * @param message texto que se abre ya escrito en el chat
 */
export function whatsappLink(
  phone: string | null | undefined,
  message: string
): string | null {
  const number = whatsappNumber(phone)
  if (!number) return null
  return `https://wa.me/${number}?text=${encodeURIComponent(message)}`
}


/** Formato de bolívares con separador de miles venezolano: 1.234,56 Bs */
const BS_FORMAT = new Intl.NumberFormat('es-VE', {
  minimumFractionDigits: 2,
  maximumFractionDigits: 2
})

/** Formatea un monto en bolívares: 10.000,00 Bs */
export function fmtBs(n: number | null | undefined): string {
  return `${BS_FORMAT.format(Number(n || 0))} Bs`
}

/** Convierte dolares a bolivares con la tasa indicada (redondeo a 2 decimales) */
export function usdToBs(usd: number | null | undefined, rate: number | null | undefined): number {
  return Math.round(Number(usd || 0) * Number(rate || 0) * 100) / 100
}