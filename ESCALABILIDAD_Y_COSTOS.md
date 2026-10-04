# 🚀 Escalabilidad y costos — BunRider (Socopó)

Auditoría de capacidad y costo para el objetivo **500 viajes/día y muchos usuarios**, y
las optimizaciones aplicadas para evitar sorpresas de costo o lentitud en Supabase.

Proyecto Supabase: `inxxhkwybjkcaeyahami` (región `us-west-2`). **Plan actual: Free.**

---

## 1. Resumen ejecutivo

El backend está bien pensado para costo (push en lote, Realtime en vez de polling
agresivo, compresión y límites de storage, limpieza con `pg_cron`). Había **2-3 puntos
calientes** que habrían reventado el plan Free mucho antes de 500 viajes/día. Ya están
mitigados:

| Punto caliente | Antes | Después |
|---|---|---|
| Mensajes Realtime por GPS | ~200-600 escrituras `rides`/viaje (×2 suscriptores) | ~50/viaje (≤ 5/min) |
| Egress por polling de notificaciones | cada **60 s**, también en 2º plano | cada **120 s** y solo en 1er plano |
| Crecimiento de `rides` | sin tope (~270 MB/año) | archivado disponible + `rides_archive` |
| RLS `auth.uid()` por fila | 46 políticas | 0 (una vez por consulta) |

---

## 2. Cambios aplicados

### Frontend
- `src/pages/conductor/ActiveRide.tsx` y `DriverDashboard.tsx`: el envío de ubicación
  (`update_driver_location`) se limita a **1 vez cada 12 s** en el cliente (antes: en
  CADA lectura GPS).
- `src/contexts/NotificationContext.tsx`: polling in-app a **120 s** y **se salta cuando
  la app está en segundo plano** (antes 60 s siempre activo).

### Base de datos (migraciones)
- **081_optimizacion_escala_y_costos.sql**
  - `update_driver_location`: throttle estricto → nunca < 12 s entre escrituras; si no se
    movió ≥ 25 m, solo un "latido" cada 60 s. (Misma firma/retorno.)
  - RLS: toda política que usaba `auth.uid()/jwt()/role()` ahora lo envuelve en
    `(select ...)` (evaluación única por consulta). Resuelve `auth_rls_initplan`.
- **082_endurecer_spatial_ref_sys.sql**: documenta que `spatial_ref_sys` **no** se puede
  endurecer desde el proyecto (pertenece a `supabase_admin`). Impacto bajo. Ver §4.
- **083_archivado_viajes.sql**: tabla `rides_archive` (snapshot JSONB del viaje + filas
  hijas) y RPC `archive_old_rides(p_months, p_delete)`. Por defecto **solo archiva**
  (no borra). Solo borra si `p_delete = true` y el viaje no está referenciado por un
  `payout`.

> Nada de esto cambia firmas de RPC, permisos ni la lógica de negocio.

---

## 3. Modelo de capacidad para 500 viajes/día (estimación)

Supuestos: viaje medio 8-12 min, GPS en movimiento cada 1-3 s.

| Recurso | Por viaje | ×500/día | Mes | Límite Free | Estado |
|---|---|---|---|---|---|
| UPDATE `rides` (GPS+estado) | ~50 + 5 | ~28 k/día | ~0,8 M | — | ✅ |
| Mensajes Realtime (×2) | ~110 | ~55 k/día | **~1,6 M** | 2 M | ✅ (ajustado) |
| Conexiones Realtime pico | — | ~100-250 | — | 200 | ⚠️ vigilar |
| Tamaño `rides` | ~1,5 KB | ~750 KB/día | ~22 MB | 500 MB | ⚠️ (~1,5-2 años) |
| Edge Functions (push lote) | ~1-3 | ~1-2 k/día | 30-60 k | 500 k | ✅ |
| Storage | compresión + purga 90 d | — | — | 1 GB | ✅ |
| MAU | — | — | — | 50 k | ✅ |
| Egress | depende de DAU y sesión | — | — | 5 GB | ⚠️ vigilar |

**Conclusión:** con estos cambios, 500 viajes/día **cabe en Free**, pero los topes de
**Realtime (200 conexiones / 2 M mensajes)** y **egress (5 GB)** son los que primero se
acercan. Si el uso crece, **Pro** (5 M realtime, 8 GB BD, ~250 GB egress) da muchísimo
margen y es la recomendación para producción con tracción.

Los `rides` siguen creciendo ~270 MB/año; para producción conviene activar la retención
(§5) antes de ~1 año.

---

## 4. Pasos manuales (fuera del código)

1. **Activar "Leaked password protection"** (Auth → Providers → Email). El advisor lo
   reporta deshabilitado. Es un toggle del dashboard de Supabase.
2. **Ticket a soporte de Supabase** para `spatial_ref_sys` (RLS/escritura) o mover
   `postgis` fuera de `public`. Impacto bajo.
3. **Decidir plan**: Free sirve para arrancar; **Pro** recomendado para 500 viajes/día
   sostenidos con varios cientos de usuarios.

---

## 5. Activar retención de viajes (opcional)

La RPC `archive_old_rides` es **manual** por defecto. Para probarla:

```sql
-- Solo archivado (seguro, no borra nada):
SELECT public.archive_old_rides(18, false);

-- Archivado + borrado de los que no tengan payout (recuperable vía rides_archive):
SELECT public.archive_old_rides(18, true);
```

Para automatizarlo (solo cuando estés seguro), añade al cron diario:

```sql
SELECT cron.schedule('bunrider-archive-rides', '30 3 * * *',
  'SELECT public.archive_old_rides(18, true)');
```

Recuerda: borrar un viaje elimina en cascada `driver_earnings`, `coupon_redemptions` y
`ride_incidents` (quedan guardados en el snapshot `rides_archive.data`).

---

## 6. Monitoreo y alertas

```sql
-- Tamaño de las tablas más pesadas
SELECT relname, pg_size_pretty(pg_total_relation_size(oid)) AS total
FROM pg_class WHERE relkind='r' AND relnamespace='public'::regnamespace
ORDER BY pg_total_relation_size(oid) DESC LIMIT 10;

-- Viajes de los últimos 7 días (pico diario)
SELECT date_trunc('day', created_at) AS dia, count(*)
FROM public.rides WHERE created_at > now() - interval '7 days'
GROUP BY 1 ORDER BY 1;

-- Consultas más costosas (pg_stat_statements ya está instalado)
SELECT calls, round(mean_exec_time::numeric,1) AS media_ms, left(query,90)
FROM extensions.pg_stat_statements ORDER BY total_exec_time DESC LIMIT 15;
```

- **Dashboard → Reports/Usage**: vigilar *Egress*, *Realtime messages*, *Realtime peak
  connections* y *Database size*. Considera alertas cuando superen ~70 % del límite.
- Cron activos: `ridesocopo-cleanup-daily` (3:00) y `bunrider-availability-reminders`
  (cada 5 min; también expira viajes sin conductor).

---

## 7. Cómo probar la carga sin romper nada

No se pueden crear ramas en Free. Plan recomendado:

1. **Entorno staging**: crear un proyecto Supabase Free aparte y aplicar las migraciones.
2. **k6** simulando el ciclo: login → `request_ride` → `accept_ride` →
   bucle `update_driver_location` → `complete_ride`, + suscripciones Realtime.
   Medir p95 de latencia, errores y consumo.
3. **Smoke test** en producción fuera de hora pico, con cuenta de prueba y limpieza
   inmediata (`supabase/reset_datos_prueba.sql`).
4. **Correctitud bajo concurrencia**: dos conductores aceptando el mismo viaje,
   expiración de viajes sin conductor y reembolso.

---

## 8. Rollback

- Frontend: revertir los 3 archivos (`git checkout -- <ruta>`).
- DB: `update_driver_location` se puede volver a la versión previa (migración 079); los
  cambios de RLS son equivalentes en semántica. `rides_archive` y `archive_old_rides` se
  pueden soltar con `DROP` sin afectar `rides`.

