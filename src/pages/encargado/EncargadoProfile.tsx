import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { User, MapPin, MessageCircle, LogOut, Loader2 } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { AppLogo } from '@/components/ui/AppLogo'

export function EncargadoProfile() {
  const { user, signOut } = useAuth()
  const navigate = useNavigate()
  const [zoneName, setZoneName] = useState('')
  const [phone, setPhone] = useState('')
  const [error, setError] = useState('')
  const [saving, setSaving] = useState(false)

  useEffect(() => {
    if (user?.zone_id) {
      supabase
        .from('zones')
        .select('name, support_whatsapp')
        .eq('id', user.zone_id)
        .single()
        .then(({ data }) => {
          if (data) {
            setZoneName(data.name)
            setPhone(data.support_whatsapp || '')
          }
        })
    }
  }, [user?.zone_id])

  const handleSaveSupport = async () => {
    if (!user?.zone_id) return
    setError('')
    setSaving(true)
    try {
      const { error } = await supabase.rpc('set_zone_support', {
        p_zone_id: user.zone_id,
        p_phone: phone
      })
      if (error) throw error
    } catch (err: any) {
      setError(err.message)
    } finally {
      setSaving(false)
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
            <p className="text-xs text-white/80">Encargado de {zoneName || 'tu ciudad'}</p>
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6 space-y-4">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        <div className="card flex items-center gap-4">
          <div className="w-16 h-16 bg-primary-50 rounded-full flex items-center justify-center">
            <User className="w-8 h-8 text-primary-600" />
          </div>
          <div className="flex-1">
            <h2 className="font-semibold text-surface-800">{user?.full_name}</h2>
            <p className="text-sm text-surface-500">{user?.email}</p>
            <span className="badge-info mt-1"><MapPin className="w-3 h-3 inline mr-1" />{zoneName || 'Sin ciudad'}</span>
          </div>
        </div>

        <div className="card space-y-3">
          <h3 className="font-semibold text-surface-700 flex items-center gap-2">
            <MessageCircle className="w-4 h-4 text-emerald-600" /> WhatsApp de soporte de mi zona
          </h3>
          <p className="text-xs text-surface-400">
            Este número se muestra a los usuarios de {zoneName || 'tu ciudad'} en el botón "Soporte" de su perfil.
          </p>
          <input
            type="tel"
            className="input"
            placeholder="0412-1234567"
            value={phone}
            onChange={(e) => setPhone(e.target.value)}
          />
          <button onClick={handleSaveSupport} className="btn-primary w-full" disabled={saving}>
            {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : <><MessageCircle className="w-4 h-4" /> Guardar número</>}
          </button>
        </div>

        <button onClick={handleSignOut} className="btn-danger w-full">
          <LogOut className="w-4 h-4" /> Cerrar sesión
        </button>
      </div>
    </div>
  )
}
