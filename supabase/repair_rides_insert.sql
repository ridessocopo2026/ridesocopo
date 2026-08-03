-- ============================================================
-- REPARACIÓN: RLS para INSERT en rides (request_ride_with_proof)
-- ============================================================

-- 1. OTORGAR PERMISOS EN TODAS LAS COLUMNAS DE RIDES
GRANT ALL ON public.rides TO anon, authenticated, service_role;
GRANT ALL ON public.rides TO postgres;

-- 2. RECREAR POLÍTICA client_create_rides con WITH CHECK
DROP POLICY IF EXISTS "client_create_rides" ON public.rides;
CREATE POLICY "client_create_rides" ON public.rides
  FOR INSERT WITH CHECK (auth.uid() = client_id);

-- 3. OTORGAR EXECUTE A LAS FUNCIONES DE CREACIÓN DE VIAJES
GRANT EXECUTE ON FUNCTION public.request_ride TO anon, authenticated, service_role;
GRANT EXECUTE ON FUNCTION public.request_ride_with_proof TO anon, authenticated, service_role;

-- 4. HACER PÚBLICO EL BUCKET payments (para que el comprobante se vea en AdminProofs)
UPDATE storage.buckets SET public = TRUE WHERE id = 'payments';

-- 5. POLÍTICAS PARA VER COMPROBANTES (el cliente ve los suyos, admin ve todos)
DROP POLICY IF EXISTS "users_upload_own_payment_proofs" ON storage.objects;
CREATE POLICY "users_upload_own_payment_proofs" ON storage.objects
  FOR INSERT WITH CHECK (
    bucket_id = 'payments'
    AND auth.uid()::text = (storage.foldername(name))[1]
  );

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

DROP POLICY IF EXISTS "public_read_payments" ON storage.objects;
CREATE POLICY "public_read_payments" ON storage.objects
  FOR SELECT USING (bucket_id = 'payments');

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT 'Reparación de INSERT en rides completada' AS estado;