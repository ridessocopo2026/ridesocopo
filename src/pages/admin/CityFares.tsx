import { useState, useEffect, useCallback } from 'react'
import { useNavigate } from 'react-router-dom'
import { ChevronLeft, Loader2, Save, RotateCcw, AlertTriangle, DollarSign } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'

interface FareRow {
  category: string
  display_name: string
  global_fare: number
  override_fare: number | null
  effective_fare: number
  is_override: boolean
}

export function CityFares() {
  const { user } = useAuth()
  const navigate = useNavigate()
  const isEncargado = user?.role === 'encargado'
  const backPath = isEncargado ? '/encargado' : '/admin'

  const [cities, setCities] = useState<{ id: string; name: string }[]>([])
  const [cityId, setCityId] = useState('')
  const [rows, setRows] = useState<FareRow[]>([])
  const [inputs, setInputs] = useState<Record<string, string>>({})
  const [loading, setLoading] = useState(true)
  const [savingCat, setSavingCat] = useState<string | null>(null)
  const [error, setError] = useState('')
  const [okMsg, setOkMsg] = useState('')

  useEffect(() => {
    if (isEncargado) {
      setCityId(user?.zone_id || '')
      return
    }
    supabase.rpc('get_active_cities').then(({ data }) => {
      if (data) {
        const list = data as { id: string; name: string }[]
        setCities(list)
        if (list.length > 0) setCityId((prev) => prev || list[0].id)
      }
    })
  }, [isEncargado, user?.zone_id])

  const loadMatrix = useCallback(async () => {
    if (!cityId) return
    setLoading(true)
    const { data, error } = await supabase.rpc('get_city_fare_matrix', { p_zone_id: cityId })
    if (error) { setError(error.message); setLoading(false); return }
    const list = (data || []) as FareRow[]
    setRows(list)
    const inp: Record<string, string> = {}
    for (const r of list) inp[r.category] = String(r.effective_fare)
    setInputs(inp)
    setLoading(false)
  }, [cityId])

  useEffect(() => { void loadMatrix() }, [loadMatrix])

  const saveRow = async (r: FareRow) => {
    setError(''); setOkMsg('')
    const val = parseFloat(inputs[r.category])
    if (!isFinite(val) || val < 0) { setError('Precio no valido'); return }
    setSavingCat(r.category)
    const { error } = await supabase.rpc('admin_set_city_fare', { p_zone_id: cityId, p_category: r.category, p_base_fare_usd: val })
    setSavingCat(null)
    if (error) { setError(error.message); return }
    setOkMsg('Guardado')
    await loadMatrix()
  }

  const clearRow = async (r: FareRow) => {
    setError(''); setOkMsg('')
    setSavingCat(r.category)
    const { error } = await supabase.rpc('admin_set_city_fare', { p_zone_id: cityId, p_category: r.category, p_base_fare_usd: null })
    setSavingCat(null)
    if (error) { setError(error.message); return }
    setOkMsg('Restaurado al precio global')
    await loadMatrix()
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center gap-3">
          <button onClick={() => navigate(backPath)} className="p-2 text-surface-400 hover:text-surface-600" aria-label="Volver">
            <ChevronLeft className="w-5 h-5" />
          </button>
          <div className="w-10 h-10 bg-primary-600 rounded-xl flex items-center justify-center">
            <DollarSign className="w-5 h-5 text-white" />
          </div>
          <div>
            <h1 className="text-lg font-bold text-surface-800">Precios por ciudad</h1>
            <p className="text-xs text-surface-500">Precio base por tipo de vehiculo</p>
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6 space-y-4">
        {error && <div className="card p-3 bg-red-50 border-red-200 text-sm text-red-600">{error}</div>}
        {okMsg && <div className="card p-3 bg-emerald-50 border-emerald-200 text-sm text-emerald-700">{okMsg}</div>}

        {!isEncargado && cities.length > 0 && (
          <div className="card p-3 flex items-center justify-between gap-2">
            <span className="text-sm font-medium text-surface-600">Ciudad</span>
            <select className="input w-auto py-1.5 text-sm" value={cityId} onChange={(e) => setCityId(e.target.value)}>
              {cities.map((c) => (<option key={c.id} value={c.id}>{c.name}</option>))}
            </select>
          </div>
        )}

        <div className="rounded-xl p-3 bg-amber-50 border border-amber-200 flex items-start gap-2">
          <AlertTriangle className="w-4 h-4 text-amber-600 flex-shrink-0 mt-0.5" />
          <p className="text-xs text-amber-700">
            El precio base es el punto de partida por tipo de vehiculo. Al pasajero se le suma el recargo del barrio de destino. Si dejas el valor global, esa ciudad usa el mismo precio que las demas.
          </p>
        </div>

        {loading ? (
          <div className="card p-6 flex justify-center"><Loader2 className="w-6 h-6 animate-spin text-primary-600" /></div>
        ) : rows.length === 0 ? (
          <div className="card p-4 text-sm text-surface-500">No hay tipos de vehiculo activos.</div>
        ) : (
          <div className="space-y-2">
            {rows.map((r) => (
              <div key={r.category} className="card p-3">
                <div className="flex items-center justify-between mb-2">
                  <p className="font-semibold text-surface-800 text-sm">{r.display_name}</p>
                  <p className="text-[11px] text-surface-400">Global: ${Number(r.global_fare).toFixed(2)}{r.is_override ? ' - personalizado' : ' - usa global'}</p>
                </div>
                <div className="flex items-center gap-2">
                  <div className="relative flex-1">
                    <span className="absolute left-3 top-1/2 -translate-y-1/2 text-surface-400 text-sm">$</span>
                    <input
                      type="number"
                      step="0.50"
                      min="0"
                      className="input pl-7"
                      value={inputs[r.category] ?? ''}
                      onChange={(e) => setInputs((p) => ({ ...p, [r.category]: e.target.value }))}
                    />
                  </div>
                  <button onClick={() => saveRow(r)} disabled={savingCat === r.category} className="btn-primary px-3" aria-label="Guardar">
                    {savingCat === r.category ? <Loader2 className="w-4 h-4 animate-spin" /> : <Save className="w-4 h-4" />}
                  </button>
                  {r.is_override && (
                    <button onClick={() => clearRow(r)} disabled={savingCat === r.category} className="btn-outline px-3" title="Usar el precio global" aria-label="Usar global">
                      <RotateCcw className="w-4 h-4" />
                    </button>
                  )}
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}