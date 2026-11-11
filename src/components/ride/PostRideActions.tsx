import type { RefObject } from 'react'
import { Star, Save, CheckCircle, ShieldAlert, AlertCircle, Home, Briefcase, Loader2, MapPin } from 'lucide-react'
import { RatingCard } from '@/components/ui/RatingCard'
import type { Ride, RideIncident } from '@/types/database'

interface PostRideActionsProps {
  ride: Ride
  incident: RideIncident | null
  /** El conductor marco completado y el cliente aun no confirma */
  needsCompletionConfirm: boolean
  loading: boolean
  favoriteSaved: boolean
  showSaveFavorite: boolean
  favoriteName: string
  /** Precisión GPS obtenida al guardar (metros), si se pudo leer */
  favoriteAccuracy?: number | null
  /** Aviso cuando el GPS falló y se usó el punto del viaje */
  favoriteWarning?: string
  ratingRef?: RefObject<HTMLDivElement>
  onConfirmCompletion: () => void
  onRateDriver: (rating: number, review: string) => Promise<void>
  onReportProblem: () => void
  onFavoriteNameChange: (value: string) => void
  onSaveFavorite: (name?: string) => void
}

/** Accesos rapidos para guardar el destino con un solo toque */
const QUICK_NAMES = [
  { name: 'Casa', Icon: Home },
  { name: 'Trabajo', Icon: Briefcase }
] as const

/**
 * Acciones al terminar el viaje, en orden de utilidad:
 *   1) Guardar destino (con chips de un toque)
 *   2) Calificar al conductor
 *   3) Reportar un problema (secundario)
 *
 * Va justo debajo de "Ver mapa del viaje" y antes de la ficha del conductor
 * para que no pase desapercibido.
 */
export function PostRideActions({
  ride,
  incident,
  needsCompletionConfirm,
  loading,
  favoriteSaved,
  showSaveFavorite,
  favoriteName,
  favoriteAccuracy,
  favoriteWarning,
  ratingRef,
  onConfirmCompletion,
  onRateDriver,
  onReportProblem,
  onFavoriteNameChange,
  onSaveFavorite
}: PostRideActionsProps) {
  return (
    <div ref={ratingRef} className="space-y-4">
      {/* Encabezado: deja claro que hay dos acciones utiles aqui */}
      <div className="rounded-2xl bg-gradient-to-br from-primary-600 to-primary-800 px-4 py-3 text-white">
        <p className="flex items-center gap-2 font-semibold">
          <CheckCircle className="w-5 h-5" /> Viaje completado
        </p>
        <p className="mt-0.5 text-xs text-white/80">Guarda el destino y califica a tu conductor</p>
      </div>

      {needsCompletionConfirm ? (
        <div className="card border-2 border-primary-100 bg-primary-50">
          <div className="mb-2 flex items-center gap-2">
            <CheckCircle className="w-5 h-5 text-primary-600" />
            <h3 className="font-semibold text-surface-800">El conductor completó el viaje</h3>
          </div>
          <p className="mb-4 text-sm text-surface-600">¿Confirmas que el viaje se realizó correctamente?</p>
          <div className="space-y-2">
            <button onClick={onConfirmCompletion} className="btn-success w-full" disabled={loading}>
              {loading
                ? <Loader2 className="w-4 h-4 animate-spin" />
                : <><CheckCircle className="w-4 h-4" /> Confirmar viaje</>}
            </button>
            <button
              onClick={onReportProblem}
              className="btn-outline w-full text-red-600 border-red-200 hover:border-red-300"
            >
              <ShieldAlert className="w-4 h-4" /> Reportar incidente
            </button>
          </div>
        </div>
      ) : (
        <>
          {/* 1) Guardar destino */}
          {showSaveFavorite && (
            <div className="card border-2 border-amber-200 bg-amber-50">
              <div className="mb-2 flex items-center gap-2">
                <Star className="w-5 h-5 text-amber-500" />
                <h3 className="font-semibold text-surface-800">Guardar destino</h3>
              </div>

              {favoriteSaved ? (
                <p className="flex items-center gap-1 text-sm font-medium text-emerald-700" aria-live="polite">
                  <CheckCircle className="w-4 h-4" /> Guardado en tus lugares
                  {typeof favoriteAccuracy === 'number' && favoriteAccuracy > 0
                    ? ` · precisión ±${favoriteAccuracy} m`
                    : ''}
                </p>
              ) : (
                <>
                  <p className="text-sm text-surface-600">
                    ¿Guardar <strong>{ride.destination_barrio_name || 'este destino'}</strong> para pedirlo más rápido?
                  </p>
                  {ride.destination_address && (
                    <p className="mt-0.5 truncate text-xs text-surface-500">{ride.destination_address}</p>
                  )}
                  <p className="mt-1.5 flex items-start gap-1 text-[11px] text-amber-800">
                    <MapPin className="w-3 h-3 flex-shrink-0 mt-0.5" />
                    Se guardará tu ubicación actual (donde estás ahora), no el punto del sector.
                  </p>
                  {favoriteWarning && (
                    <p className="mt-1 text-[11px] text-red-600">{favoriteWarning}</p>
                  )}

                  <div className="mt-3 flex flex-wrap gap-2">
                    {QUICK_NAMES.map(({ name, Icon }) => (
                      <button
                        key={name}
                        type="button"
                        onClick={() => onSaveFavorite(name)}
                        disabled={loading}
                        className="inline-flex items-center gap-1.5 rounded-full border-2 border-amber-300 bg-white px-3 py-1.5 text-sm font-semibold text-amber-700 transition-colors hover:bg-amber-100 disabled:opacity-50"
                        aria-label={`Guardar destino como ${name}`}
                      >
                        <Icon className="w-4 h-4" /> {name}
                      </button>
                    ))}
                  </div>

                  <div className="mt-3 flex gap-2">
                    <input
                      type="text"
                      className="input flex-1"
                      placeholder="Otro nombre (ej. Taller)"
                      value={favoriteName}
                      onChange={(e) => onFavoriteNameChange(e.target.value)}
                      aria-label="Nombre del lugar"
                    />
                    <button
                      onClick={() => onSaveFavorite()}
                      className="btn-primary"
                      disabled={loading || !favoriteName.trim()}
                    >
                      {loading ? <Loader2 className="w-4 h-4 animate-spin" /> : <Save className="w-4 h-4" />}
                      Guardar
                    </button>
                  </div>
                </>
              )}
            </div>
          )}

          {/* 2) Calificar al conductor */}
          <RatingCard
            title="Califica a tu conductor"
            subtitle="Tu opinión ayuda a mejorar el servicio"
            onSubmit={onRateDriver}
            alreadyRated={ride.rating}
            alreadyReviewed={ride.review}
          />

          {/* Disputa en revision */}
          {ride.incident_id && incident &&
            (incident.status === 'abierto' || incident.status === 'en_revision') && (
            <div className="flex items-start gap-3 rounded-xl border border-amber-200 bg-amber-50 p-4">
              <AlertCircle className="w-5 h-5 flex-shrink-0 text-amber-600" />
              <div>
                <h3 className="font-semibold text-amber-700">Disputa en revisión</h3>
                <p className="mt-1 text-sm text-amber-600">
                  Reportaste un problema con este viaje. La plataforma lo está revisando
                  y se te notificará la resolución.
                </p>
              </div>
            </div>
          )}

          {/* 3) Reportar problema (secundario) */}
          {!ride.incident_id && (
            <button
              onClick={onReportProblem}
              className="btn-outline w-full text-red-600 border-red-200 hover:border-red-300"
            >
              <AlertCircle className="w-4 h-4" /> Reportar un problema con el viaje
            </button>
          )}
        </>
      )}
    </div>
  )
}