-- ============================================================
-- PRUEBA: SIMULAR ROL AUTHENTICATED (como el navegador)
-- Esto revela el error exacto que recibe la app
-- ============================================================

BEGIN;
SET LOCAL ROLE authenticated;

-- 1. Probar get_user_role con el admin real
SELECT public.get_user_role('cbbd6371-d96b-44aa-8f32-460b8ade5594') AS admin_role;

ROLLBACK;

-- 2. Probar get_admin_rides con auth.uid() del admin
BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', 'cbbd6371-d96b-44aa-8f32-460b8ade5594', true);
SELECT public.get_admin_rides(NULL, NOW() - INTERVAL '90 days', NOW(), NULL, 5, 0) AS rides;
ROLLBACK;