import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { ClipboardCheck, ShieldAlert, Users, UserCheck, Receipt, MapPin, LogOut, Ticket } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { fmt } from '@/lib/format'
import { useAuth } from '@/contexts/AuthContext'
import { AppLogo } from '@/components/ui/AppLogo'
import type { CouponStats } from '@/types/database'

const modules = [
  { to: '/encargado/comprobantes', icon: <ClipboardCheck className="w-6 h-6" />, title: 'Comprobantes', desc: 'Verificar pagos y recargas' },
  { to: '/encargado/incidentes', icon: <ShieldAlert className="w-6 h-6" />, title: 'Incidentes', desc: 'Atender incidentes de viajes' },
  { to: '/encargado/conductores', icon: <Users className="w-6 h-6" />, title: 'Conductores', desc: 'Aprobar y gestionar' },
  { to: '/encargado/usuarios', icon: <UserCheck className="w-6 h-6" />, title: 'Usuarios', desc: 'Pasajeros y conductores' },
  { to: '/encargado/transacciones', icon: <Receipt className="w-6 h-6" />, title: 'Transacciones', desc: 'Movimientos de dinero' }
]

export function EncargadoDashboard() {
  const { user, signOut } = useAuth()
  const navigate = useNavigate()
  const [zoneName, setZoneName] = useState('')
  const [couponStats, setCouponStats] = useState<CouponStats | null>(null)

  useEffect(() => {
    if (user?.zone_id) {
      supabase
        .from('zones')
        .select('name')
        .eq('id', user.zone_id)
        .single()
        .then(({ data }) => { if (data) setZoneName(data.name) })
    }
  }, [user?.zone_id])

  // Métricas de promociones de MI ciudad (últimos 30 días)
  useEffect(() => {
    const now = new Date()
    const from = new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000)
    supabase
      .rpc('get_coupon_stats_detailed', {
        p_fecha_inicio: from.toISOString(),
        p_fecha_fin: now.toISOString(),
        p_zone_id: user?.zone_id ?? null
      })
      .then(({ data, error }) => {
        if (!error && data) setCouponStats(data as CouponStats)
      })
  }, [user?.zone_id])

  const handleSignOut = async () => {
    await signOut()
    navigate('/login')
  }

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-primary-600 border-b border-primary-700 px-6 py-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <AppLogo variant="dark" />
            <div>
              <h1 className="text-lg font-bold text-white">Panel del Encargado</h1>
              <p className="text-xs text-white/80 flex items-center gap-1">
                <MapPin className="w-3 h-3" /> {zoneName || 'Tu ciudad'}
              </p>
            </div>
          </div>
          <button onClick={handleSignOut} className="p-2 text-white/80 hover:text-white transition-colors">
            <LogOut className="w-5 h-5" />
          </button>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6 space-y-4">
        <div className="grid grid-cols-2 gap-3">
          {modules.map((m) => (
            <button
              key={m.to}
              onClick={() => navigate(m.to)}
              className="card card-hover p-4 text-left"
            >
              <div className="w-11 h-11 bg-primary-50 rounded-xl flex items-center justify-center text-primary-600 mb-2">
                {m.icon}
              </div>
              <p className="font-semibold text-surface-800">{m.title}</p>
              <p className="text-xs text-surface-400 mt-0.5">{m.desc}</p>
            </button>
          ))}
        </div>

        {/* Promociones: cupones usados en esta ciudad */}
        <div className="card p-4 bg-purple-50 border-purple-200">
          <p className="text-xs text-purple-700 flex items-center gap-1 font-semibold">
            <Ticket className="w-4 h-4" /> Promociones (últimos 30 días)
          </p>
          {couponStats ? (
            <>
              <p className="text-2xl font-bold text-purple-700 mt-1">−{fmt(couponStats.total_discount_usd)}</p>
              <p className="text-[10px] text-purple-600">
                {couponStats.redemptions} canjes • {couponStats.viajes_con_cupon ?? 0} viajes con cupón • {couponStats.usuarios_unicos ?? 0} clientes
              </p>
              {(couponStats.top_cupones?.length ?? 0) > 0 && (
                <div className="mt-2 pt-2 border-t border-purple-200 space-y-1">
                  {couponStats.top_cupones!.slice(0, 3).map((c) => (
                    <div key={c.code} className="flex justify-between text-[11px] text-purple-700">
                      <span className="font-medium">{c.code}</span>
                      <span>{c.redemptions} usos • −{fmt(c.discount)}</span>
                    </div>
                  ))}
                </div>
              )}
            </>
          ) : (
            <p className="text-xs text-purple-600 mt-1">Sin datos en el período</p>
          )}
        </div>
      </div>
    </div>
  )
}
