import { NavLink } from 'react-router-dom'
import { Home, Car, Wallet, User, History, Bell, MapPin, Settings } from 'lucide-react'
import type { UserRole } from '@/types/database'

interface NavItem {
  to: string
  label: string
  icon: React.ReactNode
}

interface BottomNavProps {
  role: UserRole
}

export function BottomNav({ role }: BottomNavProps) {
  const items: NavItem[] = []

  if (role === 'cliente') {
    items.push(
      { to: '/cliente', label: 'Inicio', icon: <Home className="nav-icon" /> },
      { to: '/cliente/historial', label: 'Historial', icon: <History className="nav-icon" /> },
      { to: '/cliente/billetera', label: 'Billetera', icon: <Wallet className="nav-icon" /> },
      { to: '/cliente/perfil', label: 'Perfil', icon: <User className="nav-icon" /> }
    )
  } else if (role === 'conductor') {
    items.push(
      { to: '/conductor', label: 'Panel', icon: <Car className="nav-icon" /> },
      { to: '/conductor/historial', label: 'Historial', icon: <History className="nav-icon" /> },
      { to: '/conductor/billetera', label: 'Billetera', icon: <Wallet className="nav-icon" /> },
      { to: '/conductor/perfil', label: 'Perfil', icon: <User className="nav-icon" /> }
    )
  } else if (role === 'encargado') {
    items.push(
      { to: '/encargado', label: 'Panel', icon: <Home className="nav-icon" /> },
      { to: '/encargado/conductores', label: 'Conductores', icon: <User className="nav-icon" /> },
      { to: '/encargado/recargas', label: 'Recargas', icon: <Wallet className="nav-icon" /> },
      { to: '/encargado/perfil', label: 'Perfil', icon: <Settings className="nav-icon" /> }
    )
  } else if (role === 'super_admin') {
    items.push(
      { to: '/admin', label: 'Dashboard', icon: <Home className="nav-icon" /> },
      { to: '/admin/zonas', label: 'Zonas', icon: <MapPin className="nav-icon" /> },
      { to: '/admin/conductores', label: 'Conductores', icon: <User className="nav-icon" /> },
      { to: '/admin/config', label: 'Config', icon: <Settings className="nav-icon" /> }
    )
  }

  return (
    <nav className="fixed bottom-0 left-0 right-0 bg-white border-t border-surface-100 safe-bottom z-40">
      <div className="flex justify-around items-center h-16 max-w-md mx-auto">
        {items.map((item) => (
          <NavLink
            key={item.to}
            to={item.to}
            className={({ isActive }) => `nav-item ${isActive ? 'active' : ''}`}
          >
            {item.icon}
            <span>{item.label}</span>
          </NavLink>
        ))}
      </div>
    </nav>
  )
}