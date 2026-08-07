import { useState } from 'react'
import { Link, useNavigate, useSearchParams } from 'react-router-dom'
import { Mail, Lock, Loader2 } from 'lucide-react'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { HexUnderline } from '@/components/ui/HexUnderline'
import { AppLogo } from '@/components/ui/AppLogo'

export function Login() {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(false)
  const { signIn, signInWithGoogle } = useAuth()
  const navigate = useNavigate()
  const [searchParams] = useSearchParams()
  const redirectTo = searchParams.get('redirect') || '/'

  const handleSubmit = async (e: React.FormEvent) => {
    e.preventDefault()
    setError('')
    setLoading(true)

    const { error } = await signIn(email, password)
    if (error) {
      setError(error)
      setLoading(false)
      return
    }

    navigate(redirectTo)
  }

  const handleGoogle = async () => {
    setError('')
    setLoading(true)
    const { error } = await signInWithGoogle()
    if (error) {
      setError(error)
      setLoading(false)
    }
  }

  return (
    <div className="min-h-screen bg-white flex flex-col items-center justify-center px-6 py-12">
      <div className="w-full max-w-sm">
        {/* Logo */}
        <div className="flex flex-col items-center mb-8">
          <AppLogo size="lg" rounded="rounded-2xl" className="mb-4 shadow-elevated" />
          <h1 className="text-3xl font-bold text-surface-800">RiderFlasshi</h1>
          <p className="text-sm text-surface-500 mt-1">Transporte de pasajeros en Socopó</p>
          <HexUnderline />
        </div>

        <h2 className="text-xl font-semibold text-surface-800 mb-6 text-center">
          Iniciar sesión
        </h2>

        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        <button
          onClick={handleGoogle}
          className="btn-outline w-full"
          disabled={loading}
        >
          <svg className="w-5 h-5" viewBox="0 0 24 24">
            <path fill="#4285F4" d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z"/>
            <path fill="#34A853" d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z"/>
            <path fill="#FBBC05" d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z"/>
            <path fill="#EA4335" d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z"/>
          </svg>
          Continuar con Google
        </button>

        <div className="flex items-center gap-4 my-6">
          <div className="flex-1 h-px bg-surface-200" />
          <span className="text-xs text-surface-400">o con tu correo</span>
          <div className="flex-1 h-px bg-surface-200" />
        </div>

        <form onSubmit={handleSubmit} className="space-y-4">
          <div>
            <label className="label" htmlFor="email">Correo electrónico</label>
            <div className="relative">
              <Mail className="absolute left-3 top-1/2 -translate-y-1/2 w-5 h-5 text-surface-400" />
              <input
                id="email"
                type="email"
                className="input pl-10"
                placeholder="tu@correo.com"
                value={email}
                onChange={(e) => setEmail(e.target.value)}
                required
              />
            </div>
          </div>

          <div>
            <label className="label" htmlFor="password">Contraseña</label>
            <div className="relative">
              <Lock className="absolute left-3 top-1/2 -translate-y-1/2 w-5 h-5 text-surface-400" />
              <input
                id="password"
                type="password"
                className="input pl-10"
                placeholder="••••••••"
                value={password}
                onChange={(e) => setPassword(e.target.value)}
                required
              />
            </div>
          </div>

          <button type="submit" className="btn-primary w-full" disabled={loading}>
            {loading ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Iniciar sesión'}
          </button>
        </form>

        <p className="text-center text-sm text-surface-500 mt-6">
          ¿No tienes cuenta?{' '}
          <Link to="/registro" className="text-primary-600 font-medium hover:text-primary-700">
            Regístrate
          </Link>
        </p>
      </div>
    </div>
  )
}