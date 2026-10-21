export interface LatLng {
  lat: number
  lng: number
}

export interface BarrioReference {
  id: string
  name: string
  lat?: number | null
  lng?: number | null
}

/**
 * Distancia en metros entre dos puntos (Haversine).
 * Se ejecuta en el navegador: no consume Supabase ni servicios externos.
 */
export function distanceMeters(a: LatLng, b: LatLng): number {
  const R = 6_371_000
  const toRad = (value: number) => (value * Math.PI) / 180
  const dLat = toRad(b.lat - a.lat)
  const dLng = toRad(b.lng - a.lng)
  const lat1 = toRad(a.lat)
  const lat2 = toRad(b.lat)

  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2

  return 2 * R * Math.asin(Math.min(1, Math.sqrt(h)))
}

/**
 * Barrio de referencia más cercano a un punto, usando la lista ya cargada
 * en el cliente. Misma lógica práctica que calculate_fare en el backend
 * (barrio activo más cercano dentro de la ciudad), sin RPC adicional.
 */
export function nearestBarrio<T extends BarrioReference>(
  point: LatLng,
  barrios: T[]
): { barrio: T; distanceMeters: number } | null {
  let best: { barrio: T; distanceMeters: number } | null = null

  for (const barrio of barrios) {
    if (barrio.lat == null || barrio.lng == null) continue

    const distance = distanceMeters(point, {
      lat: Number(barrio.lat),
      lng: Number(barrio.lng)
    })

    if (!best || distance < best.distanceMeters) {
      best = { barrio, distanceMeters: distance }
    }
  }

  return best
}
