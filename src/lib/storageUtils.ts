import { supabase } from '@/lib/supabase'

/**
 * Obtiene una URL firmada temporal para un archivo de storage.
 * Necesario porque el bucket `payments` es privado (los comprobantes
 * no deben ser visibles públicamente).
 *
 * @param bucket - Nombre del bucket
 * @param path - Ruta del archivo (ej. 'userId/payments/123.jpg')
 * @param expiresIn - Segundos de validez (default 1 hora)
 */
export async function getSignedUrl(
  bucket: string,
  path: string,
  expiresIn = 3600
): Promise<string | null> {
  try {
    // Extraer solo el pathname si viene una URL completa
    const cleanPath = path.split('?')[0]

    // Intentar extraer path relativo si es storage URL completa
    let filePath = cleanPath
    const matches = cleanPath.match(/\/storage\/v1\/object\/public\/([^/]+\/.+)/)
    if (matches) {
      filePath = matches[1]
    } else {
      const privateMatches = cleanPath.match(/\/storage\/v1\/object\/authenticated\/([^/]+\/.+)/)
      if (privateMatches) {
        filePath = privateMatches[1]
      }
    }

    // Si no es una ruta de storage, devolver como está (ej. URL de ImgBB)
    if (!filePath.includes('/')) {
      return cleanPath
    }

    const { data, error } = await supabase.storage
      .from(bucket)
      .createSignedUrl(filePath, expiresIn)

    if (error || !data?.signedUrl) {
      console.error('Error generando URL firmada:', error)
      return null
    }

    return data.signedUrl
  } catch (err) {
    console.error('Error en getSignedUrl:', err)
    return null
  }
}

/**
 * Determina si una URL es una URL de storage de Supabase
 * o una URL externa (ImgBB, etc.)
 */
export function isSupabaseStorageUrl(url: string): boolean {
  return url.includes('/storage/v1/object/')
}

/**
 * Resuelve una URL de comprobante: si es de storage, genera URL firmada;
 * si es externa (ImgBB), la devuelve tal cual;
 * si es una ruta simple (ej. 'userId/proofs/file.jpg'), genera URL firmada
 * del bucket payments.
 */
export async function resolveProofUrl(
  url: string | null | undefined,
  bucket = 'payments'
): Promise<string | null> {
  if (!url) return null

  // Si ya es una URL firmada (tiene token), devolverla
  if (url.includes('token=') || url.includes('&token=')) {
    return url
  }

  // Es URL externa (ImgBB, cloudinary, etc.)
  if (/^https?:\/\//.test(url) && !isSupabaseStorageUrl(url)) {
    return url
  }

  // Extraer bucket y path de URLs de storage
  const publicMatch = url.match(/\/storage\/v1\/object\/public\/([^/]+)\/(.+)/)
  if (publicMatch) {
    return getSignedUrl(publicMatch[1], publicMatch[2])
  }

  const authMatch = url.match(/\/storage\/v1\/object\/authenticated\/([^/]+)\/(.+)/)
  if (authMatch) {
    return getSignedUrl(authMatch[1], authMatch[2])
  }

  // Ruta simple sin esquema → tratar como archivo del bucket payments
  if (!/^https?:\/\//.test(url)) {
    // Quitar prefijo con barra inicial si existe
    const cleanPath = url.replace(/^\//, '')
    if (cleanPath.includes('/')) {
      return getSignedUrl(bucket, cleanPath)
    }
  }

  return null
}
