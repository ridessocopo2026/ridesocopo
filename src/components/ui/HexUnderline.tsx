interface HexUnderlineProps {
  className?: string
}

export function HexUnderline({ className = '' }: HexUnderlineProps) {
  return (
    <div className={`hex-underline ${className}`}>
      <div className="hex-node" />
    </div>
  )
}