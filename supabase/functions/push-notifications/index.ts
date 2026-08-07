// ============================================================
// RIDERFLASSHI - Edge Function: push-notifications
// Recibe notificaciones y envía Web Push a los suscriptores.
// Se invoca desde el trigger SQL vía pg_net.
//
// ✅ SOPORTE DE LOTE (optimización de costos):
//   Acepta `{ notification_ids: [...] }` (procesa varias en UNA
//   invocación — 1 llamada por statement SQL en vez de una por
//   notificación) o `{ notification_id: "..." }` (backward compat
//   para reprocesos manuales).
//
// Secretos requeridos (supabase secrets set):
//   PUSH_FUNCTION_SECRET  - secreto compartido con la BD (en push_settings)
//   VAPID_PUBLIC_KEY      - clave pública VAPID
//   VAPID_PRIVATE_KEY     - clave privada VAPID
//   VAPID_SUBJECT         - email de contacto
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const FUNCTION_SECRET = Deno.env.get("PUSH_FUNCTION_SECRET") || "";
const VAPID_PUBLIC_KEY = Deno.env.get("VAPID_PUBLIC_KEY") || "";
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY") || "";
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") || "mailto:contacto@riderflasshi.com";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// Configurar VAPID
webpush.setVapidDetails(
  VAPID_SUBJECT,
  VAPID_PUBLIC_KEY,
  VAPID_PRIVATE_KEY,
);

// Máx. de notificaciones por invocación (evitar timeout)
const MAX_PER_INVOCATION = 100;

// ------------------------------------------------------------
// Procesa UNA notificación: envía push a las suscripciones del usuario
// ------------------------------------------------------------
async function processNotification(notificationId: string) {
  // 1. Obtener notificación
  const { data: notification, error: notifErr } = await supabase
    .from("notifications")
    .select("title, body, data, user_id")
    .eq("id", notificationId)
    .single();

  if (notifErr || !notification) {
    // Puede haber sido borrada; marcar outbox como error
    await supabase
      .from("notification_outbox")
      .update({ error: "Notification not found", sent_at: new Date().toISOString() })
      .eq("notification_id", notificationId);
    return { ok: false, error: "Notification not found" };
  }

  // 2. Obtener suscripciones activas del usuario
  const { data: subscriptions, error: subsErr } = await supabase
    .from("push_subscriptions")
    .select("endpoint, p256dh, auth")
    .eq("user_id", notification.user_id);

  if (subsErr) throw subsErr;

  if (!subscriptions || subscriptions.length === 0) {
    await supabase
      .from("notification_outbox")
      .update({ sent_at: new Date().toISOString() })
      .eq("notification_id", notificationId);
    return { ok: true, sent: 0, skipped: "no subscriptions" };
  }

  // 3. Enviar push a cada suscripción
  const data = notification.data || {};
  const url = data.url || "/";

  const payload = JSON.stringify({
    title: notification.title,
    body: notification.body,
    icon: "/icons/icon-192x192.png",
    badge: "/icons/icon-192x192.png",
    data: { url },
  });

  let sentCount = 0;
  const expiredEndpoints: string[] = [];

  for (const sub of subscriptions) {
    try {
      await webpush.sendNotification(
        { endpoint: sub.endpoint, keys: { p256dh: sub.p256dh, auth: sub.auth } },
        payload,
        { TTL: 86400, urgency: "high" },
      );
      sentCount++;
    } catch (err: any) {
      const statusCode = err?.statusCode;
      if (statusCode === 410 || statusCode === 404) {
        expiredEndpoints.push(sub.endpoint);
      } else {
        console.error(`Error enviando push a ${sub.endpoint}:`, err.message || err);
      }
    }
  }

  // 4. Borrar suscripciones expiradas
  if (expiredEndpoints.length > 0) {
    await supabase
      .from("push_subscriptions")
      .delete()
      .in("endpoint", expiredEndpoints);
  }

  // 5. Marcar outbox como enviado
  await supabase
    .from("notification_outbox")
    .update({
      sent_at: new Date().toISOString(),
      attempts: 1,
      error: expiredEndpoints.length > 0
        ? `Expired: ${expiredEndpoints.length}`
        : null,
    })
    .eq("notification_id", notificationId);

  return { ok: true, sent: sentCount };
}

// ------------------------------------------------------------
// Handler principal
// ------------------------------------------------------------
Deno.serve(async (req) => {
  // CORS simple
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: { "Access-Control-Allow-Origin": "*" },
    });
  }

  // Validar secreto compartido
  const authHeader = req.headers.get("Authorization") || "";
  const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : "";

  const { data: settings } = await supabase
    .from("push_settings")
    .select("function_secret")
    .limit(1);

  const validSecret = settings?.[0]?.function_secret || FUNCTION_SECRET;

  if (token !== validSecret) {
    return new Response(JSON.stringify({ error: "No autorizado" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  try {
    const body = await req.json();
    const notificationIds: string[] = Array.isArray(body?.notification_ids)
      ? body.notification_ids
      : body?.notification_id
        ? [body.notification_id]
        : [];

    if (notificationIds.length === 0) {
      return new Response(
        JSON.stringify({ error: "notification_id o notification_ids requerido" }),
        { status: 400, headers: { "Content-Type": "application/json" } },
      );
    }

    // 💰 LOTE: procesar varias notificaciones en UNA invocación
    const results: any[] = [];
    for (const notificationId of notificationIds.slice(0, MAX_PER_INVOCATION)) {
      try {
        const r = await processNotification(notificationId);
        results.push({ notification_id: notificationId, ...r });
      } catch (err: any) {
        results.push({
          notification_id: notificationId,
          ok: false,
          error: err.message || "Error interno",
        });
      }
    }

    return new Response(
      JSON.stringify({ ok: true, processed: results.length, results }),
      { status: 200, headers: { "Content-Type": "application/json" } },
    );
  } catch (err: any) {
    console.error("Error en push-notifications:", err);
    return new Response(
      JSON.stringify({ error: err.message || "Error interno" }),
      { status: 500, headers: { "Content-Type": "application/json" } },
    );
  }
});
