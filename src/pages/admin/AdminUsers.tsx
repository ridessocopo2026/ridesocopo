import { useState, useEffect, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import { Users, Search, Loader2, MessageCircle, Receipt, Filter, ShieldAlert } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
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
  status: 'activo' | 'pausado' | 'bloqueado' | 'eliminado'
  status_reason: string | null
  status_until: string | null
  activo: boolean
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

// Estado de la CUENTA (pausar / bloquear / eliminar)
const cuentaBadges: Record<string, { label: string; cls: string }> = {
  activo: { label: 'Activa', cls: 'badge-success' },
  pausado: { label: 'Pausada', cls: 'badge-warning' },
  bloqueado: { label: 'Bloqueada', cls: 'badge-danger' },
  eliminado: { label: 'Eliminada', cls: 'badge-danger' }
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

  // Estado de la cuenta (pausar / bloquear / reactivar / eliminar)
  const [cuentaInput, setCuentaInput] = useState('')
  const [appliedCuenta, setAppliedCuenta] = useState('')
  const [cuentaTarget, setCuentaTarget] = useState<AdminUserItem | null>(null)
  const [cuentaAccion, setCuentaAccion] = useState<'pausado' | 'bloqueado' | 'activo' | 'eliminar'>('bloqueado')
  const [cuentaMotivo, setCuentaMotivo] = useState('')
  const [cuentaHasta, setCuentaHasta] = useState('')
  const [cuentaModo, setCuentaModo] = useState<'anonimizar' | 'borrar_real'>('anonimizar')
  const [cuentaGuardando, setCuentaGuardando] = useState(false)

  const navigate = useNavigate()

  // Solo el super_admin puede cambiar roles (defensa en profundidad)
  const { user } = useAuth()

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
        p_offset: page * pageSize,
        p_estado: appliedCuenta || null
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
  }, [appliedSearch, appliedRole, appliedStatus, appliedCuenta, page, pageSize])

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
    setAppliedCuenta(cuentaInput)
  }

  // Pausar / bloquear / reactivar / eliminar la cuenta (solo super_admin)
  const handleCuenta = async () => {
    if (!cuentaTarget) return
    setCuentaGuardando(true)
    setError('')
    try {
      if (cuentaAccion === 'eliminar') {
        const aviso = cuentaModo === 'borrar_real'
          ? 'Se borrarán TODOS sus datos. Solo es posible si la cuenta no tiene historial.'
          : 'Se borrarán sus datos personales y se conservará el historial de viajes y dinero.'
        if (!confirm(`¿Eliminar la cuenta de ${cuentaTarget.full_name}?\n\n${aviso}\n\nEsta acción no se puede deshacer.`)) return

        const { error } = await supabase.rpc('admin_delete_account', {
          p_user_id: cuentaTarget.id,
          p_mode: cuentaModo,
          p_reason: cuentaMotivo.trim() || null
        })
        if (error) throw error
      } else {
        const { error } = await supabase.rpc('admin_set_account_status', {
          p_user_id: cuentaTarget.id,
          p_status: cuentaAccion,
          p_reason: cuentaMotivo.trim() || null,
          p_until: cuentaAccion === 'pausado' && cuentaHasta ? new Date(cuentaHasta).toISOString() : null
        })
        if (error) throw error
      }
      setCuentaTarget(null)
      setCuentaMotivo('')
      setCuentaHasta('')
      setCuentaModo('anonimizar')
      load()
    } catch (err: any) {
      setError(err.message)
    } finally {
      setCuentaGuardando(false)
    }
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
          <div className="grid grid-cols-1 md:grid-cols-5 gap-3">
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
            <div>
              <label className="label">Estado de cuenta</label>
              <select className="input" value={cuentaInput} onChange={(e) => setCuentaInput(e.target.value)}>
                <option value="">Todas</option>
                <option value="activo">Activas</option>
                <option value="pausado">Pausadas</option>
                <option value="bloqueado">Bloqueadas</option>
                <option value="eliminado">Eliminadas</option>
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
                    <th className="px-4 py-3">Estado conductor</th>
                    <th className="px-4 py-3">Cuenta</th>
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
                    // Estado de la cuenta: si la pausa ya venció, vuelve a estar activa
                    const acct = cuentaBadges[u.status]
                    const pausaVencida = u.status === 'pausado' && u.activo
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
                          {acct ? (
                            <div>
                              <span className={pausaVencida ? 'badge-success' : acct.cls}>
                                {pausaVencida ? 'Activa (pausa vencida)' : acct.label}
                              </span>
                              {u.status !== 'activo' && u.status_reason && (
                                <p className="text-[10px] text-surface-400 mt-0.5 truncate max-w-[170px]" title={u.status_reason}>
                                  {u.status_reason}
                                </p>
                              )}
                              {u.status === 'pausado' && !u.activo && u.status_until && (
                                <p className="text-[10px] text-surface-400">
                                  hasta {new Date(u.status_until).toLocaleDateString('es-VE', { day: '2-digit', month: 'short', year: 'numeric' })}
                                </p>
                              )}
                            </div>
                          ) : (
                            <span className="text-xs text-surface-400">—</span>
                          )}
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
                          {user?.role === 'super_admin' && u.id !== user.id && u.role !== 'super_admin' && (
                            <button
                              onClick={() => {
                                setCuentaTarget(u)
                                setCuentaAccion(u.activo ? 'pausado' : 'activo')
                                setCuentaMotivo('')
                                setCuentaHasta('')
                                setCuentaModo('anonimizar')
                              }}
                              className="btn-outline text-xs px-3 py-1.5 mr-1 text-amber-700 border-amber-200"
                              title="Pausar, bloquear, reactivar o eliminar la cuenta"
                            >
                              <ShieldAlert className="w-3.5 h-3.5" /> Estado
                            </button>
                          )}
                          {user?.role === 'super_admin' && (
                            u.role === 'encargado' ? (
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
                            )
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

      {/* Modal: estado de la cuenta (pausar / bloquear / reactivar / eliminar) */}
      {cuentaTarget && (
        <div className="fixed inset-0 bg-black/50 z-[60] flex items-center justify-center p-6">
          <div className="bg-white rounded-3xl p-6 w-full max-w-sm shadow-elevated animate-slide-up max-h-[90vh] overflow-y-auto">
            <h2 className="text-lg font-bold text-surface-800 text-center mb-1">Estado de la cuenta</h2>
            <p className="text-sm text-surface-500 text-center mb-4">
              {cuentaTarget.full_name}
              <br />
              <span className="text-xs">{cuentaTarget.email}</span>
            </p>

            <label className="label">Acción</label>
            <select
              className="input mb-3"
              value={cuentaAccion}
              onChange={(e) => setCuentaAccion(e.target.value as 'pausado' | 'bloqueado' | 'activo' | 'eliminar')}
            >
              <option value="pausado">Pausar (temporal: no opera, conserva su dinero)</option>
              <option value="bloqueado">Bloquear (no puede operar nada)</option>
              <option value="activo">Reactivar</option>
              <option value="eliminar">Eliminar la cuenta</option>
            </select>

            {cuentaAccion !== 'activo' && (
              <>
                <label className="label">Motivo (obligatorio)</label>
                <textarea
                  className="input mb-3"
                  rows={2}
                  placeholder="Ej: uso indebido, cobros duplicados..."
                  value={cuentaMotivo}
                  onChange={(e) => setCuentaMotivo(e.target.value)}
                />
              </>
            )}

            {cuentaAccion === 'pausado' && (
              <>
                <label className="label">Fin de la pausa (opcional)</label>
                <input
                  type="datetime-local"
                  className="input mb-3"
                  value={cuentaHasta}
                  onChange={(e) => setCuentaHasta(e.target.value)}
                />
                <p className="text-[11px] text-surface-400 mb-3">
                  Si lo dejas vacío, dura hasta que la reactives a mano. Si pones fecha, se reactiva sola al vencer.
                </p>
              </>
            )}

            {cuentaAccion === 'eliminar' && (
              <>
                <label className="label">Tipo de eliminación</label>
                <select
                  className="input mb-3"
                  value={cuentaModo}
                  onChange={(e) => setCuentaModo(e.target.value as 'anonimizar' | 'borrar_real')}
                >
                  <option value="anonimizar">Anonimizar (conserva viajes y dinero)</option>
                  <option value="borrar_real">Borrar de verdad (solo si no tiene historial)</option>
                </select>
              </>
            )}

            <div className="flex gap-2">
              <button onClick={() => setCuentaTarget(null)} className="btn-outline flex-1" disabled={cuentaGuardando}>
                Cancelar
              </button>
              <button
                onClick={handleCuenta}
                className={cuentaAccion === 'eliminar' ? 'btn-danger flex-1' : 'btn-primary flex-1'}
                disabled={cuentaGuardando || (cuentaAccion !== 'activo' && !cuentaMotivo.trim())}
              >
                {cuentaGuardando ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Confirmar'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
