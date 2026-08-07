// ============================================================
// RIDERFLASSHI - Helper de tiempo real OPTIMIZADO PARA COSTO
// Realtime (postgres_changes) es la FUENTE PRINCIPAL.
// El polling (60s) solo actúa como respaldo si Realtime se
// desconecta → hasta 10x menos requests/hora por usuario.
// ============================================================
import { supabase } from '@/lib/supabase'
import { useCallback, useEffect, useRef, useState } from 'react'
import type { RideIncident } from '@/types/database'

const POLL_MS = 60000 // 60s — SOLO respaldo si Realtime se desconecta (antes 6s = 10x menos requests)

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
    let realtimeOk = false
    let pollTimer: number | null = null
    let isPolling = false

    const stopPolling = () => {
      if (pollTimer !== null) {
        window.clearInterval(pollTimer)
        pollTimer = null
      }
    }

    const pollOnce = async () => {
      if (isPolling || !mounted) return
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
    }

    const startPolling = () => {
      if (pollTimer !== null) return
      // Poll inmediato al detectar desconexión + respaldo periódico
      pollOnce()
      pollTimer = window.setInterval(pollOnce, POLL_MS)
    }

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
      .subscribe((status) => {
        // 💰 COSTO: el polling SOLO se activa si Realtime no está conectado
        realtimeOk = status === 'SUBSCRIBED'
        if (realtimeOk) stopPolling()
        else startPolling()
      })

    return () => {
      mounted = false
      stopPolling()
      supabase.removeChannel(channel)
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

    let mounted = true
    let pollTimer: number | null = null
    let isPolling = false

    // 💰 COSTO: FUENTE PRINCIPAL = Realtime (nuevo viaje 'buscando' llega
    // al instante, RLS lo filtra por categoría del conductor). Esto
    // reemplaza el polling de 6s → cientos de requests/hora ahorrados.
    const channel = supabase
      .channel('driver-available-rides')
      .on(
        'postgres_changes',
        {
          event: 'INSERT',
          schema: 'public',
          table: 'rides',
          filter: 'status=eq.buscando'
        },
        () => {
          if (mounted) loadRidesRef.current()
        }
      )
      .subscribe()

    // RESPALDO barato: cada 60s (antes 6s → 10x menos requests/hora)
    const pollOnce = async () => {
      if (isPolling || !mounted) return
      isPolling = true
      try {
        await loadRidesRef.current()
      } catch (_) {
        // Silencioso
      } finally {
        isPolling = false
      }
    }
    pollTimer = window.setInterval(pollOnce, POLL_MS)

    return () => {
      mounted = false
      if (pollTimer !== null) window.clearInterval(pollTimer)
      supabase.removeChannel(channel)
    }
  }, [isOnline])
}

/**
 * Cargar y mantener al día el incidente/disputa de un viaje.
 * - Carga inicial al montar o cuando cambia el incident_id
 * - Se suscribe a cambios en ride_incidents del viaje para reflejar
 *   en vivo la resolución del administrador
 */
export function useRideIncident(
  rideId: string | undefined,
  incidentId: string | undefined
): RideIncident | null {
  const [incident, setIncident] = useState<RideIncident | null>(null)

  useEffect(() => {
    if (!rideId || !incidentId) {
      setIncident(null)
      return
    }

    let mounted = true

    const load = async () => {
      const { data, error } = await supabase
        .from('ride_incidents')
        .select('*')
        .eq('id', incidentId)
        .single()
      if (mounted && !error && data) {
        setIncident(data as RideIncident)
      }
    }

    load()

    // Realtime: reflejar al instante cuando el admin resuelva el reporte
    const channel = supabase
      .channel(`incident-rt-${rideId}`)
      .on(
        'postgres_changes',
        {
          event: '*',
          schema: 'public',
          table: 'ride_incidents',
          filter: `ride_id=eq.${rideId}`
        },
        () => load()
      )
      .subscribe()

    return () => {
      mounted = false
      supabase.removeChannel(channel)
    }
  }, [rideId, incidentId])

  return incident
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