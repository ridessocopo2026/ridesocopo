// ============================================================
// RIDESOCOPÓ - Edge Function: push-notifications
// Recibe notificaciones y envía Web Push a los suscriptores.
// Se invoca desde el trigger SQL vía pg_net.
//
// Secretos requeridos (supabase secrets set):
//   PUSH_FUNCTION_SECRET  - secreto compartido con la BD (en push_settings)
//   VAPID_PUBLIC_KEY      - clave pública VAPID
//   VAPID_PRIVATE_KEY     - clave privada VAPID
//   VAPID_SUBJECT         - email de contacto (ridessocopo@gmail.com)
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const FUNCTION_SECRET = Deno.env.get("PUSH_FUNCTION_SECRET")!;
const VAPID_PUBLIC_KEY = Deno.env.get("VAPID_PUBLIC_KEY")!;
const VAPID_PRIVATE_KEY = Deno.env.get("VAPID_PRIVATE_KEY")!;
const VAPID_SUBJECT = Deno.env.get("VAPID_SUBJECT") || "mailto:ridessocopo@gmail.com";

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
  if (token !== FUNCTION_SECRET) {
    return new Response(JSON.stringify({ error: "No autorizado" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  try {
    const { notification_id: notificationId } = await req.json();

    if (!notificationId) {
      return new Response(
        JSON.stringify({ error: "notification_id requerido" }),
        {
          status: 400,
          headers: { "Content-Type": "application/json" },
        },
      );
    }

    // 1. Obtener notificación
    const { data: notification, error: notifErr } = await supabase
      .from("notifications")
      .select("*")
      .eq("id", notificationId)
      .single();

    if (notifErr || !notification) {
      // La notificación puede haber sido borrada; marcar outbox como error
      await supabase
        .from("notification_outbox")
        .update({
          error: "Notification not found",
          sent_at: new Date().toISOString(),
        })
        .eq("notification_id", notificationId);
      return new Response(
        JSON.stringify({ ok: false, error: "Notificación no encontrada" }),
        {
          status: 404,
          headers: { "Content-Type": "application/json" },
        },
      );
    }

    const userId = notification.user_id;

    // 2. Obtener suscripciones activas del usuario
    const { data: subscriptions, error: subsErr } = await supabase
      .from("push_subscriptions")
      .select("*")
      .eq("user_id", userId);

    if (subsErr) {
      throw subsErr;
    }

    if (!subscriptions || subscriptions.length === 0) {
      // No hay suscripciones: marcar como enviado (nadie a quien notificar)
      await supabase
        .from("notification_outbox")
        .update({ sent_at: new Date().toISOString() })
        .eq("notification_id", notificationId);
      return new Response(
        JSON.stringify({ ok: true, skipped: "no subscriptions" }),
        {
          status: 200,
          headers: { "Content-Type": "application/json" },
        },
      );
    }

    // 3. Enviar push a cada suscripción
    const title = notification.title;
    const body = notification.body;
    const data = notification.data || {};
    const url = data.url || "/";
    const type = notification.type || undefined;

    const payload = JSON.stringify({
      title,
      body,
      icon: "/icons/icon-192x192.png",
      badge: "/icons/icon-192x192.png",
      data: { url },
    });

    let sentCount = 0;
    const expiredEndpoints: string[] = [];

    for (const sub of subscriptions) {
      try {
        const pushSubscription = {
          endpoint: sub.endpoint,
          keys: {
            p256dh: sub.p256dh,
            auth: sub.auth,
          },
        };

        await webpush.sendNotification(pushSubscription, payload, {
          TTL: 86400,
          urgency: "high",
        });
        sentCount++;
      } catch (err: any) {
        const statusCode = err?.statusCode;
        const isExpired = statusCode === 410 || statusCode === 404;

        if (isExpired) {
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

    return new Response(
      JSON.stringify({
        ok: true,
        sent: sentCount,
        expired: expiredEndpoints.length,
        type,
      }),
      {
        status: 200,
        headers: { "Content-Type": "application/json" },
      },
    );
  } catch (err: any) {
    console.error("Error en push-notifications:", err);
    return new Response(
      JSON.stringify({ error: err.message || "Error interno" }),
      {
        status: 500,
        headers: { "Content-Type": "application/json" },
      },
    );
  }
});