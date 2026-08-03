import { useState, useEffect } from 'react'
import { Wallet, Banknote, Smartphone, CreditCard, Plus, Trash2, Loader2, Pencil, Copy, ShieldCheck } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { EmptyState } from '@/components/ui/EmptyState'
import type { PaymentMethodConfig, PaymentMethodField } from '@/types/database'

const iconMap: Record<string, React.ReactNode> = {
  wallet: <Wallet className="w-5 h-5" />,
  cash: <Banknote className="w-5 h-5" />,
  phone: <Smartphone className="w-5 h-5" />,
  card: <CreditCard className="w-5 h-5" />,
  default: <Wallet className="w-5 h-5" />
}

export function AdminPaymentMethods() {
  const [methods, setMethods] = useState<PaymentMethodConfig[]>([])
  const [fieldsMap, setFieldsMap] = useState<Record<string, PaymentMethodField[]>>({})
  const [expanded, setExpanded] = useState<string | null>(null)
  const [showForm, setShowForm] = useState(false)
  const [editing, setEditing] = useState<PaymentMethodConfig | null>(null)
  const [name, setName] = useState('')
  const [description, setDescription] = useState('')
  const [icon, setIcon] = useState('wallet')
  const [proofRequired, setProofRequired] = useState(false)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const { user } = useAuth()

  // Estado para campo nuevo
  const [newFieldLabel, setNewFieldLabel] = useState('')
  const [newFieldValue, setNewFieldValue] = useState('')

  useEffect(() => {
    loadMethods()
  }, [])

  const loadMethods = async () => {
    const { data, error } = await supabase
      .from('payment_methods')
      .select('*')
      .order('name')

    if (!error && data) {
      setMethods(data as PaymentMethodConfig[])
      // Cargar campos de cada método
      const newFields: Record<string, PaymentMethodField[]> = {}
      for (const m of data as PaymentMethodConfig[]) {
        const { data: fieldData } = await supabase
          .from('payment_method_fields')
          .select('*')
          .eq('payment_method_id', m.id)
        if (fieldData) {
          newFields[m.id] = fieldData as PaymentMethodField[]
        }
      }
      setFieldsMap(newFields)
    }
    setLoading(false)
  }

  const resetForm = () => {
    setEditing(null)
    setName('')
    setDescription('')
    setIcon('wallet')
    setProofRequired(false)
    setShowForm(false)
  }

  const handleEdit = (method: PaymentMethodConfig) => {
    setEditing(method)
    setName(method.name)
    setDescription(method.description || '')
    setIcon(method.icon || 'wallet')
    setProofRequired(method.proof_required || false)
    setShowForm(true)
  }

  const handleSave = async (e: React.FormEvent) => {
    e.preventDefault()
    setError('')

    if (!name) {
      setError('El nombre es obligatorio')
      return
    }

    setSaving(true)

    try {
      if (editing) {
        const { error } = await supabase
          .from('payment_methods')
          .update({ name, description, icon, proof_required: proofRequired })
          .eq('id', editing.id)
        if (error) throw error
      } else {
        const { error } = await supabase
          .from('payment_methods')
          .insert({ name, description, icon, proof_required: proofRequired })
        if (error) throw error
      }

      resetForm()
      loadMethods()
    } catch (err: any) {
      setError(err.message)
    } finally {
      setSaving(false)
    }
  }

  const handleToggle = async (method: PaymentMethodConfig) => {
    const { error } = await supabase
      .from('payment_methods')
      .update({ is_active: !method.is_active })
      .eq('id', method.id)

    if (!error) {
      loadMethods()
    }
  }

  const handleDelete = async (id: string) => {
    if (!confirm('¿Seguro que deseas eliminar este método de pago?')) return

    const { error } = await supabase
      .from('payment_methods')
      .delete()
      .eq('id', id)

    if (!error) {
      loadMethods()
    }
  }

  const toggleExpanded = (id: string) => {
    setExpanded(expanded === id ? null : id)
  }

  const handleAddField = async (methodId: string) => {
    if (!newFieldLabel || !newFieldValue) {
      setError('Completa el label y el valor del campo')
      return
    }
    setError('')
    setSaving(true)

    const { error } = await supabase
      .from('payment_method_fields')
      .insert({ payment_method_id: methodId, label: newFieldLabel, value: newFieldValue })

    if (error) {
      setError(error.message)
    } else {
      setNewFieldLabel('')
      setNewFieldValue('')
      loadMethods()
    }
    setSaving(false)
  }

  const handleDeleteField = async (fieldId: string) => {
    const { error } = await supabase
      .from('payment_method_fields')
      .delete()
      .eq('id', fieldId)

    if (!error) {
      loadMethods()
    }
  }

  const iconOptions = [
    { value: 'wallet', label: 'Billetera' },
    { value: 'cash', label: 'Efectivo' },
    { value: 'phone', label: 'Pago Móvil' },
    { value: 'card', label: 'Tarjeta' }
  ]

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 bg-primary-600 rounded-xl flex items-center justify-center">
              <Wallet className="w-5 h-5 text-white" />
            </div>
            <div>
              <h1 className="text-lg font-bold text-surface-800">Métodos de Pago</h1>
              <p className="text-xs text-surface-500">Controla métodos, campos y comprobantes</p>
            </div>
          </div>
          <button onClick={() => { resetForm(); setShowForm(!showForm) }} className="btn-primary">
            <Plus className="w-4 h-4" />
            Nuevo
          </button>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}

        {showForm && (
          <form onSubmit={handleSave} className="card space-y-4 mb-6 animate-fade-in">
            <h2 className="font-semibold text-surface-800">{editing ? `Editar: ${editing.name}` : 'Nuevo método de pago'}</h2>

            <div>
              <label className="label">Nombre *</label>
              <input
                type="text"
                className="input"
                placeholder="Ej: Zelle, Pago Móvil, Tarjeta"
                value={name}
                onChange={(e) => setName(e.target.value)}
                required
              />
            </div>

            <div>
              <label className="label">Descripción</label>
              <input
                type="text"
                className="input"
                placeholder="Descripción corta"
                value={description}
                onChange={(e) => setDescription(e.target.value)}
              />
            </div>

            <div>
              <label className="label">Ícono</label>
              <div className="grid grid-cols-2 gap-2">
                {iconOptions.map((opt) => (
                  <button
                    key={opt.value}
                    type="button"
                    onClick={() => setIcon(opt.value)}
                    className={`p-3 rounded-xl border-2 text-sm font-medium transition-all ${
                      icon === opt.value
                        ? 'border-primary-600 bg-primary-50 text-primary-700'
                        : 'border-surface-200 text-surface-600'
                    }`}
                  >
                    {opt.label}
                  </button>
                ))}
              </div>
            </div>

            <div className="flex items-center justify-between bg-surface-50 rounded-xl p-3">
              <div className="flex items-center gap-2">
                <ShieldCheck className="w-5 h-5 text-primary-600" />
                <div>
                  <p className="text-sm font-medium text-surface-700">Requiere comprobante</p>
                  <p className="text-xs text-surface-400">El cliente debe subir captura del pago</p>
                </div>
              </div>
              <button
                type="button"
                onClick={() => setProofRequired(!proofRequired)}
                className={`switch ${proofRequired ? 'bg-primary-600' : 'bg-surface-200'}`}
              >
                <span className={`switch-thumb ${proofRequired ? 'translate-x-5' : 'translate-x-1'}`} />
              </button>
            </div>

            <div className="flex gap-2">
              <button type="button" onClick={resetForm} className="btn-outline flex-1">
                Cancelar
              </button>
              <button type="submit" className="btn-primary flex-1" disabled={saving}>
                {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : 'Guardar'}
              </button>
            </div>
          </form>
        )}

        {loading ? (
          <div className="space-y-3">
            <div className="skeleton h-20 rounded-2xl" />
            <div className="skeleton h-20 rounded-2xl" />
          </div>
        ) : methods.length === 0 ? (
          <EmptyState
            icon={<Wallet className="w-8 h-8" />}
            title="Sin métodos de pago"
            description="Agrega el primer método de pago"
          />
        ) : (
          <div className="space-y-3">
            {methods.map((method) => (
              <div key={method.id} className="card">
                <div className="flex items-center justify-between">
                  <div className="flex items-center gap-3">
                    <div className="w-12 h-12 bg-primary-50 rounded-xl flex items-center justify-center text-primary-600">
                      {iconMap[method.icon || 'default']}
                    </div>
                    <div>
                      <p className="font-medium text-surface-700">{method.name}</p>
                      <p className="text-xs text-surface-400">
                        {method.proof_required ? '🖼️ Requiere comprobante' : '💵 Pago directo'}
                      </p>
                    </div>
                  </div>
                  <div className="flex items-center gap-2">
                    <button
                      onClick={() => handleToggle(method)}
                      className={`px-3 py-1 rounded-full text-xs font-medium transition-colors ${
                        method.is_active
                          ? 'bg-emerald-50 text-emerald-700'
                          : 'bg-surface-100 text-surface-500'
                      }`}
                    >
                      {method.is_active ? 'Activo' : 'Inactivo'}
                    </button>
                    <button
                      onClick={() => handleEdit(method)}
                      className="p-2 text-accent-600 hover:bg-accent-50 rounded-lg transition-colors"
                    >
                      <Pencil className="w-4 h-4" />
                    </button>
                    <button
                      onClick={() => handleDelete(method.id)}
                      className="p-2 text-red-400 hover:bg-red-50 rounded-lg transition-colors"
                    >
                      <Trash2 className="w-4 h-4" />
                    </button>
                  </div>
                </div>

                {/* Expandir campos */}
                <button
                  onClick={() => toggleExpanded(method.id)}
                  className="mt-3 w-full text-center text-xs text-primary-600 font-medium py-1 hover:bg-primary-50 rounded-lg transition-colors"
                >
                  {expanded === method.id ? 'Ocultar campos ▼' : 'Configurar campos de pago ▾'}
                </button>

                {expanded === method.id && (
                  <div className="mt-3 space-y-2 animate-fade-in">
                    {fieldsMap[method.id]?.map((field) => (
                      <div key={field.id} className="flex items-center gap-2 bg-surface-50 rounded-lg p-2">
                        <Copy className="w-4 h-4 text-primary-600 flex-shrink-0" />
                        <div className="flex-1 min-w-0">
                          <p className="text-xs text-surface-400 truncate">{field.label}</p>
                          <p className="text-sm font-medium text-surface-700 truncate">{field.value}</p>
                        </div>
                        <button
                          onClick={() => handleDeleteField(field.id)}
                          className="p-1.5 text-red-400 hover:bg-red-50 rounded-lg transition-colors"
                        >
                          <Trash2 className="w-4 h-4" />
                        </button>
                      </div>
                    ))}

                    {/* Agregar campo */}
                    <div className="space-y-2">
                      <input
                        type="text"
                        className="input text-sm"
                        placeholder="Label: Número Pago Móvil"
                        value={newFieldLabel}
                        onChange={(e) => setNewFieldLabel(e.target.value)}
                      />
                      <input
                        type="text"
                        className="input text-sm"
                        placeholder="Valor: 0412-0000000"
                        value={newFieldValue}
                        onChange={(e) => setNewFieldValue(e.target.value)}
                      />
                      <button
                        onClick={() => handleAddField(method.id)}
                        className="btn-outline w-full text-sm"
                        disabled={saving}
                      >
                        <Plus className="w-4 h-4" />
                        Agregar campo
                      </button>
                    </div>
                  </div>
                )}
              </div>
            ))}
          </div>
        )}
      </div>
    </div>
  )
}