import { Routes, Route, Navigate, useLocation } from 'react-router-dom'
import { AuthProvider, useAuth } from '@/contexts/AuthContext'
import { NotificationProvider } from '@/contexts/NotificationContext'
import { BottomNav } from '@/components/ui/BottomNav'
import { InstallAppButton } from '@/components/ui/InstallAppButton'
import { NotificationsPage } from '@/pages/NotificationsPage'
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

function ProtectedRoute({ children }: { children: React.ReactNode }) {
  const { user, loading } = useAuth()

  if (loading) return null

  if (!user) {
    return <Navigate to="/login" replace />
  }

  return <>{children}</>
}

function RoleRoute({ role, children }: { role: string; children: React.ReactNode }) {
  const { user } = useAuth()

  if (!user) return <Navigate to="/login" replace />

  if (user.role !== role) {
    return <Navigate to="/" replace />
  }

  return <>{children}</>
}

function HomeRedirect() {
  const { user } = useAuth()

  if (!user) return <Navigate to="/login" replace />

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
      return <Navigate to="/login" replace />
  }
}

function AppLayout({ children }: { children: React.ReactNode }) {
  const { user } = useAuth()
  const location = useLocation()

  const isAuthPage = ['/login', '/registro', '/onboarding'].includes(location.pathname)

  if (isAuthPage || !user) {
    return <>{children}</>
  }

  return (
    <div className="min-h-screen">
      {children}
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
          <Route path="/login" element={<Login />} />
          <Route path="/registro" element={<Register />} />
          <Route path="/onboarding" element={
            <ProtectedRoute>
              <Onboarding />
            </ProtectedRoute>
          } />

          <Route path="/" element={<HomeRedirect />} />

          {/* Notificaciones (accesible para cualquier usuario autenticado) */}
          <Route path="/notificaciones" element={
            <ProtectedRoute>
              <NotificationsPage />
            </ProtectedRoute>
          } />

          <Route path="/cliente" element={
            <RoleRoute role="cliente">
              <ClientHome />
            </RoleRoute>
          } />
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

          <Route path="*" element={<Navigate to="/" replace />} />
        </Routes>
      </AppLayout>
      </NotificationProvider>
    </AuthProvider>
  )
}
