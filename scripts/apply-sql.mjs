/**
 * Aplica un archivo .sql en el proyecto de Supabase (equivalente a pegar el
 * contenido en el SQL Editor del dashboard).
 *
 * Usa la Management API oficial:
 *   POST https://api.supabase.com/v1/projects/{ref}/database/query
 *
 * USO
 *   node scripts/apply-sql.mjs supabase/migrations/076_restaurar_flujo_invitado.sql
 *
 * REQUIERE un Personal Access Token de Supabase (dashboard → Account → Access
 * Tokens → Generate new token) en la variable de entorno SUPABASE_ACCESS_TOKEN:
 *   $env:SUPABASE_ACCESS_TOKEN = 'sbp_...'   (PowerShell, solo esa sesión)
 * o pásalo como segundo argumento:  node scripts/apply-sql.mjs archivo.sql sbp_...
 *
 * El token se puede revocar en el dashboard cuando termines.
 *
 * El project-ref se lee de supabase/.temp/project-ref (proyecto enlazado) y,
 * si no existe, se deduce de VITE_SUPABASE_URL en .env.local / .env.production.
 */

import { readFileSync, existsSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = resolve(dirname(fileURLToPath(import.meta.url)), '..')

function readProjectRef() {
  const tempRef = resolve(root, 'supabase/.temp/project-ref')
  if (existsSync(tempRef)) return readFileSync(tempRef, 'utf8').trim()

  for (const envFile of ['.env.local', '.env.production']) {
    const path = resolve(root, envFile)
    if (!existsSync(path)) continue
    const match = readFileSync(path, 'utf8').match(/VITE_SUPABASE_URL=https:\/\/([a-z0-9]+)\.supabase\.co/)
    if (match) return match[1]
  }
  return ''
}

const [, , sqlPathArg, tokenArg] = process.argv

async function main() {
  if (!sqlPathArg) {
    console.error('❌ Uso: node scripts/apply-sql.mjs <archivo.sql> [token]')
    process.exitCode = 1
    return
  }

  const sqlPath = resolve(root, sqlPathArg)
  if (!existsSync(sqlPath)) {
    console.error(`❌ No existe el archivo: ${sqlPath}`)
    process.exitCode = 1
    return
  }

  const token = tokenArg || process.env.SUPABASE_ACCESS_TOKEN || ''
  if (!token) {
    console.error('❌ Falta SUPABASE_ACCESS_TOKEN (Personal Access Token de Supabase).')
    console.error('   Dashboard → Account → Access Tokens → Generate new token.')
    console.error("   PowerShell:  $env:SUPABASE_ACCESS_TOKEN = 'sbp_...'")
    process.exitCode = 1
    return
  }

  const projectRef = readProjectRef()
  if (!projectRef) {
    console.error('❌ No se pudo determinar el project-ref (revisa supabase/.temp/project-ref o .env.local).')
    process.exitCode = 1
    return
  }

  const query = readFileSync(sqlPath, 'utf8')
  console.log(`→ Proyecto: ${projectRef}`)
  console.log(`→ SQL:      ${sqlPathArg} (${query.length} caracteres)`)

  const response = await fetch(`https://api.supabase.com/v1/projects/${projectRef}/database/query`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({ query })
  })

  const text = await response.text()

  if (!response.ok) {
    console.error(`❌ Error ${response.status}: ${text}`)
    if (response.status === 401) console.error('   El token no es válido o fue revocado.')
    process.exitCode = 1
    return
  }

  console.log('✅ SQL aplicado correctamente.')
  console.log(text || '(sin filas devueltas)')
}

main().catch((err) => {
  console.error('❌ Error inesperado:', err?.message || err)
  process.exitCode = 1
})
