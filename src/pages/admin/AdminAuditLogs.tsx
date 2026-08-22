import { useState, useEffect, useCallback } from 'react'
import { ScrollText, Loader2, Filter, ChevronDown, ChevronUp } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { EmptyState } from '@/components/ui/EmptyState'
import { SkeletonList } from '@/components/ui/Skeleton'
import { AppLogo } from '@/components/ui/AppLogo'

interface AuditItem {
  id: string
  action: string
  entity_type: string | null
  entity_id: string | null
  details: Record<string, unknown> | null
  fecha: string
  usuario: string | null
  usuario_email: string | null
}

interface AuditResponse {
  total: number
  items: AuditItem[]
}

const actionLabels: Record<string, string> = {
  SET_USER_ROLE: 'Cambio de rol',
  APPROVE_RIDE_PROOF: 'Comprobante de viaje',
  APPROVE_RECHARGE: 'Recarga de billetera',
  SET_ZONE_SUPPORT: 'Soporte de ciudad',
  REVIEW_DRIVER: 'Revisión de conductor',
  RESOLVE_INCIDENT: 'Resolución de incidente',
  PROMOTE_SUPER_ADMIN: 'Promoción a admin',
  REQUEST_RIDE: 'Solicitud de viaje',
  REQUEST_RIDE_WITH_PROOF: 'Viaje con comprobante',
  ACCEPT_RIDE: 'Viaje aceptado',
  RIDE_STARTED: 'Viaje iniciado',
  CONFIRM_RIDE_COMPLETION: 'Viaje completado',
  CANCEL_RIDE: 'Viaje cancelado',
  SEND_BROADCAST: 'Notificación masiva',
  CLEANUP_OLD_DATA: 'Limpieza de datos',
  SAVE_LEGAL_PAGE: 'Página legal'
}

// Acciones sensibles (rol/dinero) resaltadas para el admin
const sensitiveActions = new Set([
  'SET_USER_ROLE',
  'APPROVE_RIDE_PROOF',
  'APPROVE_RECHARGE',
  'REVIEW_DRIVER',
  'RESOLVE_INCIDENT',
  'PROMOTE_SUPER_ADMIN',
  'SEND_BROADCAST'
])

export function AdminAuditLogs() {
  const [items, setItems] = useState<AuditItem[]>([])
  const [total, setTotal] = useState(0)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [page, setPage] = useState(0)
  const [pageSize] = useState(25)
  const [expanded, setExpanded] = useState<Set<string>>(new Set())

  // Filtro por acción
  const [actionInput, setActionInput] = useState('')
  const [appliedAction, setAppliedAction] = useState('')

  const load = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      const { data, error } = await supabase.rpc('get_audit_logs', {
        p_action: appliedAction || null,
        p_user_id: null,
        p_fecha_desde: null,
        p_fecha_hasta: null,
        p_limit: pageSize,
        p_offset: page * pageSize
      })
      if (error) throw error
      const res = data as AuditResponse
      setItems(res.items || [])
      setTotal(res.total || 0)
    } catch (err: any) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }, [appliedAction, page, pageSize])

  useEffect(() => {
    load()
  }, [load])

  const handleApply = () => {
    setPage(0)
    setAppliedAction(actionInput)
  }

  const totalPages = Math.max(1, Math.ceil(total / pageSize))

  const toggleDetail = (id: string) => {
    setExpanded((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center gap-3">
          <AppLogo />
          <div>
            <h1 className="text-lg font-bold text-surface-800">Auditoría</h1>
            <p className="text-xs text-surface-500">Registro de acciones sensibles del sistema</p>
          </div>
        </div>
      </div>

      <div className="max-w-4xl mx-auto px-4 py-6">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        <div className="card p-4 space-y-3">
          <div className="grid grid-cols-1 md:grid-cols-3 gap-3">
            <div>
              <label className="label">Acción</label>
              <select className="input" value={actionInput} onChange={(e) => setActionInput(e.target.value)}>
                <option value="">Todas</option>
                {Object.entries(actionLabels).map(([key, label]) => (
                  <option key={key} value={key}>{label}</option>
                ))}
              </select>
            </div>
            <div className="md:col-span-2 flex items-end justify-between">
              <p className="text-xs text-surface-400">
                <Filter className="w-3 h-3 inline mr-1" />
                {total} registros
              </p>
              <button onClick={handleApply} className="btn-primary text-sm px-4 py-2" disabled={loading}>
                {loading ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Filtrar'}
              </button>
            </div>
          </div>
        </div>

        {loading ? (
          <SkeletonList count={5} />
        ) : items.length === 0 ? (
          <EmptyState
            icon={<ScrollText className="w-8 h-8" />}
            title="Sin registros"
            description="No hay registros que coincidan con el filtro"
          />
        ) : (
          <div className="card overflow-hidden">
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="bg-surface-50 text-left text-xs text-surface-500 uppercase">
                    <th className="px-4 py-3">Fecha</th>
                    <th className="px-4 py-3">Quién</th>
                    <th className="px-4 py-3">Acción</th>
                    <th className="px-4 py-3">Detalle</th>
                  </tr>
                </thead>
                <tbody>
                  {items.map((a) => {
                    const isSensitive = sensitiveActions.has(a.action)
                    const isOpen = expanded.has(a.id)
                    return (
                      <tr key={a.id} className="border-t border-surface-100 hover:bg-surface-50/50 align-top">
                        <td className="px-4 py-3 whitespace-nowrap text-xs text-surface-500">
                          {new Date(a.fecha).toLocaleString('es-VE', {
                            day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit'
                          })}
                        </td>
                        <td className="px-4 py-3">
                          <p className="font-medium text-surface-700 text-xs">{a.usuario || 'Sistema'}</p>
                          {a.usuario_email && <p className="text-[10px] text-surface-400">{a.usuario_email}</p>}
                        </td>
                        <td className="px-4 py-3">
                          <span className={`text-xs px-2 py-1 rounded-full ${isSensitive ? 'badge-danger' : 'badge-info'}`}>
                            {actionLabels[a.action] || a.action}
                          </span>
                        </td>
                        <td className="px-4 py-3">
                          <button
                            onClick={() => toggleDetail(a.id)}
                            className="btn-outline text-xs px-2 py-1"
                            title={isOpen ? 'Ocultar detalle' : 'Ver detalle'}
                          >
                            {isOpen ? <ChevronUp className="w-3.5 h-3.5" /> : <ChevronDown className="w-3.5 h-3.5" />}
                            {isOpen ? ' Ocultar' : ' Ver'}
                          </button>
                          {isOpen && (
                            <pre className="mt-2 text-[10px] bg-surface-50 rounded-lg p-2 text-surface-600 overflow-x-auto whitespace-pre-wrap break-words max-w-[320px]">
                              {JSON.stringify(a.details ?? {}, null, 2)}
                            </pre>
                          )}
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>

            <div className="flex items-center justify-between px-4 py-3 border-t border-surface-100">
              <button
                className="btn-outline text-xs px-3 py-1.5"
                disabled={page === 0}
                onClick={() => setPage(page - 1)}
              >
                ← Anterior
              </button>
              <span className="text-xs text-surface-500">
                Página {page + 1} de {totalPages} • {total} registros
              </span>
              <button
                className="btn-outline text-xs px-3 py-1.5"
                disabled={page + 1 >= totalPages}
                onClick={() => setPage(page + 1)}
              >
                Siguiente →
              </button>
            </div>
          </div>
        )}
      </div>
    </div>
  )
}

