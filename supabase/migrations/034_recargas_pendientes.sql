-- RECARGAS PENDIENTES
CREATE OR REPLACE FUNCTION public.get_pending_recharges()
RETURNS TABLE (
  transaction_id UUID, user_id UUID, user_name TEXT, user_email TEXT,
  amount_usd NUMERIC, proof_url TEXT, status TEXT, created_at TIMESTAMPTZ
) LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT t.id, t.user_id, COALESCE(p.full_name,'Usuario'), COALESCE(p.email,''),
         t.amount_usd, t.proof_url, t.status::TEXT, t.created_at
  FROM transactions t LEFT JOIN profiles p ON p.id = t.user_id
  WHERE t.type='recarga' AND t.status='pendiente' AND t.proof_url IS NOT NULL
  ORDER BY t.created_at ASC;
$$;
GRANT EXECUTE ON FUNCTION public.get_pending_recharges TO anon, authenticated, service_role;

-- APROBAR RECARGA
CREATE OR REPLACE FUNCTION public.approve_recharge(p_transaction_id UUID, p_approve BOOLEAN)
RETURNS JSONB LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v_admin_id UUID := auth.uid(); v_txn RECORD; v_wallet_id UUID;
BEGIN
  IF public.get_user_role(v_admin_id) NOT IN ('super_admin','encargado') THEN RAISE EXCEPTION 'No autorizado'; END IF;
  SELECT * INTO v_txn FROM transactions WHERE id = p_transaction_id;
  IF v_txn.id IS NULL THEN RAISE EXCEPTION 'Transaccion no encontrada'; END IF;
  IF v_txn.status != 'pendiente' THEN RAISE EXCEPTION 'La recarga ya fue procesada'; END IF;
  IF p_approve THEN
    SELECT id INTO v_wallet_id FROM wallets WHERE user_id = v_txn.user_id;
    IF v_wallet_id IS NULL THEN
      INSERT INTO wallets (user_id, balance_usd, debt_limit_usd) VALUES (v_txn.user_id,0,0) RETURNING id INTO v_wallet_id;
    END IF;
    UPDATE wallets SET balance_usd = balance_usd + v_txn.amount_usd, updated_at = NOW() WHERE id = v_wallet_id;
    UPDATE transactions SET status='completado', reviewed_by=v_admin_id, reviewed_at=NOW() WHERE id=p_transaction_id;
    INSERT INTO notifications (user_id,title,body,type,data) VALUES
      (v_txn.user_id,'Recarga aprobada','Tu recarga de $'||v_txn.amount_usd::TEXT||' fue aprobada.','recharge_approved',jsonb_build_object('transaction_id',p_transaction_id));
  ELSE
    UPDATE transactions SET status='rechazado', reviewed_by=v_admin_id, reviewed_at=NOW() WHERE id=p_transaction_id;
    INSERT INTO notifications (user_id,title,body,type,data) VALUES
      (v_txn.user_id,'Recarga rechazada','Tu recarga de $'||v_txn.amount_usd::TEXT||' fue rechazada.','recharge_rejected',jsonb_build_object('transaction_id',p_transaction_id));
  END IF;
  RETURN jsonb_build_object('success',TRUE,'transaction_id',p_transaction_id,'approved',p_approve);
END; $$;
GRANT EXECUTE ON FUNCTION public.approve_recharge TO anon, authenticated, service_role;
