-- Enforce LEXIAA N.G Pro-only content inside the SECURITY DEFINER purchase RPCs.
-- This closes the direct-RPC bypass; Edge Function checks alone are not sufficient.

create or replace function public.lexiaa_novel_buy(p_novel_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_novel public.lexiaa_novels%rowtype;
  v_balance bigint;
  v_purchase_id uuid;
  v_list_amount bigint;
  v_amount bigint;
  v_discount integer := 0;
  v_now timestamptz := now();
  v_is_pro boolean := false;
begin
  if v_uid is null then
    return jsonb_build_object('success', false, 'message', 'Silakan masuk ke akun LEXIAA terlebih dahulu.');
  end if;

  select * into v_novel
  from public.lexiaa_novels
  where id = p_novel_id and is_published = true;

  if not found then
    return jsonb_build_object('success', false, 'message', 'Novel tidak tersedia.');
  end if;

  select exists(
    select 1 from public.ng_pro_memberships
    where user_id = v_uid and status = 'active' and starts_at <= v_now and ends_at > v_now
  ) into v_is_pro;

  if v_novel.is_pro_only and not v_is_pro then
    return jsonb_build_object('success', false, 'message', 'Novel ini khusus anggota LEXIAA N.G Pro aktif.');
  end if;

  select balance into v_balance
  from public.ng_wallet_accounts
  where auth_user_id = v_uid
  for update;

  if not found then
    return jsonb_build_object('success', false, 'message', 'Akun Wallet N.G. belum terdaftar pada akun ini.');
  end if;

  if exists (
    select 1 from public.lexiaa_novel_purchases
    where user_id = v_uid and novel_id = p_novel_id
  ) then
    return jsonb_build_object('success', true, 'already_owned', true, 'message', 'Novel sudah dimiliki.', 'balance', v_balance);
  end if;

  v_list_amount := v_novel.price;
  if v_is_pro then
    select coalesce(discount_percent, 50) into v_discount
    from public.ng_pro_settings where id = true;
  end if;

  v_discount := greatest(0, least(100, coalesce(v_discount, 50)));
  v_amount := floor(v_list_amount * (100 - v_discount)::numeric / 100)::bigint;

  if v_balance < v_amount then
    return jsonb_build_object('success', false, 'message', 'Saldo Wallet N.G. tidak mencukupi.', 'balance', v_balance, 'price', v_amount, 'list_price', v_list_amount, 'discount_percent', v_discount);
  end if;

  update public.ng_wallet_accounts
  set balance = balance - v_amount, updated_at = v_now
  where auth_user_id = v_uid
  returning balance into v_balance;

  insert into public.lexiaa_novel_purchases(user_id, novel_id, amount)
  values (v_uid, p_novel_id, v_amount)
  returning id into v_purchase_id;

  insert into public.ng_wallet_transactions(auth_user_id, description, amount, direction, status)
  values (v_uid, 'Pembelian novel: ' || left(v_novel.title, 90), v_amount, 'debit', 'success');

  return jsonb_build_object('success', true, 'already_owned', false, 'purchase_id', v_purchase_id, 'balance', v_balance, 'amount', v_amount, 'list_price', v_list_amount, 'discount_percent', v_discount);
exception
  when unique_violation then
    select balance into v_balance from public.ng_wallet_accounts where auth_user_id = auth.uid();
    return jsonb_build_object('success', true, 'already_owned', true, 'message', 'Novel sudah dimiliki.', 'balance', v_balance);
end;
$$;

create or replace function public.ng_video_purchase_linked(p_pin text,p_video_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_account public.ng_wallet_accounts%rowtype;
  v_video public.ng_videos%rowtype;
  v_list_amount bigint;
  v_amount bigint;
  v_discount integer := 0;
  v_balance bigint;
  v_login jsonb;
  v_now timestamptz := now();
  v_is_pro boolean := false;
begin
  if v_uid is null then return jsonb_build_object('success',false,'message','Sesi LEXIAA tidak valid.'); end if;
  select * into v_account from public.ng_wallet_accounts where auth_user_id=v_uid and payments_linked_at is not null for update;
  if not found then return jsonb_build_object('success',false,'message','Wallet belum terhubung. Hubungkan Wallet terlebih dahulu.','wallet_not_linked',true); end if;
  v_login:=public.ng_wallet_login(v_account.phone,p_pin);
  if coalesce((v_login->>'success')::boolean,false) is not true then return v_login; end if;
  if not exists(select 1 from public.ng_video_vip_subscriptions where user_id=v_uid and ends_at>v_now) then
    return jsonb_build_object('success',false,'message','Langganan VIP kamu sudah berakhir. Aktifkan VIP kembali.');
  end if;
  select * into v_video from public.ng_videos where id=p_video_id and is_published=true;
  if not found or v_video.price<=0 then return jsonb_build_object('success',false,'message','Video berbayar tidak ditemukan.'); end if;

  select exists(select 1 from public.ng_pro_memberships where user_id=v_uid and status='active' and starts_at<=v_now and ends_at>v_now) into v_is_pro;
  if v_video.is_pro_only and not v_is_pro then
    return jsonb_build_object('success',false,'message','Video ini khusus anggota LEXIAA N.G Pro aktif.');
  end if;

  if exists(select 1 from public.ng_video_purchases where user_id=v_uid and video_id=p_video_id) then
    return jsonb_build_object('success',true,'already_owned',true);
  end if;
  v_list_amount:=v_video.price;
  if v_is_pro then
    select coalesce(discount_percent,50) into v_discount from public.ng_pro_settings where id=true;
  end if;
  v_amount:=floor(v_list_amount*(100-v_discount)::numeric/100)::bigint;
  if v_account.balance<v_amount then
    return jsonb_build_object('success',false,'message','Saldo Wallet N.G tidak mencukupi.','balance',v_account.balance,'required',v_amount,'list_price',v_list_amount,'discount_percent',v_discount);
  end if;
  update public.ng_wallet_accounts set balance=balance-v_amount,updated_at=v_now
    where auth_user_id=v_uid returning balance into v_balance;
  insert into public.ng_wallet_transactions(auth_user_id,description,amount,direction,status)
    values(v_uid,'Pembelian video: '||v_video.title,v_amount,'debit','success');
  insert into public.ng_video_purchases(user_id,video_id,amount)
    values(v_uid,p_video_id,v_amount) on conflict(user_id,video_id) do nothing;
  return jsonb_build_object('success',true,'balance',v_balance,'amount',v_amount,'list_price',v_list_amount,'discount_percent',v_discount);
end;
$$;
