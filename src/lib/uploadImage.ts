import { supabase } from '@/lib/supabase'
import { compressImage, formatKb } from '@/lib/imageCompress'
import { uploadToImgBB } from '@/lib/imgbb'

/**
 * Subida de imágenes optimizada (bajo costo).
 *
 * Todas las imágenes de la app pasan por aquí: se COMPRIMEN en el
 * teléfono antes de salir y se suben con caché de 1 año.
 *
 * Beneficio directo:
 *  - Storage y egress de Supabase: una foto de 4 MB pasa a ~200 KB.
 *  - Datos móviles del usuario: la subida deja de ser lenta.
 *  - La app se mantiene rápida al mostrar fotos en listas.
 *
 * Sin dependencias externas: usa Canvas nativo (ver imageCompress.ts).
 */

export type ImagePreset = 'avatar' | 'vehicle' | 'banner' | 'proof' | 'document' | 'incident'

interface PresetConfig {
  maxDim: number
  quality: number
  maxBytes: number
}

export const IMAGE_PRESETS: Record<ImagePreset, PresetConfig> = {
  /** Foto de perfil (se muestra a 48-64 px): 512 px sobra */
  avatar: { maxDim: 512, quality: 0.82, maxBytes: 160 * 1024 },
  /** Foto del vehículo (se ve en tarjeta + detalle) */
  vehicle: { maxDim: 1024, quality: 0.8, maxBytes: 320 * 1024 },
  /** Banner del inicio: lo descarga CADA cliente, por eso 1280 px */
  banner: { maxDim: 1280, quality: 0.82, maxBytes: 320 * 1024 },
  /** Comprobante de pago/recarga: debe verse el monto y la referencia */
  proof: { maxDim: 1280, quality: 0.78, maxBytes: 420 * 1024 },
  /** Cédula / licencia del conductor: igual, debe ser legible */
  document: { maxDim: 1280, quality: 0.8, maxBytes: 420 * 1024 },
  /** Foto de incidencia reportada durante el viaje */
  incident: { maxDim: 1280, quality: 0.78, maxBytes: 420 * 1024 }
}

/** Ajusta la extensión del archivo al formato real comprimido (webp/jpg) */
function withRealExtension(path: string, mime: string): string {
  const ext = mime === 'image/webp' ? 'webp' : 'jpg'
  return path.replace(/\.[A-Za-z0-9]+$/, '') + '.' + ext
}

/** Comprime la imagen según el preset (nunca sube el original completo) */
export async function prepareImage(file: File, preset: ImagePreset): Promise<File> {
  return compressImage(file, IMAGE_PRESETS[preset])
}

/**
 * Comprime y sube a Supabase Storage.
 * Devuelve la RUTA interna del archivo (para buckets privados) o su URL.
 *
 * @param bucket   nombre del bucket (payments, documents, vehicles, avatars...)
 * @param path     ruta destino; la extensión se ajusta al formato comprimido
 * @param file     archivo original elegido por el usuario
 * @param preset   preset de compresión según el uso de la imagen
 */
export async function uploadImageToStorage(
  bucket: string,
  path: string,
  file: File,
  preset: ImagePreset
): Promise<{ path: string; size: number; originalSize: number }> {
  const optimizada = await prepareImage(file, preset)
  const destino = withRealExtension(path, optimizada.type)

  const { data, error } = await supabase.storage.from(bucket).upload(destino, optimizada, {
    upsert: true,
    contentType: optimizada.type,
    // El archivo nunca cambia de contenido en esa ruta → caché de 1 año
    // (evita volver a descargarlo desde Supabase: menos egress)
    cacheControl: '31536000'
  })

  if (error) throw error

  return { path: data.path, size: optimizada.size, originalSize: file.size }
}

/**
 * Comprime y sube a ImgBB (host externo GRATIS).
 * Para imágenes que no son privadas: foto de perfil del cliente,
 * foto del vehículo y banners. Así no consumen Storage ni egress
 * de Supabase.
 */
export async function uploadImageToExternalHost(
  file: File,
  preset: ImagePreset
): Promise<{ url: string; size: number; originalSize: number }> {
  const optimizada = await prepareImage(file, preset)
  const url = await uploadToImgBB(optimizada)
  return { url, size: optimizada.size, originalSize: file.size }
}

/** Texto corto para mostrar el ahorro logrado: "3.4 MB → 180 KB" */
export function describeSaving(originalSize: number, finalSize: number): string {
  return `${formatKb(originalSize)} → ${formatKb(finalSize)}`
}
