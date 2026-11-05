-- LEXIAA N.G Wallet: secure account registration/login
-- Apply this migration in the Supabase SQL Editor for the LEXIAA N.G project.
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.ng_wallet_accounts (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique references auth.users(id) on delete cascade,
  phone text not null unique,
  pin_hash text not null,
  display_name text not null,
  balance bigint not null default 0 check (balance >= 0),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ng_wallet_phone_format check (phone ~ '^\\+62[0-9]{8,13}$'),
  constraint ng_wallet_name_length check (char_length(display_name) between 2 and 32)
);

create table if not exists public.ng_wallet_login_attempts (
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  phone text not null,
  failed_attempts integer not null default 0,
  locked_until timestamptz,
  updated_at timestamptz not null default now(),
  primary key (auth_user_id, phone)
);

alter table public.ng_wallet_accounts enable row level security;
alter table public.ng_wallet_login_attempts enable row level security;
revoke all on public.ng_wallet_accounts from anon, authenticated;
revoke all on public.ng_wallet_login_attempts from anon, authenticated;

create or replace function public.ng_wallet_register(p_phone text, p_pin text, p_name text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_phone text := regexp_replace(coalesce(p_phone, ''), '[[:space:]-]', '', 'g');
  v_name text := btrim(coalesce(p_name, ''));
begin
  if v_uid is null then
    return jsonb_build_object('success', false, 'message', 'Sesi akun utama tidak ditemukan. Silakan masuk kembali.');
  end if;
  if v_phone !~ '^\\+62[0-9]{8,13}$' then
    return jsonb_build_object('success', false, 'message', 'Nomor harus diawali +62 dan berisi 10–15 digit setelah kode negara.');
  end if;
  if coalesce(p_pin, '') !~ '^[0-9]{4}$' then
    return jsonb_build_object('success', false, 'message', 'PIN harus tepat 4 digit angka.');
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 32 then
    return jsonb_build_object('success', false, 'message', 'Nama akun harus terdiri dari 2–32 karakter.');
  end if;
  if exists (select 1 from public.ng_wallet_accounts where auth_user_id = v_uid) then
    return jsonb_build_object('success', false, 'message', 'Akun Saldo LEXIAA N.G sudah terdaftar pada akun utama ini.');
  end if;
  insert into public.ng_wallet_accounts(auth_user_id, phone, pin_hash, display_name, balance)
  values (v_uid, v_phone, extensions.crypt(p_pin, extensions.gen_salt('bf', 10)), v_name, 0);
  return jsonb_build_object('success', true, 'name', v_name, 'phone', v_phone, 'balance', 0);
exception
  when unique_violation then
    return jsonb_build_object('success', false, 'message', 'Nomor tersebut sudah digunakan. Pilih ID nomor lain.');
end;
$$;

create or replace function public.ng_wallet_login(p_phone text, p_pin text)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_phone text := regexp_replace(coalesce(p_phone, ''), '[[:space:]-]', '', 'g');
  v_account public.ng_wallet_accounts%rowtype;
  v_attempt public.ng_wallet_login_attempts%rowtype;
  v_failed integer;
begin
  if v_uid is null then
    return jsonb_build_object('success', false, 'message', 'Sesi akun utama tidak ditemukan. Silakan masuk kembali.');
  end if;
  if v_phone !~ '^\\+62[0-9]{8,13}$' or coalesce(p_pin, '') !~ '^[0-9]{4}$' then
    return jsonb_build_object('success', false, 'message', 'Nomor atau PIN tidak cocok.');
  end if;

  insert into public.ng_wallet_login_attempts(auth_user_id, phone)
  values (v_uid, v_phone) on conflict (auth_user_id, phone) do nothing;
  select * into v_attempt from public.ng_wallet_login_attempts
  where auth_user_id = v_uid and phone = v_phone for update;

  if v_attempt.locked_until is not null and v_attempt.locked_until > now() then
    return jsonb_build_object('success', false, 'message', 'Terlalu banyak percobaan. Coba lagi setelah 15 menit.');
  end if;

  select * into v_account from public.ng_wallet_accounts
  where auth_user_id = v_uid and phone = v_phone;

  if not found or extensions.crypt(p_pin, v_account.pin_hash) <> v_account.pin_hash then
    v_failed := coalesce(v_attempt.failed_attempts, 0) + 1;
    update public.ng_wallet_login_attempts
      set failed_attempts = case when v_failed >= 5 then 0 else v_failed end,
          locked_until = case when v_failed >= 5 then now() + interval '15 minutes' else null end,
          updated_at = now()
      where auth_user_id = v_uid and phone = v_phone;
    return jsonb_build_object('success', false, 'message', case when v_failed >= 5 then 'Terlalu banyak percobaan. Akun dikunci sementara selama 15 menit.' else 'Nomor atau PIN tidak cocok.' end);
  end if;

  update public.ng_wallet_login_attempts
    set failed_attempts = 0, locked_until = null, updated_at = now()
    where auth_user_id = v_uid and phone = v_phone;

  return jsonb_build_object('success', true, 'name', v_account.display_name, 'phone', v_account.phone, 'balance', v_account.balance);
end;
$$;

revoke all on function public.ng_wallet_register(text, text, text) from public, anon;
revoke all on function public.ng_wallet_login(text, text) from public, anon;
grant execute on function public.ng_wallet_register(text, text, text) to authenticated;
grant execute on function public.ng_wallet_login(text, text) to authenticated;
