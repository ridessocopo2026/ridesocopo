import { useState, useEffect } from 'react'
import { Image, Plus, Trash2, Loader2, Hexagon, Upload } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { uploadToImgBB } from '@/lib/imgbb'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { EmptyState } from '@/components/ui/EmptyState'
import { HexUnderline } from '@/components/ui/HexUnderline'
import type { Banner } from '@/types/database'

export function AdminBanners() {
  const [banners, setBanners] = useState<Banner[]>([])
  const [showForm, setShowForm] = useState(false)
  const [title, setTitle] = useState('')
  const [subtitle, setSubtitle] = useState('')
  const [imageFile, setImageFile] = useState<File | null>(null)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const { user } = useAuth()

  useEffect(() => {
    loadBanners()
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

  const handleCreate = async (e: React.FormEvent) => {
    e.preventDefault()
    setError('')

    if (!title) {
      setError('El título es obligatorio')
      return
    }

    setSaving(true)

    try {
      let imageUrl = null

      if (imageFile) {
        // Subir a ImgBB (ahorro de costos)
        imageUrl = await uploadToImgBB(imageFile)
      }

      const { data, error } = await supabase.rpc('create_banner', {
        p_title: title,
        p_subtitle: subtitle || null,
        p_image_url: imageUrl,
        p_link_url: null,
        p_sort_order: banners.length
      })

      if (error) throw error

      setTitle('')
      setSubtitle('')
      setImageFile(null)
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

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 bg-primary-600 rounded-xl flex items-center justify-center">
              <Hexagon className="w-5 h-5 text-white" />
            </div>
            <div>
              <h1 className="text-lg font-bold text-surface-800">Banners Promocionales</h1>
              <p className="text-xs text-surface-500">Gestiona la publicidad</p>
            </div>
          </div>
          <button onClick={() => setShowForm(!showForm)} className="btn-primary">
            <Plus className="w-4 h-4" />
            Nuevo
          </button>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}
        <HexUnderline />

        {showForm && (
          <form onSubmit={handleCreate} className="card space-y-4 mb-6 animate-fade-in">
            <h2 className="font-semibold text-surface-800">Nuevo banner</h2>

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
              <label className="flex flex-col items-center justify-center w-full h-32 border-2 border-dashed border-surface-200 rounded-xl cursor-pointer hover:border-primary-400 transition-colors">
                {imageFile ? (
                  <div className="text-center">
                    <Upload className="w-8 h-8 text-primary-600 mx-auto mb-1" />
                    <span className="text-xs text-surface-600">{imageFile.name}</span>
                  </div>
                ) : (
                  <div className="text-center">
                    <Upload className="w-8 h-8 text-surface-400 mx-auto mb-1" />
                    <span className="text-xs text-surface-500">Toca para subir imagen</span>
                  </div>
                )}
                <input
                  type="file"
                  accept="image/*"
                  className="hidden"
                  onChange={(e) => setImageFile(e.target.files?.[0] || null)}
                />
              </label>
            </div>

            <button type="submit" className="btn-primary w-full" disabled={saving}>
              {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Crear banner'}
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
            {banners.map((banner) => (
              <div key={banner.id} className="card">
                <div className="flex items-start justify-between">
                  <div className="flex-1">
                    <h3 className="font-semibold text-surface-700">{banner.title}</h3>
                    {banner.subtitle && (
                      <p className="text-sm text-surface-500 mt-1">{banner.subtitle}</p>
                    )}
                  </div>
                  <div className="flex items-center gap-2">
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