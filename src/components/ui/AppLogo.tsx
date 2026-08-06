interface AppLogoProps {
  size?: 'sm' | 'md' | 'lg' | 'xl'
  className?: string
  rounded?: string
}

const sizeClasses = {
  sm: 'w-8 h-8',
  md: 'w-10 h-10',
  lg: 'w-16 h-16',
  xl: 'w-20 h-20'
}

/**
 * Logo oficial de RideSocopó (PNG transparente).
 * Se usa en encabezados y en la pantalla de bienvenida.
 */
export function AppLogo({ size = 'md', className = '', rounded = 'rounded-xl' }: AppLogoProps) {
  return (
    <img
      src="/icons/icon-192x192.png"
      alt="RideSocopó"
      className={`${sizeClasses[size]} ${rounded} object-contain flex-shrink-0 ${className}`}
    />
  )
}
