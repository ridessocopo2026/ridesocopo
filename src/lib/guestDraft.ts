/**
 * Borrador del invitado (sin sesión) para no perder lo que ya eligió
 * cuando la app lo manda a iniciar sesión o a registrarse.
 *
 * Se guarda en sessionStorage (por pestaña y se descarta al cerrarla)
 * y expira solo a los 30 minutos; así nunca queda basura entre visitas.
 */

import type { VehicleCategoryType } from '@/types/database'

const GUEST_DRAFT_KEY = 'rider_guest_draft'
const GUEST_DRAFT_TTL_MS = 30 * 60 * 1000 // 30 minutos

export interface GuestDraft {
  cityId: string
  destBarrioId: string
  destAddress: string
  category: VehicleCategoryType | null
  origin: { lat: number; lng: number } | null
  originAddress: string
  savedAt: number
}

export function saveGuestDraft(draft: Omit<GuestDraft, 'savedAt'>): void {
  try {
    sessionStorage.setItem(GUEST_DRAFT_KEY, JSON.stringify({ ...draft, savedAt: Date.now() }))
  } catch (_) {
    // sessionStorage no disponible (modo privado estricto)
  }
}

export function loadGuestDraft(): GuestDraft | null {
  try {
    const raw = sessionStorage.getItem(GUEST_DRAFT_KEY)
    if (!raw) return null
    const draft = JSON.parse(raw) as GuestDraft
    if (!draft || typeof draft.savedAt !== 'number') return null
    // Caducado → descartar
    if (Date.now() - draft.savedAt > GUEST_DRAFT_TTL_MS) {
      clearGuestDraft()
      return null
    }
    return draft
  } catch (_) {
    return null
  }
}

export function clearGuestDraft(): void {
  try {
    sessionStorage.removeItem(GUEST_DRAFT_KEY)
  } catch (_) {
    // sessionStorage no disponible
  }
}
