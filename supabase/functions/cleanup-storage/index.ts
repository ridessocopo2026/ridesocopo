// ============================================================
// BUNRIDER - Edge Function: cleanup-storage
// Borra los comprobantes antiguos del bucket 'payments' usando la
// Storage API (borrar por SQL NO elimina el archivo real de S3).
//
// 🔐 Seguridad:
//  - Solo responde a peticiones con el secreto compartido
//    (PUSH_FUNCTION_SECRET, el mismo que ya usa push-notifications
//    y que vive en push_settings.function_secret de la BD).
//  - Cualquier usuario no autorizado recibe 401.
//  - Las rutas a borrar las calcula la RPC storage_paths_to_purge(),
//    que NUNCA devuelve un archivo referenciado por filas pendientes.
//
// 💰 Costo: 1 invocación al día (cron 3:00 AM) con muy pocas
//    peticiones a Storage, y sólo borra; no lee contenidos.
// ============================================================

import { createClient } from "jsr:@supabase/supabase-js@2";

const FUNCTION_SECRET = Deno.env.get("PUSH_FUNCTION_SECRET") || "";
const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SUPABASE_SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;

const BUCKET = "payments";
const DIAS_DEFAULT = 90;
const TAMANO_LOTE = 100; // la Storage API borra por lotes

const supabase = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Access-Control-Allow-Headers": "authorization, content-type",
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json", ...corsHeaders },
  });
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return json({ error: "Método no permitido" }, 405);
  }

  // ── Autenticación por secreto compartido ────────────────────
  const authHeader = req.headers.get("Authorization") || "";
  const token = authHeader.startsWith("Bearer ") ? authHeader.slice(7) : "";

  if (!FUNCTION_SECRET || token !== FUNCTION_SECRET) {
    return json({ error: "No autorizado" }, 401);
  }

  // ── Días de retención (por defecto 90, mínimo 30) ───────────
  let dias = DIAS_DEFAULT;
  try {
    const body = await req.json();
    const solicitado = Number(body?.dias);
    if (Number.isFinite(solicitado) && solicitado >= 30) dias = Math.floor(solicitado);
  } catch {
    // Sin cuerpo válido: se usa el valor por defecto
  }

  // ── 1. Rutas seguras de borrar (lo decide la base de datos) ─
  const { data, error } = await supabase.rpc("storage_paths_to_purge", { p_dias: dias });

  if (error) {
    console.error("Error en storage_paths_to_purge:", error.message);
    return json({ error: error.message }, 500);
  }

  const paths: string[] = Array.isArray(data?.paths) ? data.paths : [];

  if (paths.length === 0) {
    return json({ ok: true, dias, candidatos: 0, borrados: 0, mensaje: "Nada que limpiar" });
  }

  // ── 2. Borrado real con la Storage API (en lotes) ──────────
  let borrados = 0;
  const errores: string[] = [];

  for (let i = 0; i < paths.length; i += TAMANO_LOTE) {
    const lote = paths.slice(i, i + TAMANO_LOTE);
    const { data: eliminados, error: removeError } = await supabase.storage
      .from(BUCKET)
      .remove(lote);

    if (removeError) {
      errores.push(removeError.message);
      continue;
    }
    borrados += eliminados?.length ?? 0;
  }

  // ── 3. Auditoría (visible en el panel del admin) ────────────
  try {
    await supabase.from("audit_logs").insert({
      user_id: null,
      action: "CLEANUP_STORAGE",
      entity_type: "storage",
      entity_id: null,
      details: {
        bucket: BUCKET,
        dias,
        candidatos: paths.length,
        borrados,
        protegidas: data?.protegidas ?? 0,
        errores: errores.length,
      },
    });
  } catch (auditError) {
    console.error("No se pudo registrar la auditoría:", auditError);
  }

  return json({
    ok: true,
    dias,
    candidatos: paths.length,
    borrados,
    protegidas: data?.protegidas ?? 0,
    errores,
  });
});
