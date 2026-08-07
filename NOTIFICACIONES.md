# 🔔 Notificaciones Push + In-App — RiderFlasshi

Sistema completo de notificaciones:

## 🚀 Despliegue paso a paso

### 1. Generar VAPID Keys
```bash
npx web-push generate-vapid-keys --json
```
Esto genera un JSON con:
- `publicKey` → VAPID_PUBLIC_KEY
- `privateKey` → VAPID_PRIVATE_KEY

El email de contacto es `ridessocopo@gmail.com` (configurado automáticamente en la Edge Function).

### 2. Configurar Frontend (.env.local)
```bash
VITE_SUPABASE_URL=https://inxxhkwybjkcaeyahami.supabase.co
VITE_SUPABASE_ANON_KEY=tu_anon_key
VITE_IMGBB_API_KEY=tu_api_key
VITE_VAPID_PUBLIC_KEY=tu_vapid_public_key
```

### 3. Ejecutar migración SQL
Abrir el **Supabase SQL Editor** y ejecutar `supabase/migrations/009_push_notifications.sql`.
Si `CREATE EXTENSION pg_net` falla, activar manualmente:
Dashboard → Database → Extensions → habilitar `pg_net`.

**Después de la migración**, actualizar la configuración en SQL:
```sql
UPDATE push_settings
SET function_url = 'https://inxxhkwybjkcaeyahami.supabase.co/functions/v1/push-notifications',
    function_secret = 'tu-secreto-aleatorio-muy-largo';
```

### 4. Configurar secrets en Supabase
```bash
supabase secrets set PUSH_FUNCTION_SECRET="tu-secreto-aleatorio-muy-largo"
supabase secrets set VAPID_PUBLIC_KEY="tu_vapid_public_key"
supabase secrets set VAPID_PRIVATE_KEY="tu_vapid_private_key"
supabase secrets set VAPID_SUBJECT="mailto:ridessocopo@gmail.com"
```

### 5. Desplegar Edge Function
```bash
supabase functions deploy push-notifications --project-ref inxxhkwybjkcaeyahami
```

### 6. Verificación
1. Abre la app en https y haz login.
2. Toca la campana 🔔 → página de notificaciones.
3. Toca "Activar" notificaciones push.
4. Solicita un viaje o ve la aprobación de un conductor → deberías recibir push en el móvil incluso con la app cerrada.
5. Admin → Panel → Notificaciones → enviar a todos.

---

## 📡 Cómo funciona

```
Supabase RPC (accept_ride, complete_ride...)
    ↓ inserta en notifications (in-app)
[Trigger AFTER INSERT] → pg_net.http_post
    ↓
Edge Function push-notifications (valida secreto)
    ↓ web-push (VAPID + RFC 8291)
Service Worker de la PWA → notificación push en el móvil
```

## 💰 Costos

| Componente | Costo |
|---|---|
| Supabase Edge Functions | $0 (500K invocaciones/mes free) |
| pg_net | $0 (incluido en free) |
| Frontend polling (cada 60s) | ~1,440 req/día/usuario ≈ centavos |
| VAPID keys | $0 (auto-generadas) |

## 🛡️ Seguridad

- **RLS**: usuarios solo ven sus propias notificaciones y suscripciones
- **Push settings**: solo `service_role` puede leer (edge function)
- **Secreto compartido**: la edge function valida `Bearer` token
- **VAPID private key**: SOLO en Supabase secrets, nunca en frontend
- **Expiración**: endpoints 410/404 se eliminan automáticamente

## 🧩 Archivos creados/modificados

| Archivo | Propósito |
|---|---|
| `supabase/migrations/009_push_notifications.sql` | Tablas, RPCs, trigger, refactor funciones |
| `supabase/functions/push-notifications/index.ts` | Edge Function (envío web-push) |
| `public/sw.js` | Service Worker (push + notificationclick) |
| `src/lib/pushNotifications.ts` | Suscripción/desuscripción push |
| `src/contexts/NotificationContext.tsx` | Polling + badge + mark read |
| `src/components/ui/NotificationBell.tsx` | Campana con badge |
| `src/pages/NotificationsPage.tsx` | Historial in-app |
| `src/pages/admin/AdminNotifications.tsx` | Envío masivo admin |
| `src/App.tsx` | Rutas `/notificaciones` y `/admin/notificaciones` |
| `vite.config.ts` | registro de servicio worker personalizado |
| `.env.example` | VAPID public key doc |