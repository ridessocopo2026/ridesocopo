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
