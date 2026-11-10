import type { ReactNode } from 'react'
import { fmt } from '@/lib/format'

export interface PriceBreakdownProps {
  baseFare: number
  originSurcharge?: number | null
  originLabel?: string | null
  destinationSurcharge?: number | null
  destinationLabel?: string | null
  discount?: number | null
  couponCode?: string | null
  /** Comision de la plataforma: solo para admin/conductor */
  commission?: number | null
  total: number
  totalLabel?: string
  className?: string
}

/**
 * Desglose de la tarifa de un viaje.
 *
 * Muestra SOLO las lineas que aplican (recargos > 0, cupon > 0) para que el
 * pasajero entienda de donde sale el total. Ejemplo:
 *
 *   Tarifa base                              2,00$
 *   Recargo sector de destino (Bumbum)      +3,00$
 *   Subtotal                                 5,00$
 *   Total a pagar                            5,00$
 *
 * Se usa en la hoja de pago (ClientHome) y en el detalle del viaje
 * (TripDetailInfo) para que ambos muestren exactamente lo mismo.
 */
export function PriceBreakdown({
  baseFare,
  originSurcharge,
  originLabel,
  destinationSurcharge,
  destinationLabel,
  discount,
  couponCode,
  commission,
  total,
  totalLabel = 'Total a pagar',
  className = ''
}: PriceBreakdownProps) {
  const origin = Number(originSurcharge || 0)
  const destination = Number(destinationSurcharge || 0)
  const coupon = Number(discount || 0)
  const hasSurcharges = origin > 0 || destination > 0

  const row = (label: ReactNode, value: string, valueClass = 'text-surface-700') => (
    <div className="flex justify-between gap-3">
      <span className="text-surface-500">{label}</span>
      <span className={`font-medium ${valueClass}`}>{value}</span>
    </div>
  )

  return (
    <div className={`space-y-2 text-sm ${className}`}>
      {row('Tarifa base', fmt(baseFare))}

      {origin > 0 &&
        row(
          <>Recargo sector de origen{originLabel ? ` (${originLabel})` : ''}</>,
          `+${fmt(origin)}`,
          'text-accent-700'
        )}

      {destination > 0 &&
        row(
          <>Recargo sector de destino{destinationLabel ? ` (${destinationLabel})` : ''}</>,
          `+${fmt(destination)}`,
          'text-accent-700'
        )}

      {hasSurcharges && (
        <div className="flex justify-between gap-3 pt-2 border-t border-surface-100">
          <span className="text-surface-600">Subtotal</span>
          <span className="font-semibold text-surface-800">{fmt(baseFare + origin + destination)}</span>
        </div>
      )}

      {coupon > 0 &&
        row(
          <>Cupón aplicado{couponCode ? ` (${couponCode})` : ''}</>,
          `-${fmt(coupon)}`,
          'text-emerald-700'
        )}

      {commission != null && row('Comisión de la app', fmt(commission))}

      <div className="flex justify-between gap-3 pt-2 border-t border-surface-200 items-baseline">
        <span className="font-semibold text-surface-800">{totalLabel}</span>
        <span className="text-2xl font-bold text-primary-600">{fmt(total)}</span>
      </div>
    </div>
  )
}