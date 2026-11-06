-- Admin-only wallet credit. Invoke only from the authenticated lexiaa-admin Edge Function using service_role.
create or replace function public.ng_wallet_admin_credit(
  p_auth_user_id uuid,
  p_amount bigint,
  p_description text default 'Top Up oleh Admin'
) returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_balance bigint;
  v_tx uuid;
begin
  if p_auth_user_id is null then
    return jsonb_build_object('success',false,'message','Penerima tidak valid.');
  end if;
  if p_amount is null or p_amount < 1 or p_amount > 1000000000 then
    return jsonb_build_object('success',false,'message','Nominal harus antara Rp1 dan Rp1.000.000.000.');
  end if;
  update public.ng_wallet_accounts
    set balance = balance + p_amount, updated_at = now()
    where auth_user_id = p_auth_user_id
    returning balance into v_balance;
  if not found then
    return jsonb_build_object('success',false,'message','Akun Saldo LEXIAA N.G tidak ditemukan.');
  end if;
  insert into public.ng_wallet_transactions(auth_user_id,description,amount,direction,status)
    values(p_auth_user_id,left(coalesce(nullif(trim(p_description),''),'Top Up oleh Admin'),120),p_amount,'credit','success')
    returning id into v_tx;
  return jsonb_build_object('success',true,'balance',v_balance,'transaction_id',v_tx);
end;
$$;
revoke all on function public.ng_wallet_admin_credit(uuid,bigint,text) from public, anon, authenticated;
grant execute on function public.ng_wallet_admin_credit(uuid,bigint,text) to service_role;
