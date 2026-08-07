-- ============================================================
-- RIDERFLASSHI - Migración 039: PÁGINAS LEGALES
-- Contenido de Políticas de Privacidad, Términos y Condiciones
-- y "Sobre RiderFlasshi", editable desde el panel admin.
-- Lectura pública (para SEO y usuarios) + edición solo super_admin.
-- ============================================================

CREATE TABLE IF NOT EXISTS public.legal_pages (
  key TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  content TEXT NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_by UUID REFERENCES public.profiles(id)
);

INSERT INTO public.legal_pages (key, title, content) VALUES
('politicas_privacidad', 'Políticas de Privacidad',
E'En RiderFlasshi respetamos tu privacidad. Esta política explica qué información recopilamos y cómo la usamos.\n\n1. INFORMACIÓN QUE RECOPILAMOS\n- Datos de cuenta: nombre, correo electrónico y teléfono.\n- Datos de viaje: ubicaciones de origen y destino, historial de viajes y calificaciones.\n- Datos de pago: saldo de la billetera, comprobantes y referencia de pagos.\n\n2. USO DE LA INFORMACIÓN\nUsamos tus datos para: conectar pasajeros con conductores y gestionar los viajes, procesar pagos y liquidaciones, enviar notificaciones sobre tus viajes y la app, y mejorar nuestro servicio.\n\n3. COMPARTIR INFORMACIÓN\nTu ubicación e información de viaje se comparten únicamente con el conductor asignado para prestar el servicio. No vendemos tus datos a terceros.\n\n4. ALMACENAMIENTO Y SEGURIDAD\nTu información se almacena de forma segura con controles de acceso. Solo personal autorizado accede a los datos necesarios para operar la plataforma.\n\n5. TUS DERECHOS\nPuedes solicitar acceso, corrección o eliminación de tus datos personales. Conservamos la información el tiempo necesario para fines legales y operativos.\n\n6. CONTACTO\nSi tienes preguntas sobre esta política, contáctanos a través de los canales oficiales de RiderFlasshi.'),
('terminos_condiciones', 'Términos y Condiciones de Uso',
E'Al usar la aplicación RiderFlasshi aceptas estos términos.\n\n1. EL SERVICIO\nRiderFlasshi conecta pasajeros con conductores de moto, carro y camioneta en Socopó, Barinas, Venezuela. El pago puede hacerse en efectivo, con saldo de la billetera o mediante pago móvil.\n\n2. REGISTRO Y CUENTA\nDebes proporcionar información veraz al registrarte y eres responsable de mantener la confidencialidad de tu cuenta. La app puede suspender cuentas que infrinjan estas normas.\n\n3. PASAJEROS\nAl solicitar un viaje confirmas que el destino y los datos son correctos. Los montos son estimados y pueden incluir recargos por sector. Las cancelaciones pueden generar cargos según la política vigente.\n\n4. CONDUCTORES\nPara ser conductor debes estar aprobado y contar con un vehículo apto. Debes cumplir las leyes de tránsito y brindar un servicio seguro. La comisión se descuenta conforme a la configuración vigente.\n\n5. PAGOS Y BILLETERA\nEl saldo de la billetera es un crédito digital de la plataforma. Las recargas quedan pendientes hasta ser aprobadas con su comprobante. Los retiros siguen un flujo de doble confirmación.\n\n6. RESPONSABILIDAD\nLa plataforma no es responsable por daños fuera de su control. Estos términos pueden actualizarse; la versión vigente estará siempre disponible en esta página.\n\n7. CONTACTO\nPara dudas, contáctanos por los canales oficiales de RiderFlasshi.'),
('sobre_riderflash', 'Sobre RiderFlasshi',
E'RiderFlasshi es la aplicación de transporte de pasajeros de Socopó, Barinas, Venezuela.\n\nConectamos de forma rápida y segura a pasajeros con conductores de motos, carros y camionetas de la localidad, con precios claros y varias formas de pago: efectivo, billetera digital y pago móvil.\n\n¿CÓMO FUNCIONA?\n1. Indica a dónde quieres ir y dónde te recogemos.\n2. Elige el tipo de vehículo y la forma de pago.\n3. Un conductor aprobado acepta tu viaje.\n4. Sigue tu viaje en tiempo real y paga al final.\n\nRiderFlasshi está hecha para Socopó y su gente: transporte accesible, con tecnología simple y apoyo local. Un proyecto independiente en crecimiento que trabaja cada día para mejorar el servicio.\n\n¡Gracias por viajar con RiderFlasshi!')
ON CONFLICT (key) DO NOTHING;

-- ============================================================
-- RLS: lectura pública + edición solo super_admin
-- ============================================================
ALTER TABLE public.legal_pages ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "public_read_legal_pages" ON public.legal_pages;
CREATE POLICY "public_read_legal_pages" ON public.legal_pages
  FOR SELECT USING (TRUE);

DROP POLICY IF EXISTS "super_admin_manage_legal_pages" ON public.legal_pages;
CREATE POLICY "super_admin_manage_legal_pages" ON public.legal_pages
  FOR ALL USING (public.get_user_role(auth.uid()) = 'super_admin');

GRANT SELECT ON public.legal_pages TO anon, authenticated;
GRANT ALL ON public.legal_pages TO service_role;

-- ============================================================
-- RPC: guardar página legal (solo super_admin)
-- ============================================================
CREATE OR REPLACE FUNCTION public.save_legal_page(p_key TEXT, p_title TEXT, p_content TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
BEGIN
  IF public.get_user_role(v_admin_id) != 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  IF p_key NOT IN ('politicas_privacidad', 'terminos_condiciones', 'sobre_riderflash') THEN
    RAISE EXCEPTION 'Clave no válida';
  END IF;

  IF p_title IS NULL OR trim(p_title) = '' OR p_content IS NULL OR trim(p_content) = '' THEN
    RAISE EXCEPTION 'El título y el contenido son obligatorios';
  END IF;

  UPDATE public.legal_pages
  SET title = p_title, content = p_content, updated_at = NOW(), updated_by = v_admin_id
  WHERE key = p_key;

  IF NOT FOUND THEN
    INSERT INTO public.legal_pages (key, title, content, updated_by)
    VALUES (p_key, p_title, p_content, v_admin_id);
  END IF;

  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_admin_id, 'SAVE_LEGAL_PAGE', 'legal_pages', p_key,
          jsonb_build_object('title', p_title));

  RETURN jsonb_build_object('success', TRUE, 'key', p_key);
END;
$$;

REVOKE ALL ON FUNCTION public.save_legal_page(TEXT, TEXT, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.save_legal_page(TEXT, TEXT, TEXT) TO authenticated, service_role;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 039: páginas legales aplicada' AS estado;

SELECT key, title FROM public.legal_pages ORDER BY key;

