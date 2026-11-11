import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { History, Star, ChevronRight, MapPin } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { EmptyState } from '@/components/ui/EmptyState'
import { SkeletonList } from '@/components/ui/Skeleton'
import { HexUnderline } from '@/components/ui/HexUnderline'
import { Pagination } from '@/components/ui/Pagination'
import type { Ride } from '@/types/database'
import { AppLogo } from '@/components/ui/AppLogo'
import { ExactLocationModal } from '@/components/ride/ExactLocationModal'

const PAGE_SIZE = 10

export function ClientHistory() {
  const [rides, setRides] = useState<Ride[]>([])
  const [loading, setLoading] = useState(true)
  const [page, setPage] = useState(1)
  const [totalItems, setTotalItems] = useState(0)
  // Viaje al que se le va a fijar el punto exacto con el GPS actual
  const [exactRide, setExactRide] = useState<Ride | null>(null)
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
      .select('id, category, tracking_code, status, origin_address, destination_address, destination_barrio_name, destination_is_exact, completed_at, created_at, rating, final_fare_usd')
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
      <div className="bg-primary-600 border-b border-primary-700 px-6 py-4">
        <div className="flex items-center gap-3">
          <AppLogo variant="dark" />
          <div>
            <h1 className="text-lg font-bold text-white">Historial de viajes</h1>
            <p className="text-xs text-white/80">Tus viajes anteriores</p>
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
                      <span className="font-bold text-primary-600">{ride.final_fare_usd.toFixed(2)}$</span>
                      <ChevronRight className="w-4 h-4 text-surface-300" />
                    </div>
                  </div>

                  {ride.status === 'completada' && !ride.destination_is_exact && (
                    <button
                      type="button"
                      onClick={(e) => {
                        e.stopPropagation()
                        setExactRide(ride)
                      }}
                      className="mt-3 flex w-full items-center justify-center gap-2 rounded-xl border-2 border-dashed border-primary-300 py-2 text-xs font-semibold text-primary-700 transition-colors hover:bg-primary-50"
                    >
                      <MapPin className="h-4 w-4" /> Fijar ubicación exacta
                    </button>
                  )}
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

        {exactRide && (
          <ExactLocationModal
            ride={exactRide}
            onClose={() => setExactRide(null)}
            onSaved={(id) =>
              setRides((prev) => prev.map((r) => (r.id === id ? { ...r, destination_is_exact: true } : r)))
            }
          />
        )}
      </div>
    </div>
  )
}