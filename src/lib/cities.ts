import { supabase } from '@/lib/supabase'

/**
 * Cache de ciudades activas (5 min) en memoria + sessionStorage.
 * Evita repetir la RPC get_active_cities en cada navegacion.
 */
const CACHE_KEY = 'rs_active_cities_v2'
const TTL_MS = 5 * 60 * 1000

let memory: { ts: number; data: any[] } | null = null

export async function getActiveCities() {
  const now = Date.now()
  if (memory && now - memory.ts < TTL_MS) return { data: memory.data, error: null }

  try {
    const raw = sessionStorage.getItem(CACHE_KEY)
    if (raw) {
      const parsed = JSON.parse(raw)
      if (parsed && now - parsed.ts < TTL_MS && Array.isArray(parsed.data)) {
        memory = parsed
        return { data: parsed.data, error: null }
      }
    }
  } catch { /* sin storage */ }

  const { data, error } = await supabase.rpc('get_active_cities')
  if (!error && Array.isArray(data)) {
    memory = { ts: now, data: data }
    try { sessionStorage.setItem(CACHE_KEY, JSON.stringify(memory)) } catch { /* sin storage */ }
  }
  return { data: data || null, error }
}

export function clearActiveCitiesCache() {
  memory = null
  try { sessionStorage.removeItem(CACHE_KEY) } catch { /* sin storage */ }
}