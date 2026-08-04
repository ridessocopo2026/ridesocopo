import { createContext, useContext, useEffect, useState, ReactNode, useCallback, useRef } from 'react'
import { supabase } from '@/lib/supabase'
import type { Profile } from '@/types/database'
import { Loader } from '@/components/ui/Loader'

interface AuthContextType {
  user: Profile | null
  loading: boolean
  signIn: (email: string, password: string) => Promise<{ error: string | null }>
  signUp: (email: string, password: string, fullName: string) => Promise<{ error: string | null }>
  signInWithGoogle: () => Promise<{ error: string | null }>
  signOut: () => Promise<void>
  refreshProfile: () => Promise<void>
}

const AuthContext = createContext<AuthContextType | undefined>(undefined)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<Profile | null>(null)
  const [loading, setLoading] = useState(true)
  // Evita fetches duplicados del mismo perfil
  const fetchingRef = useRef<{ userId: string | null }>({ userId: null })

  const fetchProfile = useCallback(async (userId: string) => {
    // Guard: si ya estamos cargando el mismo userId, no repetimos
    if (fetchingRef.current.userId === userId) return
    fetchingRef.current.userId = userId

    try {
      const { data, error } = await supabase
        .from('profiles')
        .select('*')
        .eq('id', userId)
        .single()

      if (!error && data) {
        setUser(data as Profile)
      } else if (error) {
        console.error('Error cargando perfil:', error)
      }
    } finally {
      fetchingRef.current.userId = null
    }
  }, [])

  useEffect(() => {
    let mounted = true

    // 1. Restaurar sesión al cargar la app.
    //    ESPERAMOS a que el perfil se cargue antes de setLoading(false)
    //    para que HomeRedirect nunca vea user=null cuando hay sesión.
    supabase.auth.getSession().then(async ({ data: { session } }) => {
      if (!mounted) return

      if (session?.user) {
        await fetchProfile(session.user.id)
      }
      if (mounted) setLoading(false)
    })

    // 2. Escuchar cambios de autenticación
    const { data: { subscription } } = supabase.auth.onAuthStateChange(async (event, session) => {
      if (!mounted) return

      if (event === 'SIGNED_IN' && session?.user) {
        await fetchProfile(session.user.id)
        setLoading(false)
      } else if (event === 'SIGNED_OUT') {
        // ⚠️ Solo limpiar si NO hay sesión persistida (evita logout fantasma
        // cuando el refresh token expira estando la pestaña en segundo plano).
        const { data: { session: currentSession } } = await supabase.auth.getSession()
        if (!currentSession) {
          setUser(null)
          setLoading(false)
        }
      } else if (event === 'TOKEN_REFRESHED' && session?.user) {
        // Solo refrescar el perfil si no hay uno cargado
        await fetchProfile(session.user.id)
      }
    })

    // 3. Al volver a la pestaña (app PWA en segundo plano), refrescar la sesión
    //    si hay una activa. Esto NO gasta recursos porque solo se ejecuta
    //    cuando el usuario regresa a la app, no periódicamente.
    const handleVisibilityChange = async () => {
      if (document.visibilityState !== 'visible') return

      const { data: { session } } = await supabase.auth.getSession()
      if (session?.user) {
        // Refrescar el access token silenciosamente
        await supabase.auth.refreshSession()
      }
    }

    document.addEventListener('visibilitychange', handleVisibilityChange)

    return () => {
      mounted = false
      subscription.unsubscribe()
      document.removeEventListener('visibilitychange', handleVisibilityChange)
    }
  }, [fetchProfile])

  const signIn = async (email: string, password: string) => {
    const { error } = await supabase.auth.signInWithPassword({ email, password })
    return { error: error?.message || null }
  }

  const signUp = async (email: string, password: string, fullName: string) => {
    const { error } = await supabase.auth.signUp({
      email,
      password,
      options: {
        data: { full_name: fullName }
      }
    })
    return { error: error?.message || null }
  }

  const signInWithGoogle = async () => {
    const { error } = await supabase.auth.signInWithOAuth({
      provider: 'google',
      options: {
        redirectTo: window.location.origin
      }
    })
    return { error: error?.message || null }
  }

  const signOut = async () => {
    await supabase.auth.signOut()
    setUser(null)
  }

  const refreshProfile = useCallback(async () => {
    if (user?.id) {
      await fetchProfile(user.id)
    }
  }, [user?.id, fetchProfile])

  if (loading) {
    return (
      <div className="min-h-screen flex items-center justify-center">
        <Loader size="lg" text="Cargando..." />
      </div>
    )
  }

  return (
    <AuthContext.Provider value={{ user, loading, signIn, signUp, signInWithGoogle, signOut, refreshProfile }}>
      {children}
    </AuthContext.Provider>
  )
}

export function useAuth() {
  const context = useContext(AuthContext)
  if (context === undefined) {
    throw new Error('useAuth debe usarse dentro de AuthProvider')
  }
  return context
}