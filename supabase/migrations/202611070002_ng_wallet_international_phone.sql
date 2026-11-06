-- Extend Wallet N.G phone validation to international E.164 numbers.
-- Existing +62 accounts remain valid; this enables the region selector for other calling codes.
alter table public.ng_wallet_accounts drop constraint if exists ng_wallet_phone_format;
alter table public.ng_wallet_accounts
  add constraint ng_wallet_phone_format check (phone ~ '^\+[1-9][0-9]{7,14}$');

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
  if v_phone !~ '^\+[1-9][0-9]{7,14}$' then
    return jsonb_build_object('success', false, 'message', 'Nomor harus menggunakan kode negara internasional dan berisi 8–15 digit setelah tanda +.');
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
  if v_phone !~ '^\+[1-9][0-9]{7,14}$' or coalesce(p_pin, '') !~ '^[0-9]{4}$' then
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

  if not found then
    v_failed := coalesce(v_attempt.failed_attempts, 0) + 1;
    update public.ng_wallet_login_attempts
      set failed_attempts = case when v_failed >= 5 then 0 else v_failed end,
          locked_until = case when v_failed >= 5 then now() + interval '15 minutes' else null end,
          updated_at = now()
      where auth_user_id = v_uid and phone = v_phone;
    return jsonb_build_object('success', false, 'message', case when v_failed >= 5 then 'Terlalu banyak percobaan. Akun dikunci sementara selama 15 menit.' else 'Nomor atau PIN tidak cocok.' end);
  end if;

  if extensions.crypt(p_pin, v_account.pin_hash) <> v_account.pin_hash then
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
