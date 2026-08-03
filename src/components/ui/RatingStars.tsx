import { Star } from 'lucide-react'

interface RatingStarsProps {
  value: number
  onChange: (value: number) => void
  disabled?: boolean
  size?: 'sm' | 'md' | 'lg'
}

export function RatingStars({ value, onChange, disabled = false, size = 'lg' }: RatingStarsProps) {
  const sizes = {
    sm: 'w-5 h-5',
    md: 'w-7 h-7',
    lg: 'w-9 h-9'
  }

  return (
    <div className="flex items-center gap-1">
      {[1, 2, 3, 4, 5].map((star) => (
        <button
          key={star}
          type="button"
          disabled={disabled}
          onClick={() => onChange(star)}
          className={`transition-all ${disabled ? 'cursor-default' : 'cursor-pointer hover:scale-110'} ${star <= value ? 'text-amber-400' : 'text-surface-200'}`}
          aria-label={`${star} estrellas`}
        >
          <Star className={`${sizes[size]} ${star <= value ? 'fill-current' : ''}`} />
        </button>
      ))}
    </div>
  )
}