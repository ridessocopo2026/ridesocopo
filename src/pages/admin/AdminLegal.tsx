import { useState, useEffect } from 'react'
import { FileText, Loader2, Save, ShieldCheck, CheckCircle2 } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { AppLogo } from '@/components/ui/AppLogo'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { HexUnderline } from '@/components/ui/HexUnderline'

interface LegalSection {
  key: string
  label: string
  description: string
  title: string
  content: string
}

const SECTIONS: { key: string; label: string; description: string }[] = [
  { key: 'politicas_privacidad', label: 'Políticas de Privacidad', description: 'Texto público de privacidad' },
  { key: 'terminos_condiciones', label: 'Términos y Condiciones', description: 'Texto público de términos de uso' },
  { key: 'sobre_riderflash', label: 'Sobre RiderFlasshi', description: 'Información sobre la empresa/app' },
]

export function AdminLegal() {
  const [sections, setSections] = useState<Record<string, { title: string; content: string }>>({})
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const [saved, setSaved] = useState(false)

  useEffect(() => {
    loadSections()
  }, [])

  const loadSections = async () => {
    setLoading(true)
    const keys = SECTIONS.map((s) => s.key)
    const { data, error } = await supabase
      .from('legal_pages')
      .select('key, title, content')
      .in('key', keys)

    if (error) {
      setError(error.message)
    } else {
      const map: Record<string, { title: string; content: string }> = {}
      for (const s of SECTIONS) {
        const row = data?.find((d: any) => d.key === s.key)
        map[s.key] = { title: row?.title || '', content: row?.content || '' }
      }
      setSections(map)
    }
    setLoading(false)
  }

  const handleSave = async () => {
    setError('')
    setSaved(false)
    setSaving(true)

    try {
      for (const s of SECTIONS) {
        const cur = sections[s.key]
        if (!cur || !cur.title.trim() || !cur.content.trim()) {
          throw new Error(`"${s.label}" necesita título y contenido`)
        }
        const { error } = await supabase.rpc('save_legal_page', {
          p_key: s.key,
          p_title: cur.title.trim(),
          p_content: cur.content,
        })
        if (error) throw error
      }
      setSaved(true)
      setTimeout(() => setSaved(false), 3000)
    } catch (err: any) {
      setError(err.message || 'Error al guardar')
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
            <h1 className="text-lg font-bold text-surface-800">Contenido Legal</h1>
            <p className="text-xs text-surface-500">Privacidad, términos y sobre la app</p>
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6 space-y-5">
        {error && <ErrorMessage message={error} onDismiss={() => setError('')} />}
        <HexUnderline />

        {saved && (
          <div className="flex items-center gap-2 bg-emerald-50 text-emerald-700 border border-emerald-200 rounded-xl px-4 py-3 text-sm font-medium">
            <CheckCircle2 className="w-4 h-4" /> Contenido guardado correctamente.
          </div>
        )}

        {loading ? (
          <div className="space-y-4">
            <div className="skeleton h-40 rounded-2xl" />
            <div className="skeleton h-40 rounded-2xl" />
          </div>
        ) : (
          <>
            {SECTIONS.map((s) => (
              <div key={s.key} className="card space-y-3">
                <div className="flex items-center gap-3">
                  <div className="w-10 h-10 bg-primary-50 rounded-xl flex items-center justify-center text-primary-600">
                    <FileText className="w-5 h-5" />
                  </div>
                  <div>
                    <h3 className="font-semibold text-surface-700">{s.label}</h3>
                    <p className="text-xs text-surface-400">{s.description}</p>
                  </div>
                </div>

                <div>
                  <label className="label">Título</label>
                  <input
                    className="input"
                    value={sections[s.key]?.title || ''}
                    onChange={(e) =>
                      setSections((prev) => ({ ...prev, [s.key]: { ...prev[s.key], title: e.target.value } }))
                    }
                    placeholder={`Título de ${s.label.toLowerCase()}`}
                  />
                </div>

                <div>
                  <label className="label">Contenido</label>
                  <textarea
                    className="input min-h-[180px] resize-y leading-relaxed"
                    value={sections[s.key]?.content || ''}
                    onChange={(e) =>
                      setSections((prev) => ({ ...prev, [s.key]: { ...prev[s.key], content: e.target.value } }))
                    }
                    placeholder="Escribe el contenido..."
                  />
                  <p className="text-[11px] text-surface-400 mt-1">Usa saltos de línea para separar párrafos.</p>
                </div>
              </div>
            ))}

            <div className="flex items-center gap-2 text-[11px] text-surface-400">
              <ShieldCheck className="w-4 h-4" />
              Solo el Super Administrador puede editar este contenido.
            </div>

            <button onClick={handleSave} className="btn-primary w-full" disabled={saving}>
              {saving ? <Loader2 className="w-4 h-4 animate-spin" /> : <><Save className="w-4 h-4" /> Guardar todo</>}
            </button>
          </>
        )}
      </div>
    </div>
  )
}
