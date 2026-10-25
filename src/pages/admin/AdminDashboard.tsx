import { useState, useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { Activity, Users, UsersRound, Car, DollarSign, TrendingUp, LogOut, MapPin, Settings, Ticket, Image, Wallet, ClipboardCheck, Banknote, Bell, ShieldAlert, BarChart3, Landmark, ArrowDownUp, PiggyBank, ScrollText, FileText } from 'lucide-react'
import { supabase } from '@/lib/supabase'
import { fmt } from '@/lib/format'
import { useAuth } from '@/contexts/AuthContext'
import { SkeletonList } from '@/components/ui/Skeleton'
import { HexUnderline } from '@/components/ui/HexUnderline'
import { NotificationBell } from '@/components/ui/NotificationBell'
import { AppLogo } from '@/components/ui/AppLogo'
import type { TreasuryOverview } from '@/types/database'

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
  const [treasury, setTreasury] = useState<TreasuryOverview | null>(null)
  const [loading, setLoading] = useState(true)
  const { user, signOut } = useAuth()
  const navigate = useNavigate()

  useEffect(() => {
    loadStats()
  }, [])

  const loadStats = async () => {
    try {
      const [usersRes, driversRes, pendingRes, ridesRes, walletRes, treasuryRes] = await Promise.all([
        supabase.from('profiles').select('id', { count: 'exact' }),
        supabase.from('profiles').select('id', { count: 'exact' }).eq('role', 'conductor'),
        supabase.from('profiles').select('id', { count: 'exact' }).eq('driver_status', 'pendiente'),
        supabase.from('rides').select('id', { count: 'exact', head: true }),
        supabase.rpc('get_wallet_overview'),
        supabase.rpc('get_treasury_overview')
      ])

      setStats({
        totalUsers: usersRes.count || 0,
        totalDrivers: driversRes.count || 0,
        pendingDrivers: pendingRes.count || 0,
        totalRides: ridesRes.count || 0
      })

      if (walletRes.data) {
        setWalletOverview(walletRes.data as WalletOverview)
      }
      if (treasuryRes.data) {
        setTreasury(treasuryRes.data as TreasuryOverview)
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
    { to: '/admin/usuarios', icon: <UsersRound className="w-6 h-6" />, title: 'Usuarios', desc: 'Pasajeros y conductores' },
    { to: '/admin/tarifas', icon: <Car className="w-6 h-6" />, title: 'Tarifas', desc: 'Tarifas por vehículo' },
    { to: '/admin/tasa', icon: <DollarSign className="w-6 h-6" />, title: 'Tasa de cambio', desc: 'Bs./USD' },
    { to: '/admin/comprobantes', icon: <ClipboardCheck className="w-6 h-6" />, title: 'Comprobantes', desc: 'Aprobar pagos de viajes' },
    { to: '/admin/liquidaciones', icon: <Banknote className="w-6 h-6" />, title: 'Liquidaciones', desc: 'Pagos entre conductores y plataforma' },
    { to: '/admin/cuentas', icon: <Landmark className="w-6 h-6" />, title: 'Estado de cuentas', desc: 'Efectivo, banco y deudas por conductor' },
    { to: '/admin/notificaciones', icon: <Bell className="w-6 h-6" />, title: 'Notificaciones', desc: 'Enviar push a todos los usuarios' },
    { to: '/admin/pagos', icon: <Wallet className="w-6 h-6" />, title: 'Métodos de pago', desc: 'Activa/desactiva métodos de pago' },
    { to: '/admin/banners', icon: <Image className="w-6 h-6" />, title: 'Banners', desc: 'Publicidad y promociones' },
    { to: '/admin/cupones', icon: <Ticket className="w-6 h-6" />, title: 'Cupones', desc: 'Códigos de descuento' },
    { to: '/admin/legal', icon: <FileText className="w-6 h-6" />, title: 'Contenido legal', desc: 'Privacidad, términos y sobre la app' },
    { to: '/admin/config', icon: <Settings className="w-6 h-6" />, title: 'Configuración', desc: 'Comisiones y límites' },
    { to: '/admin/incidentes', icon: <ShieldAlert className="w-6 h-6" />, title: 'Incidentes', desc: 'Accidentes y reportes de viajes' },
    { to: '/admin/transacciones', icon: <Banknote className="w-6 h-6" />, title: 'Transacciones', desc: 'Movimientos de dinero detallados' },
    { to: '/admin/viajes', icon: <Car className="w-6 h-6" />, title: 'Viajes', desc: 'Buscar por tracking y ver detalle' },
    { to: '/admin/operacion', icon: <Activity className="w-6 h-6" />, title: 'Operacion en vivo', desc: 'Conductores y viajes en tiempo real' },
    { to: '/admin/precios-ciudad', icon: <DollarSign className="w-6 h-6" />, title: 'Precios por ciudad', desc: 'Precio base por ciudad' },
    { to: '/admin/metricas', icon: <BarChart3 className="w-6 h-6" />, title: 'Métricas', desc: 'Finanzas, filtros y estadísticas' },
    { to: '/admin/auditoria', icon: <ScrollText className="w-6 h-6" />, title: 'Auditoría', desc: 'Historial de acciones sensibles' }
  ]

  return (
    <div className="min-h-screen bg-surface-50 pb-24">
      <div className="bg-white border-b border-surface-100 px-6 py-4">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-3">
            <AppLogo />
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

            {/* En banco (digital exacto) */}
            <div className="flex items-center justify-between py-1.5 border-b border-white/15">
              <div className="flex items-center gap-2">
                <Landmark className="w-4 h-4 text-white/80" />
                <span className="text-xs text-white/80">En banco (Pago Móvil/Zelle)</span>
              </div>
              <p className="text-lg font-bold">
                {fmt(treasury ? treasury.banco.digital.neto : walletOverview.total_banco)}
              </p>
            </div>

            {/* Efectivo en caja */}
            <div className="flex items-center justify-between py-1.5 border-b border-white/15">
              <div className="flex items-center gap-2">
                <Banknote className="w-4 h-4 text-white/80" />
                <span className="text-xs text-white/80">Efectivo en caja</span>
              </div>
              <p className="text-lg font-bold">
                {treasury ? fmt(treasury.efectivo.en_caja_total) : '—'}
              </p>
            </div>

            {/* Por cobrar a conductores */}
            <div className="flex items-center justify-between py-1.5 border-b border-white/15">
              <div className="flex items-center gap-2">
                <Wallet className="w-4 h-4 text-white/80" />
                <span className="text-xs text-white/80">Por cobrar a conductores</span>
              </div>
              <p className="text-lg font-bold">
                {treasury ? fmt(treasury.deudas.conductores_deben) : '—'}
              </p>
            </div>

            {/* Sin clasificar (histórico) */}
            {treasury && treasury.banco.sin_clasificar.neto !== 0 && (
              <div className="flex items-center justify-between py-1.5 border-b border-white/15">
                <div className="flex items-center gap-2">
                  <DollarSign className="w-4 h-4 text-white/80" />
                  <span className="text-xs text-white/80">Sin clasificar (histórico)</span>
                </div>
                <p className="text-lg font-bold">{fmt(treasury.banco.sin_clasificar.neto)}</p>
              </div>
            )}

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
              Banco y caja se calculan con el método real de cada movimiento. La conciliación completa está en Estado de cuentas.
            </p>
            <button
              onClick={() => navigate('/admin/cuentas')}
              className="mt-3 w-full bg-white/15 hover:bg-white/25 rounded-lg py-2 text-xs font-semibold"
            >
              Ver estado de cuentas →
            </button>
          </div>
        ) : (
          <div className="card bg-gradient-to-br from-primary-600 to-primary-800 text-white border-0">
            <div className="flex items-center gap-2 mb-2">
              <DollarSign className="w-5 h-5" />
              <span className="text-sm font-medium">Saldo total de la app</span>
            </div>
            <p className="text-3xl font-bold">0.00$</p>
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