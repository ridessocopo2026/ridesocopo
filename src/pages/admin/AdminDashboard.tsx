import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { Users, Car, DollarSign, TrendingUp, Hexagon, LogOut, MapPin, Settings, Ticket, Image, Wallet, ClipboardCheck, Banknote, Bell, ShieldAlert, BarChart3, Landmark, ArrowDownUp, PiggyBank } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { fmt } from '@/lib/format'
import { useAuth } from '@/contexts/AuthContext'
import { SkeletonList } from '@/components/ui/Skeleton'
import { HexUnderline } from '@/components/ui/HexUnderline'
import { NotificationBell } from '@/components/ui/NotificationBell'

interface WalletOverview {
  total_banco: number
  deuda_wallets: number
  patrimonio_app: number
  detalle?: {
    recargas_clientes: number
    pagos_pago_movil_viajes: number
    pagos_conductores_plataforma: number
    pagos_plataforma_conductores: number
  }
}

export function AdminDashboard() {
  const [stats, setStats] = useState({
    totalUsers: 0,
    totalDrivers: 0,
    pendingDrivers: 0,
    totalRides: 0
  })
  const [walletOverview, setWalletOverview] = useState<WalletOverview | null>(null)
  const [loading, setLoading] = useState(true)
  const { user, signOut } = useAuth()
  const navigate = useNavigate()

  useEffect(() => {
    loadStats()
  }, [])

  const loadStats = async () => {
    try {
      const [usersRes, driversRes, pendingRes, ridesRes, walletRes] = await Promise.all([
        supabase.from('profiles').select('id', { count: 'exact' }),
        supabase.from('profiles').select('id', { count: 'exact' }).eq('role', 'conductor'),
        supabase.from('profiles').select('id', { count: 'exact' }).eq('driver_status', 'pendiente'),
        supabase.from('rides').select('*'),
        supabase.rpc('get_wallet_overview')
      ])

      setStats({
        totalUsers: usersRes.count || 0,
        totalDrivers: driversRes.count || 0,
        pendingDrivers: pendingRes.count || 0,
        totalRides: ridesRes.data?.length || 0
      })

      if (walletRes.data) {
        setWalletOverview(walletRes.data as WalletOverview)
      }
    } catch (err) {
      console.error('Error cargando stats:', err)
    } finally {
      setLoading(false)
    }
  }

  const handleSignOut = async () => {
    await signOut()
    navigate('/login')
  }

  const menuItems = [
    { to: '/admin/barrios', icon: <MapPin className="w-6 h-6" />, title: 'Barrios', desc: 'Barrios y precios de llegada' },
    { to: '/admin/zonas', icon: <MapPin className="w-6 h-6" />, title: 'Cobertura', desc: 'Polígono de cobertura de Socopó' },
    { to: '/admin/conductores', icon: <Users className="w-6 h-6" />, title: 'Conductores', desc: 'Aprobar y gestionar' },
    { to: '/admin/tarifas', icon: <Car className="w-6 h-6" />, title: 'Tarifas', desc: 'Tarifas por vehículo' },
    { to: '/admin/tasa', icon: <DollarSign className="w-6 h-6" />, title: 'Tasa de cambio', desc: 'Bs./USD' },
    { to: '/admin/comprobantes', icon: <ClipboardCheck className="w-6 h-6" />, title: 'Comprobantes', desc: 'Aprobar pagos de viajes' },
    { to: '/admin/liquidaciones', icon: <Banknote className="w-6 h-6" />, title: 'Liquidaciones', desc: 'Pagos entre conductores y plataforma' },
    { to: '/admin/notificaciones', icon: <Bell className="w-6 h-6" />, title: 'Notificaciones', desc: 'Enviar push a todos los usuarios' },
    { to: '/admin/pagos', icon: <Wallet className="w-6 h-6" />, title: 'Métodos de pago', desc: 'Activa/desactiva métodos de pago' },
    { to: '/admin/banners', icon: <Image className="w-6 h-6" />, title: 'Banners', desc: 'Publicidad y promociones' },
    { to: '/admin/cupones', icon: <Ticket className="w-6 h-6" />, title: 'Cupones', desc: 'Códigos de descuento' },
    { to: '/admin/config', icon: <Settings className="w-6 h-6" />, title: 'Configuración', desc: 'Comisiones y límites' },
    { to: '/admin/incidentes', icon: <ShieldAlert className="w-6 h-6" />, title: 'Incidentes', desc: 'Accidentes y reportes de viajes' },
    { to: '/admin/transacciones', icon: <Banknote className="w-6 h-6" />, title: 'Transacciones', desc: 'Movimientos de dinero detallados' },
    { to: '/admin/viajes', icon: <Car className="w-6 h-6" />, title: 'Viajes', desc: 'Buscar por tracking y ver detalle' },
    { to: '/admin/metricas', icon: <BarChart3 className="w-6 h-6" />, title: 'Métricas', desc: 'Finanzas, filtros y estadísticas' }
  ]

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 bg-primary-600 rounded-xl flex items-center justify-center">
              <Hexagon className="w-5 h-5 text-white" />
            </div>
            <div>
              <h1 className="text-lg font-bold text-surface-800">Panel Admin</h1>
              <p className="text-xs text-surface-500">Super Administrador</p>
            </div>
          </div>
          <div className="flex items-center gap-1">
            <NotificationBell />
            <button onClick={handleSignOut} className="p-2 text-surface-400 hover:text-red-500 transition-colors">
              <LogOut className="w-5 h-5" />
            </button>
          </div>
        </div>
      </div>

      <div className="max-w-md mx-auto px-4 py-6 space-y-6">
        {/* Stats */}
        {loading ? (
          <SkeletonList count={2} />
        ) : (
          <div className="grid grid-cols-2 gap-3">
            <div className="card">
              <div className="flex items-center gap-2 mb-2">
                <Users className="w-4 h-4 text-primary-600" />
                <span className="text-xs text-surface-500">Usuarios</span>
              </div>
              <p className="text-2xl font-bold text-surface-800">{stats.totalUsers}</p>
            </div>
            <div className="card">
              <div className="flex items-center gap-2 mb-2">
                <Car className="w-4 h-4 text-accent-600" />
                <span className="text-xs text-surface-500">Conductores</span>
              </div>
              <p className="text-2xl font-bold text-surface-800">{stats.totalDrivers}</p>
            </div>
            <div className="card">
              <div className="flex items-center gap-2 mb-2">
                <Users className="w-4 h-4 text-amber-500" />
                <span className="text-xs text-surface-500">Pendientes</span>
              </div>
              <p className="text-2xl font-bold text-amber-500">{stats.pendingDrivers}</p>
            </div>
            <div className="card">
              <div className="flex items-center gap-2 mb-2">
                <TrendingUp className="w-4 h-4 text-emerald-600" />
                <span className="text-xs text-surface-500">Viajes</span>
              </div>
              <p className="text-2xl font-bold text-surface-800">{stats.totalRides}</p>
            </div>
          </div>
        )}

        {/* Saldo total de la app - Vista de patrimonios */}
        {walletOverview ? (
          <div className="card bg-gradient-to-br from-primary-600 to-primary-800 text-white border-0">
            <div className="flex items-center gap-2 mb-3">
              <Landmark className="w-5 h-5" />
              <span className="text-sm font-medium">Saldo total de la app</span>
            </div>

            {/* Total en banco */}
            <div className="flex items-center justify-between py-1.5 border-b border-white/15">
              <div className="flex items-center gap-2">
                <DollarSign className="w-4 h-4 text-white/80" />
                <span className="text-xs text-white/80">Total en banco (pago móvil/Zelle)</span>
              </div>
              <p className="text-lg font-bold">{fmt(walletOverview.total_banco)}</p>
            </div>

            {/* Deuda a wallets */}
            <div className="flex items-center justify-between py-1.5 border-b border-white/15">
              <div className="flex items-center gap-2">
                <ArrowDownUp className="w-4 h-4 text-white/80" />
                <span className="text-xs text-white/80">Debe a clientes y conductores</span>
              </div>
              <p className="text-lg font-bold">{fmt(walletOverview.deuda_wallets)}</p>
            </div>

            {/* Patrimonio de la app */}
            <div className="flex items-center justify-between pt-2">
              <div className="flex items-center gap-2">
                <PiggyBank className="w-5 h-5 text-yellow-300" />
                <span className="text-sm font-semibold">Le pertenece a la app</span>
              </div>
              <p className="text-2xl font-bold text-yellow-300">{fmt(walletOverview.patrimonio_app)}</p>
            </div>

            <p className="text-[10px] text-white/60 mt-2">
              Cuando conductores/clientes soliciten retiro, estos valores se ajustan automáticamente.
            </p>
          </div>
        ) : (
          <div className="card bg-gradient-to-br from-primary-600 to-primary-800 text-white border-0">
            <div className="flex items-center gap-2 mb-2">
              <DollarSign className="w-5 h-5" />
              <span className="text-sm font-medium">Saldo total de la app</span>
            </div>
            <p className="text-3xl font-bold">$0.00</p>
          </div>
        )}

        {/* Menú de gestión */}
        <div>
          <h2 className="text-lg font-semibold text-surface-800 mb-3">Gestión</h2>
          <HexUnderline />
          <div className="space-y-2">
            {menuItems.map((item) => (
              <button
                key={item.to}
                onClick={() => navigate(item.to)}
                className="card card-hover w-full flex items-center gap-4"
              >
                <div className="w-12 h-12 bg-primary-50 rounded-xl flex items-center justify-center text-primary-600">
                  {item.icon}
                </div>
                <div className="flex-1 text-left">
                  <p className="font-medium text-surface-700">{item.title}</p>
                  <p className="text-xs text-surface-400">{item.desc}</p>
                </div>
              </button>
            ))}
          </div>
        </div>
      </div>
    </div>
  )
}