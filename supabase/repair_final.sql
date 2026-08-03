-- ============================================================
-- REPARACIÓN FINAL: BUCKET payments + RLS de rides
-- Copia y ejecuta TODO este script en Supabase SQL Editor
-- ============================================================

-- 1. CREAR BUCKET payments (si no existe)
INSERT INTO storage.buckets (id, name, public)
VALUES ('payments', 'payments', FALSE)
ON CONFLICT (id) DO UPDATE SET public = FALSE;

-- 2. PERMISOS DE STORAGE PARA payments
GRANT ALL ON storage.objects TO anon, authenticated, service_role;
GRANT ALL ON storage.buckets TO anon, authenticated, service_role;

-- 3. POLÍTICAS DE STORAGE PARA payments
-- Insertar comprobantes
DROP POLICY IF EXISTS "users_upload_own_payment_proofs" ON storage.objects;
CREATE POLICY "users_upload_own_payment_proofs" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'payments'
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

-- Ver/eliminar sus propios comprobantes
DROP POLICY IF EXISTS "users_manage_own_payment_proofs" ON storage.objects;
CREATE POLICY "users_manage_own_payment_proofs" ON storage.objects
  FOR ALL USING (
    bucket_id = 'payments'
    AND auth.uid()::text = (storage.foldername(name))[1]
  )
  WITH CHECK (
    bucket_id = 'payments'
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

-- Admin/Encargado pueden ver todos los comprobantes
DROP POLICY IF EXISTS "admins_view_payments" ON storage.objects;
CREATE POLICY "admins_view_payments" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'payments'
    AND public.get_user_role(auth.uid()) IN ('super_admin', 'encargado')
  );

-- 4. RECONSTRUIR POLÍTICAS DE RIDES (INSERT con WITH CHECK)
DROP POLICY IF EXISTS "client_create_rides" ON public.rides;
CREATE POLICY "client_create_rides" ON public.rides
  FOR INSERT WITH CHECK (auth.uid() = client_id);

-- 5. REOTORGAR GRANT EXECUTE A LAS FUNCIONES NUEVAS
GRANT EXECUTE ON FUNCTION public.request_ride_with_proof TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.approve_ride_proof TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.get_pending_proofs TO anon, authenticated, service_role;

-- 6. VERIFICACIÓN
SELECT 'Reparación final completada' AS estado;