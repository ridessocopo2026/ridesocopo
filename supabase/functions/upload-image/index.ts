// ============================================================
// RIDERFLASSHI - Edge Function: upload-image
// Sube imágenes a ImgBB DESDE EL SERVIDOR.
//
// 🔐 Seguridad:
//  - La API key de ImgBB vive SOLO aquí (secreto del servidor).
//  - El cliente autenticado envía la imagen y recibe la URL.
//  - Se valida tipo MIME, tamaño máximo y se autentica con Supabase.
//  - Rate limiting: verifica el JWT del usuario y limita subidas.
//
// Configurar secreto:
//   ⚠️ ROTAR ESTA KEY: la anterior quedó expuesta en el código.
//   supabase secrets set IMGBB_API_KEY=TU_NUEVA_KEY_ROTADA
//   supabase functions deploy upload-image --no-verify-jwt=false
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";
import { encodeBase64 } from "jsr:@std/encoding@1/base64";

const IMGBB_API_KEY = Deno.env.get("IMGBB_API_KEY") || "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_ANON_KEY = Deno.env.get("SUPABASE_ANON_KEY")!;

const supabase = createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

// Configuración
const MAX_FILE_SIZE = 5 * 1024 * 1024; // 5MB
const ALLOWED_MIME_TYPES = [
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/gif",
];
const MAX_UPLOADS_PER_MINUTE = 10;

// Almacén simple de rate limiting en memoria (por usuario)
const uploadCounts = new Map<string, { count: number; resetAt: number }>();

function checkRateLimit(userId: string): boolean {
  const now = Date.now();
  const record = uploadCounts.get(userId);

  if (!record || now > record.resetAt) {
    uploadCounts.set(userId, { count: 1, resetAt: now + 60_000 });
    return true;
  }

  if (record.count >= MAX_UPLOADS_PER_MINUTE) {
    return false;
  }

  record.count++;
  return true;
}

// Limpieza periódica del rate limiter (cada 5 min)
setInterval(() => {
  const now = Date.now();
  for (const [key, value] of uploadCounts) {
    if (now > value.resetAt) {
      uploadCounts.delete(key);
    }
  }
}, 300_000);

Deno.serve(async (req) => {
  // CORS
  if (req.method === "OPTIONS") {
    return new Response("ok", {
      headers: {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
      },
    });
  }

  // Solo POST
  if (req.method !== "POST") {
    return new Response(JSON.stringify({ error: "Método no permitido" }), {
      status: 405,
      headers: { "Content-Type": "application/json" },
    });
  }

  // ── 1. AUTENTICACIÓN ──────────────────────────────────────
  // Verificar JWT del usuario autenticado de Supabase.
  const authHeader = req.headers.get("Authorization") || "";
  const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : "";

  if (!token) {
    return new Response(JSON.stringify({ error: "No autorizado" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  const { data: { user }, error: authError } = await supabase.auth.getUser(token);

  if (authError || !user) {
    return new Response(JSON.stringify({ error: "Token inválido o expirado" }), {
      status: 401,
      headers: { "Content-Type": "application/json" },
    });
  }

  // ── 2. RATE LIMITING ──────────────────────────────────────
  if (!checkRateLimit(user.id)) {
    return new Response(
      JSON.stringify({ error: `Límite de ${MAX_UPLOADS_PER_MINUTE} subidas por minuto alcanzado` }),
      {
        status: 429,
        headers: { "Content-Type": "application/json" },
      }
    );
  }

  // ── 3. RECIBIR Y VALIDAR IMAGEN ───────────────────────────
  let formData: FormData;
  try {
    formData = await req.formData();
  } catch {
    return new Response(JSON.stringify({ error: "Formato inválido. Usa multipart/form-data con campo 'image'" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  const file = formData.get("image");

  if (!(file instanceof File)) {
    return new Response(JSON.stringify({ error: "Campo 'image' requerido (File)" }), {
      status: 400,
      headers: { "Content-Type": "application/json" },
    });
  }

  // Validar tipo MIME
  if (!ALLOWED_MIME_TYPES.includes(file.type)) {
    return new Response(
      JSON.stringify({
        error: `Tipo de archivo no permitido: ${file.type}. Permitidos: ${ALLOWED_MIME_TYPES.join(", ")}`,
      }),
      {
        status: 400,
        headers: { "Content-Type": "application/json" },
      }
    );
  }

  // Validar tamaño
  if (file.size > MAX_FILE_SIZE) {
    return new Response(
      JSON.stringify({
        error: `Archivo demasiado grande (máximo ${MAX_FILE_SIZE / 1024 / 1024}MB)`,
      }),
      {
        status: 400,
        headers: { "Content-Type": "application/json" },
      }
    );
  }

  // ── 4. VERIFICAR API KEY ──────────────────────────────────
  if (!IMGBB_API_KEY) {
    console.error("IMGBB_API_KEY no configurada. Ejecuta: supabase secrets set IMGBB_API_KEY=...");
    return new Response(JSON.stringify({ error: "Error interno: servicio no configurado" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }

  // ── 5. SUBIR A IMGBB ──────────────────────────────────────
  try {
    const fileBytes = await file.arrayBuffer();
    const base64Image = encodeBase64(new Uint8Array(fileBytes));

    const imgbbForm = new FormData();
    imgbbForm.append("key", IMGBB_API_KEY);
    imgbbForm.append("image", base64Image);

    const imgbbResponse = await fetch("https://api.imgbb.com/1/upload", {
      method: "POST",
      body: imgbbForm,
    });

    const imgbbData = await imgbbResponse.json();

    if (!imgbbResponse.ok || !imgbbData.success) {
      console.error("Error ImgBB:", imgbbData?.error?.message || imgbbData);
      return new Response(
        JSON.stringify({
          error: imgbbData?.error?.message || "Error subiendo imagen a ImgBB",
        }),
        {
          status: 502,
          headers: { "Content-Type": "application/json" },
        }
      );
    }

    // Sanitizar URL devuelta (solo HTTPS http/https)
    const url = String(imgbbData.data.url || "");
    if (!url.startsWith("https://") && !url.startsWith("http://")) {
      return new Response(JSON.stringify({ error: "URL inválida de ImgBB" }), {
        status: 502,
        headers: { "Content-Type": "application/json" },
      });
    }

    return new Response(
      JSON.stringify({
        ok: true,
        url,
        display_url: imgbbData.data.display_url || url,
      }),
      {
        status: 200,
        headers: {
          "Content-Type": "application/json",
          "Access-Control-Allow-Origin": "*",
        },
      }
    );
  } catch (err: any) {
    console.error("Error en upload-image:", err.message || err);
    return new Response(JSON.stringify({ error: "Error interno al subir imagen" }), {
      status: 500,
      headers: { "Content-Type": "application/json" },
    });
  }
});