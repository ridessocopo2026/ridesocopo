import { useEffect, useState } from 'react'
import { UserCog, Loader2 } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'

/**
 * Permite al conductor solicitar un cambio de nombre.
 * Queda pendiente de aprobacion del administrador (igual que la foto).
 */
export function NameChangeRequest() {
  const { user } = useAuth()
  const [pending, setPending] = useState<string | null>(null)
  const [name, setName] = useState('')
  const [busy, setBusy] = useState(false)
  const [msg, setMsg] = useState('')
  const [err, setErr] = useState('')

  const load = async () => {
    if (!user?.id) return
    const { data } = await supabase
      .from('profiles')
      .select('full_name_pending')
      .eq('id', user.id)
      .single()
    setPending(((data as { full_name_pending?: string | null } | null)?.full_name_pending) || null)
  }

  useEffect(() => {
    load()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [user?.id])

  const submit = async () => {
    setErr('')
    setMsg('')
    setBusy(true)
    try {
      const { error } = await supabase.rpc('request_name_change', { p_new_name: name.trim() })
      if (error) throw error
      setMsg('Solicitud enviada. Queda pendiente de aprobación.')
      setName('')
      await load()
    } catch (e: any) {
      setErr(e?.message || 'No se pudo enviar la solicitud')
    } finally {
      setBusy(false)
    }
  }

  if (!user) return null

  return (
    <div className="card space-y-3">
      <div className="flex items-center gap-3">
        <div className="w-10 h-10 bg-primary-50 rounded-full flex items-center justify-center">
          <UserCog className="w-5 h-5 text-primary-600" />
        </div>
        <div className="min-w-0">
          <p className="font-medium text-surface-700">Cambiar mi nombre</p>
          <p className="text-xs text-surface-400 truncate">Actual: {user.full_name || '—'}</p>
        </div>
      </div>

      {pending ? (
        <div className="bg-amber-50 border border-amber-200 rounded-xl p-3">
          <p className="text-xs text-amber-800">
            Nombre en revisión: <strong>{pending}</strong>. Un administrador debe aprobarlo.
          </p>
        </div>
      ) : (
        <>
          {err && <p className="text-xs text-red-600">{err}</p>}
          {msg && <p className="text-xs text-emerald-600">{msg}</p>}
          <input
            type="text"
            className="input"
            placeholder="Escribe tu nombre completo"
            value={name}
            maxLength={60}
            onChange={(e) => setName(e.target.value)}
          />
          <button
            type="button"
            onClick={submit}
            className="btn-primary w-full"
            disabled={busy || name.trim().length < 3}
          >
            {busy ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Solicitar cambio de nombre'}
          </button>
          <p className="text-[11px] text-surface-400">
            El cambio queda pendiente de aprobación del administrador.
          </p>
        </>
      )}
    </div>
  )
}