import { ClipboardList } from 'lucide-react'
import { useNavigate } from 'react-router-dom'

/** Boton para que el conductor complete/actualice sus documentos y vehiculo. */
export function CompleteDocsButton() {
  const navigate = useNavigate()
  return (
    <button
      type="button"
      onClick={() => navigate('/conductor/onboarding')}
      className="card w-full flex items-center gap-3 p-4 text-left hover:border-primary-300 transition-colors"
    >
      <div className="w-10 h-10 bg-amber-50 rounded-full flex items-center justify-center flex-shrink-0">
        <ClipboardList className="w-5 h-5 text-amber-600" />
      </div>
      <div className="flex-1 min-w-0">
        <p className="font-medium text-surface-700">Completar mis datos</p>
        <p className="text-xs text-surface-400">Documentos y vehículo del conductor</p>
      </div>
    </button>
  )
}