import { useState, useEffect } from 'react'
import { Image, Plus, Trash2, Loader2, Upload, Pencil, X, ChevronUp, ChevronDown } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { uploadToImgBB } from '@/lib/imgbb'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { EmptyState } from '@/components/ui/EmptyState'
import { HexUnderline } from '@/components/ui/HexUnderline'
import type { Banner } from '@/types/database'
import { AppLogo } from '@/components/ui/AppLogo'

export function AdminBanners() {
  const [banners, setBanners] = useState<Banner[]>([])
  const [showForm, setShowForm] = useState(false)
  const [editingId, setEditingId] = useState<string | null>(null)
  const [title, setTitle] = useState('')
  const [subtitle, setSubtitle] = useState('')
  const [imageFile, setImageFile] = useState<File | null>(null)
  // Preview de la imagen seleccionada (object URL) o la imagen actual del banner en edición
  const [previewUrl, setPreviewUrl] = useState<string | null>(null)
  const [editingImage, setEditingImage] = useState<string | null>(null)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const { user } = useAuth()

  useEffect(() => {
    loadBanners()
    return () => {
      // Limpiar el object URL al desmontar (evita fugas de memoria)
      if (previewUrl) URL.revokeObjectURL(previewUrl)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  const loadBanners = async () => {
    const { data, error } = await supabase
      .from('banners')
      .select('*')
      .order('sort_order')

    if (!error && data) {
      setBanners(data as Banner[])
    }
    setLoading(false)
  }

  const resetForm = () => {
    if (previewUrl) URL.revokeObjectURL(previewUrl)
    setTitle('')
    setSubtitle('')
    setImageFile(null)
    setPreviewUrl(null)
    setEditingImage(null)
    setEditingId(null)
  }

  const handleFileChange = (file: File | null) => {
    if (previewUrl) URL.revokeObjectURL(previewUrl)
    setImageFile(file)
    setPreviewUrl(file ? URL.createObjectURL(file) : null)
  }

  const handleEdit = (banner: Banner) => {
    setEditingId(banner.id)
    setTitle(banner.title)
    setSubtitle(banner.subtitle || '')
    setImageFile(null)
    setPreviewUrl(null)
    setEditingImage(banner.image_url || null)
    setShowForm(true)
    window.scrollTo({ top: 0, behavior: 'smooth' })
  }

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setError('')

    if (!title) {
      setError('El título es obligatorio')
      return
    }

    setSaving(true)

    try {
      // Si hay archivo nuevo → subir a ImgBB; si no, conservar la imagen actual
      let imageUrl = editingImage
      if (imageFile) {
        imageUrl = await uploadToImgBB(imageFile)
      }

      if (editingId) {
        const { error } = await supabase
          .from('banners')
          .update({
            title,
            subtitle: subtitle || null,
            image_url: imageUrl,
          })
          .eq('id', editingId)
        if (error) throw error
      } else {
        const { data, error } = await supabase.rpc('create_banner', {
          p_title: title,
          p_subtitle: subtitle || null,
          p_image_url: imageUrl,
          p_link_url: null,
          p_sort_order: banners.length
        })
        if (error) throw error
      }

      resetForm()
      setShowForm(false)
      loadBanners()
    } catch (err: any) {
      setError(err.message)
    } finally {
      setSaving(false)
    }
  }

  const handleDelete = async (id: string) => {
    if (!confirm('¿Eliminar este banner?')) return

    const { error } = await supabase
      .from('banners')
      .delete()
      .eq('id', id)

    if (!error) {
      loadBanners()
    }
  }

  const handleToggle = async (banner: Banner) => {
    const { error } = await supabase
      .from('banners')
      .update({ is_active: !banner.is_active })
      .eq('id', banner.id)

    if (!error) {
      loadBanners()
    }
  }

  // Reordena un banner intercambiando su sort_order con el banner adyacente
  const handleMove = async (banner: Banner, direction: 'up' | 'down') => {
    const idx = banners.findIndex((b) => b.id === banner.id)
    const targetIdx = direction === 'up' ? idx - 1 : idx + 1
    if (idx < 0 || targetIdx < 0 || targetIdx >= banners.length) return

    const target = banners[targetIdx]
    const tmp = banner.sort_order

    await supabase
      .from('banners')
      .update({ sort_order: target.sort_order })
      .eq('id', banner.id)
    await supabase
      .from('banners')
      .update({ sort_order: tmp })
      .eq('id', target.id)

    loadBanners()
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <AppLogo />
            <div>
              <h1 className="text-lg font-bold text-surface-800">Banners Promocionales</h1>
              <p className="text-xs text-surface-500">Gestiona la publicidad</p>
            </div>
          </div>
          <button
            onClick={() => {
              if (showForm) resetForm()
              setShowForm(!showForm)
            }}
            className="btn-primary"
          >
            <Plus className="w-4 h-4" />
            Nuevo
          </button>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}
        <HexUnderline />

        {showForm && (
          <form onSubmit={handleSubmit} className="card space-y-4 mb-6 animate-fade-in">
            <h2 className="font-semibold text-surface-800">{editingId ? 'Editar banner' : 'Nuevo banner'}</h2>

            <div>
              <label className="label">Título *</label>
              <input
                type="text"
                className="input"
                placeholder="Ej: Promoción de bienvenida"
                value={title}
                onChange={(e) => setTitle(e.target.value)}
                required
              />
            </div>

            <div>
              <label className="label">Subtítulo</label>
              <input
                type="text"
                className="input"
                placeholder="Descripción corta"
                value={subtitle}
                onChange={(e) => setSubtitle(e.target.value)}
              />
            </div>

            <div>
              <label className="label">Imagen</label>
              {previewUrl || editingImage ? (
                <div className="relative">
                  <img
                    src={previewUrl || editingImage || undefined}
                    alt="Vista previa"
                    className="w-full h-40 object-cover rounded-xl border border-surface-200"
                  />
                  <button
                    type="button"
                    onClick={() => {
                      handleFileChange(null)
                      setEditingImage(null)
                    }}
                    className="absolute top-2 right-2 p-1.5 bg-black/60 text-white rounded-full hover:bg-black/80 transition-colors"
                    aria-label="Quitar imagen"
                  >
                    <X className="w-4 h-4" />
                  </button>
                  <label className="absolute bottom-2 right-2 flex items-center gap-1 bg-white/90 text-surface-700 text-xs font-medium px-2.5 py-1.5 rounded-lg cursor-pointer hover:bg-white shadow-sm">
                    <Upload className="w-3 h-3" />
                    Cambiar
                    <input
                      type="file"
                      accept="image/*"
                      className="hidden"
                      onChange={(e) => handleFileChange(e.target.files?.[0] || null)}
                    />
                  </label>
                </div>
              ) : (
                <label className="flex flex-col items-center justify-center w-full h-32 border-2 border-dashed border-surface-200 rounded-xl cursor-pointer hover:border-primary-400 transition-colors">
                  <div className="text-center">
                    <Upload className="w-8 h-8 text-surface-400 mx-auto mb-1" />
                    <span className="text-xs text-surface-500">Toca para subir imagen</span>
                  </div>
                  <input
                    type="file"
                    accept="image/*"
                    className="hidden"
                    onChange={(e) => handleFileChange(e.target.files?.[0] || null)}
                  />
                </label>
              )}
            </div>

            <button type="submit" className="btn-primary w-full" disabled={saving}>
              {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : (editingId ? 'Guardar cambios' : 'Crear banner')}
            </button>
          </form>
        )}

        {banners.length === 0 ? (
          <EmptyState
            icon={<Image className="w-8 h-8" />}
            title="Sin banners"
            description="Crea tu primer banner promocional"
          />
        ) : (
          <div className="space-y-3">
            {banners.map((banner, idx) => (
              <div key={banner.id} className="card">
                {banner.image_url && (
                  <img
                    src={banner.image_url}
                    alt={banner.title}
                    loading="lazy"
                    className="w-full h-32 object-cover rounded-xl mb-3 border border-surface-100"
                  />
                )}
                <div className="flex items-start justify-between">
                  <div className="flex-1">
                    <h3 className="font-semibold text-surface-700">{banner.title}</h3>
                    {banner.subtitle && (
                      <p className="text-sm text-surface-500 mt-1">{banner.subtitle}</p>
                    )}
                  </div>
                  <div className="flex items-center gap-2">
                    <div className="flex flex-col gap-0.5">
                      <button
                        onClick={() => handleMove(banner, 'up')}
                        disabled={idx === 0}
                        className="p-0.5 text-surface-400 hover:text-primary-600 disabled:opacity-30 disabled:cursor-not-allowed transition-colors"
                        title="Mover arriba"
                      >
                        <ChevronUp className="w-4 h-4" />
                      </button>
                      <button
                        onClick={() => handleMove(banner, 'down')}
                        disabled={idx === banners.length - 1}
                        className="p-0.5 text-surface-400 hover:text-primary-600 disabled:opacity-30 disabled:cursor-not-allowed transition-colors"
                        title="Mover abajo"
                      >
                        <ChevronDown className="w-4 h-4" />
                      </button>
                    </div>
                    <button
                      onClick={() => handleEdit(banner)}
                      className="p-2 text-primary-500 hover:text-primary-700 transition-colors"
                      title="Editar banner"
                    >
                      <Pencil className="w-4 h-4" />
                    </button>
                    <button
                      onClick={() => handleToggle(banner)}
                      className={`px-3 py-1 rounded-full text-xs font-medium transition-colors ${
                        banner.is_active
                          ? 'bg-emerald-50 text-emerald-700'
                          : 'bg-surface-100 text-surface-500'
                      }`}
                    >
                      {banner.is_active ? 'Activo' : 'Inactivo'}
                    </button>
                    <button
                      onClick={() => handleDelete(banner.id)}
                      className="p-2 text-red-400 hover:text-red-600 transition-colors"
                    >
                      <Trash2 className="w-4 h-4" />
                    </button>
                  </div>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}