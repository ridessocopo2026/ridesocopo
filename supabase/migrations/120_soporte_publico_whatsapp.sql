-- ============================================================
-- 120 - SOPORTE PÚBLICO POR WHATSAPP (INVITADOS)
-- ------------------------------------------------------------
-- get_my_support() está revocado para anon y además depende de
-- auth.uid(); por eso el invitado no veía el botón de soporte.
--
-- get_public_support(p_zone_id) devuelve SOLO el número público:
--   1) el de la ciudad seleccionada (invitado),
--   2) el de la ciudad del usuario autenticado,
--   3) el número de respaldo.
-- Es intencionalmente ejecutable por anon (es información pública).
-- ============================================================

CREATE OR REPLACE FUNCTION public.get_public_support(p_zone_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'phone', COALESCE(
      (SELECT support_whatsapp FROM zones WHERE id = p_zone_id AND is_active = TRUE),
      (SELECT z.support_whatsapp
         FROM profiles p
         JOIN zones z ON z.id = p.zone_id
        WHERE p.id = auth.uid()),
      '+584162608950'
    )
  );
$$;

REVOKE ALL ON FUNCTION public.get_public_support(UUID) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.get_public_support(UUID) TO anon, authenticated, service_role;

SELECT 'Migración 120 aplicada: soporte público por WhatsApp' AS estado;