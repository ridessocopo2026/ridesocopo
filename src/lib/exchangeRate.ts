import { supabase } from '@/lib/supabase'

/**
 * Tasa de cambio (Bs por USD) con cache.
 *
 * Objetivo: que la app NO repita la peticion de la tasa en cada pantalla.
 *  - Una sola peticion aunque varias pantallas la pidan a la vez (deduplicacion).
 *  - Se reutiliza 10 minutos (memoria + localStorage).
 *  - Si la red falla, devuelve la ultima tasa conocida (o 0) sin romper el flujo.
 */
const TTL_MS = 10 * 60 * 1000
const STORAGE_KEY = 'bunrider:exchange_rate'

interface CachedRate {
  rate: number
  at: number
}

let memory: CachedRate | null = null
let inflight: Promise<number> | null = null

function readStorage(): CachedRate | null {
  try {
    const raw = localStorage.getItem(STORAGE_KEY)
    if (!raw) return null
    const parsed = JSON.parse(raw) as CachedRate
    if (!parsed || !Number.isFinite(parsed.rate) || !Number.isFinite(parsed.at)) return null
    return parsed
  } catch {
    return null
  }
}

function store(rate: number): void {
  const entry: CachedRate = { rate, at: Date.now() }
  memory = entry
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(entry))
  } catch {
    // Sin storage disponible: solo queda en memoria
  }
}

/** Tasa en cache si sigue vigente (< 10 min). 0 si no hay. */
export function peekExchangeRate(): number {
  const entry = memory ?? readStorage()
  if (!entry) return 0
  return Date.now() - entry.at < TTL_MS ? entry.rate : 0
}

/** Devuelve la tasa (usando cache cuando esta vigente). */
export async function getExchangeRate(force = false): Promise<number> {
  const entry = memory ?? readStorage()
  if (entry) memory = entry

  if (!force && entry && Date.now() - entry.at < TTL_MS) {
    return entry.rate
  }

  if (inflight) return inflight

  inflight = (async () => {
    try {
      const { data, error } = await supabase.rpc('get_active_exchange_rate')
      if (error) throw error
      const rate = Number(data)
      if (!Number.isFinite(rate) || rate <= 0) throw new Error('tasa invalida')
      store(rate)
      return rate
    } catch {
      // Mejor una tasa vieja que ninguna
      return entry?.rate ?? 0
    } finally {
      inflight = null
    }
  })()

  return inflight
}