import { useState, useEffect } from 'react'
import { MapContainer, TileLayer, Marker, Popup } from 'react-leaflet'
import L from 'leaflet'
import { Image, Check, X, Loader2, ExternalLink, MapPin } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { EmptyState } from '@/components/ui/EmptyState'
import { SkeletonList } from '@/components/ui/Skeleton'
import type { Ride } from '@/types/database'

const clientIcon = L.divIcon({
  className: 'custom-div-icon',
  html: `<div class="w-8 h-8 bg-accent-600 rounded-full border-4 border-white shadow-lg flex items-center justify-center">
    <svg class="w-4 h-4 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M16 7a4 4 0 11-8 0 4 4 0 018 0zM12 14a7 7 0 00-7 7h14a7 7 0 00-7-7z"/>
    </svg>
  </div>`,
  iconSize: [32, 32],
  iconAnchor: [16, 32]
})

export function AdminProofs() {
  const [proofs, setProofs] = useState<Ride[]>([])
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [actionLoading, setActionLoading] = useState<string | null>(null)
  const { user } = useAuth()

  useEffect(() => {
    loadProofs()
  }, [])

  const loadProofs = async () => {
    const { data, error } = await supabase.rpc('get_pending_proofs')
    if (!error && data) {
      setProofs(data as Ride[])
    }
    setLoading(false)
  }

  const handleReview = async (rideId: string, approve: boolean) => {
    setError('')
    setActionLoading(rideId)

    try {
      const { error } = await supabase.rpc('approve_ride_proof', {
        p_ride_id: rideId,
        p_approve: approve
      })
      if (error) throw error
      setProofs(proofs.filter(p => p.id !== rideId))
    } catch (err: any) {
      setError(err.message)
    } finally {
      setActionLoading(null)
    }
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 bg-primary-600 rounded-xl flex items-center justify-center">
            <Image className="w-5 h-5 text-white" />
          </div>
          <div>
            <h1 className="text-lg font-bold text-surface-800">Comprobantes pendientes</h1>
            <p className="text-xs text-surface-500">Aprobar o rechazar pagos de viajes</p>
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        {loading ? (
          <SkeletonList count={3} />
        ) : proofs.length === 0 ? (
          <EmptyState
            icon={<Image className="w-8 h-8" />}
            title="Sin comprobantes pendientes"
            description="Los comprobantes de pago aparecerán aquí cuando los clientes suban capturas"
          />
        ) : (
          <div className="space-y-3">
            {proofs.map((ride) => (
              <div key={ride.id} className="card">
                <div className="flex items-center justify-between mb-3">
                  <span className="badge-warning">Pendiente</span>
                  <span className="text-sm text-surface-500">
                    #{ride.id.slice(0, 8).toUpperCase()}
                  </span>
                </div>

                <p className="text-sm text-surface-600 mb-2">
                  <strong>Origen:</strong> {ride.origin_address || '—'}
                </p>
                <p className="text-sm text-surface-600 mb-2">
                  <strong>Destino:</strong> {ride.destination_address || '—'}
                </p>
                {ride.destination_barrio_name && (
                  <p className="text-sm text-surface-600 mb-2">
                    <strong>Barrio / Sitio de llegada:</strong>{' '}
                    <span className="badge-primary">{ride.destination_barrio_name}</span>
                  </p>
                )}
                <p className="text-sm text-surface-600 mb-2">
                  <strong>Monto:</strong> {ride.final_fare_usd.toFixed(2)}$
                </p>
                <p className="text-sm text-surface-600 mb-3">
                  <strong>Método:</strong> {ride.payment_method}
                </p>

                {/* Mapa con ubicación del cliente */}
                <div className="h-40 rounded-xl overflow-hidden shadow-soft mb-3 relative">
                  <MapContainer
                    center={[ride.origin_lat, ride.origin_lng]}
                    zoom={15}
                    className="h-full w-full"
                  >
                    <TileLayer
                      url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
                      attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
                    />
                    <Marker position={[ride.origin_lat, ride.origin_lng]} icon={clientIcon}>
                      <Popup>Cliente</Popup>
                    </Marker>
                  </MapContainer>
                  <div className="absolute top-2 left-2 bg-white/90 rounded-lg px-2 py-1 text-[10px] text-surface-600 z-[1000]">
                    <MapPin className="w-3 h-3 inline mr-1" />
                    Ubicación del cliente (GPS)
                  </div>
                </div>

                {ride.proof_url && (
                  <a
                    href={ride.proof_url}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="inline-flex items-center gap-1 text-primary-600 text-sm mb-3 hover:underline"
                  >
                    <ExternalLink className="w-4 h-4" />
                    Ver comprobante
                  </a>
                )}

                <div className="flex gap-2">
                  <button
                    onClick={() => handleReview(ride.id, true)}
                    className="btn-success flex-1"
                    disabled={actionLoading === ride.id}
                  >
                    {actionLoading === ride.id ? <Loader2 className="w-4 h-4 animate-spin" /> : <><Check className="w-4 h-4" /> Aprobar</>}
                  </button>
                  <button
                    onClick={() => handleReview(ride.id, false)}
                    className="btn-danger flex-1"
                    disabled={actionLoading === ride.id}
                  >
                    <X className="w-4 h-4" />
                    Rechazar
                  </button>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}