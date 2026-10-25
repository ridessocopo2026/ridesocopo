// ============================================================
// BUNRIDER - Pago en efectivo (solo USD)
// ------------------------------------------------------------
// Fuente única de verdad para el dinero en efectivo:
//   - denominaciones disponibles en la interfaz
//   - total entregado y vuelto
//   - textos para el pasajero y para el conductor
//
// El servidor valida exactamente lo mismo dentro de request_ride
// (migración 110): aquí solo se anticipa lo que va a aceptar.
// ============================================================
import { fmt } from '@/lib/format'

/**
 * Billetes que se ofrecen en la app.
 * El servidor acepta denominaciones de 1 a 100 000, así que añadir
 * un billete nuevo aquí NO requiere una migración.
 */
export const CASH_DENOMS = [1, 5, 10, 20, 50] as const

/** Billetes elegidos: { "20": 1, "5": 2 } */
export interface CashByBills { b: Record<string, number> }
/** El pasajero paga el monto exacto: no requiere vuelto */
export interface CashExact { x: true }
export type CashBills = CashByBills | CashExact

/** Redondeo a centavos sin errores de coma flotante */
const round2 = (n: number) => Math.round((n + Number.EPSILON) * 100) / 100

/** ¿El pasajero marcó "pago exacto"? */
export function isExactCash(cash: CashBills | null | undefined): cash is CashExact {
  return !!cash && 'x' in cash && cash.x === true
}

/** Billetes seleccionados ({ "20": 1 }) o {} si no aplica */
export function cashBillsMap(cash: CashBills | null | undefined): Record<string, number> {
  return cash && 'b' in cash ? cash.b : {}
}

/** Total que entregará el pasajero (0 si no hay billetes) */
export function cashTotal(cash: CashBills | null | undefined): number {
  const bills = cashBillsMap(cash)
  return round2(
    Object.entries(bills).reduce((sum, [denom, count]) => sum + Number(denom) * Number(count), 0)
  )
}

/** Vuelto que debe llevar el conductor (nunca negativo) */
export function cashChange(cash: CashBills | null | undefined, fareUsd: number): number {
  if (isExactCash(cash)) return 0
  const total = cashTotal(cash)
  if (total <= 0) return 0
  return round2(Math.max(0, total - Number(fareUsd || 0)))
}

/** Cuánto falta para cubrir la tarifa (0 si ya la cubre o es exacto) */
export function cashMissing(cash: CashBills | null | undefined, fareUsd: number): number {
  if (isExactCash(cash)) return 0
  const total = cashTotal(cash)
  if (total <= 0) return 0
  return round2(Math.max(0, Number(fareUsd || 0) - total))
}

/**
 * ¿La selección permite solicitar el viaje?
 * - "Pago exacto" siempre sirve.
 * - Con billetes, deben cubrir la tarifa.
 */
export function canSubmitCash(cash: CashBills | null | undefined, fareUsd: number): boolean {
  if (isExactCash(cash)) return true
  const total = cashTotal(cash)
  if (total <= 0) return false
  return total + 1e-9 >= Number(fareUsd || 0)
}

/** Detalle legible de los billetes: "20$ + 5$" */
export function cashBillsLabel(cash: CashBills | null | undefined): string {
  return Object.entries(cashBillsMap(cash))
    .sort(([a], [b]) => Number(b) - Number(a))
    .map(([denom, count]) => (count > 1 ? `${count}× ${denom}$` : `${denom}$`))
    .join(' + ')
}

/**
 * Texto corto para el conductor.
 *   "Paga con 25,00$ · vuelto 1,80$"
 *   "Paga con 23,20$ · sin vuelto"
 *   "Pago exacto · sin vuelto"
 */
export function describeCash(cash: CashBills | null | undefined, fareUsd: number): string | null {
  if (!cash) return null
  if (isExactCash(cash)) return 'Pago exacto · sin vuelto'

  const total = cashTotal(cash)
  if (total <= 0) return null

  const change = cashChange(cash, fareUsd)
  return change > 0
    ? `Paga con ${fmt(total)} · vuelto ${fmt(change)}`
    : `Paga con ${fmt(total)} · sin vuelto`
}

/**
 * Normaliza lo que llega de la base de datos (jsonb) al tipo CashBills.
 * Devuelve null si el contenido no tiene la forma esperada.
 */
export function parseCashBills(raw: unknown): CashBills | null {
  if (!raw || typeof raw !== 'object') return null
  const value = raw as Record<string, unknown>

  if (value.x === true) return { x: true }

  const bills = value.b
  if (!bills || typeof bills !== 'object') return null

  const clean: Record<string, number> = {}
  for (const [denom, count] of Object.entries(bills as Record<string, unknown>)) {
    const d = Number(denom)
    const c = Number(count)
    if (!Number.isFinite(d) || !Number.isFinite(c) || d <= 0 || c <= 0) continue
    clean[String(Math.trunc(d))] = Math.trunc(c)
  }
  return Object.keys(clean).length > 0 ? { b: clean } : null
}
