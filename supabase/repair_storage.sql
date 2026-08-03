-- ============================================================
-- REPARACIÓN: POLÍTICAS DE STORAGE PARA SUBIR ARCHIVOS
-- Copia y ejecuta TODO este script en Supabase SQL Editor
-- ============================================================

-- 1. PERMISOS BASE DE STORAGE
GRANT ALL ON storage.objects TO authenticated;
GRANT ALL ON storage.buckets TO authenticated;
GRANT ALL ON storage.objects TO service_role;

-- 2. COMPROBAR QUE EXISTEN LOS BUCKETS
INSERT INTO storage.buckets (id, name, public)
VALUES 
  ('avatars', 'avatars', FALSE),
  ('documents', 'documents', FALSE),
  ('vehicles', 'vehicles', TRUE),
  ('payments', 'payments', FALSE),
  ('banners', 'banners', TRUE)
ON CONFLICT (id) DO UPDATE SET public = EXCLUDED.public;

-- 3. PERMITIR SUBIR DOCUMENTOS PERSONALES (cédula/licencia)
DROP POLICY IF EXISTS "users_upload_own_documents" ON storage.objects;
CREATE POLICY "users_upload_own_documents" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'documents' 
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

-- 4. PERMITIR SUBIR AVATAR
DROP POLICY IF EXISTS "users_upload_own_avatar" ON storage.objects;
CREATE POLICY "users_upload_own_avatar" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'avatars' 
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

-- 5. PERMITIR SUBIR FOTOS DE VEHÍCULOS
DROP POLICY IF EXISTS "users_upload_own_vehicle_photos" ON storage.objects;
CREATE POLICY "users_upload_own_vehicle_photos" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'vehicles' 
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

-- 6. PERMITIR SUBIR COMPROBANTES DE PAGO
DROP POLICY IF EXISTS "users_upload_own_payment_proofs" ON storage.objects;
CREATE POLICY "users_upload_own_payment_proofs" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'payments' 
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

-- 7. PERMITIR AL CONDUCTOR GESTIONAR SUS PROPIOS ARCHIVOS (ver/eliminar/actualizar)
DROP POLICY IF EXISTS "drivers_manage_own_files" ON storage.objects;
CREATE POLICY "drivers_manage_own_files" ON storage.objects
  FOR ALL USING (
    bucket_id IN ('documents', 'vehicles', 'avatars')
    AND auth.uid()::text = (storage.foldername(name))[1]
  )
  WITH CHECK (
    bucket_id IN ('documents', 'vehicles', 'avatars')
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

-- 8. VER SUS PROPIOS AVATARS
DROP POLICY IF EXISTS "users_view_own_avatar" ON storage.objects;
CREATE POLICY "users_view_own_avatar" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'avatars' 
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

-- 9. PERMITIR AL ADMIN VER TODOS LOS ARCHIVOS
DROP POLICY IF EXISTS "super_admin_view_all_storage" ON storage.objects;
CREATE POLICY "super_admin_view_all_storage" ON storage.objects
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'super_admin');

-- 10. PERMITIR AL ENCARGADO VER TODOS LOS ARCHIVOS
DROP POLICY IF EXISTS "encargado_view_all_storage" ON storage.objects;
CREATE POLICY "encargado_view_all_storage" ON storage.objects
  FOR SELECT USING (public.get_user_role(auth.uid()) = 'encargado');

-- 11. PERMITIR VER BANNERS PÚBLICOS
DROP POLICY IF EXISTS "public_view_banners" ON storage.objects;
CREATE POLICY "public_view_banners" ON storage.objects
  FOR SELECT USING (bucket_id = 'banners');

-- 12. PERMITIR AL ADMIN GESTIONAR BANNERS
DROP POLICY IF EXISTS "super_admin_manage_banners" ON storage.objects;
CREATE POLICY "super_admin_manage_banners" ON storage.objects
  FOR ALL USING (bucket_id = 'banners')
  WITH CHECK (bucket_id = 'banners');

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'Reparación de Storage completada' AS estado;