/**
 * Compresión de imágenes en el navegador (sin dependencias externas).
 *
 * Objetivo: que una foto de perfil (3-5 MB desde la cámara del móvil)
 * se convierta en ~25-60 KB antes de subirla. Así:
 *  - no gastamos Storage ni egress de Supabase (las fotos van a ImgBB),
 *  - el conductor descarga unos pocos KB y no se ralentiza la app,
 *  - la subida en datos móviles es instantánea.
 *
 * Usa Canvas + createImageBitmap nativos (0 KB extra en el bundle).
 */

export interface CompressImageOptions {
  /** Lado mayor máximo en píxeles (por defecto 512, suficiente para un avatar) */
  maxDim?: number
  /** Calidad de compresión 0-1 (por defecto 0.82) */
  quality?: number
  /** Si el resultado supera este tamaño, se aplica un segundo pase más agresivo */
  maxBytes?: number
}

const DEFAULTS: Required<CompressImageOptions> = {
  maxDim: 512,
  quality: 0.82,
  maxBytes: 160 * 1024
}

interface DecodedImage {
  source: CanvasImageSource
  width: number
  height: number
  cleanup: () => void
}

/** Formatea bytes para mostrarlos al usuario (ej: "38 KB") */
export function formatKb(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  const kb = bytes / 1024
  if (kb < 1024) return `${Math.round(kb)} KB`
  return `${(kb / 1024).toFixed(1)} MB`
}

const IMAGE_LOAD_TIMEOUT_MS = 20000

/**
 * Lee los primeros bytes y deduce el formato REAL del archivo
 * (no confía en file.type, que en Android suele venir mal o vacío).
 */
async function detectFormat(file: File): Promise<string> {
  try {
    const head = new Uint8Array(await file.slice(0, 16).arrayBuffer())
    if (head.length === 0) return 'archivo vacío'

    const hex = (i: number) => head[i].toString(16).padStart(2, '0')
    const ascii = (from: number, to: number) =>
      String.fromCharCode(...Array.from(head.slice(from, to))).toLowerCase()

    if (hex(0) === 'ff' && hex(1) === 'd8' && hex(2) === 'ff') return 'JPEG'
    if (hex(0) === '89' && hex(1) === '50' && hex(2) === '4e' && hex(3) === '47') return 'PNG'
    if (ascii(0, 4) === 'riff' && ascii(8, 12) === 'webp') return 'WebP'

    if (head.length >= 12 && ascii(4, 8) === 'ftyp') {
      const brand = ascii(8, 12)
      if (brand.startsWith('avi')) return 'AVIF'
      if (['heic', 'heix', 'hevc', 'hevx', 'heim', 'heis', 'mif1', 'msf1'].includes(brand)) {
        return 'HEIC/HEIF'
      }
      return 'ISO-BMFF'
    }

    if (hex(0) === '25' && hex(1) === '50' && hex(2) === '44' && hex(3) === '46') return 'PDF'
    return 'formato desconocido'
  } catch {
    return 'desconocido'
  }
}

/** Carga un <img> con timeout (evita quedarse colgado con fotos enormes). */
function loadImage(src: string): Promise<HTMLImageElement> {
  return new Promise((resolve, reject) => {
    const el = new Image()
    let settled = false
    let timer: number | undefined

    const finish = (act: () => void) => {
      if (settled) return
      settled = true
      if (timer !== undefined) window.clearTimeout(timer)
      act()
    }

    timer = window.setTimeout(() => finish(() => reject(new Error('timeout'))), IMAGE_LOAD_TIMEOUT_MS)
    el.onload = () => finish(() => resolve(el))
    el.onerror = () => finish(() => reject(new Error('decode')))
    el.src = src
  })
}

/** Lee el archivo como data URL (evita bloqueos de blob: y fallos de archivos "en la nube"). */
function readAsDataUrl(file: File): Promise<string> {
  return new Promise((resolve, reject) => {
    const reader = new FileReader()
    reader.onload = () => resolve(String(reader.result || ''))
    reader.onerror = () => reject(new Error('read'))
    reader.readAsDataURL(file)
  })
}

async function decodeImage(file: File): Promise<DecodedImage> {
  // 1) Vía rápida: createImageBitmap respeta la orientación EXIF
  if (typeof createImageBitmap === 'function') {
    try {
      const bitmap = await createImageBitmap(file, { imageOrientation: 'from-image' })
      return {
        source: bitmap,
        width: bitmap.width,
        height: bitmap.height,
        cleanup: () => bitmap.close()
      }
    } catch {
      // Navegador antiguo, formato no soportado o falta de memoria: seguimos
    }

    // 2) Igual pero reduciendo al decodificar (fotos enormes con poca RAM)
    try {
      const bitmap = await createImageBitmap(file, { resizeWidth: 2048, resizeQuality: 'high' })
      return {
        source: bitmap,
        width: bitmap.width,
        height: bitmap.height,
        cleanup: () => bitmap.close()
      }
    } catch {
      // Seguimos con <img>
    }
  }

  // 3) Fallback: <img> con blob URL (los navegadores modernos ya aplican el EXIF)
  const objectUrl = URL.createObjectURL(file)
  try {
    const img = await loadImage(objectUrl)
    return {
      source: img,
      width: img.naturalWidth,
      height: img.naturalHeight,
      cleanup: () => URL.revokeObjectURL(objectUrl)
    }
  } catch {
    URL.revokeObjectURL(objectUrl)
  }

  // 4) Último recurso: <img> con data URL (esquiva restricciones de blob:)
  try {
    const dataUrl = await readAsDataUrl(file)
    const img = await loadImage(dataUrl)
    return {
      source: img,
      width: img.naturalWidth,
      height: img.naturalHeight,
      cleanup: () => { /* el data URL no reserva memoria */ }
    }
  } catch {
    // Sin más opciones: damos el diagnóstico real del archivo
  }

  const format = await detectFormat(file)
  const size = formatKb(file.size)
  throw new Error(
    `No pudimos abrir esta imagen (${format} · ${size}). ` +
    'Prueba con otra foto o tómala de nuevo con la cámara.'
  )
}

function toBlob(canvas: HTMLCanvasElement, type: string, quality: number): Promise<Blob | null> {
  return new Promise((resolve) => {
    canvas.toBlob((blob) => resolve(blob), type, quality)
  })
}

async function encode(
  source: CanvasImageSource,
  srcWidth: number,
  srcHeight: number,
  maxDim: number,
  quality: number
): Promise<Blob> {
  // Nunca ampliamos: si la foto es más pequeña se mantiene igual
  const scale = Math.min(1, maxDim / Math.max(srcWidth, srcHeight))
  const width = Math.max(1, Math.round(srcWidth * scale))
  const height = Math.max(1, Math.round(srcHeight * scale))

  const canvas = document.createElement('canvas')
  canvas.width = width
  canvas.height = height

  const ctx = canvas.getContext('2d')
  if (!ctx) throw new Error('Este dispositivo no puede procesar la imagen')
  ctx.drawImage(source, 0, 0, width, height)

  // WebP primero (mejor compresión); si el navegador no lo soporta, JPEG.
  const webp = await toBlob(canvas, 'image/webp', quality)
  if (webp && webp.type === 'image/webp') return webp

  const jpeg = await toBlob(canvas, 'image/jpeg', quality)
  if (jpeg) return jpeg

  throw new Error('No pudimos comprimir la imagen')
}

/**
 * Comprime y redimensiona una imagen lista para subirla.
 * Devuelve un File nuevo (WebP o JPEG) del tamaño indicado.
 */
export async function compressImage(file: File, options: CompressImageOptions = {}): Promise<File> {
  const { maxDim, quality, maxBytes } = { ...DEFAULTS, ...options }

  if (!file.type.startsWith('image/')) {
    throw new Error('El archivo seleccionado no es una imagen')
  }

  const decoded = await decodeImage(file)

  try {
    let blob = await encode(decoded.source, decoded.width, decoded.height, maxDim, quality)

    // Segundo pase si aún es grande (fotos muy detalladas)
    if (blob.size > maxBytes) {
      const smaller = await encode(
        decoded.source,
        decoded.width,
        decoded.height,
        Math.round(maxDim * 0.75),
        Math.max(0.6, quality - 0.12)
      )
      if (smaller.size < blob.size) blob = smaller
    }

    const baseName = (file.name || 'foto').replace(/\.[^.]+$/, '') || 'foto'
    const ext = blob.type === 'image/webp' ? 'webp' : 'jpg'

    return new File([blob], `${baseName}.${ext}`, {
      type: blob.type,
      lastModified: Date.now()
    })
  } finally {
    decoded.cleanup()
  }
}
