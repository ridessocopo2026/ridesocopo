-- ============================================================
-- BUNRIDER - Migración 078: DINERO Y MÉTRICAS POR CIUDAD
-- ------------------------------------------------------------
-- OBJETIVO
--   Que el ENCARGADO vea y opere SOLO el dinero y las métricas
--   de SU ciudad, y que el super_admin siga viendo todo igual.
--
-- QUÉ SE ARREGLA (verificado en vivo antes de esta migración)
--   1) get_admin_metrics  → permitía encargado y sumaba TODAS
--      las ciudades (montos globales).
--   2) get_wallet_overview → total_banco / deuda_wallets /
--      patrimonio_app de TODO el negocio.
--   3) get_payouts → todas las liquidaciones del sistema.
--   4) approve_payout / admin_pay_driver /
--      admin_pay_driver_manual / adjust_driver_debt → el
--      encargado podía MOVER DINERO de conductores de otra
--      ciudad (sin candado de zona).
--   5) driver_request_payout → notificaba a los encargados de
--      TODAS las ciudades.
--   6) RLS: encargado_view_drivers / _vehicles / _documents /
--      _wallets / _transactions / _rides no filtraban ciudad
--      (el nombre decía "de su zona" pero el código no).
--   7) storage.objects: encargado_view_all_storage daba SELECT
--      sobre TODOS los buckets (comprobantes de pago de
--      cualquier ciudad).
--
-- CRITERIO
--   - Regla única: el encargado NUNCA elige ciudad; el backend
--     la impone con caller_zone_id(). El super_admin puede
--     elegir con p_zone_id (NULL = todas).
--   - No se crean tablas, ni cron, ni edge functions, ni vistas
--     materializadas. Solo se reescriben funciones y políticas.
--   - Firmas: se añade p_zone_id con DEFAULT NULL al final, así
--     las llamadas actuales del front siguen funcionando.
--   - Con el super_admin (zona NULL) los resultados son
--     IDÉNTICOS a antes (regresión cero).
-- ============================================================

-- ============================================================
-- 0. BACKFILL (idempotente, sin IDs hardcodeados)
-- ------------------------------------------------------------
-- Sin esto, apretar el candado de ciudad escondería datos
-- legítimos que quedaron sin zona (verificado: 32 viajes, todos
-- dentro del polígono de Socopó).
-- ============================================================

-- 0.1 Viajes sin ciudad → se detecta por el polígono del origen
UPDATE public.rides r
SET origin_zone_id = z.id
FROM public.zones z
WHERE r.origin_zone_id IS NULL
  AND z.zone_type = 'cobertura_general'
  AND z.is_active = TRUE
  AND z.polygon IS NOT NULL
  AND ST_Contains(z.polygon, ST_SetSRID(ST_MakePoint(r.origin_lng, r.origin_lat), 4326));

-- 0.2 Conductores sin ciudad → ciudad donde más viajó
UPDATE public.profiles p
SET zone_id = sub.zone_id
FROM (
  SELECT DISTINCT ON (r.driver_id) r.driver_id AS user_id, r.origin_zone_id AS zone_id
  FROM public.rides r
  WHERE r.driver_id IS NOT NULL
    AND r.origin_zone_id IS NOT NULL
  GROUP BY r.driver_id, r.origin_zone_id
  ORDER BY r.driver_id, COUNT(*) DESC
) sub
WHERE p.id = sub.user_id
  AND p.zone_id IS NULL
  AND p.role = 'conductor';

-- 0.3 Clientes sin ciudad → ciudad donde más viajó como cliente
UPDATE public.profiles p
SET zone_id = sub.zone_id
FROM (
  SELECT DISTINCT ON (r.client_id) r.client_id AS user_id, r.origin_zone_id AS zone_id
  FROM public.rides r
  WHERE r.client_id IS NOT NULL
    AND r.origin_zone_id IS NOT NULL
  GROUP BY r.client_id, r.origin_zone_id
  ORDER BY r.client_id, COUNT(*) DESC
) sub
WHERE p.id = sub.user_id
  AND p.zone_id IS NULL
  AND p.role = 'cliente';

-- 0.4 Índice para los filtros de ciudad en liquidaciones
CREATE INDEX IF NOT EXISTS idx_payouts_status_created
  ON public.payouts(type, status, created_at DESC);

-- ============================================================
-- 1. HELPER: ¿este usuario pertenece a la ciudad del que llama?
-- ------------------------------------------------------------
-- SECURITY DEFINER para poder usarse dentro de políticas RLS
-- (wallets, transactions, vehicles, driver_documents, storage)
-- SIN provocar recursión de RLS ni depender de profiles.
-- Devuelve FALSE para el super_admin (él usa otras políticas).
-- ============================================================
CREATE OR REPLACE FUNCTION public.user_in_caller_zone(p_user_id TEXT)
RETURNS BOOLEAN
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT CASE
    WHEN public.caller_zone_id() IS NULL THEN FALSE
    WHEN p_user_id IS NULL
      OR p_user_id !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
      THEN FALSE
    ELSE EXISTS (
      SELECT 1
      FROM public.profiles p
      WHERE p.id = p_user_id::uuid
        AND p.zone_id = public.caller_zone_id()
    )
  END;
$$;

-- NO revocar de anon: las políticas RLS se evalúan también sin
-- sesión y una función sin permiso rompería la consulta.
GRANT EXECUTE ON FUNCTION public.user_in_caller_zone(text) TO anon, authenticated, service_role;

-- ============================================================
-- 2. GET_ADMIN_METRICS: candado de ciudad
--    p_zone_id = NULL -> global (super_admin)
--    Encargado: se fuerza SU ciudad (p_zone_id se ignora)
-- ------------------------------------------------------------
-- OJO: al añadir p_zone_id la firma cambia → hay que borrar la
-- versión anterior. Si no, quedaría viva una sobrecarga SIN
-- candado de ciudad (el agujero seguiría abierto).
-- ============================================================
DROP FUNCTION IF EXISTS public.get_admin_metrics(timestamptz, timestamptz, uuid, uuid, text);

CREATE OR REPLACE FUNCTION public.get_admin_metrics(
  p_fecha_inicio TIMESTAMPTZ DEFAULT NOW() - INTERVAL '30 days',
  p_fecha_fin TIMESTAMPTZ DEFAULT NOW(),
  p_conductor_id UUID DEFAULT NULL,
  p_cliente_id UUID DEFAULT NULL,
  p_metodo TEXT DEFAULT NULL,
  p_zone_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_caller_zone UUID;
  v_zone UUID;
  v_comisiones NUMERIC := 0;
  v_total INTEGER := 0;
  v_completadas INTEGER := 0;
  v_canceladas INTEGER := 0;
  v_incidentes INTEGER := 0;
  v_tarifa_avg NUMERIC := 0;
  v_deuda_app NUMERIC := 0;
  v_deuda_drivers NUMERIC := 0;
  v_efectivo NUMERIC := 0;
  v_recargas NUMERIC := 0;
  v_pagos_conductores NUMERIC := 0;
  v_pagos_plataforma NUMERIC := 0;

  -- Dinero REAL que entra/sale
  v_tarifas_digitales NUMERIC := 0;
  v_penalizaciones NUMERIC := 0;
  v_reembolsos_clientes NUMERIC := 0;
  v_compensaciones_conductores NUMERIC := 0;

  -- Comisiones de viajes en EFECTIVO (ya descontadas de wallets)
  v_comisiones_efectivo NUMERIC := 0;

  v_ingresos_reales NUMERIC := 0;

  v_por_metodo JSONB;
  v_por_conductor JSONB;
  v_por_cliente JSONB;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- 🔒 El encargado solo su ciudad; el super_admin puede elegir (NULL = todas)
  v_caller_zone := public.caller_zone_id();
  v_zone := COALESCE(v_caller_zone, p_zone_id);

  -- ============================================================
  -- RESUMEN DE VIAJES (con filtros)
  -- comisiones SOLO de completados
  -- ============================================================
  SELECT
    COALESCE(SUM(r.commission_usd) FILTER (WHERE r.status = 'completada'), 0),
    COUNT(*),
    COUNT(*) FILTER (WHERE r.status = 'completada'),
    COUNT(*) FILTER (WHERE r.status = 'cancelada'),
    COUNT(*) FILTER (WHERE r.status = 'incidente'),
    COALESCE(AVG(CASE WHEN r.status = 'completada' THEN r.final_fare_usd END), 0)
  INTO v_comisiones, v_total, v_completadas, v_canceladas, v_incidentes, v_tarifa_avg
  FROM rides r
  WHERE r.created_at >= p_fecha_inicio
    AND r.created_at <= p_fecha_fin
    AND (v_zone IS NULL OR r.origin_zone_id = v_zone)
    AND (p_conductor_id IS NULL OR r.driver_id = p_conductor_id)
    AND (p_cliente_id IS NULL OR r.client_id = p_cliente_id)
    AND (p_metodo IS NULL OR LOWER(r.payment_method) = LOWER(p_metodo));

  -- ============================================================
  -- TARIFAS DE VIAJES DIGITALES que ENTRARON a la plataforma
  -- (Pago Móvil y Billetera: el cliente pagó, el dinero está en la app)
  -- ============================================================
  SELECT COALESCE(SUM(r.final_fare_usd), 0)
  INTO v_tarifas_digitales
  FROM rides r
  WHERE r.created_at >= p_fecha_inicio
    AND r.created_at <= p_fecha_fin
    AND LOWER(r.payment_method) IN ('pago móvil', 'pago movil', 'billetera')
    AND r.status IN ('completada', 'cancelada')
    AND (v_zone IS NULL OR r.origin_zone_id = v_zone)
    AND (p_conductor_id IS NULL OR r.driver_id = p_conductor_id)
    AND (p_cliente_id IS NULL OR r.client_id = p_cliente_id)
    AND (p_metodo IS NULL OR LOWER(r.payment_method) = LOWER(p_metodo));

  -- ============================================================
  -- COMISIONES DE VIAJES EN EFECTIVO
  -- Estas comisiones YA fueron descontadas de la wallet del conductor
  -- por settle_ride_earnings → el dinero YA está en la plataforma
  -- ============================================================
  SELECT COALESCE(SUM(de.commission_usd), 0)
  INTO v_comisiones_efectivo
  FROM driver_earnings de
  JOIN rides r ON r.id = de.ride_id
  WHERE LOWER(r.payment_method) = 'efectivo'
    AND r.status = 'completada'
    AND r.created_at >= p_fecha_inicio
    AND r.created_at <= p_fecha_fin
    AND (v_zone IS NULL OR r.origin_zone_id = v_zone)
    AND (p_conductor_id IS NULL OR r.driver_id = p_conductor_id)
    AND (p_cliente_id IS NULL OR r.client_id = p_cliente_id)
    AND (p_metodo IS NULL OR LOWER(r.payment_method) = LOWER(p_metodo));

  -- ============================================================
  -- SUMAR PENALIZACIONES / REEMBOLSOS / COMPENSACIONES
  -- desde resolution_details de ride_incidents resueltos
  -- ============================================================
  SELECT
    COALESCE(SUM((ri.resolution_details->>'penalty')::numeric), 0),
    COALESCE(SUM((ri.resolution_details->>'refund_client')::numeric), 0),
    COALESCE(SUM((ri.resolution_details->>'compensate_driver')::numeric), 0)
  INTO v_penalizaciones, v_reembolsos_clientes, v_compensaciones_conductores
  FROM ride_incidents ri
  JOIN rides r ON r.id = ri.ride_id
  WHERE ri.status = 'resuelto'
    AND ri.resolved_at >= p_fecha_inicio
    AND ri.resolved_at <= p_fecha_fin
    AND (v_zone IS NULL OR r.origin_zone_id = v_zone)
    AND (p_conductor_id IS NULL OR r.driver_id = p_conductor_id)
    AND (p_cliente_id IS NULL OR r.client_id = p_cliente_id)
    AND (p_metodo IS NULL OR LOWER(r.payment_method) = LOWER(p_metodo));

  -- ============================================================
  -- ESTADO ACTUAL DE BILLETERAS DE CONDUCTORES
  -- (el encargado solo las de los conductores de su ciudad)
  -- ============================================================
  SELECT
    COALESCE(SUM(w.balance_usd) FILTER (WHERE w.balance_usd > 0), 0),
    COALESCE(SUM(ABS(w.balance_usd)) FILTER (WHERE w.balance_usd < 0), 0)
  INTO v_deuda_app, v_deuda_drivers
  FROM wallets w
  JOIN profiles pr ON pr.id = w.user_id
  WHERE pr.role = 'conductor'
    AND (v_zone IS NULL OR pr.zone_id = v_zone);

  -- ============================================================
  -- EFECTIVO COBRADO POR CONDUCTORES (con filtros)
  -- ============================================================
  SELECT COALESCE(SUM(de.cash_received_usd), 0)
  INTO v_efectivo
  FROM driver_earnings de
  JOIN rides r ON r.id = de.ride_id
  WHERE r.created_at >= p_fecha_inicio
    AND r.created_at <= p_fecha_fin
    AND (v_zone IS NULL OR r.origin_zone_id = v_zone)
    AND (p_conductor_id IS NULL OR r.driver_id = p_conductor_id)
    AND (p_cliente_id IS NULL OR r.client_id = p_cliente_id)
    AND (p_metodo IS NULL OR LOWER(r.payment_method) = LOWER(p_metodo));

  -- ============================================================
  -- RECARGAS APROBADAS (por ciudad del dueño de la billetera)
  -- ============================================================
  SELECT COALESCE(SUM(t.amount_usd), 0)
  INTO v_recargas
  FROM transactions t
  LEFT JOIN profiles pr ON pr.id = t.user_id
  WHERE t.type = 'recarga'
    AND t.status IN ('aprobado', 'completado')
    AND t.created_at >= p_fecha_inicio
    AND t.created_at <= p_fecha_fin
    AND (v_zone IS NULL OR pr.zone_id = v_zone);

  -- ============================================================
  -- PAGOS DE CONDUCTORES → PLATAFORMA (aprobados)
  -- ============================================================
  SELECT COALESCE(SUM(po.amount_usd), 0)
  INTO v_pagos_conductores
  FROM payouts po
  LEFT JOIN profiles pr ON pr.id = po.driver_id
  WHERE po.type = 'driver_pay_platform'
    AND po.status = 'aprobado'
    AND po.created_at >= p_fecha_inicio
    AND po.created_at <= p_fecha_fin
    AND (v_zone IS NULL OR pr.zone_id = v_zone);

  -- ============================================================
  -- PAGOS DE PLATAFORMA → CONDUCTORES (aprobados/confirmados)
  -- ============================================================
  SELECT COALESCE(SUM(po.amount_usd), 0)
  INTO v_pagos_plataforma
  FROM payouts po
  LEFT JOIN profiles pr ON pr.id = po.driver_id
  WHERE po.type = 'platform_pay_driver'
    AND po.status IN ('aprobado', 'confirmado')
    AND po.created_at >= p_fecha_inicio
    AND po.created_at <= p_fecha_fin
    AND (v_zone IS NULL OR pr.zone_id = v_zone);

  -- ============================================================
  -- CÁLCULO REAL DE INGRESOS DE LA PLATAFORMA
  -- ============================================================
  v_ingresos_reales :=
    v_tarifas_digitales        -- dinero que entró por viajes digitales
    + v_comisiones_efectivo    -- comisiones de efectivo YA descontadas de wallets
    + v_penalizaciones         -- dinero retenido al culpable
    + v_recargas               -- clientes que recargaron billetera
    + v_pagos_conductores      -- comisiones que SÍ pagaron los conductores
    - v_reembolsos_clientes    -- devoluciones al cliente
    - v_compensaciones_conductores -- compensaciones pagadas por incidentes
    - v_pagos_plataforma;      -- retiros pagados a conductores

  -- ============================================================
  -- DESGLOSE POR MÉTODO DE PAGO
  -- ============================================================
  SELECT COALESCE(jsonb_agg(t), '[]'::jsonb)
  INTO v_por_metodo
  FROM (
    SELECT
      LOWER(r.payment_method) AS metodo,
      COUNT(*) AS viajes,
      COUNT(*) FILTER (WHERE r.status = 'completada') AS completados,
      COALESCE(SUM(r.final_fare_usd), 0) AS tarifa_total,
      COALESCE(SUM(r.commission_usd) FILTER (WHERE r.status = 'completada'), 0) AS comision_total
    FROM rides r
    WHERE r.created_at >= p_fecha_inicio
      AND r.created_at <= p_fecha_fin
      AND (v_zone IS NULL OR r.origin_zone_id = v_zone)
      AND (p_conductor_id IS NULL OR r.driver_id = p_conductor_id)
      AND (p_cliente_id IS NULL OR r.client_id = p_cliente_id)
      AND (p_metodo IS NULL OR LOWER(r.payment_method) = LOWER(p_metodo))
    GROUP BY LOWER(r.payment_method)
    ORDER BY comision_total DESC
  ) t;

  -- ============================================================
  -- RANKING POR CONDUCTOR
  -- ============================================================
  SELECT COALESCE(jsonb_agg(t), '[]'::jsonb)
  INTO v_por_conductor
  FROM (
    SELECT
      pr.full_name AS conductor,
      COUNT(*) AS viajes,
      COUNT(*) FILTER (WHERE r.status = 'completada') AS completados,
      COALESCE(SUM(de.cash_received_usd), 0) AS ganado_efectivo,
      COALESCE(SUM(de.app_credit_usd), 0) AS ganado_app,
      COALESCE(SUM(r.commission_usd) FILTER (WHERE r.status = 'completada'), 0) AS comisiones
    FROM rides r
    LEFT JOIN profiles pr ON pr.id = r.driver_id
    LEFT JOIN driver_earnings de ON de.ride_id = r.id
    WHERE r.created_at >= p_fecha_inicio
      AND r.created_at <= p_fecha_fin
      AND (v_zone IS NULL OR r.origin_zone_id = v_zone)
      AND (p_conductor_id IS NULL OR r.driver_id = p_conductor_id)
      AND (p_cliente_id IS NULL OR r.client_id = p_cliente_id)
      AND (p_metodo IS NULL OR LOWER(r.payment_method) = LOWER(p_metodo))
      AND r.driver_id IS NOT NULL
    GROUP BY pr.full_name
    ORDER BY completados DESC
    LIMIT 20
  ) t;

  -- ============================================================
  -- RANKING POR CLIENTE
  -- ============================================================
  SELECT COALESCE(jsonb_agg(t), '[]'::jsonb)
  INTO v_por_cliente
  FROM (
    SELECT
      pr.full_name AS cliente,
      COUNT(*) AS viajes,
      COUNT(*) FILTER (WHERE r.status = 'completada') AS completados,
      COALESCE(SUM(r.final_fare_usd), 0) AS total_gastado
    FROM rides r
    LEFT JOIN profiles pr ON pr.id = r.client_id
    WHERE r.created_at >= p_fecha_inicio
      AND r.created_at <= p_fecha_fin
      AND (v_zone IS NULL OR r.origin_zone_id = v_zone)
      AND (p_conductor_id IS NULL OR r.driver_id = p_conductor_id)
      AND (p_cliente_id IS NULL OR r.client_id = p_cliente_id)
      AND (p_metodo IS NULL OR LOWER(r.payment_method) = LOWER(p_metodo))
    GROUP BY pr.full_name
    ORDER BY total_gastado DESC
    LIMIT 20
  ) t;

  -- ============================================================
  -- RESPUESTA COMPLETA (mismas claves que antes + zona aplicada)
  -- ============================================================
  RETURN jsonb_build_object(
    'zona', jsonb_build_object(
      'zone_id', v_zone,
      'es_global', (v_zone IS NULL),
      'forzada_por_rol', (v_caller_zone IS NOT NULL)
    ),
    'resumen', jsonb_build_object(
      'ingresos_plataforma', v_ingresos_reales,
      'comisiones_pendientes', v_comisiones,
      'comisiones_efectivo', v_comisiones_efectivo,
      'deuda_con_conductores', v_deuda_app,
      'deuda_conductores', v_deuda_drivers,
      'efectivo_conductores', v_efectivo,
      'total_recargas', v_recargas,
      'tarifas_digitales', v_tarifas_digitales,
      'penalizaciones', v_penalizaciones,
      'reembolsos_clientes', v_reembolsos_clientes,
      'compensaciones_conductores', v_compensaciones_conductores,
      'pagos_conductores_plataforma', v_pagos_conductores,
      'pagos_plataforma_conductores', v_pagos_plataforma,
      'total_viajes', v_total,
      'viajes_completados', v_completadas,
      'viajes_cancelados', v_canceladas,
      'viajes_incidentes', v_incidentes,
      'tarifa_promedio', v_tarifa_avg
    ),
    'por_metodo', v_por_metodo,
    'por_conductor', v_por_conductor,
    'por_cliente', v_por_cliente
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_admin_metrics(timestamptz, timestamptz, uuid, uuid, text, uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_admin_metrics(timestamptz, timestamptz, uuid, uuid, text, uuid) FROM anon;

-- ============================================================
-- 3. GET_WALLET_OVERVIEW: candado de ciudad
--    ("dinero en banco" del negocio en su conjunto para el
--     super_admin; para el encargado, SOLO su ciudad)
-- ------------------------------------------------------------
-- También cambia la firma → se borra la versión sin argumentos.
-- ============================================================
DROP FUNCTION IF EXISTS public.get_wallet_overview();

CREATE OR REPLACE FUNCTION public.get_wallet_overview(p_zone_id UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_caller_zone UUID;
  v_zone UUID;
  v_total_banco NUMERIC := 0;
  v_deuda_wallets NUMERIC := 0;
  v_patrimonio_app NUMERIC := 0;
  v_recargas NUMERIC := 0;
  v_pagos_pago_movil NUMERIC := 0;
  v_pagos_conductores_plataforma NUMERIC := 0;
  v_pagos_plataforma_conductores NUMERIC := 0;
BEGIN
  -- Solo admin/encargado
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  -- 🔒 El encargado solo su ciudad; el super_admin puede elegir (NULL = todas)
  v_caller_zone := public.caller_zone_id();
  v_zone := COALESCE(v_caller_zone, p_zone_id);

  -- ============================================================
  -- ENTRADAS FÍSICAS (dinero que llegó al banco del admin)
  -- ============================================================

  -- 1a. Recargas aprobadas de clientes (por ciudad del cliente)
  SELECT COALESCE(SUM(t.amount_usd), 0)
  INTO v_recargas
  FROM transactions t
  JOIN profiles p ON p.id = t.user_id
  WHERE t.type = 'recarga'
    AND t.status IN ('aprobado', 'completado')
    AND p.role = 'cliente'
    AND (v_zone IS NULL OR p.zone_id = v_zone);

  -- 1b. Viajes pagados con Pago Móvil (comprobante aprobado)
  --     El dinero físico llegó al banco del admin cuando se aprobó
  SELECT COALESCE(SUM(r.final_fare_usd), 0)
  INTO v_pagos_pago_movil
  FROM rides r
  WHERE LOWER(r.payment_method) IN ('pago móvil', 'pago movil')
    AND r.proof_status = 'aprobado'
    AND (v_zone IS NULL OR r.origin_zone_id = v_zone);

  -- 1c. Conductores que pagaron a la plataforma (payout aprobado)
  SELECT COALESCE(SUM(po.amount_usd), 0)
  INTO v_pagos_conductores_plataforma
  FROM payouts po
  LEFT JOIN profiles p ON p.id = po.driver_id
  WHERE po.type = 'driver_pay_platform'
    AND po.status = 'aprobado'
    AND (v_zone IS NULL OR p.zone_id = v_zone);

  -- ============================================================
  -- SALIDAS FÍSICAS (dinero que salió del banco del admin)
  -- ============================================================

  -- 1d. Pagos de plataforma → conductores (retiros/liquidaciones)
  SELECT COALESCE(SUM(po.amount_usd), 0)
  INTO v_pagos_plataforma_conductores
  FROM payouts po
  LEFT JOIN profiles p ON p.id = po.driver_id
  WHERE po.type = 'platform_pay_driver'
    AND po.status IN ('aprobado', 'confirmado')
    AND (v_zone IS NULL OR p.zone_id = v_zone);

  -- ============================================================
  -- CÁLCULO TOTAL EN BANCO
  -- ============================================================
  v_total_banco := v_recargas
                 + v_pagos_pago_movil
                 + v_pagos_conductores_plataforma
                 - v_pagos_plataforma_conductores;

  -- ============================================================
  -- DEUDA A WALLETS (lo que la app debe a clientes y conductores)
  -- Solo saldos positivos (si hay negativos = deuda a la app)
  -- ============================================================
  SELECT COALESCE(SUM(w.balance_usd), 0)
  INTO v_deuda_wallets
  FROM wallets w
  JOIN profiles p ON p.id = w.user_id
  WHERE w.balance_usd > 0
    AND (v_zone IS NULL OR p.zone_id = v_zone);

  -- ============================================================
  -- PATRIMONIO (lo que realmente le pertenece a la app)
  -- Para el encargado es un valor DE SU CIUDAD; la UI muestra el
  -- global solo al super_admin.
  -- ============================================================
  v_patrimonio_app := ROUND(v_total_banco - v_deuda_wallets, 2);

  RETURN jsonb_build_object(
    'zona', jsonb_build_object(
      'zone_id', v_zone,
      'es_global', (v_zone IS NULL),
      'forzada_por_rol', (v_caller_zone IS NOT NULL)
    ),
    'total_banco', ROUND(v_total_banco, 2),
    'deuda_wallets', ROUND(v_deuda_wallets, 2),
    'patrimonio_app', v_patrimonio_app,
    'detalle', jsonb_build_object(
      'recargas_clientes', ROUND(v_recargas, 2),
      'pagos_pago_movil_viajes', ROUND(v_pagos_pago_movil, 2),
      'pagos_conductores_plataforma', ROUND(v_pagos_conductores_plataforma, 2),
      'pagos_plataforma_conductores', ROUND(v_pagos_plataforma_conductores, 2)
    )
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_wallet_overview(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_wallet_overview(uuid) FROM anon;

-- ============================================================
-- 4. GET_PAYOUTS: el encargado solo ve liquidaciones de
--    conductores de SU ciudad (el super_admin ve todas)
-- ============================================================
CREATE OR REPLACE FUNCTION public.get_payouts()
RETURNS SETOF payouts
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_user_id UUID := auth.uid();
  v_role TEXT;
  v_zone UUID;
BEGIN
  IF v_user_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT role::text INTO v_role FROM profiles WHERE id = v_user_id;
  v_zone := public.caller_zone_id();

  IF v_role = 'super_admin' THEN
    RETURN QUERY SELECT * FROM payouts ORDER BY created_at DESC LIMIT 50;

  ELSIF v_role = 'encargado' THEN
    -- 🔒 Encargado sin ciudad asignada: no ve nada
    IF v_zone IS NULL THEN
      RETURN;
    END IF;
    RETURN QUERY
      SELECT po.*
      FROM payouts po
      JOIN profiles dr ON dr.id = po.driver_id
      WHERE dr.zone_id = v_zone
      ORDER BY po.created_at DESC
      LIMIT 50;

  ELSE
    RETURN QUERY SELECT * FROM payouts WHERE driver_id = v_user_id ORDER BY created_at DESC LIMIT 50;
  END IF;
END;
$$;

GRANT EXECUTE ON FUNCTION public.get_payouts() TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.get_payouts() FROM anon;

-- ============================================================
-- 5. APPROVE_PAYOUT: candado de ciudad + rate limit + auditoría
--    (mueve dinero: aprobar/rechazar pagos entre conductor y
--     plataforma, en ambas direcciones)
-- ============================================================
CREATE OR REPLACE FUNCTION public.approve_payout(
  p_payout_id UUID,
  p_approve BOOLEAN
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_payout RECORD;
  v_wallet RECORD;
  v_driver_zone UUID;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('approve_payout', 30);

  SELECT * INTO v_payout FROM payouts WHERE id = p_payout_id FOR UPDATE;
  IF v_payout.id IS NULL THEN
    RAISE EXCEPTION 'Pago no encontrado';
  END IF;

  -- 🔒 Encargado: solo conductores de SU ciudad
  SELECT zone_id INTO v_driver_zone FROM profiles WHERE id = v_payout.driver_id;
  IF public.get_user_role(v_admin_id) = 'encargado'
     AND (public.caller_zone_id() IS NULL
          OR COALESCE(v_driver_zone, '00000000-0000-0000-0000-000000000000'::uuid) != public.caller_zone_id()) THEN
    RAISE EXCEPTION 'No autorizado para pagos de otra ciudad';
  END IF;

  IF v_payout.status != 'pendiente' THEN
    RAISE EXCEPTION 'El pago ya fue procesado';
  END IF;

  IF v_payout.type = 'driver_pay_platform' AND p_approve THEN
    -- El conductor pagó a la plataforma → acreditar a su balance (reduce deuda)
    SELECT * INTO v_wallet FROM wallets WHERE user_id = v_payout.driver_id;
    UPDATE wallets
    SET balance_usd = balance_usd + v_payout.amount_usd,
        updated_at = NOW()
    WHERE user_id = v_payout.driver_id;

    UPDATE payouts SET status = 'aprobado', reviewed_by = v_admin_id, updated_at = NOW()
    WHERE id = p_payout_id;

    INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description)
    VALUES (v_wallet.id, v_payout.driver_id, 'credito', v_payout.amount_usd, 'completado',
            'Pago del conductor a la plataforma (aprobado)');

    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (v_payout.driver_id, 'Pago aprobado',
            'Tu pago de ' || v_payout.amount_usd || '$ fue aprobado. Tu deuda fue actualizada.',
            'payout_approved', jsonb_build_object('payout_id', p_payout_id));

  ELSIF v_payout.type = 'driver_pay_platform' AND NOT p_approve THEN
    UPDATE payouts SET status = 'rechazado', reviewed_by = v_admin_id, updated_at = NOW()
    WHERE id = p_payout_id;

    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (v_payout.driver_id, 'Pago rechazado',
            'Tu pago de ' || v_payout.amount_usd || '$ fue rechazado. Verifica el comprobante.',
            'payout_rejected', jsonb_build_object('payout_id', p_payout_id));

  ELSIF v_payout.type = 'platform_pay_driver' AND p_approve THEN
    -- La app paga al conductor: aprobar NO descuenta aún.
    -- El conductor debe confirmar recepción (segunda confirmación).
    UPDATE payouts SET status = 'aprobado', reviewed_by = v_admin_id, updated_at = NOW()
    WHERE id = p_payout_id;

    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (v_payout.driver_id, 'Pago aprobado — Confirma recibo',
            CONCAT('La plataforma te pagó $', v_payout.amount_usd, '. Confirma que lo recibiste.'),
            'payout_approved_confirm',
            jsonb_build_object('payout_id', p_payout_id, 'url', '/conductor/billetera'));

  ELSIF v_payout.type = 'platform_pay_driver' AND NOT p_approve THEN
    -- Admin rechazó la solicitud de retiro del conductor
    UPDATE payouts SET status = 'rechazado', reviewed_by = v_admin_id, updated_at = NOW()
    WHERE id = p_payout_id;

    INSERT INTO notifications (user_id, title, body, type, data)
    VALUES (v_payout.driver_id, 'Solicitud de retiro rechazada',
            CONCAT('Tu solicitud de retiro de $', v_payout.amount_usd, ' fue rechazada. Contacta a la plataforma.'),
            'payout_rejected', jsonb_build_object('payout_id', p_payout_id));
  END IF;

  -- 📝 Auditoría (mueve dinero)
  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_admin_id, 'APPROVE_PAYOUT', 'payout', p_payout_id,
          jsonb_build_object('approved', p_approve, 'type', v_payout.type,
                             'amount_usd', v_payout.amount_usd,
                             'driver_id', v_payout.driver_id,
                             'zone_id', v_driver_zone));

  RETURN jsonb_build_object('success', TRUE, 'payout_id', p_payout_id, 'status',
    (SELECT status FROM payouts WHERE id = p_payout_id));
END;
$$;

GRANT EXECUTE ON FUNCTION public.approve_payout(uuid, boolean) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.approve_payout(uuid, boolean) FROM anon;

-- ============================================================
-- 6. ADMIN_PAY_DRIVER: candado de ciudad + rate limit + auditoría
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_pay_driver(
  p_driver_id UUID,
  p_amount_usd NUMERIC,
  p_description TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_payout_id UUID;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('admin_pay_driver', 20);

  IF p_amount_usd <= 0 THEN
    RAISE EXCEPTION 'Monto inválido';
  END IF;

  -- 🔒 Encargado: solo conductores de SU ciudad
  IF public.get_user_role(v_admin_id) = 'encargado'
     AND (public.caller_zone_id() IS NULL
          OR NOT EXISTS (SELECT 1 FROM profiles p
                         WHERE p.id = p_driver_id AND p.zone_id = public.caller_zone_id())) THEN
    RAISE EXCEPTION 'No autorizado para pagar a conductores de otra ciudad';
  END IF;

  INSERT INTO payouts (driver_id, amount_usd, type, status, description, created_by)
  VALUES (p_driver_id, p_amount_usd, 'platform_pay_driver', 'pendiente',
          COALESCE(p_description, 'Pago de la plataforma al conductor'), v_admin_id)
  RETURNING id INTO v_payout_id;

  -- NOTIFICAR al conductor
  PERFORM public.notify_user(
    p_driver_id,
    'Pago disponible',
    'La plataforma te pagará ' || p_amount_usd || '$. Confirma cuando lo recibas.',
    'payout_platform_pay',
    jsonb_build_object('payout_id', v_payout_id, 'url', '/conductor/billetera')
  );

  -- 📝 Auditoría (mueve dinero)
  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_admin_id, 'ADMIN_PAY_DRIVER', 'payout', v_payout_id,
          jsonb_build_object('driver_id', p_driver_id, 'amount_usd', p_amount_usd,
                             'description', p_description));

  RETURN v_payout_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_pay_driver(uuid, numeric, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.admin_pay_driver(uuid, numeric, text) FROM anon;

-- ============================================================
-- 7. ADMIN_PAY_DRIVER_MANUAL: candado de ciudad + auditoría
-- ============================================================
CREATE OR REPLACE FUNCTION public.admin_pay_driver_manual(
  p_driver_id UUID,
  p_amount_usd NUMERIC,
  p_description TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_wallet RECORD;
  v_payout_id UUID;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('admin_pay_driver_manual', 20);

  IF p_amount_usd <= 0 THEN
    RAISE EXCEPTION 'Monto inválido';
  END IF;

  -- 🔒 Encargado: solo conductores de SU ciudad
  IF public.get_user_role(v_admin_id) = 'encargado'
     AND (public.caller_zone_id() IS NULL
          OR NOT EXISTS (SELECT 1 FROM profiles p
                         WHERE p.id = p_driver_id AND p.zone_id = public.caller_zone_id())) THEN
    RAISE EXCEPTION 'No autorizado para pagar a conductores de otra ciudad';
  END IF;

  -- Validar saldo disponible del conductor
  SELECT * INTO v_wallet FROM wallets WHERE user_id = p_driver_id;
  IF v_wallet.id IS NULL THEN
    RAISE EXCEPTION 'Billetera del conductor no encontrada';
  END IF;

  IF v_wallet.balance_usd < p_amount_usd THEN
    RAISE EXCEPTION USING MESSAGE = format('El conductor solo tiene disponible: $%s', v_wallet.balance_usd);
  END IF;

  -- Crear payout (la app paga al conductor)
  INSERT INTO payouts (driver_id, amount_usd, type, status, description, created_by)
  VALUES (p_driver_id, p_amount_usd, 'platform_pay_driver', 'pendiente',
          COALESCE(p_description, 'Pago de la plataforma al conductor'), v_admin_id)
  RETURNING id INTO v_payout_id;

  -- Notificar al conductor
  INSERT INTO notifications (user_id, title, body, type, data)
  VALUES (p_driver_id, 'Pago disponible',
          CONCAT('La plataforma te pagará $', p_amount_usd, '. Confirma cuando lo recibas.'),
          'payout_platform_pay',
          jsonb_build_object('payout_id', v_payout_id, 'url', '/conductor/billetera'));

  -- 📝 Auditoría (mueve dinero)
  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_admin_id, 'ADMIN_PAY_DRIVER_MANUAL', 'payout', v_payout_id,
          jsonb_build_object('driver_id', p_driver_id, 'amount_usd', p_amount_usd,
                             'description', p_description));

  RETURN v_payout_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.admin_pay_driver_manual(uuid, numeric, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.admin_pay_driver_manual(uuid, numeric, text) FROM anon;

-- ============================================================
-- 8. ADJUST_DRIVER_DEBT: candado de ciudad + auditoría
--    (ajustar deuda = mover dinero de la billetera)
-- ============================================================
CREATE OR REPLACE FUNCTION public.adjust_driver_debt(
  p_driver_id UUID,
  p_amount_usd NUMERIC,
  p_description TEXT DEFAULT 'Ajuste de deuda'
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id UUID := auth.uid();
  v_wallet RECORD;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  PERFORM public.guard_rate_limit('adjust_driver_debt', 20);

  -- 🔒 Encargado: solo conductores de SU ciudad
  IF public.get_user_role(v_admin_id) = 'encargado'
     AND (public.caller_zone_id() IS NULL
          OR NOT EXISTS (SELECT 1 FROM profiles p
                         WHERE p.id = p_driver_id AND p.zone_id = public.caller_zone_id())) THEN
    RAISE EXCEPTION 'No autorizado para ajustar deuda de otra ciudad';
  END IF;

  SELECT * INTO v_wallet FROM wallets WHERE user_id = p_driver_id;

  UPDATE wallets
  SET balance_usd = balance_usd + p_amount_usd,
      updated_at = NOW()
  WHERE user_id = p_driver_id;

  INSERT INTO transactions (wallet_id, user_id, type, amount_usd, status, description, reviewed_by)
  VALUES (v_wallet.id, p_driver_id, 'ajuste', p_amount_usd, 'completado', p_description, v_admin_id);

  -- NOTIFICAR al conductor
  PERFORM public.notify_user(
    p_driver_id,
    'Ajuste de deuda',
    'Tu billetera fue ajustada: $' || p_amount_usd || '. Motivo: ' || p_description,
    'debt_adjustment',
    jsonb_build_object('amount', p_amount_usd, 'url', '/conductor/billetera')
  );

  -- 📝 Auditoría (mueve dinero)
  INSERT INTO audit_logs (user_id, action, entity_type, entity_id, details)
  VALUES (v_admin_id, 'ADJUST_DRIVER_DEBT', 'profile', p_driver_id,
          jsonb_build_object('amount_usd', p_amount_usd, 'description', p_description));

  RETURN jsonb_build_object(
    'success', TRUE,
    'driver_id', p_driver_id,
    'nuevo_balance', v_wallet.balance_usd + p_amount_usd
  );
END;
$$;

GRANT EXECUTE ON FUNCTION public.adjust_driver_debt(uuid, numeric, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.adjust_driver_debt(uuid, numeric, text) FROM anon;

-- ============================================================
-- 9. DRIVER_REQUEST_PAYOUT: notificar SOLO al super_admin y al
--    encargado de la ciudad del conductor (antes avisaba a los
--    encargados de TODAS las ciudades)
-- ============================================================
CREATE OR REPLACE FUNCTION public.driver_request_payout(
  p_amount_usd NUMERIC,
  p_description TEXT DEFAULT NULL
)
RETURNS UUID
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_driver_id UUID := auth.uid();
  v_wallet RECORD;
  v_profile RECORD;
  v_payout_id UUID;
BEGIN
  IF v_driver_id IS NULL THEN
    RAISE EXCEPTION 'No autenticado';
  END IF;

  SELECT * INTO v_profile FROM profiles WHERE id = v_driver_id;
  IF v_profile.role != 'conductor' OR v_profile.driver_status != 'aprobado' THEN
    RAISE EXCEPTION 'No autorizado o conductor no aprobado';
  END IF;

  IF p_amount_usd <= 0 THEN
    RAISE EXCEPTION 'Monto inválido';
  END IF;

  -- Validar saldo disponible
  SELECT * INTO v_wallet FROM wallets WHERE user_id = v_driver_id;
  IF v_wallet.id IS NULL THEN
    RAISE EXCEPTION 'Billetera no encontrada';
  END IF;

  IF v_wallet.balance_usd < p_amount_usd THEN
    RAISE EXCEPTION USING MESSAGE = format('Saldo insuficiente. Disponible: $%s, solicitado: $%s', v_wallet.balance_usd, p_amount_usd);
  END IF;

  -- Crear payout (la app paga al conductor)
  INSERT INTO payouts (driver_id, amount_usd, type, status, description, created_by)
  VALUES (v_driver_id, p_amount_usd, 'platform_pay_driver', 'pendiente',
          COALESCE(p_description, 'Retiro solicitado por el conductor'), v_driver_id)
  RETURNING id INTO v_payout_id;

  -- Notificar solo a quien puede resolverlo: super_admin + encargado de SU ciudad
  INSERT INTO notifications (user_id, title, body, type, data)
  SELECT id, 'Solicitud de retiro',
         CONCAT(v_profile.full_name, ' solicita retiro de $', p_amount_usd),
         'payout_request',
         jsonb_build_object('payout_id', v_payout_id, 'url', '/encargado/liquidaciones')
  FROM profiles
  WHERE role = 'super_admin'
     OR (role = 'encargado' AND (v_profile.zone_id IS NULL OR zone_id = v_profile.zone_id));

  RETURN v_payout_id;
END;
$$;

GRANT EXECUTE ON FUNCTION public.driver_request_payout(numeric, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION public.driver_request_payout(numeric, text) FROM anon;

-- ============================================================
-- 10. RLS: el encargado SOLO ve su ciudad
-- ------------------------------------------------------------
-- Antes: "encargado_view_*" sin filtro de zona (el nombre decía
-- "de su zona" pero el código no filtraba nada). Ahora todas
-- llevan el candado. El super_admin no cambia (sus políticas son
-- aparte).
-- ============================================================

-- 10.1 PROFILES: solo pasajeros y conductores de su ciudad
DROP POLICY IF EXISTS "encargado_view_drivers" ON public.profiles;
CREATE POLICY "encargado_view_drivers" ON public.profiles
  FOR SELECT USING (
    public.get_user_role((SELECT auth.uid())) = 'encargado'
    AND role IN ('conductor', 'cliente')
    AND zone_id = public.caller_zone_id()
  );

-- 10.2 VEHICLES: solo vehículos de conductores de su ciudad
DROP POLICY IF EXISTS "encargado_view_vehicles" ON public.vehicles;
CREATE POLICY "encargado_view_vehicles" ON public.vehicles
  FOR SELECT USING (
    public.get_user_role((SELECT auth.uid())) = 'encargado'
    AND public.user_in_caller_zone(driver_id::text)
  );

-- 10.3 DRIVER_DOCUMENTS: solo documentos de conductores de su ciudad
DROP POLICY IF EXISTS "encargado_view_documents" ON public.driver_documents;
CREATE POLICY "encargado_view_documents" ON public.driver_documents
  FOR SELECT USING (
    public.get_user_role((SELECT auth.uid())) = 'encargado'
    AND public.user_in_caller_zone(driver_id::text)
  );

-- 10.4 WALLETS: solo billeteras de usuarios de su ciudad
DROP POLICY IF EXISTS "encargado_view_wallets" ON public.wallets;
CREATE POLICY "encargado_view_wallets" ON public.wallets
  FOR SELECT USING (
    public.get_user_role((SELECT auth.uid())) = 'encargado'
    AND public.user_in_caller_zone(user_id::text)
  );

-- 10.5 TRANSACTIONS: solo movimientos de usuarios de su ciudad
DROP POLICY IF EXISTS "encargado_view_transactions" ON public.transactions;
CREATE POLICY "encargado_view_transactions" ON public.transactions
  FOR SELECT USING (
    public.get_user_role((SELECT auth.uid())) = 'encargado'
    AND public.user_in_caller_zone(user_id::text)
  );

-- 10.6 RIDES: solo viajes que se originaron en su ciudad
DROP POLICY IF EXISTS "encargado_view_rides" ON public.rides;
CREATE POLICY "encargado_view_rides" ON public.rides
  FOR SELECT USING (
    public.get_user_role((SELECT auth.uid())) = 'encargado'
    AND origin_zone_id = public.caller_zone_id()
  );

-- ============================================================
-- 11. STORAGE: el encargado solo ve archivos de su ciudad
-- ------------------------------------------------------------
-- Antes existía "encargado_view_all_storage": SELECT sobre TODOS
-- los objetos de TODOS los buckets (podía firmar y ver
-- comprobantes de pago de cualquier ciudad).
-- Se reemplaza por políticas por bucket + ciudad, manteniendo lo
-- que el panel del encargado necesita: fotos de perfil de sus
-- conductores, documentos y comprobantes de pago de sus usuarios.
-- ============================================================
DROP POLICY IF EXISTS "encargado_view_all_storage" ON storage.objects;

-- 11.1 Comprobantes de pago (bucket privado 'payments')
DROP POLICY IF EXISTS "admins_view_payments" ON storage.objects;
CREATE POLICY "admins_view_payments" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'payments'
    AND (
      public.get_user_role((SELECT auth.uid())) = 'super_admin'
      OR (
        public.get_user_role((SELECT auth.uid())) = 'encargado'
        AND public.user_in_caller_zone((storage.foldername(name))[1])
      )
    )
  );

-- 11.2 Documentos del conductor (bucket 'documents')
DROP POLICY IF EXISTS "encargado_view_documents" ON storage.objects;
CREATE POLICY "encargado_view_documents" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'documents'
    AND public.get_user_role((SELECT auth.uid())) = 'encargado'
    AND public.user_in_caller_zone((storage.foldername(name))[1])
  );

-- 11.3 Fotos de perfil (bucket 'avatars'): el panel del encargado
--      muestra la foto de sus conductores y pasajeros
DROP POLICY IF EXISTS "encargado_view_avatars" ON storage.objects;
CREATE POLICY "encargado_view_avatars" ON storage.objects
  FOR SELECT USING (
    bucket_id = 'avatars'
    AND public.get_user_role((SELECT auth.uid())) = 'encargado'
    AND public.user_in_caller_zone((storage.foldername(name))[1])
  );

-- ============================================================
-- 12. VERIFICACIÓN
-- ============================================================
SELECT 'datos sin ciudad: viajes' AS comprobacion, COUNT(*)::text AS valor
FROM public.rides WHERE origin_zone_id IS NULL
UNION ALL
SELECT 'datos sin ciudad: pasajeros y conductores', COUNT(*)::text
FROM public.profiles WHERE zone_id IS NULL AND role IN ('cliente', 'conductor')
UNION ALL
SELECT 'RPC de dinero/admin con candado de ciudad (esperado 8)',
       COUNT(*)::text
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND p.proname IN ('get_admin_metrics', 'get_wallet_overview', 'get_payouts',
                    'approve_payout', 'admin_pay_driver', 'admin_pay_driver_manual',
                    'adjust_driver_debt', 'driver_request_payout')
  AND pg_get_functiondef(p.oid) LIKE '%caller_zone_id%'
UNION ALL
SELECT 'sobrecargas SIN candado de get_admin_metrics / get_wallet_overview (esperado 0)',
       COUNT(*)::text
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'public'
  AND ((p.proname = 'get_admin_metrics'
        AND pg_get_function_identity_arguments(p.oid) = 'timestamp with time zone, timestamp with time zone, uuid, uuid, text')
    OR (p.proname = 'get_wallet_overview'
        AND pg_get_function_identity_arguments(p.oid) = ''))
UNION ALL
SELECT 'politicas del encargado con candado de ciudad (esperado 10)',
       COUNT(*)::text
FROM pg_policy p
JOIN pg_class c ON c.oid = p.polrelid
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE ((n.nspname = 'public' AND c.relname IN ('profiles', 'rides', 'wallets', 'transactions', 'vehicles', 'driver_documents'))
    OR (n.nspname = 'storage' AND c.relname = 'objects'))
  AND p.polname IN ('encargado_view_drivers', 'encargado_view_rides', 'encargado_view_wallets',
                    'encargado_view_transactions', 'encargado_view_vehicles', 'encargado_view_documents',
                    'encargado_view_avatars', 'admins_view_payments')
  AND (pg_get_expr(p.polqual, p.polrelid) LIKE '%caller_zone_id%'
    OR pg_get_expr(p.polqual, p.polrelid) LIKE '%user_in_caller_zone%')
UNION ALL
SELECT 'politica encargado_view_all_storage eliminada (esperado 0)',
       COUNT(*)::text
FROM pg_policy p JOIN pg_class c ON c.oid = p.polrelid
WHERE c.relname = 'objects' AND p.polname = 'encargado_view_all_storage';

SELECT '✅ Migración 078: dinero y métricas por ciudad listos' AS estado;
