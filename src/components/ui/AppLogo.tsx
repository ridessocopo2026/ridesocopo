interface AppLogoProps {
  size?: 'sm' | 'md' | 'lg' | 'xl'
  className?: string
  rounded?: string
  /** 'light' = logo a color (para fondos claros/blancos) | 'dark' = logo blanco (para fondos oscuros) */
  variant?: 'light' | 'dark'
}

const sizeClasses = {
  sm: 'w-8 h-8',
  md: 'w-10 h-10',
  lg: 'w-16 h-16',
  xl: 'w-20 h-20'
}

const logoSources = {
  light: '/icons/logo-morado.png', // logo morado (transparente) para fondos blancos
  dark: '/icons/logo-blanco.png'   // logo blanco (transparente) para fondos morados
}

/**
 * Logo oficial de RideSocopó.
 * Usa la variante 'light' (logo a color) en fondos blancos y
 * 'dark' (logo blanco) en fondos oscuros (ej: pantalla de bienvenida).
 */
export function AppLogo({ size = 'md', className = '', rounded = 'rounded-xl', variant = 'light' }: AppLogoProps) {
  return (
    <img
      src={logoSources[variant]}
      alt="RideSocopó"
      className={`${sizeClasses[size]} ${rounded} object-contain flex-shrink-0 ${className}`}
    />
  )
}
