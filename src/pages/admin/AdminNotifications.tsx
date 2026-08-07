import { useState } from 'react'
import { Bell, Send, Users, Loader2, CheckCircle, LogOut, ChevronLeft } from 'lucide-react'
import { useNavigate } from 'react-router-dom'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'

const TARGETS = [
  { value: 'todos', label: 'Todos los usuarios', icon: <Users className="w-4 h-4" /> },
  { value: 'clientes', label: 'Clientes', icon: <Users className="w-4 h-4" /> },
  { value: 'conductores', label: 'Conductores', icon: <Users className="w-4 h-4" /> },
  { value: 'admins', label: 'Administradores', icon: <Users className="w-4 h-4" /> },
]

export function AdminNotifications() {
  const [title, setTitle] = useState('')
  const [body, setBody] = useState('')
  const [target, setTarget] = useState('todos')
  const [sending, setSending] = useState(false)
  const [sent, setSent] = useState<{ count: number; target: string } | null>(null)
  const [error, setError] = useState('')
  const { user, signOut } = useAuth()
  const navigate = useNavigate()

  const handleSend = async () => {
    if (!title.trim()) {
      setError('Escribe un título para la notificación')
      return
    }
    if (!body.trim()) {
      setError('Escribe el mensaje de la notificación')
      return
    }

    setError('')
    setSending(true)
    setSent(null)

    try {
      const { data, error } = await supabase.rpc('send_admin_notification', {
        p_title: title.trim(),
        p_body: body.trim(),
        p_target: target,
      })

      if (error) throw error

      if (data?.success) {
        setSent({ count: data.sent || 0, target: data.target || target })
        setTitle('')
        setBody('')
      } else {
        setError('No se pudo enviar la notificación')
      }
    } catch (err: any) {
      setError(err.message || 'Error al enviar la notificación')
    } finally {
      setSending(false)
    }
  }

  const handleSignOut = async () => {
    await signOut()
    navigate('/login')
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      {/* Header */}
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center justify-between max-w-md mx-auto">
          <div className="flex items-center gap-3">
            <button onClick={() => navigate('/admin')} className="p-2 text-surface-400 hover:text-surface-600">
              <ChevronLeft className="w-5 h-5" />
            </button>
            <div className="w-10 h-10 bg-primary-600 rounded-xl flex items-center justify-center">
              <Bell className="w-5 h-5 text-white" />
            </div>
            <div>
              <h1 className="text-lg font-bold text-surface-800">Notificaciones</h1>
              <p className="text-xs text-surface-500">Enviar a todos los usuarios</p>
            </div>
          </div>
          <button onClick={handleSignOut} className="p-2 text-surface-400 hover:text-red-500 transition-colors">
            <LogOut className="w-5 h-5" />
          </button>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6 space-y-6">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        {sent && (
          <div className="bg-emerald-50 border border-emerald-200 rounded-xl p-4 flex items-start gap-3">
            <CheckCircle className="w-5 h-5 text-emerald-600 flex-shrink-0 mt-0.5" />
            <div>
              <p className="text-sm font-semibold text-emerald-700">Notificación enviada</p>
              <p className="text-xs text-emerald-600 mt-0.5">
                Se envió a {sent.count} {sent.count === 1 ? 'usuario' : 'usuarios'} ({sent.target})
              </p>
            </div>
          </div>
        )}

        {/* Formulario */}
        <div className="card p-5 space-y-4">
          <h2 className="font-semibold text-surface-800">Nueva notificación</h2>

          <div>
            <label className="label">Título *</label>
            <input
              type="text"
              className="input"
              placeholder="Ej: ¡Llega RiderFlasshi a nuevos barrios!"
              value={title}
              onChange={(e) => setTitle(e.target.value)}
              maxLength={100}
            />
          </div>

          <div>
            <label className="label">Mensaje *</label>
            <textarea
              className="input min-h-[120px] resize-none"
              placeholder="Escribe el mensaje que verán los usuarios..."
              value={body}
              onChange={(e) => setBody(e.target.value)}
              maxLength={500}
            />
            <p className="text-xs text-surface-400 mt-1">{body.length}/500</p>
          </div>

          <div>
            <label className="label">Destinatario</label>
            <div className="grid grid-cols-2 gap-2">
              {TARGETS.map((t) => (
                <button
                  key={t.value}
                  type="button"
                  onClick={() => setTarget(t.value)}
                  className={`p-3 rounded-xl border-2 text-sm font-medium transition-all ${
                    target === t.value
                      ? 'border-primary-600 bg-primary-50 text-primary-700'
                      : 'border-surface-200 text-surface-600'
                  }`}
                >
                  {t.label}
                </button>
              ))}
            </div>
          </div>

          <button
            onClick={handleSend}
            disabled={sending || !title.trim() || !body.trim()}
            className="btn-primary w-full"
          >
            {sending ? (
              <Loader2 className="w-5 h-5 animate-spin" />
            ) : (
              <Send className="w-5 h-5" />
            )}
            Enviar notificación
          </button>

          <p className="text-[11px] text-surface-400 text-center">
            Se enviará como notificación push a los móviles y quedará visible dentro de la app.
          </p>
        </div>

        {/* Info de seguridad */}
        <div className="bg-amber-50 border border-amber-200 rounded-xl p-3">
          <p className="text-xs text-amber-700">
            <strong>Importante:</strong> Solo los usuarios que hayan activado notificaciones push en su
            dispositivo recibirán el push. Todos recibirán la notificación dentro de la app.
          </p>
        </div>
      </div>
    </div>
  )
}