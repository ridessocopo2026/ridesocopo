import { useState, useEffect } from 'react'
import { Loader2, Plus, Save, Pencil, Trash2, X, Check, AlertTriangle } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { HexUnderline } from '@/components/ui/HexUnderline'
import type { VehicleCategory } from '@/types/database'
import { AppLogo } from '@/components/ui/AppLogo'

interface Usage { name?: string; vehicles: number; drivers: number; active_rides: number }

const catEmoji = (name?: string): string => {
  const n = (name || '').toLowerCase()
  if (n.includes('moto')) return '🛵'
  if (n.includes('camioneta')) return '🚚'
  if (n.includes('carro') || n.includes('auto') || n.includes('taxi')) return '🚗'
  return '🛺'
}

export function AdminFares() {
  const [categories, setCategories] = useState<VehicleCategory[]>([])
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)

  // Formulario agregar / editar
  const [formOpen, setFormOpen] = useState(false)
  const [editId, setEditId] = useState<string | null>(null)
  const [name, setName] = useState('')
  const [display, setDisplay] = useState('')
  const [base, setBase] = useState('1.00')
  const [pass, setPass] = useState('1')
  const [desc, setDesc] = useState('')
  const [iconSel, setIconSel] = useState('')

  // Identificadores internos disponibles para elegir al agregar
  const [availIds, setAvailIds] = useState<string[]>([])
  const [customMode, setCustomMode] = useState(false)

  // Eliminar (aviso + reasignacion)
  const [delTarget, setDelTarget] = useState<VehicleCategory | null>(null)
  const [delUsage, setDelUsage] = useState<Usage | null>(null)
  const [reassignTo, setReassignTo] = useState('')

  const { user } = useAuth()

  useEffect(() => {
    loadCategories()
  }, [])

  const loadCategories = async () => {
    const { data, error } = await supabase
      .from('vehicle_categories')
      .select('*')
      .order('base_fare_usd')

    if (!error && data) {
      setCategories(data as VehicleCategory[])
    }
    setLoading(false)
  }

  const loadAvailableIds = async () => {
    const { data, error } = await supabase.rpc('get_available_vehicle_category_identifiers')
    if (error || !Array.isArray(data)) return
    const ids = (data as string[]).filter(Boolean)
    setAvailIds(ids)
    if (ids.length > 0) {
      setCustomMode(false)
      setName(ids[0])
    } else {
      setCustomMode(true)
      setName('')
    }
  }

  const openAdd = () => {
    setEditId(null)
    setName('')
    setDisplay('')
    setBase('1.00')
    setPass('1')
    setDesc('')
    setIconSel('')
    setAvailIds([])
    setCustomMode(false)
    setFormOpen(true)
    setError('')
    void loadAvailableIds()
  }

  const openEdit = (cat: VehicleCategory) => {
    setEditId(cat.id)
    setName(cat.name)
    setDisplay(cat.display_name)
    setBase(cat.base_fare_usd?.toString() || '1.00')
    setPass(cat.max_passengers?.toString() || '1')
    setDesc(cat.description || '')
    setIconSel(cat.icon || '')
    setFormOpen(true)
    setError('')
  }

  const handleSave = async () => {
    setError('')
    const baseNum = parseFloat(base)
    const passNum = parseInt(pass, 10)
    if (!display.trim()) { setError('Indica el nombre visible'); return }
    if (!(baseNum >= 0)) { setError('Tarifa base invalida'); return }
    if (!(passNum >= 1)) { setError('Pasajeros invalido'); return }

    setSaving(true)
    try {
      if (editId) {
        const { error: e } = await supabase.rpc('admin_update_vehicle_category', {
          p_id: editId,
          p_display_name: display.trim(),
          p_base_fare_usd: baseNum,
          p_max_passengers: passNum,
          p_description: desc.trim() || null,
          p_icon: iconSel || null,
          p_is_active: true
        })
        if (e) throw e
      } else {
        const slug = name.trim().toLowerCase().replace(/\s+/g, '_').replace(/[^a-z0-9_]/g, '')
        if (!slug) { throw new Error('El identificador del tipo no es valido (ej: moto_lujo)') }
        // Paso 1: garantizar la etiqueta en el enum (DDL en su propia transaccion)
        const { error: e1 } = await supabase.rpc('ensure_vehicle_category_enum', { p_name: slug })
        if (e1) throw e1
        // Paso 2: crear la fila del catalogo
        const { error: e2 } = await supabase.rpc('admin_create_vehicle_category', {
          p_name: slug,
          p_display_name: display.trim(),
          p_base_fare_usd: baseNum,
          p_max_passengers: passNum,
          p_description: desc.trim() || null,
          p_icon: iconSel || slug
        })
        if (e2) throw e2
      }
      setFormOpen(false)
      loadCategories()
    } catch (err: any) {
      setError(err.message || 'Error al guardar')
    } finally {
      setSaving(false)
    }
  }

  const handleToggleActive = async (cat: VehicleCategory) => {
    setError('')
    setSaving(true)
    try {
      const { error: e } = await supabase.rpc('admin_update_vehicle_category', {
        p_id: cat.id,
        p_display_name: cat.display_name,
        p_base_fare_usd: cat.base_fare_usd,
        p_max_passengers: cat.max_passengers,
        p_description: cat.description || null,
        p_icon: cat.icon || null,
        p_is_active: !cat.is_active
      })
      if (e) throw e
      loadCategories()
    } catch (err: any) {
      setError(err.message)
    } finally {
      setSaving(false)
    }
  }

  const openDelete = async (cat: VehicleCategory) => {
    setError('')
    setDelTarget(cat)
    setDelUsage(null)
    setReassignTo('')
    try {
      const { data, error } = await supabase.rpc('admin_get_category_usage', { p_id: cat.id })
      if (error) throw error
      setDelUsage(data as Usage)
    } catch (err: any) {
      setError(err.message)
    }
  }

  const confirmDelete = async () => {
    if (!delTarget || !delUsage) return
    setError('')
    setSaving(true)
    try {
      const needTarget = delUsage.vehicles > 0
      const { error: e } = await supabase.rpc('admin_delete_vehicle_category', {
        p_id: delTarget.id,
        p_reassign_to: needTarget ? (reassignTo || null) : null
      })
      if (e) throw e
      setDelTarget(null)
      setDelUsage(null)
      loadCategories()
    } catch (err: any) {
      setError(err.message)
    } finally {
      setSaving(false)
    }
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center gap-3">
          <AppLogo />
          <div>
            <h1 className="text-lg font-bold text-surface-800">Vehículos y Tarifas</h1>
            <p className="text-xs text-surface-500">Crea y gestiona los tipos de vehículo</p>
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6 space-y-4">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}
        <HexUnderline />

        <button onClick={openAdd} className="btn-primary w-full">
          <Plus className="w-4 h-4" /> Agregar tipo de vehículo
        </button>

        {loading ? (
          <div className="flex justify-center py-8"><Loader2 className="w-6 h-6 animate-spin text-primary-600" /></div>
        ) : (
          <div className="space-y-3">
            {categories.map((cat) => (
              <div key={cat.id} className="card">
                <div className="flex items-center gap-3 mb-3">
                  <div className="w-11 h-11 bg-primary-50 rounded-xl flex items-center justify-center text-xl">
                    {cat.icon || catEmoji(cat.name)}
                  </div>
                  <div className="flex-1 min-w-0">
                    <h3 className="font-semibold text-surface-700 truncate">{cat.display_name}</h3>
                    <p className="text-xs text-surface-400 truncate">
                      Hasta {cat.max_passengers} pasajero(s) • {cat.description || cat.name}
                    </p>
                  </div>
                  {cat.is_active ? <span className="badge-success">Activo</span> : <span className="badge-warning">Inactivo</span>}
                </div>

                <div className="flex items-center gap-3 mb-3">
                  <div className="flex-1">
                    <label className="label">Tarifa base (USD)</label>
                    <input
                      type="number"
                      className="input"
                      step="0.50"
                      min="0"
                      defaultValue={cat.base_fare_usd}
                      data-cat={cat.id}
                    />
                  </div>
                  <button
                    onClick={() => {
                      const el = document.querySelector(`input[data-cat="${cat.id}"]`) as HTMLInputElement
                      const val = parseFloat(el?.value || '0')
                      if (el && val !== cat.base_fare_usd) {
                        supabase.rpc('admin_update_vehicle_category', {
                          p_id: cat.id,
                          p_display_name: cat.display_name,
                          p_base_fare_usd: val,
                          p_max_passengers: cat.max_passengers,
                          p_description: cat.description || null,
                          p_icon: cat.icon || null,
                          p_is_active: cat.is_active
                        }).then(({ error }) => { if (!error) loadCategories() })
                      }
                    }}
                    className="btn-primary mt-6 px-3"
                    disabled={saving}
                  >
                    <Save className="w-4 h-4" />
                  </button>
                </div>

                <div className="flex flex-wrap gap-2">
                  <button onClick={() => openEdit(cat)} className="btn-outline flex-1"><Pencil className="w-4 h-4" /> Editar</button>
                  <button onClick={() => handleToggleActive(cat)} disabled={saving} className="btn-outline flex-1">
                    {cat.is_active ? <X className="w-4 h-4" /> : <Check className="w-4 h-4" />}
                    {cat.is_active ? 'Desactivar' : 'Activar'}
                  </button>
                  <button onClick={() => openDelete(cat)} className="btn-danger flex-1"><Trash2 className="w-4 h-4" /> Eliminar</button>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>

      {/* Formulario agregar / editar */}
      {formOpen && (
        <div className="fixed inset-0 bg-black/40 z-50 flex items-end justify-center" onClick={() => setFormOpen(false)}>
          <div className="bottom-sheet max-w-md w-full" onClick={(e) => e.stopPropagation()}>
            <div className="bottom-sheet-handle" />
            <h2 className="text-xl font-bold text-surface-800 mb-4">
              {editId ? 'Editar tipo de vehículo' : 'Agregar tipo de vehículo'}
            </h2>
            <div className="space-y-3">
              {!editId && (
                <div>
                  <label className="label">Identificador (interno)</label>
                  {!customMode && availIds.length > 0 ? (
                    <select
                      className="input"
                      value={name}
                      onChange={(e) => {
                        const v = e.target.value
                        if (v === '__new__') {
                          setCustomMode(true)
                          setName('')
                        } else {
                          setCustomMode(false)
                          setName(v)
                        }
                      }}
                    >
                      <option value="" disabled>Elige el identificador…</option>
                      {availIds.map((id) => (
                        <option key={id} value={id}>{id}</option>
                      ))}
                      <option value="__new__">✍️ Escribir uno nuevo…</option>
                    </select>
                  ) : (
                    <div className="space-y-1">
                      <input className="input" placeholder="Ej: moto_lujo" value={name} onChange={(e) => setName(e.target.value)} />
                      {availIds.length > 0 && (
                        <button
                          type="button"
                          onClick={() => {
                            setCustomMode(false)
                            if (availIds.length > 0) setName(availIds[0])
                          }}
                          className="text-[11px] text-primary-600 underline"
                        >
                          ← Volver a elegir de la lista
                        </button>
                      )}
                    </div>
                  )}
                  <p className="text-[11px] text-surface-400 mt-1">Solo minúsculas, números y guion bajo. No se puede cambiar después.</p>
                </div>
              )}
              <div>
                <label className="label">Nombre visible</label>
                <input className="input" placeholder="Ej: Moto de Lujo" value={display} onChange={(e) => setDisplay(e.target.value)} />
              </div>
              <div className="grid grid-cols-2 gap-2">
                <div>
                  <label className="label">Tarifa base (USD)</label>
                  <input type="number" className="input" step="0.50" min="0" value={base} onChange={(e) => setBase(e.target.value)} />
                </div>
                <div>
                  <label className="label">Pasajeros</label>
                  <input type="number" className="input" min="1" value={pass} onChange={(e) => setPass(e.target.value)} />
                </div>
              </div>
              <div>
                <label className="label">Descripción</label>
                <input className="input" placeholder="Opcional" value={desc} onChange={(e) => setDesc(e.target.value)} />
              </div>
              <div>
                <label className="label">Icono</label>
                <div className="flex flex-wrap gap-2">
                  {['', '🛵', '🏍️', '🛺', '📦', '🚗', '🚚', '🚕', '🚙'].map((ic) => (
                    <button
                      key={ic || 'none'}
                      type="button"
                      onClick={() => setIconSel(ic)}
                      className={`w-11 h-11 rounded-xl border-2 text-xl flex items-center justify-center transition-all ${
                        iconSel === ic ? 'border-primary-600 bg-primary-50' : 'border-surface-200 hover:border-surface-300'
                      }`}
                    >
                      {ic || '🚘'}
                    </button>
                  ))}
                </div>
              </div>
              <div className="flex gap-2">
                <button onClick={() => setFormOpen(false)} className="btn-outline flex-1">Cancelar</button>
                <button onClick={handleSave} className="btn-primary flex-1" disabled={saving}>
                  {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : <><Check className="w-4 h-4" /> Guardar</>}
                </button>
              </div>
            </div>
          </div>
        </div>
      )}

      {/* Eliminar con aviso de vehículos asociados */}
      {delTarget && (
        <div className="fixed inset-0 bg-black/40 z-50 flex items-end justify-center" onClick={() => setDelTarget(null)}>
          <div className="bottom-sheet max-w-md w-full" onClick={(e) => e.stopPropagation()}>
            <div className="bottom-sheet-handle" />
            <h2 className="text-xl font-bold text-surface-800 mb-3">Eliminar «{delTarget.display_name}»</h2>
            {!delUsage ? (
              <div className="flex justify-center py-6"><Loader2 className="w-6 h-6 animate-spin text-primary-600" /></div>
            ) : (
              <div className="space-y-3">
                {delUsage.active_rides > 0 ? (
                  <div className="rounded-xl p-3 bg-red-50 border border-red-200 flex items-start gap-2">
                    <AlertTriangle className="w-5 h-5 text-red-600 flex-shrink-0 mt-0.5" />
                    <div>
                      <p className="text-sm font-medium text-red-700">No se puede eliminar</p>
                      <p className="text-xs text-red-600 mt-0.5">
                        Hay {delUsage.active_rides} viaje(s) activo(s) en esta categoría. Espera a que terminen.
                      </p>
                    </div>
                  </div>
                ) : delUsage.vehicles > 0 ? (
                  <div className="rounded-xl p-3 bg-amber-50 border border-amber-200 flex items-start gap-2">
                    <AlertTriangle className="w-5 h-5 text-amber-600 flex-shrink-0 mt-0.5" />
                    <div className="flex-1">
                      <p className="text-sm font-medium text-amber-700">
                        Hay {delUsage.vehicles} vehículo(s) de {delUsage.drivers} conductor(es) en «{delUsage.name}»
                      </p>
                      <p className="text-xs text-amber-600 mt-1">Para eliminar el tipo, elige a qué otro tipo se moverán:</p>
                      <select className="input mt-2" value={reassignTo} onChange={(e) => setReassignTo(e.target.value)}>
                        <option value="">— Elegir tipo destino —</option>
                        {categories.filter((c) => c.id !== delTarget.id && c.is_active).map((c) => (
                          <option key={c.id} value={c.name}>{c.display_name}</option>
                        ))}
                      </select>
                    </div>
                  </div>
                ) : (
                  <p className="text-sm text-surface-600">
                    Este tipo no tiene vehículos asociados. Se eliminará sin reasignar nada.
                  </p>
                )}

                <div className="flex gap-2">
                  <button onClick={() => setDelTarget(null)} className="btn-outline flex-1">Cancelar</button>
                  <button
                    onClick={confirmDelete}
                    className="btn-danger flex-1"
                    disabled={saving || delUsage.active_rides > 0 || (delUsage.vehicles > 0 && !reassignTo)}
                  >
                    {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : <Trash2 className="w-4 h-4" />}
                    {delUsage.vehicles > 0 ? 'Eliminar y reasignar' : 'Eliminar'}
                  </button>
                </div>
              </div>
            )}
          </div>
        </div>
      )}
    </div>
  )
}

