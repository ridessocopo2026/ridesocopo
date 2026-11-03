import { useState } from 'react'
import { Car, Check, Copy, Phone, User, Megaphone } from 'lucide-react'
import { WhatsAppIcon } from '@/components/ui/WhatsAppIcon'
import { whatsappLink } from '@/lib/format'

/** Persona involucrada que se muestra en la tarjeta de contactos. */
export interface IncidentPerson {
  /** Identificador único para el estado de "copiado" */
  key: string
  /** Etiqueta visible: Cliente, Conductor, Reportó... */
  label: string
  name?: string | null
  phone?: string | null
  /** Nota corta, por ejemplo "Reportó este incidente" */
  note?: string
  kind: 'cliente' | 'conductor' | 'soporte'
  /** true = es quien reportó el incidente (se resalta el icono) */
  isReporter?: boolean
}

const kindIcon = {
  cliente: User,
  conductor: Car,
  soporte: Megaphone
} as const

const kindStyles = {
  cliente: 'bg-accent-50 text-accent-600',
  conductor: 'bg-primary-50 text-primary-600',
  soporte: 'bg-surface-100 text-surface-600'
} as const

/**
 * Bloque "Involucrados" del panel de incidentes.
 *
 * Objetivo: que el administrador vea de un vistazo QUIÉN está en el
 * incidente y pueda llamarlo o escribirle por WhatsApp en un toque, sin
 * buscar en otras pantallas. El mensaje de WhatsApp se abre precargado
 * con el código del viaje para resolver el caso más rápido.
 *
 * Coste: 0 requests (los datos ya vienen en la RPC `get_admin_incidents`).
 */
export function IncidentContacts({
  people,
  message,
  compact = false,
  className = ''
}: {
  people: IncidentPerson[]
  /** Texto precargado de WhatsApp; recibe la persona */
  message: (person: IncidentPerson) => string
  /** Versión resumida para las tarjetas de la lista */
  compact?: boolean
  className?: string
}) {
  const [copied, setCopied] = useState<string | null>(null)

  if (people.length === 0) return null

  const handleCopy = async (person: IncidentPerson) => {
    if (!person.phone) return
    try {
      await navigator.clipboard.writeText(person.phone)
      setCopied(person.key)
      window.setTimeout(() => setCopied(null), 1500)
    } catch {
      // Sin permiso de portapapeles: no pasa nada, el número ya está visible
    }
  }

  return (
    <div className={className}>
      {!compact && (
        <p className="text-[10px] font-semibold uppercase tracking-wide text-surface-400 mb-1.5">
          Involucrados
        </p>
      )}
      <div className="space-y-2">
        {people.map((person) => {
          const Icon = kindIcon[person.kind]
          const wa = whatsappLink(person.phone, message(person))
          const isCopied = copied === person.key

          return (
            <div
              key={person.key}
              className="flex items-center gap-2.5 rounded-lg border border-surface-200 bg-white p-2.5"
            >
              <div className={`w-8 h-8 rounded-full flex items-center justify-center flex-shrink-0 ${kindStyles[person.kind]}`}>
                <Icon className="w-4 h-4" />
              </div>

              <div className="min-w-0 flex-1">
                <p className="text-[10px] uppercase tracking-wide text-surface-400">
                  {person.label}
                  {person.note && <span className="text-primary-600 normal-case"> · {person.note}</span>}
                </p>
                <p className="text-sm font-semibold text-surface-800 truncate">
                  {person.name || 'Sin nombre registrado'}
                </p>
                {person.phone ? (
                  <a
                    href={`tel:${person.phone}`}
                    className="text-xs text-surface-500 hover:text-primary-600 font-mono"
                  >
                    {person.phone}
                  </a>
                ) : (
                  <p className="text-xs text-amber-600">
                    Sin teléfono registrado · contactar por soporte
                  </p>
                )}
              </div>

              <div className="flex items-center gap-1.5 shrink-0">
                {person.phone && (
                  <a
                    href={`tel:${person.phone}`}
                    className="w-8 h-8 rounded-full bg-primary-50 text-primary-600 flex items-center justify-center"
                    aria-label={`Llamar a ${person.label.toLowerCase()}${person.name ? ` ${person.name}` : ''}`}
                    title="Llamar"
                  >
                    <Phone className="w-4 h-4" />
                  </a>
                )}
                {wa && (
                  <a
                    href={wa}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="h-8 px-2.5 rounded-full bg-emerald-50 text-emerald-600 flex items-center justify-center gap-1"
                    aria-label={`Escribir por WhatsApp a ${person.label.toLowerCase()}${person.name ? ` ${person.name}` : ''}`}
                    title="WhatsApp con mensaje listo"
                  >
                    <WhatsAppIcon className="w-4 h-4" />
                    {!compact && <span className="text-xs font-semibold">WhatsApp</span>}
                  </a>
                )}
                {person.phone && !compact && (
                  <button
                    type="button"
                    onClick={() => handleCopy(person)}
                    className="w-8 h-8 rounded-full bg-surface-100 text-surface-500 flex items-center justify-center hover:bg-surface-200"
                    aria-label="Copiar número"
                    title={isCopied ? 'Copiado' : 'Copiar número'}
                  >
                    {isCopied ? <Check className="w-4 h-4 text-emerald-600" /> : <Copy className="w-4 h-4" />}
                  </button>
                )}
              </div>
            </div>
          )
        })}
      </div>
    </div>
  )
}
