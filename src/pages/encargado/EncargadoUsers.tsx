import { useState, useEffect, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import { Users, Search, Loader2, MessageCircle, Receipt, Filter, MapPin } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { fmt, whatsappNumber } from '@/lib/format'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { EmptyState } from '@/components/ui/EmptyState'
import { SkeletonList } from '@/components/ui/Skeleton'
import { AppLogo } from '@/components/ui/AppLogo'

interface UserItem {
  id: string
  full_name: string
  email: string
  phone: string | null
  role: 'cliente' | 'conductor'
  driver_status: string | null
  is_online: boolean
  onboarding_completed: boolean
  created_at: string
  balance_usd: number
}

interface UsersResponse {
  total: number
  items: UserItem[]
}

const rolBadges: Record<string, { label: string; cls: string }> = {
  cliente: { label: 'Pasajero', cls: 'badge-success' },
  conductor: { label: 'Conductor', cls: 'badge-warning' }
}

const statusBadges: Record<string, { label: string; cls: string }> = {
  pendiente: { label: 'Pendiente', cls: 'badge-warning' },
  aprobado: { label: 'Aprobado', cls: 'badge-success' },
  rechazado: { label: 'Rechazado', cls: 'badge-danger' },
  suspendido: { label: 'Suspendido', cls: 'badge-danger' }
}

/**
 * Página de usuarios del ENCARGADO (solo lectura):
 * ve únicamente pasajeros y conductores de SU ciudad.
 * No hay botones para cambiar roles (eso es solo del super_admin).
 */
export function EncargadoUsers() {
  const { user } = useAuth()
  const navigate = useNavigate()
  const [items, setItems] = useState<UserItem[]>([])
  const [total, setTotal] = useState(0)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [page, setPage] = useState(0)
  const [pageSize] = useState(25)
  const [zoneName, setZoneName] = useState('')

  // Filtros del formulario (se aplican al pulsar "Buscar")
  const [searchInput, setSearchInput] = useState('')
  const [roleInput, setRoleInput] = useState('')
  // Filtros aplicados (los que usa la consulta)
  const [appliedSearch, setAppliedSearch] = useState('')
  const [appliedRole, setAppliedRole] = useState('')

  const load = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      const { data, error } = await supabase.rpc('get_admin_users', {
        p_search: appliedSearch.trim() || null,
        p_role: appliedRole || null,
        p_driver_status: null,
        p_limit: pageSize,
        p_offset: page * pageSize
      })
      if (error) throw error
      const res = data as UsersResponse
      setItems(res.items || [])
      setTotal(res.total || 0)
    } catch (err: any) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }, [appliedSearch, appliedRole, page, pageSize])

  useEffect(() => {
    load()
    if (user?.zone_id) {
      supabase
        .from('zones')
        .select('name')
        .eq('id', user.zone_id)
        .single()
        .then(({ data }) => { if (data) setZoneName(data.name) })
    }
  }, [load, user?.zone_id])

  const handleApply = () => {
    setPage(0)
    setAppliedSearch(searchInput)
    setAppliedRole(roleInput)
  }

  const totalPages = Math.max(1, Math.ceil(total / pageSize))

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-primary-600 border-b border-primary-700 px-6 py-4">
        <div className="flex items-center gap-3">
          <AppLogo variant="dark" />
          <div>
            <h1 className="text-lg font-bold text-white">Usuarios</h1>
            <p className="text-xs text-white/80 flex items-center gap-1">
              <MapPin className="w-3 h-3" /> {zoneName || 'Tu ciudad'}
            </p>
          </div>
        </div>
      </div>

      <div className="max-w-4xl mx-auto px-4 py-6">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        <div className="card p-4 space-y-3">
          <div className="grid grid-cols-1 md:grid-cols-4 gap-3">
            <div className="md:col-span-2">
              <label className="label">Buscar</label>
              <div className="relative">
                <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-surface-400" />
                <input
                  type="text"
                  className="input pl-9"
                  placeholder="Nombre, correo o teléfono..."
                  value={searchInput}
                  onChange={(e) => setSearchInput(e.target.value)}
                  onKeyDown={(e) => { if (e.key === 'Enter') handleApply() }}
                />
              </div>
            </div>
            <div>
              <label className="label">Rol</label>
              <select className="input" value={roleInput} onChange={(e) => setRoleInput(e.target.value)}>
                <option value="">Todos</option>
                <option value="cliente">Pasajeros</option>
                <option value="conductor">Conductores</option>
              </select>
            </div>
            <div className="flex items-end justify-between">
              <p className="text-xs text-surface-400">
                <Filter className="w-3 h-3 inline mr-1" />
                {total} usuarios
              </p>
              <button onClick={handleApply} className="btn-primary text-sm px-4 py-2" disabled={loading}>
                {loading ? <Loader2 className="w-4 h-4 animate-spin" /> : <><Search className="w-4 h-4" /> Buscar</>}
              </button>
            </div>
          </div>
        </div>

        {loading ? (
          <SkeletonList count={5} />
        ) : items.length === 0 ? (
          <EmptyState
            icon={<Users className="w-8 h-8" />}
            title="Sin usuarios"
            description="No hay usuarios que coincidan con los filtros"
          />
        ) : (
          <div className="card overflow-hidden">
            <div className="overflow-x-auto">
              <table className="w-full text-sm">
                <thead>
                  <tr className="bg-surface-50 text-left text-xs text-surface-500 uppercase">
                    <th className="px-4 py-3">Usuario</th>
                    <th className="px-4 py-3">Teléfono</th>
                    <th className="px-4 py-3">Rol</th>
                    <th className="px-4 py-3">Estado</th>
                    <th className="px-4 py-3">Saldo</th>
                    <th className="px-4 py-3 text-right">Acciones</th>
                  </tr>
                </thead>
                <tbody>
                  {items.map((u) => {
                    const wa = whatsappNumber(u.phone)
                    const rol = rolBadges[u.role]
                    const st = u.driver_status ? statusBadges[u.driver_status] : null
                    return (
                      <tr key={u.id} className="border-t border-surface-100 hover:bg-surface-50/50">
                        <td className="px-4 py-3">
                          <div className="flex items-center gap-2">
                            <div className="w-9 h-9 rounded-full bg-primary-50 flex items-center justify-center text-primary-600 font-semibold text-sm flex-shrink-0">
                              {(u.full_name || '?').charAt(0).toUpperCase()}
                            </div>
                            <div className="min-w-0">
                              <p className="font-medium text-surface-700 truncate max-w-[200px]">{u.full_name}</p>
                              <p className="text-xs text-surface-400 truncate max-w-[200px]">{u.email}</p>
                            </div>
                          </div>
                        </td>


                        <td className="px-4 py-3">
                          {u.phone ? (
                            <div className="flex items-center gap-2">
                              <span className="text-xs text-surface-600 whitespace-nowrap">{u.phone}</span>
                              {wa && (
                                <a
                                  href={`https://wa.me/${wa}`}
                                  target="_blank"
                                  rel="noopener noreferrer"
                                  title="Abrir WhatsApp"
                                  className="flex-shrink-0 w-7 h-7 rounded-full bg-emerald-500 text-white flex items-center justify-center hover:bg-emerald-600 transition-colors"
                                >
                                  <MessageCircle className="w-4 h-4" />
                                </a>
                              )}
                            </div>
                          ) : (
                            <span className="text-xs text-surface-400">—</span>
                          )}
                        </td>
                        <td className="px-4 py-3">
                          {rol ? <span className={rol.cls}>{rol.label}</span> : <span className="text-xs text-surface-400">{u.role}</span>}
                        </td>
                        <td className="px-4 py-3">
                          {st ? <span className={st.cls}>{st.label}</span> : <span className="text-xs text-surface-400">—</span>}
                        </td>
                        <td className="px-4 py-3">
                          <span className={`text-xs font-semibold ${u.balance_usd < 0 ? 'text-red-500' : 'text-surface-600'}`}>
                            {fmt(u.balance_usd)}
                          </span>
                        </td>
                        <td className="px-4 py-3 text-right">
                          <button
                            onClick={() => navigate(`/encargado/transacciones?usuario_id=${u.id}&usuario=${encodeURIComponent(u.full_name || '')}`)}
                            className="btn-outline text-xs px-3 py-1.5"
                            title="Ver transacciones"
                          >
                            <Receipt className="w-3.5 h-3.5" /> Transacciones
                          </button>
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
                Página {page + 1} de {totalPages} • {total} usuarios
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

