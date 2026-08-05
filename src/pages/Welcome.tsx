import { Link } from 'react-router-dom'
import { Hexagon, User, CarFront, ChevronRight, ShieldCheck, Clock, MapPin } from 'lucide-react'

export function Welcome() {
  return (
    <div className="min-h-screen bg-gradient-to-b from-primary-700 via-primary-600 to-accent-600 flex flex-col">
      {/* Header */}
      <div className="pt-12 pb-8 flex flex-col items-center">
        <div className="w-20 h-20 bg-white/15 backdrop-blur rounded-3xl flex items-center justify-center mb-4 shadow-elevated border border-white/20">
          <Hexagon className="w-10 h-10 text-white" />
        </div>
        <h1 className="text-3xl font-bold text-white text-center">RideSocopó</h1>
        <p className="text-white/80 text-sm mt-2 text-center px-8">
          Transporte de pasajeros en Socopó, Barinas
        </p>
      </div>

      {/* Content */}
      <div className="flex-1 flex flex-col items-center justify-center px-6">
        <h2 className="text-white text-xl font-semibold text-center mb-2">
          ¿Cómo quieres usar RideSocopó?
        </h2>
        <p className="text-white/70 text-sm text-center mb-8">
          Elige tu rol para continuar
        </p>

        <div className="w-full max-w-sm space-y-4">
          {/* Pasajero */}
          <Link
            to="/cliente"
            className="group block w-full bg-white rounded-3xl p-6 shadow-elevated hover:shadow-2xl transition-all duration-300 hover:-translate-y-1"
          >
            <div className="flex items-center gap-4">
              <div className="w-16 h-16 bg-primary-50 rounded-2xl flex items-center justify-center flex-shrink-0">
                <User className="w-8 h-8 text-primary-600" />
              </div>
              <div className="flex-1">
                <h3 className="text-lg font-bold text-surface-800">Soy Pasajero</h3>
                <p className="text-sm text-surface-500 mt-0.5">Quiero pedir un viaje</p>
              </div>
              <ChevronRight className="w-5 h-5 text-surface-300 group-hover:text-primary-500 group-hover:translate-x-1 transition-all" />
            </div>
          </Link>

          {/* Conductor */}
          <Link
            to="/login"
            className="group block w-full bg-white rounded-3xl p-6 shadow-elevated hover:shadow-2xl transition-all duration-300 hover:-translate-y-1"
          >
            <div className="flex items-center gap-4">
              <div className="w-16 h-16 bg-accent-50 rounded-2xl flex items-center justify-center flex-shrink-0">
                <CarFront className="w-8 h-8 text-accent-600" />
              </div>
              <div className="flex-1">
                <h3 className="text-lg font-bold text-surface-800">Soy Conductor</h3>
                <p className="text-sm text-surface-500 mt-0.5">Quiero conducir y ganar</p>
              </div>
              <ChevronRight className="w-5 h-5 text-surface-300 group-hover:text-accent-500 group-hover:translate-x-1 transition-all" />
            </div>
          </Link>
        </div>

        {/* Acceso a cuenta existente */}
        <p className="text-white/90 text-sm mt-8 text-center">
          ¿Ya tienes cuenta?{' '}
          <Link to="/login" className="font-semibold underline underline-offset-4 hover:text-white transition-colors">
            Inicia sesión
          </Link>{' '}
          o{' '}
          <Link to="/registro" className="font-semibold underline underline-offset-4 hover:text-white transition-colors">
            Regístrate
          </Link>
        </p>
      </div>

      {/* Features footer */}
      <div className="pb-10 pt-8">
        <div className="flex items-center justify-center gap-6 text-white/80 text-xs">
          <div className="flex items-center gap-1.5">
            <ShieldCheck className="w-4 h-4" />
            <span>Seguro</span>
          </div>
          <div className="flex items-center gap-1.5">
            <Clock className="w-4 h-4" />
            <span>Rápido</span>
          </div>
          <div className="flex items-center gap-1.5">
            <MapPin className="w-4 h-4" />
            <span>Socopó</span>
          </div>
        </div>
      </div>
    </div>
  )
}