import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { History, Star, Hexagon, ChevronRight } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { EmptyState } from '@/components/ui/EmptyState'
import { SkeletonList } from '@/components/ui/Skeleton'
import { HexUnderline } from '@/components/ui/HexUnderline'
import { Pagination } from '@/components/ui/Pagination'
import type { Ride } from '@/types/database'

const PAGE_SIZE = 10

export function ClientHistory() {
  const [rides, setRides] = useState<Ride[]>([])
  const [loading, setLoading] = useState(true)
  const [page, setPage] = useState(1)
  const [totalItems, setTotalItems] = useState(0)
  const { user } = useAuth()
  const navigate = useNavigate()

  useEffect(() => {
    if (user) {
      setLoading(true)
      loadRides()
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [user?.id, page])

  const loadRides = async () => {
    if (!user) return

    // Contar total para paginación
    const { count } = await supabase
      .from('rides')
      .select('id', { count: 'exact', head: true })
      .eq('client_id', user.id)

    // Cargar página actual
    const { data, error } = await supabase
      .from('rides')
      .select('*')
      .eq('client_id', user.id)
      .order('created_at', { ascending: false })
      .range((page - 1) * PAGE_SIZE, page * PAGE_SIZE - 1)

    if (!error && data) {
      setRides(data as Ride[])
      setTotalItems(count || 0)
    }
    setLoading(false)
  }

  const totalPages = Math.max(1, Math.ceil(totalItems / PAGE_SIZE))

  const statusBadge = {
    buscando: <span className="badge-warning">Buscando</span>,
    aceptada: <span className="badge-info">Aceptada</span>,
    en_ruta: <span className="badge-primary">En ruta</span>,
    completada: <span className="badge-success">Completada</span>,
    cancelada: <span className="badge-danger">Cancelada</span>,
    incidente: <span className="badge-danger">Incidente</span>
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
            <p className="text-xs text-surface-500">Tus viajes anteriores</p>
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6">
        <HexUnderline />

        {loading ? (
          <SkeletonList count={4} />
        ) : rides.length === 0 ? (
          <EmptyState
            icon={<History className="w-8 h-8" />}
            title="Sin viajes aún"
            description="Cuando realices tu primer viaje, aparecerá aquí"
          />
        ) : (
          <>
            <div className="space-y-3">
              {rides.map((ride) => (
                <div key={ride.id} className="card card-hover cursor-pointer" onClick={() => navigate(`/cliente/viaje/${ride.id}`)}>
                  <div className="flex items-center justify-between mb-2">
                    <div className="flex items-center gap-2">
                      <span className="badge-primary">{ride.category}</span>
                      {ride.tracking_code && (
                        <span className="text-[10px] font-mono font-bold text-primary-600 bg-primary-50 px-2 py-0.5 rounded">
                          {ride.tracking_code}
                        </span>
                      )}
                    </div>
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
                    <div className="flex items-center gap-1">
                      <span className="font-bold text-primary-600">${ride.final_fare_usd.toFixed(2)}</span>
                      <ChevronRight className="w-4 h-4 text-surface-300" />
                    </div>
                  </div>
                </div>
              ))}
            </div>

            <Pagination
              page={page}
              totalPages={totalPages}
              totalItems={totalItems}
              pageSize={PAGE_SIZE}
              onPageChange={setPage}
            />
          </>
        )}
      </div>
    </div>
  )
}