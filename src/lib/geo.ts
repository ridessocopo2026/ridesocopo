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

function pointInRing(lat: number, lng: number, ring: number[][]): boolean {
  if (!ring || ring.length < 3) return false
  let inside = false
  for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
    const [xi, yi] = ring[i]
    const [xj, yj] = ring[j]
    const intersects =
      (yi > lat) !== (yj > lat) &&
      lng < ((xj - xi) * (lat - yi)) / (yj - yi) + xi
    if (intersects) inside = !inside
  }
  return inside
}

function pointInRings(lat: number, lng: number, rings: number[][][]): boolean {
  if (!rings?.length) return false
  if (!pointInRing(lat, lng, rings[0])) return false
  for (let i = 1; i < rings.length; i++) {
    if (pointInRing(lat, lng, rings[i])) return false
  }
  return true
}

/**
 * Comprueba si un punto está dentro de un polígono GeoJSON.
 * Se ejecuta localmente (sin consumir Supabase).
 */
export function isPointInGeoJson(lat: number, lng: number, geojson: any): boolean {
  if (!geojson) return false
  let geometry = geojson
  if (typeof geojson === 'string') {
    try { geometry = JSON.parse(geojson) } catch { return false }
  }
  if (geometry?.type === 'Feature') geometry = geometry.geometry
  if (!geometry) return false
  if (geometry.type === 'Polygon') return pointInRings(lat, lng, geometry.coordinates)
  if (geometry.type === 'MultiPolygon') {
    const polys = geometry.coordinates as number[][][][] | undefined
    return polys ? polys.some((poly) => pointInRings(lat, lng, poly)) : false
  }
  return false
}

/**
 * Convierte el GeoJSON de cobertura a anillos [lat, lng] para Leaflet.
 * Devuelve un anillo por polígono (las zonas actuales no tienen huecos).
 */
export function geoJsonToLeafletRings(geojson: any): [number, number][][] {
  if (!geojson) return []
  let geometry = geojson
  if (typeof geojson === 'string') {
    try { geometry = JSON.parse(geojson) } catch { return [] }
  }
  if (geometry?.type === 'Feature') geometry = geometry.geometry
  if (!geometry) return []
  const toRing = (ring: number[][]) => ring.map(([lng, lat]) => [lat, lng] as [number, number])
  if (geometry.type === 'Polygon') {
    const outer = (geometry.coordinates as number[][][] | undefined)?.[0]
    return outer ? [toRing(outer)] : []
  }
  if (geometry.type === 'MultiPolygon') {
    const polys = geometry.coordinates as number[][][][] | undefined
    return polys ? polys.flatMap((poly) => (poly[0] ? [toRing(poly[0])] : [])) : []
  }
  return []
}
