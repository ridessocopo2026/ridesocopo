import { useState, useEffect, useRef } from 'react'
import { useNavigate } from 'react-router-dom'
import { User, LogOut, Star, MapPin, ChevronRight, MessageCircle, Car, Loader2, Camera, Trash2 } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { whatsappNumber } from '@/lib/format'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { HexUnderline } from '@/components/ui/HexUnderline'
import { AppLogo } from '@/components/ui/AppLogo'
import { resolvePhotoUrl } from '@/lib/photos'
import { uploadImageToExternalHost, describeSaving } from '@/lib/uploadImage'

export function ClientProfile() {
  const { user, signOut, refreshProfile } = useAuth()
  const navigate = useNavigate()
  const [showFavorites, setShowFavorites] = useState(false)
  const [favorites, setFavorites] = useState<any[]>([])
  const [supportPhone, setSupportPhone] = useState('')
  const [driverLoading, setDriverLoading] = useState(false)
  const [driverError, setDriverError] = useState('')

  useEffect(() => {
    supabase.rpc('get_my_support').then((res: any) => {
      if (res.data && res.data.phone) setSupportPhone(res.data.phone)
    })
  }, [])

  const loadFavorites = async () => {
    if (!user) return
    const { data, error } = await supabase
      .from('favorite_places')
      .select('*')
      .eq('user_id', user.id)
      .order('created_at', { ascending: false })

    if (!error && data) {
      setFavorites(data)
      setShowFavorites(!showFavorites)
    }
  }

  // ── Foto de perfil (opcional) ──────────────────────────────
  const fileInputRef = useRef<HTMLInputElement>(null)
  const [avatarUrl, setAvatarUrl] = useState<string | null>(null)
  const [photoBusy, setPhotoBusy] = useState(false)
  const [photoError, setPhotoError] = useState('')
  const [photoMsg, setPhotoMsg] = useState('')

  // Mantener la vista sincronizada con el perfil cargado
  useEffect(() => {
    setAvatarUrl(user?.avatar_url || null)
  }, [user?.avatar_url])

  const photo = resolvePhotoUrl(avatarUrl, 'avatars')

  const handlePhotoSelected = async (e: React.ChangeEvent<HTMLInputElement>) => {
    const file = e.target.files?.[0]
    e.target.value = '' // permite volver a elegir la misma imagen
    if (!file) return

    setPhotoError('')
    setPhotoMsg('')
    setPhotoBusy(true)

    try {
      // 1) Comprimir en el teléfono y subir a ImgBB (gratis, sin Storage
      //    ni egress de Supabase): una foto de 4 MB baja a ~30 KB
      const { url, size, originalSize } = await uploadImageToExternalHost(file, 'avatar')
      // 2) Guardar en el perfil (RPC: la RLS bloquea el UPDATE directo)
      const { error } = await supabase.rpc('set_my_avatar', { p_url: url })
      if (error) throw error

      setAvatarUrl(url)
      setPhotoMsg(`Foto guardada · ${describeSaving(originalSize, size)}`)
      await refreshProfile()
    } catch (err: any) {
      setPhotoError(err?.message || 'No pudimos guardar tu foto. Intenta de nuevo.')
    } finally {
      setPhotoBusy(false)
    }
  }

  const handleRemovePhoto = async () => {
    if (!window.confirm('¿Quitar tu foto de perfil?')) return

    setPhotoError('')
    setPhotoMsg('')
    setPhotoBusy(true)

    try {
      const { error } = await supabase.rpc('set_my_avatar', { p_url: null })
      if (error) throw error
      setAvatarUrl(null)
      setPhotoMsg('Foto eliminada')
    } catch (err: any) {
      setPhotoError(err?.message || 'No pudimos quitar tu foto')
    } finally {
      setPhotoBusy(false)
    }
  }

  const handleBecomeDriver = async () => {
    if (!window.confirm(
      '¿Quieres solicitar ser conductor? Tu cuenta quedará pendiente de aprobación y podrás completar tus datos de conductor.'
    )) return

    setDriverError('')
    setDriverLoading(true)
    try {
      const { error } = await supabase.rpc('become_driver')
      if (error) throw error
      await refreshProfile()
      navigate('/conductor/onboarding')
    } catch (err: any) {
      setDriverError(err.message)
    } finally {
      setDriverLoading(false)
    }
  }

  const handleSignOut = async () => {
    await signOut()
    navigate('/login')
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-primary-600 border-b border-primary-700 px-6 py-4">
        <div className="flex items-center gap-3">
          <AppLogo variant="dark" />
          <div>
            <h1 className="text-lg font-bold text-white">Mi Perfil</h1>
            <p className="text-xs text-white/80">Información personal</p>
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6 space-y-4">
        {/* Perfil */}
        <div className="card">
          <div className="flex items-center gap-4">
            <div className="relative flex-shrink-0">
              <div className="w-16 h-16 bg-primary-50 rounded-full flex items-center justify-center overflow-hidden">
                {photo ? (
                  <img
                    src={photo}
                    alt="Tu foto de perfil"
                    loading="lazy"
                    decoding="async"
                    width={64}
                    height={64}
                    className="w-full h-full object-cover"
                  />
                ) : (
                  <User className="w-8 h-8 text-primary-600" />
                )}
              </div>
              <button
                type="button"
                onClick={() => fileInputRef.current?.click()}
                disabled={photoBusy}
                title={photo ? 'Cambiar foto' : 'Agregar foto'}
                className="absolute -bottom-1 -right-1 w-7 h-7 rounded-full bg-primary-600 text-white flex items-center justify-center shadow-card hover:bg-primary-700 transition-colors disabled:opacity-60"
              >
                {photoBusy ? <Loader2 className="w-3.5 h-3.5 animate-spin" /> : <Camera className="w-3.5 h-3.5" />}
              </button>
            </div>

            <div className="flex-1 min-w-0">
              <h2 className="font-semibold text-surface-800 truncate">{user?.full_name}</h2>
              <p className="text-sm text-surface-500 truncate">{user?.email}</p>
              <span className="badge-primary mt-1">Cliente</span>
            </div>
          </div>

          <input
            ref={fileInputRef}
            type="file"
            accept="image/*"
            className="hidden"
            onChange={handlePhotoSelected}
          />

          <div className="mt-3 flex items-center gap-2">
            <button
              type="button"
              onClick={() => fileInputRef.current?.click()}
              disabled={photoBusy}
              className="btn-outline flex-1 text-sm"
            >
              {photoBusy ? <Loader2 className="w-4 h-4 animate-spin" /> : <Camera className="w-4 h-4" />}
              {photo ? 'Cambiar foto' : 'Agregar foto'}
            </button>
            {photo && (
              <button
                type="button"
                onClick={handleRemovePhoto}
                disabled={photoBusy}
                className="btn-outline text-sm text-red-600 border-red-200 hover:border-red-300"
              >
                <Trash2 className="w-4 h-4" />
                Quitar
              </button>
            )}
          </div>

          <p className="text-[11px] text-surface-400 mt-2">
            Opcional. Solo la verá el conductor de tu viaje, después de aceptarlo. La foto se optimiza
            automáticamente para no gastar tus datos.
          </p>

          {photoError && (
            <div className="mt-2">
              <ErrorMessage message={photoError} onDismiss={() => setPhotoError('')} />
            </div>
          )}
          {photoMsg && <p className="text-xs text-emerald-600 mt-2">{photoMsg}</p>}
        </div>

        {/* Solicitar ser conductor (solo pasajeros) */}
        {user?.role === 'cliente' && (
          <div className="card p-4">
            <div className="flex items-center gap-3 mb-3">
              <div className="w-10 h-10 bg-accent-50 rounded-full flex items-center justify-center">
                <Car className="w-5 h-5 text-accent-600" />
              </div>
              <div>
                <p className="font-medium text-surface-700">¿Quieres ser conductor?</p>
                <p className="text-xs text-surface-400">Ofrece viajes y gana dinero en tu ciudad</p>
              </div>
            </div>
            {driverError && <ErrorMessage message={driverError} onDismiss={() => setDriverError('')} />}
            <button
              onClick={handleBecomeDriver}
              className="btn-outline w-full text-accent-600 border-accent-200 hover:border-accent-300"
              disabled={driverLoading}
            >
              {driverLoading ? (
                <Loader2 className="w-4 h-4 animate-spin" />
              ) : (
                <><Car className="w-4 h-4" /> Quiero ser conductor</>
              )}
            </button>
          </div>
        )}

        {/* Lugares guardados */}
        <div className="card">
          <button
            onClick={loadFavorites}
            className="w-full flex items-center justify-between"
          >
            <div className="flex items-center gap-3">
              <div className="w-10 h-10 bg-amber-50 rounded-full flex items-center justify-center">
                <Star className="w-5 h-5 text-amber-500" />
              </div>
              <div className="text-left">
                <p className="font-medium text-surface-700">Lugares guardados</p>
                <p className="text-xs text-surface-400">Tus direcciones favoritas</p>
              </div>
            </div>
            <ChevronRight className="w-5 h-5 text-surface-400" />
          </button>

          {showFavorites && (
            <div className="mt-4 space-y-2 animate-fade-in">
              {favorites.length === 0 ? (
                <p className="text-sm text-surface-400 text-center py-4">
                  No tienes lugares guardados aún
                </p>
              ) : (
                favorites.map((fav) => (
                  <div key={fav.id} className="flex items-center gap-3 p-3 bg-surface-50 rounded-xl">
                    <MapPin className="w-4 h-4 text-primary-600 flex-shrink-0" />
                    <div className="flex-1 min-w-0">
                      <p className="text-sm font-medium text-surface-700">{fav.name}</p>
                      {fav.address && (
                        <p className="text-xs text-surface-400 truncate">{fav.address}</p>
                      )}
                    </div>
                  </div>
                ))
              )}
            </div>
          )}
        </div>

        {/* Soporte por WhatsApp */}
        {supportPhone && whatsappNumber(supportPhone) && (
          <a
            href={`https://wa.me/${whatsappNumber(supportPhone)}`}
            target="_blank"
            rel="noopener noreferrer"
            className="card flex items-center gap-3 p-4 hover:border-emerald-300 transition-colors"
          >
            <div className="w-10 h-10 bg-emerald-50 rounded-full flex items-center justify-center">
              <MessageCircle className="w-5 h-5 text-emerald-600" />
            </div>
            <div className="flex-1">
              <p className="font-medium text-surface-700">Soporte</p>
              <p className="text-xs text-surface-400">Escríbenos por WhatsApp</p>
            </div>
          </a>
        )}

        {/* Cerrar sesión */}
        <button onClick={handleSignOut} className="btn-danger w-full">
          <LogOut className="w-4 h-4" />
          Cerrar sesión
        </button>
      </div>
    </div>
  )
}