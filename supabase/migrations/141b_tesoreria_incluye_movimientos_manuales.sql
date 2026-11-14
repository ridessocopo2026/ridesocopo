-- 141b - get_treasury_overview incluye los movimientos manuales de caja
--        (inyecciones, retiros y gastos) en en_caja y banco.
--        kind efectivo -> caja ; kind externo -> banco.

CREATE OR REPLACE FUNCTION public.get_treasury_overview(p_zone_id uuid DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  v_admin_id    UUID := auth.uid();
  v_caller_zone UUID;
  v_zone        UUID;
  v_role        TEXT;

  v_recargas          NUMERIC := 0;
  v_viajes_pm         NUMERIC := 0;
  v_cobros            NUMERIC := 0;
  v_pagos             NUMERIC := 0;
  v_banco_total       NUMERIC := 0;

  v_efectivo_in       NUMERIC := 0;
  v_efectivo_out      NUMERIC := 0;
  v_digital_in        NUMERIC := 0;
  v_digital_out       NUMERIC := 0;
  v_billetera_in      NUMERIC := 0;
  v_billetera_out     NUMERIC := 0;
  v_null_in           NUMERIC := 0;
  v_null_out          NUMERIC := 0;

  v_manual_ext_in     NUMERIC := 0;
  v_manual_ext_out    NUMERIC := 0;

  v_recargas_efectivo NUMERIC := 0;
  v_efectivo_cobrado  NUMERIC := 0;
  v_efectivo_pagado   NUMERIC := 0;
  v_en_caja           NUMERIC := 0;
  v_fondo             NUMERIC := 0;

  v_conductores_deben     NUMERIC := 0;
  v_app_debe_conductores  NUMERIC := 0;
  v_clientes_deben        NUMERIC := 0;
  v_app_debe_clientes     NUMERIC := 0;

  v_conductores_total        BIGINT := 0;
  v_conductores_con_deuda    BIGINT := 0;
  v_conductores_con_saldo    BIGINT := 0;
  v_conductores_sobre_limite BIGINT := 0;
BEGIN
  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  v_role := public.get_user_role(v_admin_id)::text;
  IF v_role IS NULL OR v_role NOT IN ('super_admin', 'encargado') THEN
    RAISE EXCEPTION 'No autorizado';
  END IF;

  v_caller_zone := public.caller_zone_id();
  IF v_role = 'encargado' AND v_caller_zone IS NULL THEN
    RAISE EXCEPTION 'Tu cuenta no tiene una ciudad asignada';
  END IF;
  v_zone := COALESCE(v_caller_zone, p_zone_id);

  WITH mov AS (
    SELECT 'recarga'::text AS origen,
           'in'::text AS direccion,
           t.amount_usd AS monto,
           public.payment_method_kind(t.payment_method) AS kind
    FROM transactions t
    JOIN profiles p ON p.id = t.user_id
    WHERE t.type = 'recarga'
      AND t.status IN ('aprobado', 'completado')
      AND p.role = 'cliente'
      AND (v_zone IS NULL OR p.zone_id = v_zone)

    UNION ALL

    SELECT 'viaje_pago_movil', 'in', r.final_fare_usd, 'externo'
    FROM rides r
    WHERE LOWER(r.payment_method) IN ('pago móvil', 'pago movil')
      AND r.proof_status = 'aprobado'
      AND (v_zone IS NULL OR r.origin_zone_id = v_zone)

    UNION ALL

    SELECT 'cobro_conductor', 'in', po.amount_usd,
           public.payment_method_kind(po.payment_method)
    FROM payouts po
    LEFT JOIN profiles p ON p.id = po.driver_id
    WHERE po.type = 'driver_pay_platform'
      AND po.status = 'aprobado'
      AND (v_zone IS NULL OR p.zone_id = v_zone)

    UNION ALL

    SELECT 'pago_conductor', 'out', po.amount_usd,
           public.payment_method_kind(po.payment_method)
    FROM payouts po
    LEFT JOIN profiles p ON p.id = po.driver_id
    WHERE po.type = 'platform_pay_driver'
      AND po.status IN ('aprobado', 'confirmado')
      AND (v_zone IS NULL OR p.zone_id = v_zone)

    UNION ALL

    SELECT 'manual'::text, tm.direction, tm.amount_usd, tm.kind
    FROM public.treasury_movements tm
    WHERE (v_zone IS NULL OR tm.zone_id = v_zone)
  )
  SELECT
    COALESCE(SUM(monto) FILTER (WHERE origen = 'recarga'), 0),
    COALESCE(SUM(monto) FILTER (WHERE origen = 'viaje_pago_movil'), 0),
    COALESCE(SUM(monto) FILTER (WHERE origen = 'cobro_conductor'), 0),
    COALESCE(SUM(monto) FILTER (WHERE origen = 'pago_conductor'), 0),
    COALESCE(SUM(monto) FILTER (WHERE direccion = 'in' AND kind = 'efectivo'), 0),
    COALESCE(SUM(monto) FILTER (WHERE direccion = 'out' AND kind = 'efectivo'), 0),
    COALESCE(SUM(monto) FILTER (WHERE direccion = 'in' AND kind = 'externo'), 0),
    COALESCE(SUM(monto) FILTER (WHERE direccion = 'out' AND kind = 'externo'), 0),
    COALESCE(SUM(monto) FILTER (WHERE direccion = 'in' AND kind = 'billetera'), 0),
    COALESCE(SUM(monto) FILTER (WHERE direccion = 'out' AND kind = 'billetera'), 0),
    COALESCE(SUM(monto) FILTER (WHERE direccion = 'in' AND kind IS NULL), 0),
    COALESCE(SUM(monto) FILTER (WHERE direccion = 'out' AND kind IS NULL), 0),
    COALESCE(SUM(monto) FILTER (WHERE origen = 'recarga' AND kind = 'efectivo'), 0),
    COALESCE(SUM(monto) FILTER (WHERE origen = 'cobro_conductor' AND kind = 'efectivo'), 0),
    COALESCE(SUM(monto) FILTER (WHERE origen = 'pago_conductor' AND kind = 'efectivo'), 0),
    COALESCE(SUM(monto) FILTER (WHERE origen = 'manual' AND kind = 'externo' AND direccion = 'in'), 0),
    COALESCE(SUM(monto) FILTER (WHERE origen = 'manual' AND kind = 'externo' AND direccion = 'out'), 0)
  INTO
    v_recargas, v_viajes_pm, v_cobros, v_pagos,
    v_efectivo_in, v_efectivo_out,
    v_digital_in, v_digital_out,
    v_billetera_in, v_billetera_out,
    v_null_in, v_null_out,
    v_recargas_efectivo, v_efectivo_cobrado, v_efectivo_pagado,
    v_manual_ext_in, v_manual_ext_out
  FROM mov;

  v_banco_total := v_recargas + v_viajes_pm + v_cobros - v_pagos
                   + v_manual_ext_in - v_manual_ext_out;
  v_en_caja := v_efectivo_in - v_efectivo_out;

  IF v_zone IS NULL THEN
    SELECT COALESCE(SUM(cash_opening_balance_usd), 0) INTO v_fondo FROM zones;
  ELSE
    SELECT COALESCE(cash_opening_balance_usd, 0) INTO v_fondo FROM zones WHERE id = v_zone;
  END IF;

  SELECT
    COALESCE(SUM(ABS(w.balance_usd)) FILTER (WHERE w.balance_usd < 0), 0),
    COALESCE(SUM(w.balance_usd) FILTER (WHERE w.balance_usd > 0), 0),
    COUNT(*),
    COUNT(*) FILTER (WHERE w.balance_usd < 0),
    COUNT(*) FILTER (WHERE w.balance_usd > 0),
    COUNT(*) FILTER (WHERE w.balance_usd < 0
                       AND w.balance_usd < -COALESCE(w.debt_limit_usd, 0))
  INTO v_conductores_deben, v_app_debe_conductores,
       v_conductores_total, v_conductores_con_deuda,
       v_conductores_con_saldo, v_conductores_sobre_limite
  FROM wallets w
  JOIN profiles pr ON pr.id = w.user_id
  WHERE pr.role = 'conductor'
    AND (v_zone IS NULL OR pr.zone_id = v_zone);

  SELECT
    COALESCE(SUM(ABS(w.balance_usd)) FILTER (WHERE w.balance_usd < 0), 0),
    COALESCE(SUM(w.balance_usd) FILTER (WHERE w.balance_usd > 0), 0)
  INTO v_clientes_deben, v_app_debe_clientes
  FROM wallets w
  JOIN profiles pr ON pr.id = w.user_id
  WHERE pr.role = 'cliente'
    AND (v_zone IS NULL OR pr.zone_id = v_zone);

  RETURN jsonb_build_object(
    'zona', jsonb_build_object(
      'zone_id', v_zone,
      'es_global', v_zone IS NULL,
      'forzada_por_rol', v_caller_zone IS NOT NULL
    ),
    'banco', jsonb_build_object(
      'recargas', ROUND(v_recargas, 2),
      'viajes_pago_movil', ROUND(v_viajes_pm, 2),
      'cobros_conductores', ROUND(v_cobros, 2),
      'pagos_conductores', ROUND(v_pagos, 2),
      'total', ROUND(v_banco_total, 2),
      'digital', jsonb_build_object(
        'ingresos', ROUND(v_digital_in, 2),
        'egresos', ROUND(v_digital_out, 2),
        'neto', ROUND(v_digital_in - v_digital_out, 2)
      ),
      'billetera', jsonb_build_object(
        'ingresos', ROUND(v_billetera_in, 2),
        'egresos', ROUND(v_billetera_out, 2),
        'neto', ROUND(v_billetera_in - v_billetera_out, 2)
      ),
      'sin_clasificar', jsonb_build_object(
        'ingresos', ROUND(v_null_in, 2),
        'egresos', ROUND(v_null_out, 2),
        'neto', ROUND(v_null_in - v_null_out, 2)
      )
    ),
    'efectivo', jsonb_build_object(
      'por_cobrar', ROUND(v_conductores_deben, 2),
      'recargas_efectivo', ROUND(v_recargas_efectivo, 2),
      'cobrado_conductores', ROUND(v_efectivo_cobrado, 2),
      'pagado_conductores', ROUND(v_efectivo_pagado, 2),
      'en_caja', ROUND(v_en_caja, 2),
      'fondo_inicial', ROUND(v_fondo, 2),
      'en_caja_total', ROUND(v_fondo + v_en_caja, 2)
    ),
    'deudas', jsonb_build_object(
      'conductores_deben', ROUND(v_conductores_deben, 2),
      'app_debe_conductores', ROUND(v_app_debe_conductores, 2),
      'neto_conductores', ROUND(v_app_debe_conductores - v_conductores_deben, 2),
      'clientes_deben', ROUND(v_clientes_deben, 2),
      'app_debe_clientes', ROUND(v_app_debe_clientes, 2),
      'neto_general', ROUND(
        v_banco_total - v_app_debe_conductores - v_app_debe_clientes
        + v_conductores_deben + v_clientes_deben, 2)
    ),
    'conteos', jsonb_build_object(
      'conductores_total', v_conductores_total,
      'conductores_con_deuda', v_conductores_con_deuda,
      'conductores_con_saldo', v_conductores_con_saldo,
      'conductores_sobre_limite', v_conductores_sobre_limite
    ),
    'cuadre_diferencia', ROUND(
      v_banco_total
      - (v_en_caja
         + (v_digital_in - v_digital_out)
         + (v_billetera_in - v_billetera_out)
         + (v_null_in - v_null_out)), 2)
  );
END;
$$;
