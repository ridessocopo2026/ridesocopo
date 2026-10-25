/**
 * Selector compacto de billetes para el pago en efectivo.
 *
 * Se muestra dentro del bottom sheet de "Detalle del viaje" cuando el
 * pasajero elige Efectivo. Un toque agrega un billete; cada billete
 * aparece como pastilla que se puede quitar. El atajo "Pago exacto"
 * evita tener que elegir billetes cuando el pasajero lleva el monto justo.
 *
 * Toda la aritmética vive en '@/lib/cash' para que el conductor muestre
 * exactamente el mismo vuelto.
 */
import { Banknote, Check, X } from 'lucide-react'
import { fmt } from '@/lib/format'
import {
  CASH_DENOMS,
  type CashBills,
  cashBillsMap,
  cashChange,
  cashMissing,
  cashTotal,
  isExactCash
} from '@/lib/cash'

interface CashPaymentPickerProps {
  fareUsd: number
  value: CashBills | null
  onChange: (value: CashBills | null) => void
}

export function CashPaymentPicker({ fareUsd, value, onChange }: CashPaymentPickerProps) {
  const exact = isExactCash(value)
  const bills = cashBillsMap(value)
  const total = cashTotal(value)
  const change = cashChange(value, fareUsd)
  const missing = cashMissing(value, fareUsd)
  const selectedEntries = Object.entries(bills).sort(([a], [b]) => Number(b) - Number(a))
  const hasSelection = exact || selectedEntries.length > 0

  const addBill = (denom: number) => {
    const key = String(denom)
    // Si venía de "pago exacto", cambiarlo a billetes es intencional
    const next: Record<string, number> = exact ? {} : { ...bills }
    const count = (next[key] || 0) + 1
    if (count > 9) return
    next[key] = count
    onChange({ b: next })
  }

  const removeBill = (denom: number) => {
    const key = String(denom)
    const next: Record<string, number> = { ...bills }
    const count = (next[key] || 0) - 1
    if (count > 0) next[key] = count
    else delete next[key]
    onChange(Object.keys(next).length > 0 ? { b: next } : null)
  }

  return (
    <div className="rounded-xl border border-surface-200 bg-surface-50/60 p-3">
      <div className="flex items-center justify-between mb-2">
        <label className="text-xs font-semibold text-surface-700 flex items-center gap-1.5">
          <Banknote className="w-3.5 h-3.5 text-emerald-600" />
          ¿Con qué billetes vas a pagar?
        </label>
        {hasSelection && (
          <button
            type="button"
            onClick={() => onChange(null)}
            className="text-[11px] font-medium text-surface-400 hover:text-surface-600"
          >
            Limpiar
          </button>
        )}
      </div>

      {/* Billetes disponibles */}
      <div className="grid grid-cols-5 gap-1.5">
        {CASH_DENOMS.map((denom) => {
          const count = bills[String(denom)] || 0
          const active = count > 0
          return (
            <button
              key={denom}
              type="button"
              onClick={() => addBill(denom)}
              aria-pressed={active}
              aria-label={`Agregar billete de ${denom} dólares`}
              className={`relative h-10 rounded-lg border-2 text-sm font-bold transition-all active:scale-95 ${
                active
                  ? 'border-emerald-500 bg-emerald-50 text-emerald-700'
                  : 'border-surface-200 bg-white text-surface-600'
              }`}
            >
              {denom}$
              {count > 1 && (
                <span className="absolute -top-1.5 -right-1.5 min-w-[18px] h-[18px] px-1 rounded-full bg-emerald-600 text-white text-[10px] font-bold flex items-center justify-center">
                  {count}
                </span>
              )}
            </button>
          )
        })}
      </div>

      {/* Billetes elegidos (quitar de uno en uno) */}
      {selectedEntries.length > 0 && (
        <div className="flex flex-wrap gap-1.5 mt-2.5">
          {selectedEntries.map(([denom, count]) => (
            <button
              key={denom}
              type="button"
              onClick={() => removeBill(Number(denom))}
              aria-label={`Quitar un billete de ${denom} dólares`}
              className="inline-flex items-center gap-1 rounded-full border border-primary-200 bg-primary-50 pl-2 pr-1.5 py-1 text-[11px] font-semibold text-primary-700"
            >
              {denom}$
              {count > 1 && <span className="text-primary-500">×{count}</span>}
              <X className="w-3 h-3" />
            </button>
          ))}
        </div>
      )}

      {/* Atajo: pago exacto */}
      <button
        type="button"
        onClick={() => onChange(exact ? null : { x: true })}
        aria-pressed={exact}
        className={`w-full mt-2.5 rounded-lg border-2 px-3 py-2 text-xs font-semibold flex items-center justify-center gap-1.5 transition-all ${
          exact
            ? 'border-emerald-500 bg-emerald-50 text-emerald-700'
            : 'border-surface-200 bg-white text-surface-600'
        }`}
      >
        <Check className="w-3.5 h-3.5" />
        Pago exacto · no necesito vuelto
      </button>

      {/* Resumen: vuelto o lo que falta */}
      {exact ? (
        <p className="mt-2 text-[11px] text-emerald-700 font-medium">
          Le indicaremos al conductor que llevas el monto exacto.
        </p>
      ) : total > 0 ? (
        missing > 0 ? (
          <p className="mt-2 text-[11px] font-medium text-amber-700">
            Te faltan {fmt(missing)} para cubrir los {fmt(fareUsd)} del viaje.
          </p>
        ) : (
          <p className="mt-2 text-[11px] font-medium text-emerald-700">
            Entregas {fmt(total)} · vuelto {fmt(change)}
            {change === 0 && ' (justo)'}
          </p>
        )
      ) : (
        <p className="mt-2 text-[11px] text-surface-400">
          Toca los billetes con los que pagarás para avisar al conductor.
        </p>
      )}
    </div>
  )
}
