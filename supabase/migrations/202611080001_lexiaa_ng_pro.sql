
-- LEXIAA N.G Pro membership, applications, daily bonus and admin-configurable renewal.
create table if not exists public.ng_pro_settings (
  id boolean primary key default true check (id),
  renewal_price bigint not null default 0 check (renewal_price between 0 and 1000000000),
  duration_days integer not null default 30 check (duration_days between 1 and 3650),
  daily_bonus bigint not null default 5000000 check (daily_bonus between 0 and 1000000000),
  discount_percent integer not null default 50 check (discount_percent between 0 and 100),
  cashback_percent integer not null default 20 check (cashback_percent between 0 and 100),
  updated_at timestamptz not null default now()
);
insert into public.ng_pro_settings(id) values(true) on conflict(id) do nothing;

create table if not exists public.ng_pro_applications (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  full_name text not null check(char_length(btrim(full_name)) between 2 and 120),
  birth_date date not null,
  email text not null,
  whatsapp text not null,
  status text not null default 'pending' check(status in ('pending','approved','rejected')),
  admin_note text,
  reviewed_at timestamptz,
  reviewed_by text,
  created_at timestamptz not null default now()
);
create index if not exists ng_pro_applications_status_created_idx on public.ng_pro_applications(status,created_at desc);
create unique index if not exists ng_pro_one_pending_application_idx on public.ng_pro_applications(user_id) where status='pending';

create table if not exists public.ng_pro_memberships (
  user_id uuid primary key references auth.users(id) on delete cascade,
  application_id uuid references public.ng_pro_applications(id),
  status text not null default 'active' check(status in ('active','expired','revoked')),
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  updated_at timestamptz not null default now(),
  check(ends_at>starts_at)
);
create index if not exists ng_pro_memberships_active_idx on public.ng_pro_memberships(status,ends_at);

create table if not exists public.ng_pro_daily_rewards (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  reward_date date not null,
  amount bigint not null check(amount>=0),
  created_at timestamptz not null default now(),
  unique(user_id,reward_date)
);

alter table public.ng_pro_settings enable row level security;
alter table public.ng_pro_applications enable row level security;
alter table public.ng_pro_memberships enable row level security;
alter table public.ng_pro_daily_rewards enable row level security;
revoke all on public.ng_pro_settings,public.ng_pro_applications,public.ng_pro_memberships,public.ng_pro_daily_rewards from anon,authenticated;

create or replace function public.ng_pro_submit_application(
  p_full_name text,p_birth_date date,p_email text,p_whatsapp text
) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_uid uuid:=auth.uid(); v_id uuid; v_existing public.ng_pro_memberships%rowtype;
begin
 if v_uid is null then return jsonb_build_object('success',false,'message','Silakan masuk kembali.'); end if;
 if char_length(btrim(coalesce(p_full_name,''))) not between 2 and 120
   or p_birth_date is null or p_birth_date>current_date or p_birth_date<date '1900-01-01'
   or coalesce(p_email,'') !~* '^[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}$'
   or char_length(p_whatsapp) not between 8 and 20
 then return jsonb_build_object('success',false,'message','Periksa kembali nama, tanggal lahir, email, dan nomor WhatsApp.'); end if;
 select * into v_existing from public.ng_pro_memberships where user_id=v_uid and status='active' and ends_at>now();
 if found then return jsonb_build_object('success',false,'message','Akun ini sudah menjadi LEXIAA N.G Pro.'); end if;
 if exists(select 1 from public.ng_pro_applications where user_id=v_uid and status='pending') then
   return jsonb_build_object('success',false,'message','Pengajuan kamu masih menunggu keputusan admin.'); end if;
 insert into public.ng_pro_applications(user_id,full_name,birth_date,email,whatsapp)
 values(v_uid,btrim(p_full_name),p_birth_date,lower(btrim(p_email)),btrim(p_whatsapp)) returning id into v_id;
 return jsonb_build_object('success',true,'application_id',v_id,'message','Pengajuan berhasil dikirim. Tunggu pemberitahuan dari admin.');
end $$;

create or replace function public.ng_pro_status()
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_uid uuid:=auth.uid(); v_app public.ng_pro_applications%rowtype; v_member public.ng_pro_memberships%rowtype; v_settings public.ng_pro_settings%rowtype;
begin
 if v_uid is null then return jsonb_build_object('success',false,'message','Sesi tidak valid.'); end if;
 select * into v_app from public.ng_pro_applications where user_id=v_uid order by created_at desc limit 1;
 select * into v_member from public.ng_pro_memberships where user_id=v_uid;
 select * into v_settings from public.ng_pro_settings where id=true;
 return jsonb_build_object('success',true,'application_status',v_app.status,'application_created_at',v_app.created_at,
   'admin_note',v_app.admin_note,'pro_active',coalesce(v_member.status='active' and v_member.ends_at>now(),false),
   'pro_ends_at',v_member.ends_at,'renewal_price',v_settings.renewal_price,'duration_days',v_settings.duration_days);
end $$;

create or replace function public.ng_pro_claim_daily_bonus()
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_uid uuid:=auth.uid(); v_day date:=(now() at time zone 'Asia/Jakarta')::date; v_member public.ng_pro_memberships%rowtype; v_amount bigint; v_balance bigint;
begin
 if v_uid is null then return jsonb_build_object('success',false,'message','Sesi tidak valid.'); end if;
 select * into v_member from public.ng_pro_memberships where user_id=v_uid and status='active' and starts_at<=now() and ends_at>now();
 if not found then return jsonb_build_object('success',false,'message','Keanggotaan Pro tidak aktif.'); end if;
 select daily_bonus into v_amount from public.ng_pro_settings where id=true;
 insert into public.ng_pro_daily_rewards(user_id,reward_date,amount) values(v_uid,v_day,v_amount)
 on conflict(user_id,reward_date) do nothing;
 if not found then return jsonb_build_object('success',true,'credited',false,'message','Bonus hari ini sudah diterima.'); end if;
 update public.ng_wallet_accounts set balance=balance+v_amount,updated_at=now() where auth_user_id=v_uid returning balance into v_balance;
 if not found then delete from public.ng_pro_daily_rewards where user_id=v_uid and reward_date=v_day; return jsonb_build_object('success',false,'message','Akun Wallet N.G belum tersedia.'); end if;
 if v_amount>0 then insert into public.ng_wallet_transactions(auth_user_id,description,amount,direction,status)
 values(v_uid,'Bonus harian LEXIAA N.G Pro',v_amount,'credit','success'); end if;
 return jsonb_build_object('success',true,'credited',true,'amount',v_amount,'balance',v_balance);
end $$;

create or replace function public.ng_pro_renew()
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_uid uuid:=auth.uid(); v_account public.ng_wallet_accounts%rowtype; v_settings public.ng_pro_settings%rowtype; v_start timestamptz; v_end timestamptz; v_balance bigint;
begin
 if v_uid is null then return jsonb_build_object('success',false,'message','Sesi tidak valid.'); end if;
 select * into v_settings from public.ng_pro_settings where id=true;
 if v_settings.renewal_price<=0 then return jsonb_build_object('success',false,'message','Perpanjangan Pro belum dibuka oleh admin.'); end if;
 select * into v_account from public.ng_wallet_accounts where auth_user_id=v_uid and payments_linked_at is not null for update;
 if not found then return jsonb_build_object('success',false,'message','Hubungkan Wallet N.G terlebih dahulu.'); end if;
 if v_account.balance<v_settings.renewal_price then return jsonb_build_object('success',false,'message','Saldo Wallet N.G tidak mencukupi.'); end if;
 v_start:=now();
 select greatest(now(),ends_at) into v_start from public.ng_pro_memberships where user_id=v_uid and status='active' for update;
 if v_start is null then v_start:=now(); end if;
 v_end:=v_start+make_interval(days=>v_settings.duration_days);
 update public.ng_wallet_accounts set balance=balance-v_settings.renewal_price,updated_at=now() where auth_user_id=v_uid returning balance into v_balance;
 insert into public.ng_wallet_transactions(auth_user_id,description,amount,direction,status)
 values(v_uid,'Perpanjangan LEXIAA N.G Pro',v_settings.renewal_price,'debit','success');
 insert into public.ng_pro_memberships(user_id,status,starts_at,ends_at,updated_at)
 values(v_uid,'active',v_start,v_end,now())
 on conflict(user_id) do update set status='active',starts_at=excluded.starts_at,ends_at=excluded.ends_at,updated_at=now();
 return jsonb_build_object('success',true,'balance',v_balance,'ends_at',v_end,'amount',v_settings.renewal_price);
end $$;

revoke all on function public.ng_pro_submit_application(text,date,text,text) from public,anon;
revoke all on function public.ng_pro_status() from public,anon;
revoke all on function public.ng_pro_claim_daily_bonus() from public,anon;
revoke all on function public.ng_pro_renew() from public,anon;
grant execute on function public.ng_pro_submit_application(text,date,text,text) to authenticated;
grant execute on function public.ng_pro_status() to authenticated;
grant execute on function public.ng_pro_claim_daily_bonus() to authenticated;
grant execute on function public.ng_pro_renew() to authenticated;
-- LEXIAA N.G Spin & Quest: daily spins, server-picked prizes, wallet credits, and capped game rewards.
-- Run once in the Supabase SQL Editor.

create table if not exists public.ng_wallet_spin_daily (
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  spin_date date not null,
  free_spins_used integer not null default 0 check (free_spins_used between 0 and 20),
  quest_spins_earned integer not null default 0 check (quest_spins_earned between 0 and 10),
  quest_spins_used integer not null default 0 check (quest_spins_used between 0 and 10),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (auth_user_id, spin_date),
  check (quest_spins_used <= quest_spins_earned)
);

create table if not exists public.ng_wallet_spin_game_sessions (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  started_at timestamptz not null default now(),
  claimed_at timestamptz,
  claimed_score integer,
  created_at timestamptz not null default now()
);

create index if not exists ng_wallet_spin_game_user_created_idx
  on public.ng_wallet_spin_game_sessions(auth_user_id, created_at desc);

alter table public.ng_wallet_spin_daily enable row level security;
alter table public.ng_wallet_spin_game_sessions enable row level security;
revoke all on public.ng_wallet_spin_daily, public.ng_wallet_spin_game_sessions from anon, authenticated;

create or replace function public.ng_wallet_spin_status()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_day date := (now() at time zone 'Asia/Jakarta')::date;
  v_daily public.ng_wallet_spin_daily%rowtype;
begin
  if v_uid is null then
    return jsonb_build_object('success',false,'message','Sesi LEXIAA tidak valid. Masuk kembali.');
  end if;
  if not exists(select 1 from public.ng_wallet_accounts where auth_user_id=v_uid) then
    return jsonb_build_object('success',false,'message','Buat akun Wallet N.G terlebih dahulu.','wallet_missing',true);
  end if;
  insert into public.ng_wallet_spin_daily(auth_user_id,spin_date)
    values(v_uid,v_day) on conflict(auth_user_id,spin_date) do nothing;
  select * into v_daily from public.ng_wallet_spin_daily
    where auth_user_id=v_uid and spin_date=v_day;
  return jsonb_build_object(
    'success',true,
    'daily_free_spins',greatest(0,(case when exists(select 1 from public.ng_pro_memberships where user_id=v_uid and status='active' and starts_at<=now() and ends_at>now()) then 20 else 10 end)-v_daily.free_spins_used),
    'quest_spins',greatest(0,v_daily.quest_spins_earned-v_daily.quest_spins_used),
    'quest_spins_earned',v_daily.quest_spins_earned,
    'quest_spins_cap',10,
    'spin_date',v_day
  );
end;
$$;

create or replace function public.ng_wallet_spin()
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_day date := (now() at time zone 'Asia/Jakarta')::date;
  v_daily public.ng_wallet_spin_daily%rowtype;
  v_account public.ng_wallet_accounts%rowtype;
  v_bytes bytea;
  v_roll bigint;
  v_prize text;
  v_amount bigint := 0;
  v_balance bigint;
  v_source text;
begin
  if v_uid is null then
    return jsonb_build_object('success',false,'message','Sesi LEXIAA tidak valid. Masuk kembali.');
  end if;
  insert into public.ng_wallet_spin_daily(auth_user_id,spin_date)
    values(v_uid,v_day) on conflict(auth_user_id,spin_date) do nothing;
  select * into v_daily from public.ng_wallet_spin_daily
    where auth_user_id=v_uid and spin_date=v_day for update;
  select * into v_account from public.ng_wallet_accounts
    where auth_user_id=v_uid for update;
  if not found then
    return jsonb_build_object('success',false,'message','Akun Wallet N.G tidak ditemukan.','wallet_missing',true);
  end if;

  if v_daily.free_spins_used < case when exists(select 1 from public.ng_pro_memberships where user_id=v_uid and status='active' and starts_at<=now() and ends_at>now()) then 20 else 10 end then
    update public.ng_wallet_spin_daily
      set free_spins_used=free_spins_used+1,updated_at=now()
      where auth_user_id=v_uid and spin_date=v_day;
    v_source := 'Putaran gratis harian';
  elsif v_daily.quest_spins_used < v_daily.quest_spins_earned then
    update public.ng_wallet_spin_daily
      set quest_spins_used=quest_spins_used+1,updated_at=now()
      where auth_user_id=v_uid and spin_date=v_day;
    v_source := 'Putaran dari Quest';
  else
    return jsonb_build_object('success',false,'message','Putaran habis. Selesaikan Quest atau kembali besok.');
  end if;

  -- Weighted roll out of 1,000,000,000 using cryptographically secure random bytes.
  -- ZONK 40%; Rp1jt 40%; Rp2jt 10%; Rp3jt 5%; Rp100jt 4%;
  -- Rp999jt 0.9%; Rp1M (Rp1 miliar) 0.1%.
  v_bytes := extensions.gen_random_bytes(4);
  v_roll := (get_byte(v_bytes,0)::bigint << 24)
          + (get_byte(v_bytes,1)::bigint << 16)
          + (get_byte(v_bytes,2)::bigint << 8)
          + get_byte(v_bytes,3)::bigint;
  v_roll := mod(v_roll,1000000000);

  if v_roll < 400000000 then
    v_prize := 'ZONK';
  elsif v_roll < 800000000 then
    v_prize := 'Rp1.000.000'; v_amount := 1000000;
  elsif v_roll < 900000000 then
    v_prize := 'Rp2.000.000'; v_amount := 2000000;
  elsif v_roll < 950000000 then
    v_prize := 'Rp3.000.000'; v_amount := 3000000;
  elsif v_roll < 990000000 then
    v_prize := 'Rp100.000.000'; v_amount := 100000000;
  elsif v_roll < 999000000 then
    v_prize := 'Rp999.000.000'; v_amount := 999000000;
  else
    v_prize := 'Rp1.000.000.000'; v_amount := 1000000000;
  end if;

  if v_amount > 0 then
    update public.ng_wallet_accounts
      set balance=balance+v_amount,updated_at=now()
      where auth_user_id=v_uid returning balance into v_balance;
    insert into public.ng_wallet_transactions(auth_user_id,description,amount,direction,status)
      values(v_uid,'Hadiah Spin LEXIAA N.G · '||v_prize,v_amount,'credit','success');
  else
    v_balance := v_account.balance;
  end if;

  return jsonb_build_object(
    'success',true,'prize',v_prize,'amount',v_amount,'balance',v_balance,
    'source',v_source,'spin_date',v_day
  );
end;
$$;

create or replace function public.ng_wallet_game_start()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_id uuid;
begin
  if v_uid is null then
    return jsonb_build_object('success',false,'message','Sesi LEXIAA tidak valid. Masuk kembali.');
  end if;
  if not exists(select 1 from public.ng_wallet_accounts where auth_user_id=v_uid) then
    return jsonb_build_object('success',false,'message','Akun Wallet N.G tidak ditemukan.');
  end if;
  insert into public.ng_wallet_spin_game_sessions(auth_user_id)
    values(v_uid) returning id into v_id;
  return jsonb_build_object('success',true,'session_id',v_id);
end;
$$;

create or replace function public.ng_wallet_game_claim(p_session_id uuid,p_score integer)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_session public.ng_wallet_spin_game_sessions%rowtype;
  v_day date := (now() at time zone 'Asia/Jakarta')::date;
  v_daily public.ng_wallet_spin_daily%rowtype;
  v_elapsed integer;
  v_award integer;
begin
  if v_uid is null then
    return jsonb_build_object('success',false,'message','Sesi LEXIAA tidak valid. Masuk kembali.');
  end if;
  if p_score is null or p_score < 100 or p_score > 5000 or mod(p_score,100)<>0 then
    return jsonb_build_object('success',false,'message','Skor Quest tidak valid.');
  end if;
  select * into v_session from public.ng_wallet_spin_game_sessions
    where id=p_session_id and auth_user_id=v_uid for update;
  if not found or v_session.claimed_at is not null then
    return jsonb_build_object('success',false,'message','Sesi permainan tidak valid atau sudah diklaim.');
  end if;
  v_elapsed := floor(extract(epoch from (now()-v_session.started_at)))::integer;
  if v_elapsed < (p_score/100)*10 then
    return jsonb_build_object('success',false,'message','Waktu permainan tidak sesuai dengan skor. Coba main secara normal.');
  end if;
  insert into public.ng_wallet_spin_daily(auth_user_id,spin_date)
    values(v_uid,v_day) on conflict(auth_user_id,spin_date) do nothing;
  select * into v_daily from public.ng_wallet_spin_daily
    where auth_user_id=v_uid and spin_date=v_day for update;
  v_award := least(p_score/100,greatest(0,10-v_daily.quest_spins_earned));
  update public.ng_wallet_spin_game_sessions
    set claimed_at=now(),claimed_score=p_score
    where id=p_session_id;
  if v_award>0 then
    update public.ng_wallet_spin_daily
      set quest_spins_earned=quest_spins_earned+v_award,updated_at=now()
      where auth_user_id=v_uid and spin_date=v_day;
  end if;
  return jsonb_build_object(
    'success',true,'score',p_score,'spins_earned',v_award,
    'quest_spins',greatest(0,v_daily.quest_spins_earned+v_award-v_daily.quest_spins_used),
    'daily_quest_cap',10
  );
end;
$$;

revoke all on function public.ng_wallet_spin_status() from public,anon;
revoke all on function public.ng_wallet_spin() from public,anon;
revoke all on function public.ng_wallet_game_start() from public,anon;
revoke all on function public.ng_wallet_game_claim(uuid,integer) from public,anon;
grant execute on function public.ng_wallet_spin_status() to authenticated;
grant execute on function public.ng_wallet_spin() to authenticated;
grant execute on function public.ng_wallet_game_start() to authenticated;
grant execute on function public.ng_wallet_game_claim(uuid,integer) to authenticated;
