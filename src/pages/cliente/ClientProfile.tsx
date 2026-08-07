import { useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { User, LogOut, Star, MapPin, ChevronRight } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { HexUnderline } from '@/components/ui/HexUnderline'
import { AppLogo } from '@/components/ui/AppLogo'

export function ClientProfile() {
  const { user, signOut } = useAuth()
  const navigate = useNavigate()
  const [showFavorites, setShowFavorites] = useState(false)
  const [favorites, setFavorites] = useState<any[]>([])

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
        <div className="card flex items-center gap-4">
          <div className="w-16 h-16 bg-primary-50 rounded-full flex items-center justify-center">
            <User className="w-8 h-8 text-primary-600" />
          </div>
          <div className="flex-1">
            <h2 className="font-semibold text-surface-800">{user?.full_name}</h2>
            <p className="text-sm text-surface-500">{user?.email}</p>
            <span className="badge-primary mt-1">Cliente</span>
          </div>
        </div>

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

        {/* Cerrar sesión */}
        <button onClick={handleSignOut} className="btn-danger w-full">
          <LogOut className="w-4 h-4" />
          Cerrar sesión
        </button>
      </div>
    </div>
  )
}