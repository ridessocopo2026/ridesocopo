/**
 * Ruteo por carretera con OSRM (Open Source Routing Machine).
 *
 * Usamos el servidor publico de demostracion de OSRM:
 *   https://project-osrm.org
 * Es GRATIS y NO requiere API key -> sin costos extra.
 *
 * Nota: el servidor demo es para uso ligero. Si el volumen crece mucho se
 * puede auto-hospedar OSRM y solo cambiar OSRM_BASE (misma API).
 */

const OSRM_BASE = 'https://router.project-osrm.org'

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

/**
 * Devuelve la geometria de la ruta en carretera de `from` a `to` como lista
 * de puntos [lat, lng], o `null` si falla (sin red, limite, etc.).
 */
export async function fetchRoute(from: LatLng, to: LatLng): Promise<LatLng[] | null> {
  // OSRM usa orden lng,lat y overview=full para devolver toda la geometria.
  const url =
    `${OSRM_BASE}/route/v1/driving/${from[1]},${from[0]};${to[1]},${to[0]}` +
    `?overview=full&geometries=geojson&alternatives=false&steps=false`

  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), 8000)

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