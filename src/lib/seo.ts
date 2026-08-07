import { useEffect } from 'react'

/**
 * Establece el <title> y la meta description de la página actual
 * (buena práctica SEO para SPA).
 */
export function usePageMeta(title: string, description?: string) {
  useEffect(() => {
    if (title) document.title = title

    if (description) {
      let el = document.querySelector('meta[name="description"]')
      if (!el) {
        el = document.createElement('meta')
        el.setAttribute('name', 'description')
        document.head.appendChild(el)
      }
      el.setAttribute('content', description)
    }
  }, [title, description])
}
