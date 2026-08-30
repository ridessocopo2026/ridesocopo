import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { ArrowLeft, Loader2, FileText } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { AppLogo } from '@/components/ui/AppLogo'
import { ErrorMessage } from '@/components/ui/ErrorMessage'
import { usePageMeta } from '@/lib/seo'

interface LegalPageProps {
  pageKey: 'politicas_privacidad' | 'terminos_condiciones' | 'sobre_riderflash'
}

interface LegalContent {
  title: string
  content: string
  updated_at?: string
}

export function LegalPage({ pageKey }: LegalPageProps) {
  const [page, setPage] = useState<LegalContent | null>(null)
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const navigate = useNavigate()

  useEffect(() => {
    let mounted = true
    setLoading(true)
    setError('')

    supabase
      .from('legal_pages')
      .select('title, content, updated_at')
      .eq('key', pageKey)
      .maybeSingle()
      .then(({ data, error }) => {
        if (!mounted) return
        if (error) {
          setError('No se pudo cargar el contenido. Intenta de nuevo.')
        } else if (data) {
          setPage(data as LegalContent)
        } else {
          setError('Contenido no disponible por el momento.')
        }
        setLoading(false)
      })

    return () => { mounted = false }
  }, [pageKey])

  usePageMeta(page?.title || 'BunRider', page?.content?.slice(0, 155))

  return (
    <div className="min-h-screen bg-surface-50">
      <div className="bg-primary-600 border-b border-primary-700 px-6 py-4">
        <div className="flex items-center gap-3">
          <button
            onClick={() => navigate(-1)}
            className="p-2 -ml-2 text-white/90 hover:text-white transition-colors"
            aria-label="Volver"
          >
            <ArrowLeft className="w-5 h-5" />
          </button>
          <AppLogo variant="dark" size="sm" />
          <h1 className="text-lg font-bold text-white flex-1 min-w-0 truncate">
            {page?.title || 'BunRider'}
          </h1>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6">
        {loading ? (
          <div className="flex justify-center py-12">
            <Loader2 className="w-6 h-6 animate-spin text-primary-600" />
          </div>
        ) : error ? (
          <ErrorMessage message={error} onDismiss={() => setError('')} />
        ) : page ? (
          <>
            <article className="card whitespace-pre-wrap leading-relaxed text-surface-700 text-sm">
              {page.content}
            </article>
            {page.updated_at && (
              <p className="text-center text-[11px] text-surface-400 mt-4">
                Última actualización: {new Date(page.updated_at).toLocaleDateString('es-VE', { day: 'numeric', month: 'short', year: 'numeric' })}
              </p>
            )}
          </>
        ) : null}
      </div>

      <div className="max-w-md mx-auto px-4 pb-8 flex justify-center">
        <div className="flex items-center gap-2 text-xs text-surface-400">
          <FileText className="w-3.5 h-3.5" />
          <span>BunRider — Transporte en Socopó, Barinas</span>
        </div>
      </div>
    </div>
  )
}
