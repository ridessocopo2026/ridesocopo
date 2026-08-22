import { useState, useEffect, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import { Users, Search, Loader2, MessageCircle, Receipt, Filter } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { fmt, whatsappNumber } from '@/lib/format'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { EmptyState } from '@/components/ui/EmptyState'
import { SkeletonList } from '@/components/ui/Skeleton'
import { AppLogo } from '@/components/ui/AppLogo'

interface AdminUserItem {
  id: string
  full_name: string
  email: string
  phone: string | null
  role: 'cliente' | 'conductor' | 'encargado' | 'super_admin'
  driver_status: string | null
  is_online: boolean
  onboarding_completed: boolean
  created_at: string
  balance_usd: number
}

interface AdminUsersResponse {
  total: number
  items: AdminUserItem[]
}

const rolBadges: Record<string, { label: string; cls: string }> = {
  cliente: { label: 'Pasajero', cls: 'badge-success' },
  conductor: { label: 'Conductor', cls: 'badge-warning' },
  super_admin: { label: 'Admin', cls: 'badge-danger' },
  encargado: { label: 'Encargado', cls: 'badge-info' }
}

const statusBadges: Record<string, { label: string; cls: string }> = {
  pendiente: { label: 'Pendiente', cls: 'badge-warning' },
  aprobado: { label: 'Aprobado', cls: 'badge-success' },
  rechazado: { label: 'Rechazado', cls: 'badge-danger' },
  suspendido: { label: 'Suspendido', cls: 'badge-danger' }
}

export function AdminUsers() {
  const [items, setItems] = useState<AdminUserItem[]>([])
  const [total, setTotal] = useState(0)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [page, setPage] = useState(0)
  const [pageSize] = useState(25)

  // Filtros del formulario (se aplican al pulsar "Buscar")
  const [searchInput, setSearchInput] = useState('')
  const [roleInput, setRoleInput] = useState('')
  const [statusInput, setStatusInput] = useState('')
  // Filtros aplicados (los que usa la consulta)
  const [appliedSearch, setAppliedSearch] = useState('')
  const [appliedRole, setAppliedRole] = useState('')
  const [appliedStatus, setAppliedStatus] = useState('')
  const [roleTarget, setRoleTarget] = useState<AdminUserItem | null>(null)
  const [roleZone, setRoleZone] = useState('')
  const [roleSaving, setRoleSaving] = useState(false)
  const [cities, setCities] = useState<{ id: string; name: string }[]>([])

  const navigate = useNavigate()

  const loadCities = async () => {
    const { data } = await supabase.rpc('get_active_cities')
    if (data) setCities(data as { id: string; name: string }[])
  }

  const load = useCallback(async () => {
    setLoading(true)
    setError('')
    try {
      const { data, error } = await supabase.rpc('get_admin_users', {
        p_search: appliedSearch.trim() || null,
        p_role: appliedRole || null,
        p_driver_status: appliedStatus || null,
        p_limit: pageSize,
        p_offset: page * pageSize
      })
      if (error) throw error
      const res = data as AdminUsersResponse
      setItems(res.items || [])
      setTotal(res.total || 0)
    } catch (err: any) {
      setError(err.message)
    } finally {
      setLoading(false)
    }
  }, [appliedSearch, appliedRole, appliedStatus, page, pageSize])

  useEffect(() => {
    load()
    loadCities()
  }, [load])

  const confirmRole = async () => {
    if (!roleTarget || !roleZone) return
    setRoleSaving(true)
    setError('')
    try {
      const { error } = await supabase.rpc('set_user_role', {
        p_user_id: roleTarget.id,
        p_role: 'encargado',
        p_zone_id: roleZone
      })
      if (error) throw error
      setRoleTarget(null)
      load()
    } catch (err: any) {
      setError(err.message)
    } finally {
      setRoleSaving(false)
    }
  }

  const handleRemoveEncargado = async (u: AdminUserItem) => {
    if (!confirm(`¿Quitar a ${u.full_name} como encargado? Volverá a ser cliente.`)) return
    setError('')
    try {
      const { error } = await supabase.rpc('set_user_role', {
        p_user_id: u.id,
        p_role: 'cliente',
        p_zone_id: null
      })
      if (error) throw error
      load()
    } catch (err: any) {
      setError(err.message)
    }
  }

  const handleApply = () => {
    setPage(0)
    setAppliedSearch(searchInput)
    setAppliedRole(roleInput)
    setAppliedStatus(statusInput)
  }

  const totalPages = Math.max(1, Math.ceil(total / pageSize))

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center gap-3">
          <div className="w-10 h-10 bg-primary-600 rounded-xl flex items-center justify-center">
            <Users className="w-5 h-5 text-white" />
          </div>
          <div>
            <h1 className="text-lg font-bold text-surface-800">Usuarios</h1>
            <p className="text-xs text-surface-500">Todos los pasajeros y conductores de la plataforma</p>
          </div>
        </div>
      </div>

      <div className="max-w-5xl mx-auto px-4 py-6 space-y-4">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        {/* Filtros */}
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
                <option value="admin">Admins</option>
              </select>
            </div>
            <div>
              <label className="label">Estado conductor</label>
              <select className="input" value={statusInput} onChange={(e) => setStatusInput(e.target.value)}>
                <option value="">Todos</option>
                <option value="pendiente">Pendiente</option>
                <option value="aprobado">Aprobado</option>
                <option value="rechazado">Rechazado</option>
                <option value="suspendido">Suspendido</option>
              </select>
            </div>
          </div>
          <div className="flex items-center justify-between">
            <p className="text-xs text-surface-400">
              <Filter className="w-3 h-3 inline mr-1" />
              {total} usuarios encontrados
            </p>
            <button onClick={handleApply} className="btn-primary text-sm px-4 py-2" disabled={loading}>
              {loading ? <Loader2 className="w-4 h-4 animate-spin" /> : <><Search className="w-4 h-4" /> Buscar</>}
            </button>
          </div>
        </div>

        {/* Tabla */}
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
                    <th className="px-4 py-3">Registro</th>
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
                        <td className="px-4 py-3 whitespace-nowrap text-xs text-surface-500">
                          {new Date(u.created_at).toLocaleDateString('es-VE', { day: '2-digit', month: 'short', year: 'numeric' })}
                        </td>
                        <td className="px-4 py-3 text-right">
                          {u.role === 'encargado' ? (
                            <button
                              onClick={() => handleRemoveEncargado(u)}
                              className="btn-outline text-xs px-3 py-1.5 text-red-600 border-red-200"
                              title="Quitar encargado"
                            >
                              Quitar encargado
                            </button>
                          ) : u.role === 'super_admin' ? null : (
                            <button
                              onClick={() => { setRoleTarget(u); setRoleZone('') }}
                              className="btn-outline text-xs px-3 py-1.5"
                              title="Hacer encargado"
                            >
                              Encargado
                            </button>
                          )}
                          <button
                            onClick={() => navigate(`/admin/transacciones?usuario_id=${u.id}&usuario=${encodeURIComponent(u.full_name || '')}`)}
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

            {/* Paginación */}
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

      {/* Modal: hacer encargado */}
      {roleTarget && (
        <div className="fixed inset-0 bg-black/50 z-[60] flex items-center justify-center p-6">
          <div className="bg-white rounded-3xl p-6 w-full max-w-sm shadow-elevated animate-slide-up">
            <h2 className="text-lg font-bold text-surface-800 text-center mb-1">Hacer encargado</h2>
            <p className="text-sm text-surface-500 text-center mb-4">
              {roleTarget.full_name} gestionará la ciudad que elijas (pagos, incidentes, conductores, usuarios).
            </p>
            <label className="label">Ciudad</label>
            <select className="input mb-4" value={roleZone} onChange={(e) => setRoleZone(e.target.value)}>
              <option value="">Selecciona la ciudad…</option>
              {cities.map((c) => (
                <option key={c.id} value={c.id}>{c.name}</option>
              ))}
            </select>
            <div className="flex gap-2">
              <button onClick={() => setRoleTarget(null)} className="btn-outline flex-1" disabled={roleSaving}>
                Cancelar
              </button>
              <button onClick={confirmRole} className="btn-primary flex-1" disabled={roleSaving || !roleZone}>
                {roleSaving ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Confirmar'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
