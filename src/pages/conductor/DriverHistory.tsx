import { useState, useEffect } from 'react'
import { History, Star, Hexagon } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { EmptyState } from '@/components/ui/EmptyState'
import { SkeletonList } from '@/components/ui/Skeleton'
import type { Ride } from '@/types/database'

export function DriverHistory() {
  const [rides, setRides] = useState<Ride[]>([])
  const [loading, setLoading] = useState(true)
  const { user } = useAuth()

  useEffect(() => {
    loadRides()
  }, [])

  const loadRides = async () => {
    if (!user) return
    const { data, error } = await supabase
      .from('rides')
      .select('*')
      .eq('driver_id', user.id)
      .order('created_at', { ascending: false })
      .limit(50)

    if (!error && data) {
      setRides(data as Ride[])
    }
    setLoading(false)
  }

  const statusBadge: Record<string, React.ReactNode> = {
    buscando: <span className="badge-warning">Buscando</span>,
    aceptada: <span className="badge-info">Aceptada</span>,
    en_ruta: <span className="badge-primary">En ruta</span>,
    completada: <span className="badge-success">Completada</span>,
    cancelada: <span className="badge-danger">Cancelada</span>
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 bg-primary-600 rounded-xl flex items-center justify-center">
            <Hexagon className="w-5 h-5 text-white" />
          </div>
          <div>
            <h1 className="text-lg font-bold text-surface-800">Historial de viajes</h1>
            <p className="text-xs text-surface-500">Tus viajes realizados</p>
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6">
        {loading ? (
          <SkeletonList count={4} />
        ) : rides.length === 0 ? (
          <EmptyState
            icon={<History className="w-8 h-8" />}
            title="Sin viajes aún"
            description="Cuando realices tu primer viaje aparecerá aquí"
          />
        ) : (
          <div className="space-y-3">
            {rides.map((ride) => (
              <div key={ride.id} className="card">
                <div className="flex items-center justify-between mb-3">
                  <span className="badge-primary">{ride.category}</span>
                  {statusBadge[ride.status]}
                </div>
                <div className="space-y-2 mb-3">
                  <div className="flex items-start gap-2">
                    <div className="w-2 h-2 bg-accent-600 rounded-full mt-1.5 flex-shrink-0" />
                    <p className="text-sm text-surface-600 truncate">{ride.origin_address || 'Origen'}</p>
                  </div>
                  <div className="flex items-start gap-2">
                    <div className="w-2 h-2 bg-primary-600 rounded-full mt-1.5 flex-shrink-0" />
                    <p className="text-sm text-surface-600 truncate">{ride.destination_address || 'Destino'}</p>
                  </div>
                  {ride.destination_barrio_name && (
                    <span className="badge-primary">{ride.destination_barrio_name}</span>
                  )}
                </div>
                <div className="flex items-center justify-between pt-3 border-t border-surface-100">
                  <div className="flex items-center gap-2">
                    <span className="text-sm text-surface-400">
                      {new Date(ride.created_at).toLocaleDateString('es-VE', {
                        day: 'numeric',
                        month: 'short',
                        year: 'numeric'
                      })}
                    </span>
                    {ride.rating && (
                      <span className="flex items-center gap-1 text-sm text-amber-500">
                        <Star className="w-3 h-3 fill-current" />
                        {ride.rating}
                      </span>
                    )}
                  </div>
                  <span className="font-bold text-primary-600">${ride.final_fare_usd.toFixed(2)}</span>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}