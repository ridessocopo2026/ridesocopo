import { useState, useEffect } from 'react'
import { FileText, Loader2, Save, ShieldCheck, CheckCircle2, ExternalLink } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { AppLogo } from '@/components/ui/AppLogo'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { HexUnderline } from '@/components/ui/HexUnderline'

interface LegalSection {
  key: string
  legacyKey?: string
  label: string
  description: string
  path: string
}

interface SectionValue {
  title: string
  content: string
  updated_at?: string
}

/**
 * Páginas legales editables por el Super Administrador.
 * El contenido se guarda en public.legal_pages y se publica al
 * instante en las páginas públicas de la app.
 */
const SECTIONS: LegalSection[] = [
  {
    key: 'politicas_privacidad',
    label: 'Políticas de Privacidad',
    description: 'Texto público de privacidad',
    path: '/politicas-de-privacidad',
  },
  {
    key: 'terminos_condiciones',
    label: 'Términos y Condiciones',
    description: 'Texto público de términos de uso',
    path: '/terminos-y-condiciones',
  },
  {
    key: 'sobre_bunrider',
    legacyKey: 'sobre_riderflash',
    label: 'Sobre BunRider',
    description: 'Información sobre la empresa y la app',
    path: '/sobre-bunrider',
  },
]

export function AdminLegal() {
  const [sections, setSections] = useState<Record<string, SectionValue>>({})
  const [resolvedKeys, setResolvedKeys] = useState<Record<string, string>>({})
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const [saved, setSaved] = useState(false)

  useEffect(() => {
    loadSections()
  }, [])

  const loadSections = async () => {
    setLoading(true)
    setError('')
    const keys = SECTIONS.flatMap((s) => (s.legacyKey ? [s.key, s.legacyKey] : [s.key]))
    const { data, error } = await supabase
      .from('legal_pages')
      .select('key, title, content, updated_at')
      .in('key', keys)

    if (error) {
      setError(error.message)
    } else {
      const rows = (data || []) as { key: string; title: string; content: string; updated_at: string }[]
      const values: Record<string, SectionValue> = {}
      const keysById: Record<string, string> = {}
      for (const s of SECTIONS) {
        const row = rows.find((d) => d.key === s.key) || (s.legacyKey ? rows.find((d) => d.key === s.legacyKey) : undefined)
        values[s.key] = { title: row?.title || '', content: row?.content || '', updated_at: row?.updated_at }
        keysById[s.key] = row?.key || s.key
      }
      setSections(values)
      setResolvedKeys(keysById)
    }
    setLoading(false)
  }

  const updateSection = (key: string, patch: Partial<SectionValue>) => {
    setSections((prev) => ({ ...prev, [key]: { ...prev[key], ...patch } }))
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
        // Se guarda con la clave real existente en la base de datos
        // (sobre_bunrider o su clave heredada sobre_riderflash).
        const { error } = await supabase.rpc('save_legal_page', {
          p_key: resolvedKeys[s.key] || s.key,
          p_title: cur.title.trim(),
          p_content: cur.content,
        })
        if (error) throw error
      }
      await loadSections()
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
            <h1 className="text-lg font-bold text-surface-800">Contenido legal</h1>
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
            <div className="skeleton h-40 rounded-2xl" />
          </div>
        ) : (
          <>
            {SECTIONS.map((s) => (
              <div key={s.key} className="card space-y-3">
                <div className="flex items-start justify-between gap-3">
                  <div className="flex items-center gap-3 min-w-0">
                    <div className="w-10 h-10 bg-primary-50 rounded-xl flex items-center justify-center text-primary-600 shrink-0">
                      <FileText className="w-5 h-5" />
                    </div>
                    <div className="min-w-0">
                      <h3 className="font-semibold text-surface-700 truncate">{s.label}</h3>
                      <p className="text-xs text-surface-400">{s.description}</p>
                    </div>
                  </div>
                  <a
                    href={s.path}
                    target="_blank"
                    rel="noopener noreferrer"
                    className="shrink-0 inline-flex items-center gap-1 text-xs font-medium text-primary-600 hover:underline"
                  >
                    Ver <ExternalLink className="w-3.5 h-3.5" />
                  </a>
                </div>

                {sections[s.key]?.updated_at && (
                  <p className="text-[11px] text-surface-400">
                    Última actualización:{' '}
                    {new Date(sections[s.key].updated_at as string).toLocaleString('es-VE', {
                      day: 'numeric',
                      month: 'short',
                      year: 'numeric',
                      hour: '2-digit',
                      minute: '2-digit',
                    })}
                  </p>
                )}

                <div>
                  <label className="label">Título</label>
                  <input
                    className="input"
                    value={sections[s.key]?.title || ''}
                    onChange={(e) => updateSection(s.key, { title: e.target.value })}
                    placeholder={`Título de ${s.label.toLowerCase()}`}
                  />
                </div>

                <div>
                  <label className="label">Contenido</label>
                  <textarea
                    className="input min-h-[220px] resize-y leading-relaxed"
                    value={sections[s.key]?.content || ''}
                    onChange={(e) => updateSection(s.key, { content: e.target.value })}
                    placeholder="Escribe el contenido..."
                  />
                  <p className="text-[11px] text-surface-400 mt-1">
                    {(sections[s.key]?.content || '').length} caracteres · usa saltos de línea para separar párrafos.
                  </p>
                </div>
              </div>
            ))}

            <div className="flex items-center gap-2 text-[11px] text-surface-400">
              <ShieldCheck className="w-4 h-4" />
              Solo el Super Administrador edita este contenido; los cambios se publican al instante.
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