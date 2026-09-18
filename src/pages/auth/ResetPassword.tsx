import { useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { Lock, Loader2, CheckCircle, AlertTriangle, Eye, EyeOff } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { HexUnderline } from '@/components/ui/HexUnderline'
import { AppLogo } from '@/components/ui/AppLogo'

export function ResetPassword() {
  const { updatePassword } = useAuth()
  const navigate = useNavigate()

  const [checking, setChecking] = useState(true)
  const [valid, setValid] = useState(false)
  const [email, setEmail] = useState('')
  const [pass, setPass] = useState('')
  const [pass2, setPass2] = useState('')
  const [showPass, setShowPass] = useState(false)
  const [error, setError] = useState('')
  const [done, setDone] = useState(false)
  const [loading, setLoading] = useState(false)

  // Detecta la sesión de recuperación que Supabase crea al abrir el enlace
  useEffect(() => {
    let settled = false
    const hadRecoveryParams = /[?&#](code=|type=recovery|access_token=)/.test(window.location.href)

    const check = async () => {
      const { data } = await supabase.auth.getSession()
      if (data.session) {
        setEmail(data.session.user?.email || '')
        setValid(true)
        settled = true
        setChecking(false)
      }
    }
    void check()

    const { data: sub } = supabase.auth.onAuthStateChange((event, session) => {
      if (settled) return
      if (event === 'PASSWORD_RECOVERY' || (session && hadRecoveryParams)) {
        settled = true
        setEmail(session?.user?.email || '')
        setValid(true)
        setChecking(false)
      }
    })

    const t = setTimeout(() => {
      if (!settled) setChecking(false)
    }, 3500)

    return () => {
      sub.subscription.unsubscribe()
      clearTimeout(t)
    }
  }, [])

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setError('')

    if (pass.length < 8) {
      setError('La contraseña debe tener al menos 8 caracteres')
      return
    }
    if (pass !== pass2) {
      setError('Las contraseñas no coinciden')
      return
    }

    setLoading(true)
    const { error: err } = await updatePassword(pass)
    setLoading(false)

    if (err) {
      setError(err)
      return
    }

    setDone(true)
    // Cerramos la sesión de recuperación por seguridad
    await supabase.auth.signOut()
    setTimeout(() => navigate('/login'), 2500)
  }

  return (
    <div className="min-h-screen bg-white flex flex-col items-center justify-center px-6 py-12">
      <div className="w-full max-w-sm">
        <div className="flex flex-col items-center mb-8">
          <AppLogo size="lg" rounded="rounded-2xl" className="mb-4 shadow-elevated" />
          <h1 className="text-3xl font-bold text-surface-800">BunRider</h1>
          <p className="text-sm text-surface-500 mt-1">Restablecer contraseña</p>
          <HexUnderline />
        </div>

        {checking ? (
          <div className="flex justify-center py-10">
            <Loader2 className="w-6 h-6 animate-spin text-primary-600" />
          </div>
        ) : done ? (
          <div className="rounded-2xl p-4 bg-emerald-50 border border-emerald-200 text-center space-y-3">
            <CheckCircle className="w-8 h-8 text-emerald-600 mx-auto" />
            <p className="text-sm text-emerald-700 font-medium">¡Contraseña actualizada!</p>
            <p className="text-xs text-emerald-600">Te llevamos al inicio de sesión para que entres con tu nueva contraseña…</p>
            <Link to="/login" className="btn-primary w-full">Iniciar sesión</Link>
          </div>
        ) : !valid ? (
          <div className="space-y-4">
            <div className="rounded-2xl p-4 bg-amber-50 border border-amber-200 flex items-start gap-2">
              <AlertTriangle className="w-5 h-5 text-amber-600 flex-shrink-0 mt-0.5" />
              <div>
                <p className="text-sm font-medium text-amber-700">Enlace inválido o expirado</p>
                <p className="text-xs text-amber-600 mt-0.5">
                  El enlace de recuperación dura unas horas y solo sirve una vez. Solicita uno nuevo desde el inicio de sesión.
                </p>
              </div>
            </div>
            <Link to="/login" className="btn-primary w-full">Volver al inicio de sesión</Link>
          </div>
        ) : (
          <>
            {email && (
              <p className="text-center text-xs text-surface-400 mb-4">
                Cambiando la contraseña de <strong className="text-surface-600">{email}</strong>
              </p>
            )}

            {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

            <form onSubmit={handleSubmit} className="space-y-4">
              <div>
                <label className="label" htmlFor="pass">Nueva contraseña</label>
                <div className="relative">
                  <Lock className="absolute left-3 top-1/2 -translate-y-1/2 w-5 h-5 text-surface-400" />
                  <input
                    id="pass"
                    type={showPass ? 'text' : 'password'}
                    className="input pl-10 pr-10"
                    placeholder="Mínimo 8 caracteres"
                    value={pass}
                    onChange={(e) => setPass(e.target.value)}
                    autoComplete="new-password"
                    required
                  />
                  <button
                    type="button"
                    onClick={() => setShowPass((v) => !v)}
                    className="absolute right-3 top-1/2 -translate-y-1/2 text-surface-400 hover:text-surface-600"
                    aria-label={showPass ? 'Ocultar contraseña' : 'Mostrar contraseña'}
                  >
                    {showPass ? <EyeOff className="w-4 h-4" /> : <Eye className="w-4 h-4" />}
                  </button>
                </div>
              </div>

              <div>
                <label className="label" htmlFor="pass2">Repite la contraseña</label>
                <div className="relative">
                  <Lock className="absolute left-3 top-1/2 -translate-y-1/2 w-5 h-5 text-surface-400" />
                  <input
                    id="pass2"
                    type={showPass ? 'text' : 'password'}
                    className="input pl-10"
                    placeholder="••••••••"
                    value={pass2}
                    onChange={(e) => setPass2(e.target.value)}
                    autoComplete="new-password"
                    required
                  />
                </div>
              </div>

              <button type="submit" className="btn-primary w-full" disabled={loading}>
                {loading ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Guardar nueva contraseña'}
              </button>
            </form>

            <p className="text-center text-xs text-surface-400 mt-4">
              Por seguridad, cerraremos tu sesión al guardar la nueva contraseña.
            </p>
          </>
        )}
      </div>
    </div>
  )
}
