/**
 * Lectura unica de la ubicación actual (sin watchers ni polling).
 * Se usa cuando el cliente guarda un destino y queremos el punto EXACTO
 * donde esta en ese momento (no el centroide del sector del viaje).
 */
export interface GeoFix {
  lat: number
  lng: number
  /** Precisión reportada por el GPS, en metros */
  accuracy: number
}

/** 6 decimales (~11 cm): suficiente para un punto y más liviano */
const FACTOR = 1_000_000

function roundCoord(value: number): number {
  return Math.round(value * FACTOR) / FACTOR
}

export function getCurrentPositionOnce(timeoutMs = 12000): Promise<GeoFix> {
  return new Promise((resolve, reject) => {
    if (typeof navigator === 'undefined' || !navigator.geolocation) {
      reject(new Error('Este dispositivo no permite obtener la ubicación'))
      return
    }

    navigator.geolocation.getCurrentPosition(
      (pos) => {
        resolve({
          lat: roundCoord(pos.coords.latitude),
          lng: roundCoord(pos.coords.longitude),
          accuracy: Math.max(0, Math.round(pos.coords.accuracy || 0))
        })
      },
      (err) => {
        if (err.code === err.PERMISSION_DENIED) {
          reject(new Error('Permiso de ubicación denegado. Actívalo para usar tu punto exacto.'))
        } else if (err.code === err.POSITION_UNAVAILABLE) {
          reject(new Error('No hay señal de GPS en este momento'))
        } else {
          reject(new Error('No pudimos obtener tu ubicación a tiempo'))
        }
      },
      { enableHighAccuracy: true, timeout: timeoutMs, maximumAge: 0 }
    )
  })
}
