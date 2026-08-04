import { supabase } from '@/lib/supabase'

interface UploadResponse {
  ok?: boolean
  url?: string
  display_url?: string
  error?: string
}

/**
 * Sube una imagen a ImgBB via la Edge Function `upload-image`.
 * La API key de ImgBB NUNCA viaja al navegador — vive solo en el servidor.
 */
export async function uploadToImgBB(file: File): Promise<string> {
  const {
    data: { session },
  } = await supabase.auth.getSession()

  if (!session?.access_token) {
    throw new Error('Debes iniciar sesión para subir imágenes')
  }

  const formData = new FormData()
  formData.append('image', file)

  const response = await fetch(
    `${import.meta.env.VITE_SUPABASE_URL}/functions/v1/upload-image`,
    {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${session.access_token}`,
      },
      body: formData,
    }
  )

  const data: UploadResponse = await response.json()

  if (!response.ok || !data.ok || !data.url) {
    throw new Error(data.error || 'Error al subir imagen. Intenta de nuevo.')
  }

  return data.url
}