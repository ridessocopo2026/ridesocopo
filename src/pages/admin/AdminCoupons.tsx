import { useState, useEffect } from 'react'
import { Ticket, Plus, Trash2, Loader2 } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { fmt } from '@/lib/format'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { EmptyState } from '@/components/ui/EmptyState'
import { HexUnderline } from '@/components/ui/HexUnderline'
import type { Coupon } from '@/types/database'
import { AppLogo } from '@/components/ui/AppLogo'

export function AdminCoupons() {
  const [coupons, setCoupons] = useState<Coupon[]>([])
  const [showForm, setShowForm] = useState(false)
  const [code, setCode] = useState('')
  const [description, setDescription] = useState('')
  const [discountType, setDiscountType] = useState<'percentage' | 'fixed'>('percentage')
  const [discountValue, setDiscountValue] = useState('')
  const [maxUses, setMaxUses] = useState('')
  const [perUserLimit, setPerUserLimit] = useState('1')
  const [firstRideOnly, setFirstRideOnly] = useState(false)
  const [minFare, setMinFare] = useState('')
  const [validFrom, setValidFrom] = useState('')
  const [validUntil, setValidUntil] = useState('')
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const { user } = useAuth()

  useEffect(() => {
    loadCoupons()
  }, [])

  const loadCoupons = async () => {
    const { data, error } = await supabase
      .from('coupons')
      .select('*')
      .order('created_at', { ascending: false })

    if (!error && data) {
      setCoupons(data as Coupon[])
    }
    setLoading(false)
  }

  const handleCreate = async (e: React.FormEvent) => {
    e.preventDefault()
    setError('')

    if (!code || !discountValue) {
      setError('Completa el código y el valor del descuento')
      return
    }

    setSaving(true)

    try {
      const { data, error } = await supabase.rpc('create_coupon', {
        p_code: code,
        p_description: description || null,
        p_discount_type: discountType,
        p_discount_value: parseFloat(discountValue),
        p_max_uses: maxUses ? parseInt(maxUses) : null,
        p_valid_from: validFrom ? new Date(validFrom).toISOString() : null,
        p_valid_until: validUntil ? new Date(validUntil).toISOString() : null,
        p_per_user_limit: perUserLimit ? parseInt(perUserLimit) : 1,
        p_first_ride_only: firstRideOnly,
        p_min_fare_usd: minFare ? parseFloat(minFare) : 0
      })

      if (error) throw error

      setCode('')
      setDescription('')
      setDiscountValue('')
      setMaxUses('')
      setPerUserLimit('1')
      setFirstRideOnly(false)
      setMinFare('')
      setValidFrom('')
      setValidUntil('')
      setShowForm(false)
      loadCoupons()
    } catch (err: any) {
      setError(err.message)
    } finally {
      setSaving(false)
    }
  }

  const handleDelete = async (id: string) => {
    if (!confirm('¿Eliminar este cupón?')) return

    const { error } = await supabase
      .from('coupons')
      .delete()
      .eq('id', id)

    if (!error) {
      loadCoupons()
    }
  }

  const handleToggle = async (coupon: Coupon) => {
    const { error } = await supabase
      .from('coupons')
      .update({ is_active: !coupon.is_active })
      .eq('id', coupon.id)

    if (!error) {
      loadCoupons()
    }
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <AppLogo />
            <div>
              <h1 className="text-lg font-bold text-surface-800">Cupones de Descuento</h1>
              <p className="text-xs text-surface-500">Crea códigos promocionales</p>
            </div>
          </div>
          <button onClick={() => setShowForm(!showForm)} className="btn-primary">
            <Plus className="w-4 h-4" />
            Nuevo
          </button>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}
        <HexUnderline />

        {showForm && (
          <form onSubmit={handleCreate} className="card space-y-4 mb-6 animate-fade-in">
            <h2 className="font-semibold text-surface-800">Nuevo cupón</h2>

            <div>
              <label className="label">Código *</label>
              <input
                type="text"
                className="input uppercase"
                placeholder="RIDERFLASSHI10"
                value={code}
                onChange={(e) => setCode(e.target.value.toUpperCase())}
                required
              />
            </div>

            <div>
              <label className="label">Descripción</label>
              <input
                type="text"
                className="input"
                placeholder="10% de descuento"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
              />
            </div>

            <div>
              <label className="label">Tipo de descuento</label>
              <div className="grid grid-cols-2 gap-2">
                <button
                  type="button"
                  onClick={() => setDiscountType('percentage')}
                  className={`p-3 rounded-xl border-2 text-sm font-medium transition-all ${
                    discountType === 'percentage'
                      ? 'border-primary-600 bg-primary-50 text-primary-700'
                      : 'border-surface-200 text-surface-600'
                  }`}
                >
                  Porcentaje (%)
                </button>
                <button
                  type="button"
                  onClick={() => setDiscountType('fixed')}
                  className={`p-3 rounded-xl border-2 text-sm font-medium transition-all ${
                    discountType === 'fixed'
                      ? 'border-primary-600 bg-primary-50 text-primary-700'
                      : 'border-surface-200 text-surface-600'
                  }`}
                >
                  Monto fijo ($)
                </button>
              </div>
            </div>

            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className="label">
                  {discountType === 'percentage' ? 'Porcentaje (%)' : 'Monto ($)'}
                </label>
                <input
                  type="number"
                  className="input"
                  step="0.01"
                  min="0"
                  placeholder={discountType === 'percentage' ? '10' : '1.00'}
                  value={discountValue}
                  onChange={(e) => setDiscountValue(e.target.value)}
                  required
                />
              </div>
              <div>
                <label className="label">Usos máximos</label>
                <input
                  type="number"
                  className="input"
                  min="1"
                  placeholder="Ilimitado"
                  value={maxUses}
                  onChange={(e) => setMaxUses(e.target.value)}
                />
              </div>
            </div>

            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className="label">Usos por usuario</label>
                <input
                  type="number"
                  className="input"
                  min="1"
                  placeholder="1"
                  value={perUserLimit}
                  onChange={(e) => setPerUserLimit(e.target.value)}
                />
              </div>
              <div>
                <label className="label">Monto mínimo del viaje ($)</label>
                <input
                  type="number"
                  className="input"
                  step="0.01"
                  min="0"
                  placeholder="0.00 (sin mínimo)"
                  value={minFare}
                  onChange={(e) => setMinFare(e.target.value)}
                />
              </div>
            </div>

            <label className="flex items-center gap-2 cursor-pointer">
              <input
                type="checkbox"
                className="w-5 h-5 accent-primary-600"
                checked={firstRideOnly}
                onChange={(e) => setFirstRideOnly(e.target.checked)}
              />
              <span className="text-sm font-medium text-surface-700">Solo aplica en el primer viaje</span>
            </label>

            <div className="grid grid-cols-2 gap-4">
              <div>
                <label className="label">Válido desde</label>
                <input
                  type="datetime-local"
                  className="input"
                  value={validFrom}
                  onChange={(e) => setValidFrom(e.target.value)}
                />
              </div>
              <div>
                <label className="label">Válido hasta</label>
                <input
                  type="datetime-local"
                  className="input"
                  value={validUntil}
                  onChange={(e) => setValidUntil(e.target.value)}
                />
              </div>
            </div>

            <button type="submit" className="btn-primary w-full" disabled={saving}>
              {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Crear cupón'}
            </button>
          </form>
        )}

        {coupons.length === 0 ? (
          <EmptyState
            icon={<Ticket className="w-8 h-8" />}
            title="Sin cupones"
            description="Crea tu primer código promocional"
          />
        ) : (
          <div className="space-y-3">
            {coupons.map((coupon) => (
              <div key={coupon.id} className="card">
                <div className="flex items-start justify-between">
                  <div className="flex-1">
                    <div className="flex items-center gap-2">
                      <span className="font-mono font-bold text-primary-600">{coupon.code}</span>
                      <span className={`badge ${
                        coupon.discount_type === 'percentage' ? 'badge-info' : 'badge-primary'
                      }`}>
                        {coupon.discount_type === 'percentage'
                          ? `${coupon.discount_value}%`
                          : `${coupon.discount_value.toFixed(2)}$`}
                      </span>
                      {coupon.first_ride_only && (
                        <span className="badge badge-warning">Primer viaje</span>
                      )}
                      {coupon.per_user_limit != null && coupon.per_user_limit > 0 && (
                        <span className="badge badge-info">{coupon.per_user_limit}× por usuario</span>
                      )}
                    </div>
                    {coupon.description && (
                      <p className="text-sm text-surface-500 mt-1">{coupon.description}</p>
                    )}
                    <p className="text-xs text-surface-400 mt-1">
                      Usados: {coupon.used_count}{coupon.max_uses ? ` / ${coupon.max_uses}` : ''}
                      {coupon.min_fare_usd && coupon.min_fare_usd > 0 ? ` • Mín. ${fmt(coupon.min_fare_usd)}` : ''}
                      {coupon.valid_from ? ` • Desde ${new Date(coupon.valid_from).toLocaleDateString('es-VE')}` : ''}
                      {coupon.valid_until ? ` • Hasta ${new Date(coupon.valid_until).toLocaleDateString('es-VE')}` : ''}
                    </p>
                  </div>
                  <div className="flex items-center gap-2">
                    <button
                      onClick={() => handleToggle(coupon)}
                      className={`px-3 py-1 rounded-full text-xs font-medium transition-colors ${
                        coupon.is_active
                          ? 'bg-emerald-50 text-emerald-700'
                          : 'bg-surface-100 text-surface-500'
                      }`}
                    >
                      {coupon.is_active ? 'Activo' : 'Inactivo'}
                    </button>
                    <button
                      onClick={() => handleDelete(coupon.id)}
                      className="p-2 text-red-400 hover:text-red-600 transition-colors"
                    >
                      <Trash2 className="w-4 h-4" />
                    </button>
                  </div>
                </div>
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}