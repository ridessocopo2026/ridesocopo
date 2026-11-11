// ============================================================
// BUNRIDER - Edge Function: push-notifications
// Envia Web Push a las suscripciones de cada notificacion.
// Se invoca desde los triggers SQL via pg_net (por lote).
//
// Optimizacion (costo + velocidad):
//   - 2 consultas para TODAS las notificaciones del lote
//     (antes: 3 consultas por notificacion).
//   - Envios en paralelo con concurrencia limitada.
//   - Guarda sent_count / failed_count / error en notification_outbox
//     para diagnostico real (antes solo quedaba sent_at).
//
// Secretos requeridos (supabase secrets set):
//   PUSH_FUNCTION_SECRET  - secreto compartido con la BD (push_settings)
//   VAPID_PUBLIC_KEY      - clave publica VAPID
//   VAPID_PRIVATE_KEY     - clave privada VAPID
//   VAPID_SUBJECT         - email de contacto
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const FUNCTION_SECRET = Deno.env.get("PUSH_FUNCTION_SECRET") || "";
const VAPID_PUBLIC_KEY = Deno.env.get("VAPID_PUBLIC_KEY") || "";
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY") || "";
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") || "mailto:contactos@bunrider.com";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

webpush.setVapidDetails(VAPID_SUBJECT, VAPID_PUBLIC_KEY, VAPID_PRIVATE_KEY);

const MAX_PER_INVOCATION = 100;
const CONCURRENCY = 10;

// Notificaciones de conductores: abrir el conductor exacto en el admin
const DRIVER_FOCUS_BY_TYPE: Record<string, string> = {
  driver_pending: "pending",
  vehicle_pending: "vehicle",
  name_review: "name",
  avatar_review: "avatar",
  driver_change_request: "change",
};

type Notif = {
  id: string;
  title: string;
  body: string | null;
  data: Record<string, unknown> | null;
  user_id: string;
  type: string | null;
};

type Sub = { user_id: string; endpoint: string; p256dh: string; auth: string };

function json(payload: unknown, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" },
  });
}

function buildUrl(n: Notif): string {
  const data = n.data || {};
  const driverId = data["driver_id"];
  const focus = n.type ? DRIVER_FOCUS_BY_TYPE[n.type] : undefined;
  if (driverId && focus) {
    return `/admin/conductores?driver=${driverId}&focus=${focus}`;
  }
  const url = data["url"];
  return typeof url === "string" && url ? url : "/";
}

/** Divide un array en trozos (concurrencia controlada) */
function chunk<T>(items: T[], size: number): T[][] {
  const out: T[][] = [];
  for (let i = 0; i < items.length; i += size) out.push(items.slice(i, i + size));
  return out;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: { "Access-Control-Allow-Origin": "*" } });
  }

  // Validar secreto compartido con la BD
  const authHeader = req.headers.get("Authorization") || "";
  const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : "";

  const { data: settings } = await supabase
    .from("push_settings")
    .select("function_secret")
    .limit(1);

  const validSecret = settings?.[0]?.function_secret || FUNCTION_SECRET;
  if (token !== validSecret) return json({ error: "No autorizado" }, 401);

  try {
    const body = await req.json();
    const ids: string[] = (Array.isArray(body?.notification_ids)
      ? body.notification_ids
      : body?.notification_id
        ? [body.notification_id]
        : []
    ).slice(0, MAX_PER_INVOCATION);

    if (ids.length === 0) {
      return json({ error: "notification_id o notification_ids requerido" }, 400);
    }

    // 1) Notificaciones del lote (1 consulta)
    const { data: notifData, error: notifErr } = await supabase
      .from("notifications")
      .select("id, title, body, data, user_id, type")
      .in("id", ids);
    if (notifErr) throw notifErr;

    const notifs = (notifData || []) as Notif[];
    const found = new Set(notifs.map((n) => n.id));
    const missing = ids.filter((id) => !found.has(id));

    // 2) Suscripciones de todos los usuarios del lote (1 consulta)
    const userIds = [...new Set(notifs.map((n) => n.user_id))];
    let subs: Sub[] = [];
    if (userIds.length > 0) {
      const { data: subsData, error: subsErr } = await supabase
        .from("push_subscriptions")
        .select("user_id, endpoint, p256dh, auth")
        .in("user_id", userIds);
      if (subsErr) throw subsErr;
      subs = (subsData || []) as Sub[];
    }

    const subsByUser = new Map<string, Sub[]>();
    for (const s of subs) {
      const list = subsByUser.get(s.user_id) || [];
      list.push(s);
      subsByUser.set(s.user_id, list);
    }

    const results: Record<string, unknown>[] = [];
    const outboxRows: Record<string, unknown>[] = [];
    const expired: string[] = [];

    // 3) Enviar (concurrencia limitada)
    for (const group of chunk(notifs, CONCURRENCY)) {
      await Promise.all(
        group.map(async (n) => {
          const userSubs = subsByUser.get(n.user_id) || [];
          const base = {
            notification_id: n.id,
            user_id: n.user_id,
            sent_at: new Date().toISOString(),
            attempts: 1,
          };

          if (userSubs.length === 0) {
            outboxRows.push({ ...base, sent_count: 0, failed_count: 0, error: null });
            results.push({ notification_id: n.id, ok: true, sent: 0, skipped: "no subscriptions" });
            return;
          }

          const payload = JSON.stringify({
            title: n.title,
            body: n.body || "",
            data: { url: buildUrl(n) },
          });

          let sent = 0;
          let failed = 0;
          let firstError: string | null = null;

          await Promise.all(
            userSubs.map(async (sub) => {
              try {
                await webpush.sendNotification(
                  { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
                  payload,
                  { TTL: 86400, urgency: "high" },
                );
                sent++;
              } catch (err: any) {
                const statusCode = err?.statusCode;
                if (statusCode === 410 || statusCode === 404) {
                  expired.push(sub.endpoint);
                } else {
                  failed++;
                  firstError = firstError || `${statusCode || "error"}: ${err?.message || err}`;
                  console.error(`Error enviando push a ${sub.endpoint}:`, err?.message || err);
                }
              }
            }),
          );

          outboxRows.push({ ...base, sent_count: sent, failed_count: failed, error: firstError });
          results.push({ notification_id: n.id, ok: failed === 0, sent, failed });
        }),
      );
    }

    // 4) Borrar suscripciones expiradas (1 consulta)
    if (expired.length > 0) {
      await supabase.from("push_subscriptions").delete().in("endpoint", expired);
    }

    // 5) Guardar resultado real del envio (1 consulta)
    if (outboxRows.length > 0) {
      const { error: upErr } = await supabase
        .from("notification_outbox")
        .upsert(outboxRows, { onConflict: "notification_id" });
      if (upErr) console.error("Error guardando outbox:", upErr.message);
    }

    return json({
      ok: true,
      processed: results.length,
      notFound: missing.length,
      expired: expired.length,
      results,
    });
  } catch (err: any) {
    console.error("Error en push-notifications:", err);
    return json({ error: err?.message || "Error interno" }, 500);
  }
});
