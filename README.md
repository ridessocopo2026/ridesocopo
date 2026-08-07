# 🚗 RiderFlasshi - PWA de Transporte de Pasajeros

Aplicación PWA para transporte de pasajeros en Socopó, Barinas, Venezuela.

## 🚀 Stack Tecnológico

- **Frontend**: React 18 + Vite + TypeScript + Tailwind CSS
- **Mapas**: Leaflet + OpenStreetMap (gratis)
- **Backend**: Supabase (PostgreSQL + Auth + Storage + Realtime)
- **PWA**: vite-plugin-pwa (instalable en iOS/Android)
- **Despliegue**: Cloudflare Pages (gratis)

## 📋 Requisitos Previos

1. **Node.js 18+** - Descargar de https://nodejs.org
2. **Cuenta Supabase** - https://supabase.com
3. **Cuenta Cloudflare** - https://dash.cloudflare.com

## 🗄️ Configuración de Supabase

### Paso 1: Crear proyecto
1. Ve a https://supabase.com y crea un nuevo proyecto
2. Nombra el proyecto `ridesocopo`
3. Elige la región más cercana (US East o South America)
4. Guarda la contraseña de la base de datos

### Paso 2: Ejecutar el SQL
1. En el Dashboard de Supabase, ve a **SQL Editor**
2. Copia TODO el contenido de `supabase/migrations/001_initial_schema.sql`
3. Pégalo en el editor y haz clic en **Run**
4. Espera a que termine sin errores

### Paso 3: Configurar Autenticación
1. Ve a **Authentication → Providers**
2. Habilita **Email** (deja las opciones por defecto)
3. Habilita **Google**:
   - Ve a https://console.cloud.google.com
   - Crea un proyecto y configura OAuth
   - Copia el Client ID y Client Secret
   - Pégalos en Supabase

### Paso 4: Crear Super Admin
1. Regístrate en la app con tu email
2. En Supabase SQL Editor, ejecuta:
```sql
SELECT promote_to_super_admin('tu-email@correo.com');
```

### Paso 5: Configurar Storage
1. Ve a **Storage**
2. Verifica que los buckets se crearon: `avatars`, `documents`, `vehicles`, `payments`, `banners`

## 💻 Instalación Local

```bash
# 1. Instalar Node.js (si no lo tienes)
# Descargar de https://nodejs.org

# 2. Instalar dependencias
cd ridesocopo
npm install

# 3. Configurar variables de entorno
# Copia .env.example a .env.local y verifica los valores

# 4. Ejecutar en desarrollo
npm run dev
```

## 🚀 Despliegue en Cloudflare Pages

1. Sube el proyecto a GitHub
2. Ve a https://dash.cloudflare.com → **Workers & Pages**
3. Haz clic en **Create** → **Pages** → **Connect to Git**
4. Importa el repositorio
5. Configura el build:
   - **Build command**: `npm run build`
   - **Build output directory**: `dist`
6. Agrega las variables de entorno:
   - `VITE_SUPABASE_URL`
   - `VITE_SUPABASE_ANON_KEY`
7. Haz clic en **Save and Deploy**

### Deploy manual con Wrangler CLI
```bash
npm install -g wrangler
wrangler login
cd ridesocopo
npm run build
wrangler pages deploy dist --project-name ridesocopo
```

## 📱 Funcionalidades

### Cliente (Pasajero)
- Solicitar viajes con GPS o tocando el mapa
- Selección de vehículo (Moto, Carro, Camioneta)
- Cálculo de tarifas por zonas (PostGIS)
- Cupones de descuento
- Lugares favoritos
- Billetera virtual con recargas
- Rastreo en vivo del conductor

### Conductor
- Onboarding exhaustivo (documentos + vehículo)
- Estado PENDIENTE hasta aprobación
- Switch Disponible/Ocupado
- Aceptar viajes con verificación de saldo
- GPS efímero con throttling (8m/20s)
- Balance financiero

### Super Admin
- Dashboard con métricas
- Editor de polígonos de zonas
- Tarifas por vehículo
- Tasa de cambio Bs./USD
- Banners promocionales
- Cupones de descuento
- Aprobación de conductores

### Encargado
- Aprobar/rechazar conductores
- Verificar recargas de saldo
- Monitorear viajes activos

## 🔒 Seguridad

- **RLS estricto** en todas las tablas
- **Privacidad bidireccional**: sin visibilidad entre usuarios fuera de viaje activo
- **Cálculos en servidor**: precios y comisiones solo via RPC
- **Comisión atómica**: se bloquea al aceptar el viaje
- **Bloqueo por deuda**: límite configurable

## 🎨 Diseño

- Modo claro minimalista
- Paleta: Blanco (#ffffff), Gris (#f8fafc), Violeta (#7c3aed), Cían (#0284c7)
- Tipografías: Poppins (títulos), Inter (cuerpo)
- Elementos hexagonales sutiles
- Estados de carga, error y vacíos

## 📄 Licencia

Uso privado - RiderFlasshi © 2026