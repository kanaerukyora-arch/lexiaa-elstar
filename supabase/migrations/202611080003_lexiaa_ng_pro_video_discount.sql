-- Apply the LEXIAA N.G Pro discount to linked-wallet Video VIP and individual video purchases.
-- The original catalog prices remain unchanged; only the charged amount is discounted.
create or replace function public.ng_video_vip_purchase_linked(p_pin text,p_package text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_account public.ng_wallet_accounts%rowtype;
  v_list_amount bigint;
  v_amount bigint;
  v_discount integer := 0;
  v_duration interval;
  v_now timestamptz := now();
  v_start timestamptz;
  v_end timestamptz;
  v_balance bigint;
  v_login jsonb;
  v_is_pro boolean := false;
begin
  if v_uid is null then return jsonb_build_object('success',false,'message','Sesi LEXIAA tidak valid.'); end if;
  select * into v_account from public.ng_wallet_accounts where auth_user_id=v_uid and payments_linked_at is not null for update;
  if not found then return jsonb_build_object('success',false,'message','Wallet belum terhubung. Hubungkan Wallet terlebih dahulu.','wallet_not_linked',true); end if;
  v_login:=public.ng_wallet_login(v_account.phone,p_pin);
  if coalesce((v_login->>'success')::boolean,false) is not true then return v_login; end if;
  case p_package
    when '1h' then v_list_amount:=100000; v_duration:=interval '1 hour';
    when '10h' then v_list_amount:=200000; v_duration:=interval '10 hours';
    when '1d' then v_list_amount:=400000; v_duration:=interval '1 day';
    when '3d' then v_list_amount:=800000; v_duration:=interval '3 days';
    when '7d' then v_list_amount:=1500000; v_duration:=interval '7 days';
    when '30d' then v_list_amount:=3000000; v_duration:=interval '30 days';
    else return jsonb_build_object('success',false,'message','Paket VIP tidak valid.');
  end case;
  select exists(select 1 from public.ng_pro_memberships where user_id=v_uid and status='active' and starts_at<=v_now and ends_at>v_now) into v_is_pro;
  if v_is_pro then
    select coalesce(discount_percent,50) into v_discount from public.ng_pro_settings where id=true;
  end if;
  v_amount:=floor(v_list_amount*(100-v_discount)::numeric/100)::bigint;
  if v_account.balance<v_amount then return jsonb_build_object('success',false,'message','Saldo Wallet N.G tidak mencukupi.','balance',v_account.balance,'required',v_amount,'list_price',v_list_amount,'discount_percent',v_discount); end if;
  select greatest(v_now,ends_at) into v_start from public.ng_video_vip_subscriptions where user_id=v_uid for update;
  if v_start is null then v_start:=v_now; end if;
  v_end:=v_start+v_duration;
  update public.ng_wallet_accounts set balance=balance-v_amount,updated_at=v_now where auth_user_id=v_uid returning balance into v_balance;
  insert into public.ng_wallet_transactions(auth_user_id,description,amount,direction,status)
    values(v_uid,'Langganan Lexiaa N.G Video VIP ('||p_package||')',v_amount,'debit','success');
  insert into public.ng_video_vip_subscriptions(user_id,package_code,amount,starts_at,ends_at,updated_at)
    values(v_uid,p_package,v_amount,v_start,v_end,v_now)
    on conflict(user_id) do update set package_code=excluded.package_code,amount=excluded.amount,starts_at=excluded.starts_at,ends_at=excluded.ends_at,updated_at=v_now;
  return jsonb_build_object('success',true,'balance',v_balance,'amount',v_amount,'list_price',v_list_amount,'discount_percent',v_discount,'starts_at',v_start,'ends_at',v_end);
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
  if exists(select 1 from public.ng_video_purchases where user_id=v_uid and video_id=p_video_id) then
    return jsonb_build_object('success',true,'already_owned',true);
  end if;
  v_list_amount:=v_video.price;
  select exists(select 1 from public.ng_pro_memberships where user_id=v_uid and status='active' and starts_at<=v_now and ends_at>v_now) into v_is_pro;
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

revoke all on function public.ng_video_vip_purchase_linked(text,text) from public,anon;
revoke all on function public.ng_video_purchase_linked(text,uuid) from public,anon;
grant execute on function public.ng_video_vip_purchase_linked(text,text) to authenticated;
grant execute on function public.ng_video_purchase_linked(text,uuid) to authenticated;
