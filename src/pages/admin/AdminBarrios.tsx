import { useState, useEffect, useRef } from 'react'
import { MapContainer, TileLayer, Marker, useMapEvents, useMap } from 'react-leaflet'
import L from 'leaflet'
import { MapPin, Plus, Save, Trash2, Loader2, Pencil, Navigation, Copy, Check, X } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { HexUnderline } from '@/components/ui/HexUnderline'
import type { Barrio, VehicleCategory } from '@/types/database'
import { AppLogo } from '@/components/ui/AppLogo'

const SOCOPO_CENTER: [number, number] = [8.23293, -70.82228]

const barrioIcon = L.divIcon({
  className: 'custom-div-icon',
  html: `<div class="w-8 h-8 bg-primary-600 rounded-full border-4 border-white shadow-lg flex items-center justify-center">
    <svg class="w-4 h-4 text-white" fill="none" stroke="currentColor" viewBox="0 0 24 24">
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M17.657 16.657L13.414 20.9a1.998 1.998 0 01-2.827 0l-4.244-4.243a8 8 0 1111.314 0z"/>
      <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M15 11a3 3 0 11-6 0 3 3 0 016 0z"/>
    </svg>
  </div>`,
  iconSize: [32, 32],
  iconAnchor: [16, 16]
})

function MapClickHandler({ onSelect }: { onSelect: (lat: number, lng: number) => void }) {
  useMapEvents({
    click(e) {
      onSelect(e.latlng.lat, e.latlng.lng)
    }
  })
  return null
}

/**
 * Centra el mapa sin volver a montarlo (no recarga tiles ni reinicia el zoom
 * del usuario). Solo actúa cuando llega un "foco" nuevo (el nonce cambia),
 * así los clics normales en el mapa no mueven la vista.
 */
function MapFocus({ target }: { target: { lat: number; lng: number; zoom: number; nonce: number } | null }) {
  const map = useMap()
  useEffect(() => {
    if (!target) return
    map.setView([target.lat, target.lng], target.zoom, { animate: true })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [target?.nonce])
  return null
}

// ============================================================
// Coordenadas: acepta el formato de Google Maps
//   8.238914, -70.814995
//   El Carmen: 8.238914, -70.814995
//   https://www.google.com/maps/@8.238914,-70.814995,17z
//   https://maps.google.com/?q=8.238914,-70.814995
//   8°14'20.1"N 70°48'54.0"W
// Los enlaces CORTOS (maps.app.goo.gl/...) necesitan red para resolverse,
// así que se le pide al usuario usar el enlace largo o "copiar coordenadas".
// ============================================================
function decFromDms(deg: string, min?: string, sec?: string, hemi?: string): number {
  const d = Math.abs(parseFloat(deg)) || 0
  const m = min ? Math.abs(parseFloat(min)) || 0 : 0
  const s = sec ? Math.abs(parseFloat(sec.replace(',', '.'))) || 0 : 0
  // S (Sur), W (West) y O (Oeste) son negativos; N y E positivos
  const sign = /[SsWwOo]/.test(hemi || '') || parseFloat(deg) < 0 ? -1 : 1
  return (d + m / 60 + s / 3600) * sign
}

function parseCoords(raw: string): { lat: number; lng: number } | null {
  const text = (raw || '').trim()
  if (!text) return null

  const valid = (la: number, ln: number) =>
    Number.isFinite(la) && Number.isFinite(ln) &&
    Math.abs(la) <= 90 && Math.abs(ln) <= 180 &&
    !(la === 0 && ln === 0)

  const pair = (a: string, b: string) => {
    let la = parseFloat(a)
    let ln = parseFloat(b)
    // Si el primero no puede ser latitud, se asume que viene invertido
    if (Math.abs(la) > 90 && Math.abs(ln) <= 90) [la, ln] = [ln, la]
    return valid(la, ln) ? { lat: la, lng: ln } : null
  }

  // 1) DMS: 8°14'20.1"N 70°48'54.0"W
  const dms = text.match(
    /(\d{1,3})\s*[°º]\s*(\d{1,2})?\s*['′]?\s*(\d{1,2}(?:[.,]\d+)?)?\s*["″]?\s*([NnSs])\s*[,\s]\s*(\d{1,3})\s*[°º]\s*(\d{1,2})?\s*['′]?\s*(\d{1,2}(?:[.,]\d+)?)?\s*["″]?\s*([EeWwOo])/
  )
  if (dms) {
    const la = decFromDms(dms[1], dms[2], dms[3], dms[4])
    const ln = decFromDms(dms[5], dms[6], dms[7], dms[8])
    if (valid(la, ln)) return { lat: +la.toFixed(6), lng: +ln.toFixed(6) }
  }

  // 2) Enlace largo de Google: .../@lat,lng,17z
  const at = text.match(/@(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)/)
  if (at) {
    const r = pair(at[1], at[2])
    if (r) return r
  }

  // 3) Parámetros de URL: ?q= | &query= | ?ll= | ?center=
  const q = text.match(/[?&](?:q|query|ll|center|destination)=(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)/i)
  if (q) {
    const r = pair(q[1], q[2])
    if (r) return r
  }

  // 4) Escrito a mano: "8.238914, -70.814995" (coma, punto y coma o espacio)
  const manual = text.match(/(-?\d{1,3}(?:\.\d+)?)\s*[,;]\s*(-?\d{1,3}(?:\.\d+)?)/)
  if (manual) {
    const r = pair(manual[1], manual[2])
    if (r) return r
  }

  // 5) Último recurso: coma decimal (8,238914 -70,814995)
  const comaDec = text.match(/(-?\d{1,3},\d+)\s*[;\s]\s*(-?\d{1,3},\d+)/)
  if (comaDec) {
    const r = pair(comaDec[1].replace(',', '.'), comaDec[2].replace(',', '.'))
    if (r) return r
  }

  return null
}

function formatCoords(lat: number, lng: number): string {
  return `${lat.toFixed(6)}, ${lng.toFixed(6)}`
}

type CityInfo = { id: string; name: string; center_lat?: number | null; center_lng?: number | null }

export function AdminBarrios() {
  const [barrios, setBarrios] = useState<Barrio[]>([])
  const [cities, setCities] = useState<CityInfo[]>([])
  const [selectedCityId, setSelectedCityId] = useState('')
  const [editing, setEditing] = useState<Barrio | null>(null)
  const [name, setName] = useState('')
  const [surcharge, setSurcharge] = useState('')
  const [cats, setCats] = useState<VehicleCategory[]>([])
  const [catVals, setCatVals] = useState<Record<string, string>>({})
  const [extras, setExtras] = useState<Record<string, Record<string, number>>>({})
  const [description, setDescription] = useState('')
  const [lat, setLat] = useState<number | null>(null)
  const [lng, setLng] = useState<number | null>(null)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const { user } = useAuth()

  // Coordenadas pegadas, validación, copiado y realce del formulario
  const [coordInput, setCoordInput] = useState('')
  const [coordMsg, setCoordMsg] = useState<{ ok: boolean; text: string } | null>(null)
  const [copied, setCopied] = useState(false)
  const [highlight, setHighlight] = useState(false)
  // Foco del mapa: el nonce permite repetir el mismo sitio sin remontar el mapa
  const [mapFocus, setMapFocus] = useState<{ lat: number; lng: number; zoom: number; nonce: number } | null>(null)
  const focusNonce = useRef(0)
  const formRef = useRef<HTMLDivElement>(null)
  const centeredOnceRef = useRef(false)

  // Centro por defecto: el de la CIUDAD elegida (antes era Socopó fijo)
  const selectedCity = cities.find((c) => c.id === selectedCityId)
  const defaultCenter: [number, number] =
    selectedCity?.center_lat != null && selectedCity?.center_lng != null
      ? [selectedCity.center_lat, selectedCity.center_lng]
      : SOCOPO_CENTER

  const focusMap = (la: number, ln: number, zoom = 16) => {
    focusNonce.current += 1
    setMapFocus({ lat: la, lng: ln, zoom, nonce: focusNonce.current })
  }

  useEffect(() => {
    loadCities()
  }, [])

  useEffect(() => {
    loadCats()
  }, [])

  // Al elegir ciudad: cargar sus barrios y los recargos efectivos por categoría
  useEffect(() => {
    if (selectedCityId) {
      loadBarrios(selectedCityId)
    }
  }, [selectedCityId])

  // Primera vez que sabemos el centro de la ciudad: centrar ahí el mapa
  // (si no, abriría siempre en Socopó aunque estés configurando otra ciudad)
  useEffect(() => {
    if (centeredOnceRef.current) return
    const city = cities.find((c) => c.id === selectedCityId)
    if (!city || city.center_lat == null || city.center_lng == null) return
    centeredOnceRef.current = true
    focusMap(city.center_lat, city.center_lng, 14)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cities, selectedCityId])

  const loadCities = async () => {
    const { data, error } = await supabase.rpc('get_active_cities')
    if (!error && data) {
      const list = (data as { id: string; name: string }[]) || []
      setCities(list)
      if (list.length === 1) setSelectedCityId(list[0].id)
    }
    setLoading(false)
  }

  const loadCats = async () => {
    const { data, error } = await supabase
      .from('vehicle_categories')
      .select('*')
      .eq('is_active', true)
      .order('base_fare_usd')
    if (!error && data) {
      setCats(data as VehicleCategory[])
    }
  }

  const loadBarrios = async (zoneId: string) => {
    const { data, error } = await supabase
      .from('barrios')
      .select('*')
      .eq('zone_id', zoneId)
      .order('name')

    if (error || !data) return

    const list = data as Barrio[]
    setBarrios(list)

    // Recargos efectivos (vista) de todos los barrios de la ciudad
    const ids = list.map((b) => b.id)
    if (ids.length === 0) {
      setExtras({})
      return
    }
    const { data: rows, error: rowsError } = await supabase
      .from('v_barrio_surcharges')
      .select('barrio_id, category, surcharge_usd')
      .in('barrio_id', ids)

    const map: Record<string, Record<string, number>> = {}
    if (!rowsError && rows) {
      ;(rows as Array<{ barrio_id: string; category: string; surcharge_usd: number }>).forEach((r) => {
        if (!map[r.barrio_id]) map[r.barrio_id] = {}
        map[r.barrio_id][r.category] = Number(r.surcharge_usd)
      })
    }
    setExtras(map)
  }

  // Valor que muestra la lista: fila explícita o el fallback del barrio
  const legacyExtraOf = (barrio: Barrio, name: string): number => {
    switch (name) {
      case 'moto': return barrio.surcharge_moto_usd ?? barrio.surcharge_usd ?? 0
      case 'carro': return barrio.surcharge_carro_usd ?? barrio.surcharge_usd ?? 0
      case 'camioneta': return barrio.surcharge_camioneta_usd ?? barrio.surcharge_usd ?? 0
      default: return barrio.surcharge_usd ?? 0
    }
  }

  const resetForm = () => {
    setEditing(null)
    setName('')
    setSurcharge('')
    setCatVals({})
    setDescription('')
    setLat(null)
    setLng(null)
    setCoordInput('')
    setCoordMsg(null)
  }

  // Vuelca en lat/lng el texto pegado de Google Maps (y opcionalmente mueve el mapa)
  const applyCoordsFromText = (text: string, moveMap: boolean) => {
    if (!text.trim()) {
      setCoordMsg(null)
      return
    }
    const parsed = parseCoords(text)
    if (!parsed) {
      setCoordMsg({ ok: false, text: 'No reconocí las coordenadas. Pega algo como: 8.238914, -70.814995' })
      return
    }
    setLat(parsed.lat)
    setLng(parsed.lng)
    setCoordInput(formatCoords(parsed.lat, parsed.lng))
    if (moveMap) focusMap(parsed.lat, parsed.lng)
    setCoordMsg({ ok: true, text: `Coordenadas aplicadas: ${formatCoords(parsed.lat, parsed.lng)}` })
  }

  const copyCoords = async () => {
    if (lat == null || lng == null) return
    try {
      await navigator.clipboard.writeText(formatCoords(lat, lng))
      setCopied(true)
      setTimeout(() => setCopied(false), 1500)
    } catch {
      setCoordMsg({ ok: false, text: formatCoords(lat, lng) })
    }
  }

  // Cambiar de ciudad: limpia el formulario y centra el mapa en esa ciudad
  const handleCityChange = (cityId: string) => {
    setSelectedCityId(cityId)
    resetForm()
    const city = cities.find((c) => c.id === cityId)
    if (city?.center_lat != null && city?.center_lng != null) {
      centeredOnceRef.current = true
      focusMap(city.center_lat, city.center_lng, 14)
    }
  }

  const handleEdit = async (barrio: Barrio) => {
    setEditing(barrio)
    if (barrio.zone_id) setSelectedCityId(barrio.zone_id)
    setName(barrio.name)
    setSurcharge(barrio.surcharge_usd?.toString() || '0')
    setDescription(barrio.description || '')
    setLat(barrio.lat || null)
    setLng(barrio.lng || null)

    // Coordenadas visibles/pegables + mapa enfocado en el barrio
    setCoordInput(barrio.lat != null && barrio.lng != null ? formatCoords(barrio.lat, barrio.lng) : '')
    setCoordMsg(null)
    if (barrio.lat != null && barrio.lng != null) {
      focusMap(barrio.lat, barrio.lng, 16)
    } else {
      focusMap(defaultCenter[0], defaultCenter[1], 14)
    }

    // Llevar directo al formulario, sin scroll manual
    formRef.current?.scrollIntoView({ behavior: 'smooth', block: 'start' })
    setHighlight(true)
    setTimeout(() => setHighlight(false), 1600)

    // Recargos ya guardados para este barrio (filas explícitas)
    const { data: rows } = await supabase
      .from('barrio_surcharges')
      .select('category, surcharge_usd')
      .eq('barrio_id', barrio.id)
    const explicit: Record<string, number> = {}
    if (rows) {
      ;(rows as Array<{ category: string; surcharge_usd: number }>).forEach((r) => {
        explicit[r.category] = Number(r.surcharge_usd)
      })
    }

    // Prellenar cada vehículo: fila explícita o el valor histórico actual
    const vals: Record<string, string> = {}
    cats.forEach((c) => {
      const expVal = explicit[c.name]
      if (expVal !== undefined) {
        vals[c.name] = String(expVal)
        return
      }
      if (c.name === 'moto' || c.name === 'carro' || c.name === 'camioneta') {
        vals[c.name] = String(legacyExtraOf(barrio, c.name))
      } else {
        vals[c.name] = ''
      }
    })
    setCatVals(vals)
  }

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault()
    setError('')

    if (!selectedCityId) {
      setError('Primero selecciona la ciudad a la que pertenece el barrio')
      return
    }

    if (!name || !surcharge) {
      setError('Completa el nombre y el recargo general')
      return
    }

    setSaving(true)

    try {
      // Recargos explícitos por categoría: solo los que tengan valor.
      // Un recargo vacío no se envía: esa categoría hereda (columna o general).
      const surchargesJson = cats
        .filter((c) => (catVals[c.name] ?? '').trim() !== '')
        .map((c) => ({
          category: c.name,
          surcharge_usd: parseFloat(catVals[c.name])
        }))

      const parseNullable = (v: string | undefined) =>
        v !== undefined && v.trim() !== '' ? parseFloat(v) : null

      const { data, error } = await supabase.rpc('upsert_barrio', {
        p_name: name,
        p_surcharge_usd: parseFloat(surcharge),
        p_zone_id: selectedCityId,
        p_surcharge_moto_usd: parseNullable(catVals['moto']),
        p_surcharge_carro_usd: parseNullable(catVals['carro']),
        p_surcharge_camioneta_usd: parseNullable(catVals['camioneta']),
        p_surcharges: surchargesJson,
        p_lat: lat,
        p_lng: lng,
        p_description: description || null,
        p_barrio_id: editing?.id || null
      })

      if (error) throw error

      resetForm()
      loadBarrios(selectedCityId)
    } catch (err: any) {
      setError(err.message)
    } finally {
      setSaving(false)
    }
  }

  const handleDelete = async (id: string) => {
    if (!confirm('¿Seguro que deseas eliminar este barrio?')) return

    const { error } = await supabase.from('barrios').delete().eq('id', id)

    if (!error) {
      loadBarrios(selectedCityId)
    }
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center gap-3">
          <AppLogo />
          <div>
            <h1 className="text-lg font-bold text-surface-800">Barrios</h1>
            <p className="text-xs text-surface-500">Configura los barrios de cada ciudad</p>
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6 space-y-6">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        {/* Selector de ciudad */}
        <div className="card p-3 flex items-center justify-between gap-2">
          <div className="flex items-center gap-2">
            <MapPin className="w-4 h-4 text-primary-600 flex-shrink-0" />
            <span className="text-sm font-medium text-surface-700">Ciudad:</span>
          </div>
          <select
            className="input w-auto py-1.5 text-sm font-medium"
            value={selectedCityId}
            onChange={(e) => handleCityChange(e.target.value)}
            aria-label="Selecciona la ciudad"
          >
            <option value="" disabled>Elige la ciudad…</option>
            {cities.map((c) => (
              <option key={c.id} value={c.id}>{c.name}</option>
            ))}
          </select>
        </div>

        <div>
          <h2 className="text-lg font-semibold text-surface-800 mb-3">Barrios existentes</h2>
          <HexUnderline />
          <div className="space-y-2">
            {barrios.map((barrio) => (
              <div key={barrio.id} className="card flex items-center justify-between">
                <div className="flex-1">
                  <p className="font-medium text-surface-700">{barrio.name}</p>
                  <p className="text-xs text-surface-400 flex flex-wrap gap-x-2">
                    {cats.map((c) => {
                      const eff = extras[barrio.id]?.[c.name]
                      if (eff === undefined) return null
                      return (
                        <span key={c.name}>{c.icon} {eff.toFixed(2)}$</span>
                      )
                    })}
                    {barrio.lat && barrio.lng && ' • 📍'}
                  </p>
                </div>
                <div className="flex items-center gap-1">
                  <button
                    onClick={() => handleEdit(barrio)}
                    className="p-2 text-accent-600 hover:bg-accent-50 rounded-lg transition-colors"
                  >
                    <Pencil className="w-4 h-4" />
                  </button>
                  <button
                    onClick={() => handleDelete(barrio.id)}
                    className="p-2 text-red-400 hover:bg-red-50 rounded-lg transition-colors"
                  >
                    <Trash2 className="w-4 h-4" />
                  </button>
                </div>
              </div>
            ))}
          </div>
        </div>

        <div
          ref={formRef}
          className={`scroll-mt-4 rounded-2xl transition-shadow duration-500 ${highlight ? 'ring-2 ring-primary-300 ring-offset-2' : ''}`}
        >
          <h2 className="text-lg font-semibold text-surface-800 mb-3">
            {editing ? `Editar: ${editing.name}` : 'Nuevo barrio'}
          </h2>
          <HexUnderline />

          <form onSubmit={handleSave} className="card space-y-4">
            <div>
              <label className="label">Nombre del barrio *</label>
              <input
                type="text"
                className="input"
                placeholder="Ej: Centro, Bum Bum, El Carmen"
                value={name}
                onChange={(e) => setName(e.target.value)}
                required
              />
            </div>

            <div className="space-y-3">
              <label className="label">Recargos del barrio (USD $)</label>
              <div className="rounded-xl border border-surface-200 bg-surface-50 p-3 space-y-2">
                <div className="flex items-center gap-2">
                  <label className="text-xs font-medium text-surface-600 flex-1">Recargo general (base)</label>
                  <input
                    type="number"
                    className="input w-24 text-right py-1.5"
                    step="0.50"
                    min="0"
                    placeholder="0.00"
                    value={surcharge}
                    onChange={(e) => setSurcharge(e.target.value)}
                    required
                  />
                </div>
                <div className="border-t border-surface-200" />
                {cats.length === 0 ? (
                  <p className="text-[11px] text-surface-400">Cargando tipos de vehículo…</p>
                ) : cats.map((c) => {
                  const v = catVals[c.name] ?? ''
                  const ph = surcharge || '0.00'
                  return (
                    <div key={c.name} className="flex items-center gap-2">
                      <label className="text-xs text-surface-600 flex-1 min-w-0 flex items-center gap-1.5">
                        <span className="text-base leading-none">{c.icon}</span>
                        <span className="truncate">{c.display_name}</span>
                      </label>
                      <input
                        type="number"
                        className="input w-24 text-right py-1.5"
                        step="0.10"
                        min="0"
                        placeholder={ph}
                        value={v}
                        onChange={(e) => setCatVals((s) => ({ ...s, [c.name]: e.target.value }))}
                      />
                    </div>
                  )
                })}
              </div>
              <p className="text-[10px] text-surface-400">
                El extra se suma a la tarifa base de cada vehículo. Vacío = usa el recargo general.
                Así la Moto de Carga puede tener un extra mayor que la Moto Básica en este barrio.
              </p>
            </div>

            <div>
              <label className="label">Descripción</label>
              <input
                type="text"
                className="input"
                placeholder="Descripción opcional"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
              />
            </div>

            <div>
              <label className="label">Ubicación aproximada en el mapa</label>
              {/* Pegar coordenadas de Google Maps (además de tocar el mapa) */}
              <div className="mb-3">
                <label className="label flex items-center gap-1.5">
                  <Navigation className="w-3.5 h-3.5" /> Pegar coordenadas de Google Maps
                </label>
                <input
                  type="text"
                  className="input"
                  placeholder="8.238914, -70.814995  (o el enlace largo de Google Maps)"
                  value={coordInput}
                  onChange={(e) => {
                    setCoordInput(e.target.value)
                    applyCoordsFromText(e.target.value, false)
                  }}
                  onPaste={(e) => {
                    const text = e.clipboardData.getData('text')
                    if (!text) return
                    e.preventDefault()
                    setCoordInput(text)
                    applyCoordsFromText(text, true)
                  }}
                  onBlur={() => applyCoordsFromText(coordInput, true)}
                  onKeyDown={(e) => {
                    if (e.key === 'Enter') {
                      e.preventDefault()
                      applyCoordsFromText(coordInput, true)
                    }
                  }}
                />
                <p className={`text-[11px] mt-1 ${coordMsg ? (coordMsg.ok ? 'text-emerald-600' : 'text-amber-600') : 'text-surface-400'}`}>
                  {coordMsg
                    ? coordMsg.text
                    : 'En Google Maps: mantén pulsado el punto y toca "Copiar coordenadas". También acepta el enlace largo.'}
                </p>
              </div>

              <div className="h-48 rounded-xl overflow-hidden shadow-soft relative">
                <MapContainer
                  center={defaultCenter}
                  zoom={14}
                  className="h-full w-full"
                >
                  <MapFocus target={mapFocus} />
                  <TileLayer
                    url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
                    attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
                  />
                  {lat && lng && <Marker position={[lat, lng]} icon={barrioIcon} />}
                  <MapClickHandler
                    onSelect={(l, lg) => {
                      // Marcar a mano NO mueve la vista: solo fija la posición
                      setLat(l)
                      setLng(lg)
                      setCoordInput(formatCoords(l, lg))
                      setCoordMsg(null)
                    }}
                  />
                </MapContainer>
                <div className="absolute top-2 left-2 bg-white rounded-lg shadow-card px-2 py-1 text-xs text-surface-600 z-[1000]">
                  <MapPin className="w-3 h-3 inline mr-1" />
                  {lat && lng ? 'Ubicación seleccionada' : 'Toca el mapa o pega las coordenadas'}
                </div>
              </div>
              {/* Coordenadas actuales: se pueden copiar o quitar */}
              {lat != null && lng != null && (
                <div className="flex items-center justify-between gap-2 mt-2">
                  <span className="text-[11px] text-surface-500 font-mono">{formatCoords(lat, lng)}</span>
                  <div className="flex items-center gap-1">
                    <button type="button" onClick={copyCoords} className="btn-outline text-[11px] px-2 py-1">
                      {copied ? (
                        <><Check className="w-3 h-3" /> Copiado</>
                      ) : (
                        <><Copy className="w-3 h-3" /> Copiar</>
                      )}
                    </button>
                    <button
                      type="button"
                      onClick={() => { setLat(null); setLng(null); setCoordInput(''); setCoordMsg(null) }}
                      className="btn-outline text-[11px] px-2 py-1"
                    >
                      <X className="w-3 h-3" /> Quitar
                    </button>
                  </div>
                </div>
              )}

            </div>

            <div className="flex gap-2">
              {editing && (
                <button type="button" onClick={resetForm} className="btn-outline flex-1">
                  Cancelar
                </button>
              )}
              <button type="submit" className="btn-primary flex-1" disabled={saving}>
                {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : <><Save className="w-4 h-4" /> Guardar</>}
              </button>
            </div>
          </form>
        </div>
      </div>
    </div>
  )
}