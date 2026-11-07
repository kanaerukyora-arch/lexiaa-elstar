-- LEXIAA N.G Pro: Wallet N.G destination for daily rewards
-- Run this migration after 202611080001_lexiaa_ng_pro.sql.

alter table public.ng_pro_applications
  add column if not exists wallet_phone text;

drop function if exists public.ng_pro_submit_application(text,date,text,text);
create or replace function public.ng_pro_submit_application(
  p_full_name text,p_birth_date date,p_email text,p_whatsapp text,p_wallet_phone text
) returns jsonb
language plpgsql security definer
set search_path=public,pg_temp
as $$
declare
  v_uid uuid:=auth.uid();
  v_id uuid;
  v_existing public.ng_pro_memberships%rowtype;
  v_wallet_phone text:=regexp_replace(coalesce(p_wallet_phone,''),'[[:space:]-]','','g');
begin
  if v_uid is null then
    return jsonb_build_object('success',false,'message','Silakan masuk kembali.');
  end if;
  if char_length(btrim(coalesce(p_full_name,''))) not between 2 and 120
    or p_birth_date is null or p_birth_date>current_date or p_birth_date<date '1900-01-01'
    or coalesce(p_email,'') !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$'
    or char_length(coalesce(p_whatsapp,'')) not between 8 and 20
    or v_wallet_phone !~ '^\+[1-9][0-9]{7,14}$'
  then
    return jsonb_build_object('success',false,'message','Periksa nama, tanggal lahir, email, WhatsApp, dan nomor Wallet N.G.');
  end if;

  if not exists(
    select 1 from public.ng_wallet_accounts
    where auth_user_id=v_uid and phone=v_wallet_phone
  ) then
    return jsonb_build_object('success',false,'message','Nomor Wallet N.G tidak cocok dengan Wallet yang terhubung ke akun ini.');
  end if;

  select * into v_existing from public.ng_pro_memberships
  where user_id=v_uid and status='active' and ends_at>now();
  if found then
    return jsonb_build_object('success',false,'message','Akun ini sudah menjadi LEXIAA N.G Pro.');
  end if;
  if exists(select 1 from public.ng_pro_applications where user_id=v_uid and status='pending') then
    return jsonb_build_object('success',false,'message','Pengajuan kamu masih menunggu keputusan admin.');
  end if;

  insert into public.ng_pro_applications(user_id,full_name,birth_date,email,whatsapp,wallet_phone)
  values(v_uid,btrim(p_full_name),p_birth_date,lower(btrim(p_email)),btrim(p_whatsapp),v_wallet_phone)
  returning id into v_id;
  return jsonb_build_object('success',true,'application_id',v_id,'message','Pengajuan berhasil dikirim. Tunggu pemberitahuan dari admin.');
end
$$;

create or replace function public.ng_pro_claim_daily_bonus()
returns jsonb
language plpgsql security definer
set search_path=public,pg_temp
as $$
declare
  v_uid uuid:=auth.uid();
  v_day date:=(now() at time zone 'Asia/Jakarta')::date;
  v_member public.ng_pro_memberships%rowtype;
  v_amount bigint;
  v_balance bigint;
  v_wallet_phone text;
begin
  if v_uid is null then
    return jsonb_build_object('success',false,'message','Sesi tidak valid.');
  end if;

  select * into v_member from public.ng_pro_memberships
  where user_id=v_uid and status='active' and starts_at<=now() and ends_at>now();
  if not found then
    return jsonb_build_object('success',false,'message','Keanggotaan Pro tidak aktif.');
  end if;

  select wallet_phone into v_wallet_phone
  from public.ng_pro_applications
  where user_id=v_uid and status='approved'
  order by reviewed_at desc nulls last,created_at desc
  limit 1;
  if v_wallet_phone is null then
    return jsonb_build_object('success',false,'message','Nomor Wallet N.G tujuan bonus belum tercatat.');
  end if;

  select daily_bonus into v_amount from public.ng_pro_settings where id=true;
  insert into public.ng_pro_daily_rewards(user_id,reward_date,amount)
  values(v_uid,v_day,v_amount)
  on conflict(user_id,reward_date) do nothing;
  if not found then
    return jsonb_build_object('success',true,'credited',false,'message','Bonus hari ini sudah diterima.');
  end if;

  update public.ng_wallet_accounts
  set balance=balance+v_amount,updated_at=now()
  where auth_user_id=v_uid and phone=v_wallet_phone
  returning balance into v_balance;
  if not found then
    delete from public.ng_pro_daily_rewards where user_id=v_uid and reward_date=v_day;
    return jsonb_build_object('success',false,'message','Wallet N.G tujuan tidak ditemukan atau tidak lagi terhubung.');
  end if;

  if v_amount>0 then
    insert into public.ng_wallet_transactions(auth_user_id,description,amount,direction,status)
    values(v_uid,'Bonus harian LEXIAA N.G Pro · '||v_wallet_phone,v_amount,'credit','success');
  end if;
  return jsonb_build_object('success',true,'credited',true,'amount',v_amount,'balance',v_balance,'wallet_phone',v_wallet_phone);
end
$$;

grant execute on function public.ng_pro_submit_application(text,date,text,text,text) to authenticated;
grant execute on function public.ng_pro_claim_daily_bonus() to authenticated;
