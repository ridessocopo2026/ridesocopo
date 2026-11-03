/**
 * Ruteo por carretera con OSRM (Open Source Routing Machine).
 *
 * Usamos servidores publicos OSRM:
 *   https://project-osrm.org  (principal)
 *   https://routing.openstreetmap.de  (respaldo, misma API)
 * Son GRATIS y NO requieren API key -> sin costos extra.
 *
 * Nota: el servidor demo es para uso ligero. Si el volumen crece mucho se
 * puede auto-hospedar OSRM y solo cambiar la lista OSRM_BASES.
 */

const OSRM_BASES = [
  'https://router.project-osrm.org',
  'https://routing.openstreetmap.de/routed-car'
] as const

export type LatLng = [number, number]

/**
 * Distancia aproximada en metros entre dos puntos [lat, lng] (formula haversine).
 * Se usa para no volver a pedir la ruta si el vehiculo apenas se movio.
 */
export function distanceMeters(a: LatLng, b: LatLng): number {
  const R = 6371000
  const dLat = ((b[0] - a[0]) * Math.PI) / 180
  const dLng = ((b[1] - a[1]) * Math.PI) / 180
  const lat1 = (a[0] * Math.PI) / 180
  const lat2 = (b[0] * Math.PI) / 180
  const h =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(lat1) * Math.cos(lat2) * Math.sin(dLng / 2) ** 2
  return 2 * R * Math.asin(Math.sqrt(h))
}

/** Peticion a UN servidor OSRM. Devuelve null si falla o expira. */
async function fetchRouteFrom(
  base: string,
  from: LatLng,
  to: LatLng
): Promise<LatLng[] | null> {
  // OSRM usa orden lng,lat y overview=full para devolver toda la geometria.
  const url =
    `${base}/route/v1/driving/${from[1]},${from[0]};${to[1]},${to[0]}` +
    `?overview=full&geometries=geojson&alternatives=false&steps=false`

  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), 7000)

  try {
    const res = await fetch(url, { signal: controller.signal, headers: { Accept: 'application/json' } })
    if (!res.ok) return null
    const data = await res.json()
    const coords: [number, number][] | undefined = data?.routes?.[0]?.geometry?.coordinates
    if (!Array.isArray(coords) || coords.length < 2) return null
    // OSRM devuelve [lng, lat] -> lo convertimos a [lat, lng] para Leaflet.
    return coords.map(([lng, lat]) => [lat, lng] as LatLng)
  } catch {
    return null
  } finally {
    clearTimeout(timeout)
  }
}

/**
 * Devuelve la geometria de la ruta en carretera de `from` a `to` como lista
 * de puntos [lat, lng], o `null` si falla (sin red, limite, etc.).
 * Si el servidor principal falla se intenta el de respaldo.
 */
export async function fetchRoute(from: LatLng, to: LatLng): Promise<LatLng[] | null> {
  for (const base of OSRM_BASES) {
    const pts = await fetchRouteFrom(base, from, to)
    if (pts) return pts
  }
  return null
}
