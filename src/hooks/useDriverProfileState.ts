import { useCallback, useEffect, useState } from 'react'
import { supabase } from '@/lib/supabase'
import { useAuth } from '@/contexts/AuthContext'

export interface DriverDocumentsState {
  cedula_number: string | null
  cedula_photo_url: string | null
  license_number: string | null
  license_photo_url: string | null
  license_expiry_date: string | null
}

export interface DriverProfileState {
  approved: boolean
  complete: boolean
  missing: string[]
  has_vehicle: boolean
  has_approved_vehicle: boolean
  pending_request: boolean
  license_expired: boolean
  phone: string | null
  documents: DriverDocumentsState | null
}

export function useDriverProfileState() {
  const { user } = useAuth()
  const [state, setState] = useState<DriverProfileState | null>(null)
  const [loading, setLoading] = useState(true)

  const refresh = useCallback(async () => {
    if (!user?.id) {
      setState(null)
      setLoading(false)
      return
    }
    setLoading(true)
    const { data, error } = await supabase.rpc('get_driver_profile_state')
    if (!error && data) {
      setState(data as unknown as DriverProfileState)
    }
    setLoading(false)
  }, [user?.id])

  useEffect(() => {
    void refresh()
  }, [refresh])

  return { state, loading, refresh }
}