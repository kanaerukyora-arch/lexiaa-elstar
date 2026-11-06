-- LEXIAA N.G Video VIP
-- Run once in Supabase SQL Editor.

create table if not exists public.ng_videos (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(btrim(title)) between 1 and 160),
  price bigint not null default 0 check (price between 0 and 1000000000),
  video_path text not null unique,
  mime_type text not null check (mime_type in ('video/mp4','video/webm')),
  file_size bigint not null check (file_size > 0 and file_size <= 52428800),
  is_published boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.ng_video_vip_subscriptions (
  user_id uuid primary key references auth.users(id) on delete cascade,
  package_code text not null,
  amount bigint not null check (amount > 0),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  updated_at timestamptz not null default now(),
  constraint ng_video_vip_valid_period check (ends_at > starts_at)
);

create table if not exists public.ng_video_purchases (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  video_id uuid not null references public.ng_videos(id) on delete restrict,
  amount bigint not null check (amount > 0),
  purchased_at timestamptz not null default now(),
  unique(user_id, video_id)
);

create index if not exists ng_videos_published_created_idx on public.ng_videos(is_published, created_at desc);
create index if not exists ng_video_purchases_user_idx on public.ng_video_purchases(user_id, purchased_at desc);

alter table public.ng_videos enable row level security;
alter table public.ng_video_vip_subscriptions enable row level security;
alter table public.ng_video_purchases enable row level security;
revoke all on public.ng_videos, public.ng_video_vip_subscriptions, public.ng_video_purchases from anon, authenticated;

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('lexiaa-ng-videos', 'lexiaa-ng-videos', false, 52428800, array['video/mp4','video/webm'])
on conflict (id) do update set public = false, file_size_limit = 52428800,
  allowed_mime_types = array['video/mp4','video/webm'];

create or replace function public.ng_video_vip_purchase(p_phone text, p_pin text, p_package text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_account public.ng_wallet_accounts%rowtype;
  v_phone text := regexp_replace(coalesce(p_phone, ''), '[[:space:]-]', '', 'g');
  v_amount bigint;
  v_duration interval;
  v_now timestamptz := now();
  v_start timestamptz;
  v_end timestamptz;
  v_balance bigint;
  v_login jsonb;
begin
  if v_uid is null then
    return jsonb_build_object('success',false,'message','Sesi LEXIAA tidak valid. Masuk kembali.');
  end if;
  v_login := public.ng_wallet_login(p_phone, p_pin);
  if coalesce((v_login->>'success')::boolean, false) is not true then
    return v_login;
  end if;

  case p_package
    when '1h' then v_amount:=100000; v_duration:=interval '1 hour';
    when '10h' then v_amount:=200000; v_duration:=interval '10 hours';
    when '1d' then v_amount:=400000; v_duration:=interval '1 day';
    when '3d' then v_amount:=800000; v_duration:=interval '3 days';
    when '7d' then v_amount:=1500000; v_duration:=interval '7 days';
    when '30d' then v_amount:=3000000; v_duration:=interval '30 days';
    else return jsonb_build_object('success',false,'message','Paket VIP tidak valid.');
  end case;

  select * into v_account
  from public.ng_wallet_accounts
  where auth_user_id=v_uid and phone=v_phone
  for update;

  if not found then
    return jsonb_build_object('success',false,'message','Nomor atau PIN Wallet tidak cocok.');
  end if;
  if coalesce(p_pin,'') !~ '^[0-9]{4}$' then
    return jsonb_build_object('success',false,'message','Nomor atau PIN Wallet tidak cocok.');
  end if;
  if extensions.crypt(p_pin, v_account.pin_hash) <> v_account.pin_hash then
    return jsonb_build_object('success',false,'message','Nomor atau PIN Wallet tidak cocok.');
  end if;
  if v_account.balance < v_amount then
    return jsonb_build_object('success',false,'message','Saldo Wallet N.G tidak mencukupi.','balance',v_account.balance,'required',v_amount);
  end if;

  select greatest(v_now, ends_at) into v_start
  from public.ng_video_vip_subscriptions
  where user_id=v_uid
  for update;
  if v_start is null then v_start:=v_now; end if;
  v_end:=v_start+v_duration;

  update public.ng_wallet_accounts
  set balance=balance-v_amount,updated_at=v_now
  where auth_user_id=v_uid
  returning balance into v_balance;

  insert into public.ng_wallet_transactions(auth_user_id,description,amount,direction,status)
  values(v_uid,'Langganan Lexiaa N.G Video VIP ('||p_package||')',v_amount,'debit','success');

  insert into public.ng_video_vip_subscriptions(user_id,package_code,amount,starts_at,ends_at,updated_at)
  values(v_uid,p_package,v_amount,v_start,v_end,v_now)
  on conflict(user_id) do update set package_code=excluded.package_code,amount=excluded.amount,
    starts_at=excluded.starts_at,ends_at=excluded.ends_at,updated_at=v_now;

  return jsonb_build_object('success',true,'balance',v_balance,'amount',v_amount,'starts_at',v_start,'ends_at',v_end);
end;
$$;

create or replace function public.ng_video_purchase(p_phone text, p_pin text, p_video_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_account public.ng_wallet_accounts%rowtype;
  v_video public.ng_videos%rowtype;
  v_phone text := regexp_replace(coalesce(p_phone, ''), '[[:space:]-]', '', 'g');
  v_balance bigint;
  v_login jsonb;
begin
  if v_uid is null then
    return jsonb_build_object('success',false,'message','Sesi LEXIAA tidak valid.');
  end if;

  v_login := public.ng_wallet_login(p_phone, p_pin);
  if coalesce((v_login->>'success')::boolean, false) is not true then
    return v_login;
  end if;

  if not exists (
    select 1 from public.ng_video_vip_subscriptions
    where user_id=v_uid and ends_at>now()
  ) then
    return jsonb_build_object('success',false,'message','Langganan VIP kamu sudah berakhir. Aktifkan VIP kembali.');
  end if;

  select * into v_video
  from public.ng_videos
  where id=p_video_id and is_published=true;

  if not found then
    return jsonb_build_object('success',false,'message','Video berbayar tidak ditemukan.');
  end if;
  if v_video.price<=0 then
    return jsonb_build_object('success',false,'message','Video berbayar tidak ditemukan.');
  end if;

  if exists(select 1 from public.ng_video_purchases where user_id=v_uid and video_id=p_video_id) then
    return jsonb_build_object('success',true,'already_owned',true);
  end if;

  select * into v_account
  from public.ng_wallet_accounts
  where auth_user_id=v_uid and phone=v_phone
  for update;

  if not found then
    return jsonb_build_object('success',false,'message','Nomor atau PIN Wallet tidak cocok.');
  end if;
  if coalesce(p_pin,'') !~ '^[0-9]{4}$' then
    return jsonb_build_object('success',false,'message','Nomor atau PIN Wallet tidak cocok.');
  end if;
  if extensions.crypt(p_pin, v_account.pin_hash) <> v_account.pin_hash then
    return jsonb_build_object('success',false,'message','Nomor atau PIN Wallet tidak cocok.');
  end if;

  if exists(select 1 from public.ng_video_purchases where user_id=v_uid and video_id=p_video_id) then
    return jsonb_build_object('success',true,'already_owned',true);
  end if;

  if v_account.balance < v_video.price then
    return jsonb_build_object('success',false,'message','Saldo Wallet N.G tidak mencukupi.','balance',v_account.balance,'required',v_video.price);
  end if;

  update public.ng_wallet_accounts
  set balance=balance-v_video.price,updated_at=now()
  where auth_user_id=v_uid
  returning balance into v_balance;

  insert into public.ng_wallet_transactions(auth_user_id,description,amount,direction,status)
  values(v_uid,'Pembelian video: '||v_video.title,v_video.price,'debit','success');

  insert into public.ng_video_purchases(user_id,video_id,amount)
  values(v_uid,p_video_id,v_video.price)
  on conflict(user_id,video_id) do nothing;

  return jsonb_build_object('success',true,'balance',v_balance,'amount',v_video.price);
end;
$$;

revoke all on function public.ng_video_vip_purchase(text,text,text) from public, anon;
revoke all on function public.ng_video_purchase(text,text,uuid) from public, anon;
grant execute on function public.ng_video_vip_purchase(text,text,text) to authenticated;
grant execute on function public.ng_video_purchase(text,text,uuid) to authenticated;
