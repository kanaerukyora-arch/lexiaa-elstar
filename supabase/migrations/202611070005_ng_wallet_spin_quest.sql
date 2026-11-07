-- LEXIAA N.G Spin & Quest: daily spins, server-picked prizes, wallet credits, and capped game rewards.
-- Run once in the Supabase SQL Editor.

create table if not exists public.ng_wallet_spin_daily (
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  spin_date date not null,
  free_spins_used integer not null default 0 check (free_spins_used between 0 and 10),
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
    'daily_free_spins',greatest(0,10-v_daily.free_spins_used),
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

  if v_daily.free_spins_used < 10 then
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

  -- Weighted roll out of 10,000,000 using cryptographically secure random bytes.
  -- ZONK 80%; Rp1jt 15%; Rp2jt 4%; Rp3jt 0.9%; Rp100jt 0.09%;
  -- Rp999jt 0.009%; Rp1M 0.001% (1 in 100,000).
  v_bytes := extensions.gen_random_bytes(4);
  v_roll := (get_byte(v_bytes,0)::bigint << 24)
          + (get_byte(v_bytes,1)::bigint << 16)
          + (get_byte(v_bytes,2)::bigint << 8)
          + get_byte(v_bytes,3)::bigint;
  v_roll := mod(v_roll,10000000);

  if v_roll < 8000000 then
    v_prize := 'ZONK';
  elsif v_roll < 9500000 then
    v_prize := 'Rp1.000.000'; v_amount := 1000000;
  elsif v_roll < 9900000 then
    v_prize := 'Rp2.000.000'; v_amount := 2000000;
  elsif v_roll < 9990000 then
    v_prize := 'Rp3.000.000'; v_amount := 3000000;
  elsif v_roll < 9999000 then
    v_prize := 'Rp100.000.000'; v_amount := 100000000;
  elsif v_roll < 9999900 then
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
  if v_elapsed < (p_score/100)*2 then
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
