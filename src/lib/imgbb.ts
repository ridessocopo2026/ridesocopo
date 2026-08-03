const IMGBB_API_KEY = import.meta.env.VITE_IMGBB_API_KEY

interface ImgBBResponse {
  data?: {
    url?: string
    display_url?: string
    delete_url?: string
  }
  success?: boolean
  error?: {
    message?: string
  }
}

export async function uploadToImgBB(file: File): Promise<string> {
  if (!IMGBB_API_KEY) {
    throw new Error('Falta la API key de ImgBB en .env.local (VITE_IMGBB_API_KEY)')
  }

  const formData = new FormData()
  formData.append('image', file)
  formData.append('key', IMGBB_API_KEY)

  const response = await fetch('https://api.imgbb.com/1/upload', {
    method: 'POST',
    body: formData
  })

  const data: ImgBBResponse = await response.json()

  if (!data.success || !data.data?.url) {
    throw new Error(data.error?.message || 'Error al subir imagen a ImgBB')
  }

  return data.data.url
}