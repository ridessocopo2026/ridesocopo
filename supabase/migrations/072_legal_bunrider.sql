-- ============================================================
-- BUNRIDER - Migración 072: PÁGINAS LEGALES DE BUNRIDER
-- ------------------------------------------------------------
-- 1. Corrige el texto heredado: cambia "RiderFlasshi" por
--    "BunRider" en las páginas legales SIN borrar las ediciones
--    que ya haya hecho el Super Administrador (solo renombra la
--    marca dentro del texto que ya existe).
-- 2. Renombra la clave 'sobre_riderflash' -> 'sobre_bunrider'
--    (la URL pública pasa a /sobre-bunrider; la anterior queda
--    como redirección 301 en el borde para no perder SEO).
-- 3. Asegura que las 3 páginas existan y amplía save_legal_page
--    para aceptar la clave nueva (y la heredada).
-- Idempotente: se puede ejecutar varias veces sin duplicar nada.
-- ============================================================

-- ============================================================
-- 1. MARCA EN EL CONTENIDO EXISTENTE
-- ============================================================
UPDATE public.legal_pages
SET title = REPLACE(title, 'RiderFlasshi', 'BunRider'),
    content = REPLACE(content, 'RiderFlasshi', 'BunRider'),
    updated_at = NOW()
WHERE title LIKE '%RiderFlasshi%' OR content LIKE '%RiderFlasshi%';

-- ============================================================
-- 2. CLAVE DE LA PÁGINA "SOBRE ..."
-- ============================================================
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM public.legal_pages WHERE key = 'sobre_riderflash')
     AND NOT EXISTS (SELECT 1 FROM public.legal_pages WHERE key = 'sobre_bunrider') THEN
    UPDATE public.legal_pages SET key = 'sobre_bunrider' WHERE key = 'sobre_riderflash';
  END IF;
END $$;

-- ============================================================
-- 3. CONTENIDO POR DEFECTO (solo si falta alguna página)
-- ============================================================
INSERT INTO public.legal_pages (key, title, content) VALUES
('politicas_privacidad', 'Políticas de Privacidad',
E'En BunRider respetamos tu privacidad. Esta política explica qué información recopilamos y cómo la usamos.\n\n1. INFORMACIÓN QUE RECOPILAMOS\n- Datos de cuenta: nombre, correo electrónico y teléfono.\n- Datos de viaje: ubicaciones de origen y destino, historial de viajes y calificaciones.\n- Datos de pago: saldo de la billetera, comprobantes y referencia de pagos.\n\n2. USO DE LA INFORMACIÓN\nUsamos tus datos para: conectar pasajeros con conductores y gestionar los viajes, procesar pagos y liquidaciones, enviar notificaciones sobre tus viajes y la app, y mejorar nuestro servicio.\n\n3. COMPARTIR INFORMACIÓN\nTu ubicación e información de viaje se comparten únicamente con el conductor asignado para prestar el servicio. No vendemos tus datos a terceros.\n\n4. ALMACENAMIENTO Y SEGURIDAD\nTu información se almacena de forma segura con controles de acceso. Solo personal autorizado accede a los datos necesarios para operar la plataforma.\n\n5. TUS DERECHOS\nPuedes solicitar acceso, corrección o eliminación de tus datos personales. Conservamos la información el tiempo necesario para fines legales y operativos.\n\n6. CONTACTO\nSi tienes preguntas sobre esta política, contáctanos a través de los canales oficiales de BunRider.'),
('terminos_condiciones', 'Términos y Condiciones de Uso',
E'Al usar la aplicación BunRider aceptas estos términos.\n\n1. EL SERVICIO\nBunRider conecta pasajeros con conductores de moto, carro y camioneta en Socopó, Barinas, Venezuela. El pago puede hacerse en efectivo, con saldo de la billetera o mediante pago móvil.\n\n2. REGISTRO Y CUENTA\nDebes proporcionar información veraz al registrarte y eres responsable de mantener la confidencialidad de tu cuenta. La app puede suspender cuentas que infrinjan estas normas.\n\n3. PASAJEROS\nAl solicitar un viaje confirmas que el destino y los datos son correctos. Los montos son estimados y pueden incluir recargos por sector. Las cancelaciones pueden generar cargos según la política vigente.\n\n4. CONDUCTORES\nPara ser conductor debes estar aprobado y contar con un vehículo apto. Debes cumplir las leyes de tránsito y brindar un servicio seguro. La comisión se descuenta conforme a la configuración vigente.\n\n5. PAGOS Y BILLETERA\nEl saldo de la billetera es un crédito digital de la plataforma. Las recargas quedan pendientes hasta ser aprobadas con su comprobante. Los retiros siguen un flujo de doble confirmación.\n\n6. RESPONSABILIDAD\nLa plataforma no es responsable por daños fuera de su control. Estos términos pueden actualizarse; la versión vigente estará siempre disponible en esta página.\n\n7. CONTACTO\nPara dudas, contáctanos por los canales oficiales de BunRider.'),
('sobre_bunrider', 'Sobre BunRider',
E'BunRider es la aplicación de transporte de pasajeros de Socopó, Barinas, Venezuela.\n\nConectamos de forma rápida y segura a pasajeros con conductores de motos, carros y camionetas de la localidad, con precios claros y varias formas de pago: efectivo, billetera digital y pago móvil.\n\n¿CÓMO FUNCIONA?\n1. Indica a dónde quieres ir y dónde te recogemos.\n2. Elige el tipo de vehículo y la forma de pago.\n3. Un conductor aprobado acepta tu viaje.\n4. Sigue tu viaje en tiempo real y paga al final.\n\nBunRider está hecha para Socopó y su gente: transporte accesible, con tecnología simple y apoyo local. Un proyecto independiente en crecimiento que trabaja cada día para mejorar el servicio.\n\n¡Gracias por viajar con BunRider!')
ON CONFLICT (key) DO NOTHING;

-- Si por algún motivo quedaron las dos claves, se conserva la nueva
-- y se elimina la heredada para no duplicar contenido.
DELETE FROM public.legal_pages
WHERE key = 'sobre_riderflash'
  AND EXISTS (SELECT 1 FROM public.legal_pages WHERE key = 'sobre_bunrider');

-- ============================================================
-- 4. RPC: guardar página legal (solo super_admin)
--    Acepta 'sobre_bunrider' y la heredada 'sobre_riderflash'.
-- ============================================================
CREATE OR REPLACE FUNCTION public.save_legal_page(p_key TEXT, p_title TEXT, p_content TEXT)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_key TEXT := p_key;
BEGIN
  IF public.get_user_role(v_admin_id) != 'super_admin' THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- Compatibilidad: la página "Sobre BunRider" antes se llamaba
  -- sobre_riderflash. Con cualquiera de las dos claves, el contenido
  -- se guarda siempre en la clave nueva.
  IF v_key = 'sobre_riderflash' THEN
    v_key := 'sobre_bunrider';
  END IF;

  IF v_key NOT IN ('politicas_privacidad', 'terminos_condiciones', 'sobre_bunrider') THEN
    RAISE EXCEPTION 'Clave no válida';
  END IF;

  IF p_title IS NULL OR trim(p_title) = '' OR p_content IS NULL OR trim(p_content) = '' THEN
    RAISE EXCEPTION 'El título y el contenido son obligatorios';
  END IF;

  UPDATE public.legal_pages
  SET title = p_title, content = p_content, updated_at = NOW(), updated_by = v_admin_id
  WHERE key = v_key;

  IF NOT FOUND THEN
    INSERT INTO public.legal_pages (key, title, content, updated_by)
    VALUES (v_key, p_title, p_content, v_admin_id);
  END IF;

  DELETE FROM public.legal_pages WHERE key = 'sobre_riderflash';

  INSERT INTO public.audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_admin_id, 'SAVE_LEGAL_PAGE', 'legal_pages', v_key,
          jsonb_build_object('title', p_title));

  RETURN jsonb_build_object('success', TRUE, 'key', v_key);
END;
$$;

REVOKE ALL ON FUNCTION public.save_legal_page(TEXT, TEXT, TEXT) FROM anon;
GRANT EXECUTE ON FUNCTION public.save_legal_page(TEXT, TEXT, TEXT) TO authenticated, service_role;

-- ============================================================
-- VERIFICACIÓN
-- ============================================================
SELECT '✅ Migración 072: páginas legales de BunRider aplicada' AS estado;

SELECT key, title, updated_at FROM public.legal_pages ORDER BY key;

SELECT count(*) AS menciones_riderflasshi
FROM public.legal_pages
WHERE title LIKE '%RiderFlasshi%' OR content LIKE '%RiderFlasshi%';