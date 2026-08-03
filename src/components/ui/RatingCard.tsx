import { useState } from 'react'
import { Star, Loader2, Send } from 'lucide-react'
import { RatingStars } from './RatingStars'

interface RatingCardProps {
  title: string
  subtitle?: string
  onSubmit: (rating: number, review: string) => Promise<void>
  alreadyRated?: number
  alreadyReviewed?: string
}

export function RatingCard({ title, subtitle, onSubmit, alreadyRated, alreadyReviewed }: RatingCardProps) {
  const [rating, setRating] = useState(alreadyRated || 0)
  const [review, setReview] = useState(alreadyReviewed || '')
  const [saving, setSaving] = useState(false)
  const [done, setDone] = useState(!!alreadyRated)

  const handleSubmit = async () => {
    if (rating === 0) return
    setSaving(true)
    try {
      await onSubmit(rating, review)
      setDone(true)
    } catch (e) {
      console.error(e)
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="card bg-primary-50 border-primary-200">
      <div className="flex items-center gap-2 mb-2">
        <Star className="w-5 h-5 text-amber-400 fill-current" />
        <h3 className="font-semibold text-surface-800">{title}</h3>
      </div>
      {subtitle && <p className="text-sm text-surface-600 mb-3">{subtitle}</p>}

      {done ? (
        <div className="text-center py-3">
          <p className="text-sm text-emerald-700 font-medium">✅ ¡Gracias por tu calificación!</p>
          {alreadyRated && (
            <div className="flex justify-center mt-2">
              <RatingStars value={alreadyRated} onChange={() => {}} disabled size="md" />
            </div>
          )}
        </div>
      ) : (
        <div className="space-y-3">
          <div className="flex justify-center py-2">
            <RatingStars value={rating} onChange={setRating} />
          </div>
          <textarea
            className="input min-h-[70px]"
            placeholder="Comentario opcional (ej: Excelente servicio, muy puntual)"
            value={review}
            onChange={(e) => setReview(e.target.value)}
          />
          <button
            onClick={handleSubmit}
            className="btn-primary w-full"
            disabled={saving || rating === 0}
          >
            {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : <><Send className="w-4 h-4" /> Enviar calificación</>}
          </button>
        </div>
      )}
    </div>
  )
}