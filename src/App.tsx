import { useEffect } from 'react'
import { Routes, Route, Navigate, useLocation } from 'react-router-dom'
import { AuthProvider, useAuth } from '@/contexts/AuthContext'
import { NotificationProvider } from '@/contexts/NotificationContext'
import { BottomNav } from '@/components/ui/BottomNav'
import { InstallAppButton } from '@/components/ui/InstallAppButton'
import { Footer } from '@/components/ui/Footer'
import { NotificationsPage } from '@/pages/NotificationsPage'
import { Welcome } from '@/pages/Welcome'
import { Login } from '@/pages/auth/Login'
import { Register } from '@/pages/auth/Register'
import { Onboarding } from '@/pages/auth/Onboarding'
import { DriverOnboarding } from '@/pages/conductor/DriverOnboarding'
import { DriverPending } from '@/pages/conductor/DriverPending'
import { DriverDashboard } from '@/pages/conductor/DriverDashboard'
import { DriverWallet } from '@/pages/conductor/DriverWallet'
import { DriverHistory } from '@/pages/conductor/DriverHistory'
import { DriverProfile } from '@/pages/conductor/DriverProfile'
import { ActiveRide as DriverActiveRide } from '@/pages/conductor/ActiveRide'
import { DriverMetrics } from '@/pages/conductor/DriverMetrics'
import { ClientHome } from '@/pages/cliente/ClientHome'
import { ClientActiveRide } from '@/pages/cliente/ClientActiveRide'
import { ClientWallet } from '@/pages/cliente/ClientWallet'
import { ClientHistory } from '@/pages/cliente/ClientHistory'
import { ClientProfile } from '@/pages/cliente/ClientProfile'
import { AdminDashboard } from '@/pages/admin/AdminDashboard'
import { AdminDrivers } from '@/pages/admin/AdminDrivers'
import { AdminZones } from '@/pages/admin/AdminZones'
import { AdminFares } from '@/pages/admin/AdminFares'
import { AdminExchangeRate } from '@/pages/admin/AdminExchangeRate'
import { AdminBanners } from '@/pages/admin/AdminBanners'
import { AdminCoupons } from '@/pages/admin/AdminCoupons'
import { AdminBarrios } from '@/pages/admin/AdminBarrios'
import { AdminConfig } from '@/pages/admin/AdminConfig'
import { AdminPaymentMethods } from '@/pages/admin/AdminPaymentMethods'
import { AdminProofs } from '@/pages/admin/AdminProofs'
import { AdminPayouts } from '@/pages/admin/AdminPayouts'
import { AdminNotifications } from '@/pages/admin/AdminNotifications'
import { AdminIncidents } from '@/pages/admin/AdminIncidents'
import { AdminMetrics } from '@/pages/admin/AdminMetrics'
import { AdminTransactions } from '@/pages/admin/AdminTransactions'
import { AdminRides } from '@/pages/admin/AdminRides'
import { AdminLegal } from '@/pages/admin/AdminLegal'
import { LegalPage } from '@/pages/LegalPage'

function ProtectedRoute({ children }: { children: React.ReactNode }) {
  const { user, loading } = useAuth()

  if (loading) return null

  if (!user) {
    return <Navigate to="/welcome" replace />
  }

  return <>{children}</>
}

// Si el usuario YA está autenticado, no debe ver /welcome, /login ni /registro
function GuestRoute({ children }: { children: React.ReactNode }) {
  const { user } = useAuth()

  if (user) {
    return <Navigate to="/" replace />
  }

  return <>{children}</>
}

function RoleRoute({ role, children }: { role: string; children: React.ReactNode }) {
  const { user } = useAuth()

  if (!user) return <Navigate to="/welcome" replace />

  if (user.role !== role) {
    return <Navigate to="/" replace />
  }

  return <>{children}</>
}

function HomeRedirect() {
  const { user } = useAuth()

  if (!user) return <Navigate to="/welcome" replace />

  if (!user.onboarding_completed) {
    return <Navigate to="/onboarding" replace />
  }

  switch (user.role) {
    case 'cliente':
      return <Navigate to="/cliente" replace />
    case 'conductor':
      if (user.driver_status === 'pendiente') {
        return <Navigate to="/conductor/pendiente" replace />
      }
      return <Navigate to="/conductor" replace />
    case 'encargado':
      return <Navigate to="/encargado" replace />
    case 'super_admin':
      return <Navigate to="/admin" replace />
    default:
      return <Navigate to="/welcome" replace />
  }
}

function AppLayout({ children }: { children: React.ReactNode }) {
  const { user } = useAuth()
  const location = useLocation()

  const isPublicPage = ['/welcome', '/login', '/registro', '/onboarding'].includes(location.pathname)
  const isFullScreen =
    ['/conductor/registro', '/conductor/pendiente'].includes(location.pathname) ||
    location.pathname.startsWith('/cliente/viaje/') ||
    location.pathname.startsWith('/conductor/viaje/')

  // SEO: título de la pestaña por ruta
  useEffect(() => {
    const titles: Record<string, string> = {
      '/': 'RiderFlasshi — Pide tu transporte en Socopó, Barinas',
      '/welcome': 'RiderFlasshi — Transporte de pasajeros en Socopó',
      '/login': 'Iniciar sesión | RiderFlasshi',
      '/registro': 'Regístrate | RiderFlasshi',
      '/onboarding': 'Bienvenido | RiderFlasshi',
      '/cliente': 'Solicitar viaje | RiderFlasshi',
      '/cliente/historial': 'Historial de viajes | RiderFlasshi',
      '/cliente/billetera': 'Mi billetera | RiderFlasshi',
      '/cliente/perfil': 'Mi perfil | RiderFlasshi',
      '/conductor': 'Panel del conductor | RiderFlasshi',
      '/conductor/historial': 'Historial de viajes | RiderFlasshi',
      '/conductor/billetera': 'Mi billetera | RiderFlasshi',
      '/conductor/perfil': 'Mi perfil | RiderFlasshi',
      '/conductor/metricas': 'Mis métricas | RiderFlasshi',
      '/notificaciones': 'Notificaciones | RiderFlasshi',
      '/admin': 'Panel Admin | RiderFlasshi',
      '/politicas-de-privacidad': 'Políticas de Privacidad | RiderFlasshi',
      '/terminos-y-condiciones': 'Términos y Condiciones | RiderFlasshi',
      '/sobre-riderflash': 'Sobre RiderFlasshi',
    }
    document.title = titles[location.pathname] || 'RiderFlasshi'
  }, [location.pathname])

  if (isPublicPage || !user) {
    return (
      <>
        {children}
        <Footer />
      </>
    )
  }

  return (
    <div className="min-h-screen">
      {children}
      {!isFullScreen && (
        <div className="pb-24">
          <Footer />
        </div>
      )}
      <InstallAppButton />
      <BottomNav role={user.role} />
    </div>
  )
}

export default function App() {
  return (
    <AuthProvider>
      <NotificationProvider>
      <AppLayout>
        <Routes>
          <Route path="/welcome" element={<GuestRoute><Welcome /></GuestRoute>} />
          <Route path="/login" element={<GuestRoute><Login /></GuestRoute>} />
          <Route path="/registro" element={<GuestRoute><Register /></GuestRoute>} />
          <Route path="/onboarding" element={
            <ProtectedRoute>
              <Onboarding />
            </ProtectedRoute>
          } />

          <Route path="/" element={<HomeRedirect />} />

          {/* Páginas legales públicas */}
          <Route path="/politicas-de-privacidad" element={<LegalPage pageKey="politicas_privacidad" />} />
          <Route path="/terminos-y-condiciones" element={<LegalPage pageKey="terminos_condiciones" />} />
          <Route path="/sobre-riderflash" element={<LegalPage pageKey="sobre_riderflash" />} />

          {/* Notificaciones (accesible para cualquier usuario autenticado) */}
          <Route path="/notificaciones" element={
            <ProtectedRoute>
              <NotificationsPage />
            </ProtectedRoute>
          } />

          {/* Cliente: accesible sin login (solo se pide autenticación al solicitar un viaje) */}
          <Route path="/cliente" element={<ClientHome />} />
          <Route path="/cliente/viaje/:rideId" element={
            <RoleRoute role="cliente">
              <ClientActiveRide />
            </RoleRoute>
          } />
          <Route path="/cliente/billetera" element={
            <RoleRoute role="cliente">
              <ClientWallet />
            </RoleRoute>
          } />
          <Route path="/cliente/historial" element={
            <RoleRoute role="cliente">
              <ClientHistory />
            </RoleRoute>
          } />
          <Route path="/cliente/perfil" element={
            <RoleRoute role="cliente">
              <ClientProfile />
            </RoleRoute>
          } />

          <Route path="/conductor/onboarding" element={
            <RoleRoute role="conductor">
              <DriverOnboarding />
            </RoleRoute>
          } />
          <Route path="/conductor/pendiente" element={
            <RoleRoute role="conductor">
              <DriverPending />
            </RoleRoute>
          } />
          <Route path="/conductor" element={
            <RoleRoute role="conductor">
              <DriverDashboard />
            </RoleRoute>
          } />
          <Route path="/conductor/viaje/:rideId" element={
            <RoleRoute role="conductor">
              <DriverActiveRide />
            </RoleRoute>
          } />
          <Route path="/conductor/billetera" element={
            <RoleRoute role="conductor">
              <DriverWallet />
            </RoleRoute>
          } />
          <Route path="/conductor/historial" element={
            <RoleRoute role="conductor">
              <DriverHistory />
            </RoleRoute>
          } />
          <Route path="/conductor/metricas" element={
            <RoleRoute role="conductor">
              <DriverMetrics />
            </RoleRoute>
          } />
          <Route path="/conductor/perfil" element={
            <RoleRoute role="conductor">
              <DriverProfile />
            </RoleRoute>
          } />

          <Route path="/admin" element={
            <RoleRoute role="super_admin">
              <AdminDashboard />
            </RoleRoute>
          } />
          <Route path="/admin/conductores" element={
            <RoleRoute role="super_admin">
              <AdminDrivers />
            </RoleRoute>
          } />
          <Route path="/admin/zonas" element={
            <RoleRoute role="super_admin">
              <AdminZones />
            </RoleRoute>
          } />
          <Route path="/admin/tarifas" element={
            <RoleRoute role="super_admin">
              <AdminFares />
            </RoleRoute>
          } />
          <Route path="/admin/tasa" element={
            <RoleRoute role="super_admin">
              <AdminExchangeRate />
            </RoleRoute>
          } />
          <Route path="/admin/banners" element={
            <RoleRoute role="super_admin">
              <AdminBanners />
            </RoleRoute>
          } />
          <Route path="/admin/cupones" element={
            <RoleRoute role="super_admin">
              <AdminCoupons />
            </RoleRoute>
          } />
          <Route path="/admin/barrios" element={
            <RoleRoute role="super_admin">
              <AdminBarrios />
            </RoleRoute>
          } />
          <Route path="/admin/config" element={
            <RoleRoute role="super_admin">
              <AdminConfig />
            </RoleRoute>
          } />
          <Route path="/admin/pagos" element={
            <RoleRoute role="super_admin">
              <AdminPaymentMethods />
            </RoleRoute>
          } />
          <Route path="/admin/comprobantes" element={
            <RoleRoute role="super_admin">
              <AdminProofs />
            </RoleRoute>
          } />
          <Route path="/admin/liquidaciones" element={
            <RoleRoute role="super_admin">
              <AdminPayouts />
            </RoleRoute>
          } />
          <Route path="/admin/notificaciones" element={
            <RoleRoute role="super_admin">
              <AdminNotifications />
            </RoleRoute>
          } />
          <Route path="/admin/incidentes" element={
            <RoleRoute role="super_admin">
              <AdminIncidents />
            </RoleRoute>
          } />
          <Route path="/admin/metricas" element={
            <RoleRoute role="super_admin">
              <AdminMetrics />
            </RoleRoute>
          } />
          <Route path="/admin/transacciones" element={
            <RoleRoute role="super_admin">
              <AdminTransactions />
            </RoleRoute>
          } />
          <Route path="/admin/viajes" element={
            <RoleRoute role="super_admin">
              <AdminRides />
            </RoleRoute>
          } />
          <Route path="/admin/legal" element={
            <RoleRoute role="super_admin">
              <AdminLegal />
            </RoleRoute>
          } />

          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </AppLayout>
      </NotificationProvider>
    </AuthProvider>
  )
}
