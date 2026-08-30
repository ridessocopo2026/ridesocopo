import { supabase } from '@/lib/supabase'

/**
 * Resuelve una URL de foto: acepta una URL completa (http/https),
 * una ruta relativa o una ruta de storage, y devuelve la URL pública
 * correcta del bucket (vehicles/avatars son públicos).
 */
export function resolvePhotoUrl(
  url: string | null | undefined,
  bucket = 'vehicles'
): string | undefined {
  if (!url) return undefined
  if (/^https?:\/\//i.test(url)) return url
  if (url.startsWith('/')) return url
  if (url.startsWith('data:') || url.startsWith('blob:')) return url
  const { data } = supabase.storage.from(bucket).getPublicUrl(url)
  return data.publicUrl
}
