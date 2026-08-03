// ============================================================
// RIDESOCOPÓ - Helper de tiempo real optimizado
// Usa Realtime (postgres_changes) como fuente principal, con
// polling ligero como respaldo barato (6s).
// ============================================================
import { supabase } from '@/lib/supabase'
import { useCallback, useEffect, useRef } from 'react'

const POLL_MS = 6000 // 6 segundos — muy bajo costo (600 req/h ora/usuario)

/**
 * Suscribirse a cambios de un ride específico con fallback polling.
 * @param rideId - ID del ride a observar
 * @param onRideUpdate - Callback con el ride actualizado
 * @param getFreshRide - Función para obtener el ride fresco (para polling)
 */
export function useRideRealtime(
  rideId: string | undefined,
  onRideUpdate: (ride: any) => void,
  getFreshRide: () => Promise<any>
) {
  const onRideUpdateRef = useRef(onRideUpdate)
  const getFreshRideRef = useRef(getFreshRide)
  onRideUpdateRef.current = onRideUpdate
  getFreshRideRef.current = getFreshRide

  useEffect(() => {
    if (!rideId) return

    let mounted = true

    // --- FUENTE PRINCIPAL: Realtime (postgres_changes) ---
    const channel = supabase
      .channel(`ride-realtime-${rideId}`)
      .on(
        'postgres_changes',
        {
          event: 'UPDATE',
          schema: 'public',
          table: 'rides',
          filter: `id=eq.${rideId}`
        },
        (payload) => {
          if (mounted) {
            onRideUpdateRef.current(payload.new)
          }
        }
      )
      .subscribe()

    // --- RESPALDO: Polling ligero cada 6s ---
    // Si Realtime falla o se desconecta, el poll asegura que no se
    // pierdan cambios. Costo: ~600 req/h ora por usuario activo.
    let isPolling = false
    const interval = window.setInterval(async () => {
      if (isPolling) return
      isPolling = true
      try {
        const fresh = await getFreshRideRef.current()
        if (mounted && fresh) {
          onRideUpdateRef.current(fresh)
        }
      } catch (_) {
        // Silencioso en error de red
      } finally {
        isPolling = false
      }
    }, POLL_MS)

    return () => {
      mounted = false
      supabase.removeChannel(channel)
      window.clearInterval(interval)
    }
  }, [rideId])
}

/**
 * Hook para refrescar una lista de viajes disponibles con polling.
 */
export function useAvailableRidesPolling(
  isOnline: boolean,
  loadRides: () => Promise<void>
) {
  const loadRidesRef = useRef(loadRides)
  loadRidesRef.current = loadRides

  useEffect(() => {
    if (!isOnline) return

    let isPolling = false
    const interval = window.setInterval(async () => {
      if (isPolling) return
      isPolling = true
      try {
        await loadRidesRef.current()
      } catch (_) {
        // Silencioso
      } finally {
        isPolling = false
      }
    }, POLL_MS)

    return () => window.clearInterval(interval)
  }, [isOnline])
}

/**
 * Cargar viaje fresco desde DB (para polling).
 */
export const fetchRideById = async (rideId: string) => {
  const { data, error } = await supabase
    .from('rides')
    .select('*')
    .eq('id', rideId)
    .single()
  if (error) return null
  return data
}