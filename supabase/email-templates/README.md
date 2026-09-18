# Plantillas de correo de BunRider (Supabase Auth)

Plantillas HTML con la marca **BunRider** para los correos de autenticación.
Se envían por **Resend** a través del SMTP personalizado de Supabase
(remitente: `BunRider <no-reply@bunrider.com>`).

## Archivos
| Archivo | Plantilla de Supabase |
|---|---|
| `reset-password.html` | Authentication → Email Templates → **Reset Password** |

## Cómo pegarlas
1. Supabase Dashboard → **Authentication → Email Templates**.
2. Elige la plantilla (por ejemplo **Reset Password**).
3. **Subject heading:** `Restablece tu contraseña de BunRider`
4. Pega el contenido del archivo `.html` en el cuerpo.
5. **Save**. Prueba el flujo real desde `/login → ¿Olvidaste tu contraseña?`.

## Variables de Supabase (¡no las borres!)
- `{{ .ConfirmationURL }}` → enlace con el token (es el botón principal).
- `{{ .Token }}` → código de 6 dígitos (solo si se quiere mostrar el código).
- `{{ .SiteURL }}`, `{{ .Email }}`, `{{ .Data }}` → datos de contexto.

> Las variables son **sensibles a mayúsculas** y deben quedar con las llaves dobles.

## Configuración de envío (ya aplicada)
- Resend: dominio `bunrider.com` verificado (DKIM `resend._domainkey`, SPF y MX en `send.bunrider.com`).
- Supabase → Authentication → SMTP: `smtp.resend.com`, puerto `465`, usuario `resend`,
  contraseña = API key de Resend (**solo en el dashboard, nunca en el repo**).
- Redirect URLs: `https://bunrider.com/reset-password` y `http://localhost:5173/reset-password`.

## Buenas prácticas
- Mantener el HTML por debajo de ~100 KB para que Gmail no lo recorte.
- Estilos **inline** y layout con tablas (compatibilidad con Gmail/Outlook).
- Evitar fuentes externas: usar la pila del sistema (`'Segoe UI', Roboto, Helvetica, Arial`).
- Las imágenes pueden no mostrarse hasta que el usuario pulse "Mostrar imágenes" (normal).
- Si se cambia la marca, actualizar logo/colores (`#7c3aed` es el morado de BunRider).

## Pendientes opcionales
Plantillas equivalentes para: **Confirm signup**, **Magic link**, **Change email address**,
**Invite user** y **Reauthentication**.
