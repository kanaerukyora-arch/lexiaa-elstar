-- LEXIAA N.G Wallet top-up: QRIS selection, private proof uploads, admin review.
create table if not exists public.ng_wallet_topup_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  wallet_phone text not null,
  amount integer not null check (amount in (20000, 50000, 75000, 100000)),
  proof_path text not null,
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  admin_note text,
  created_at timestamptz not null default now(),
  reviewed_at timestamptz,
  reviewed_by text
);

create index if not exists ng_wallet_topup_requests_user_created_idx
  on public.ng_wallet_topup_requests(user_id, created_at desc);
create index if not exists ng_wallet_topup_requests_status_created_idx
  on public.ng_wallet_topup_requests(status, created_at desc);

create table if not exists public.ng_wallet_topup_qris (
  amount integer primary key check (amount in (20000, 50000, 75000, 100000)),
  image_path text not null,
  updated_at timestamptz not null default now()
);

alter table public.ng_wallet_topup_requests enable row level security;
alter table public.ng_wallet_topup_qris enable row level security;

revoke all on public.ng_wallet_topup_requests from anon, authenticated;
revoke all on public.ng_wallet_topup_qris from anon, authenticated;
grant all on public.ng_wallet_topup_requests to service_role;
grant all on public.ng_wallet_topup_qris to service_role;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values
 ('lexiaa-ng-topup-proof','lexiaa-ng-topup-proof',false,5242880,array['image/jpeg','image/png','image/webp']),
 ('lexiaa-ng-qris','lexiaa-ng-qris',true,5242880,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set
  public = excluded.public,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "LEXIAA N.G QRIS images are public" on storage.objects;
create policy "LEXIAA N.G QRIS images are public"
on storage.objects for select
to public
using (bucket_id = 'lexiaa-ng-qris');

-- Customer requests and QRIS configuration are accessed only through the Edge Function.
-- The Edge Function uses the service role after verifying the signed-in user's identity
-- or the separate LEXIAA admin token.

create or replace function public.ng_wallet_topup_review(
  p_request_id uuid,
  p_decision text,
  p_admin_note text default null
) returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_req public.ng_wallet_topup_requests%rowtype;
  v_credit jsonb;
  v_note text := left(coalesce(trim(p_admin_note), ''), 500);
  v_title text;
  v_body text;
begin
  if p_decision not in ('approved','rejected') then
    return jsonb_build_object('success',false,'message','Keputusan admin tidak valid.');
  end if;

  select * into v_req
  from public.ng_wallet_topup_requests
  where id = p_request_id
  for update;

  if not found then
    return jsonb_build_object('success',false,'message','Pengajuan top-up tidak ditemukan.');
  end if;
  if v_req.status <> 'pending' then
    return jsonb_build_object('success',false,'message','Pengajuan ini sudah pernah diproses.');
  end if;

  if p_decision = 'approved' then
    v_credit := public.ng_wallet_admin_credit(
      v_req.user_id,
      v_req.amount,
      'Top Up QRIS LEXIAA N.G'
    );
    if coalesce((v_credit->>'success')::boolean,false) is not true then
      raise exception 'Gagal menambahkan saldo: %', coalesce(v_credit->>'message','RPC saldo gagal.');
    end if;
    v_title := 'Top Up Wallet N.G Berhasil';
    v_body := 'Pembayaran QRIS sebesar Rp' || to_char(v_req.amount, 'FM999G999G999') ||
      ' telah diverifikasi. Saldo Wallet N.G kamu sudah ditambahkan.';
  else
    v_title := 'Top Up Wallet N.G Ditolak';
    v_body := 'Pengajuan top up QRIS sebesar Rp' || to_char(v_req.amount, 'FM999G999G999') ||
      ' belum dapat diterima.' ||
      case when v_note <> '' then E'\nCatatan admin: ' || v_note else '' end;
  end if;

  update public.ng_wallet_topup_requests
  set status = p_decision,
      admin_note = nullif(v_note,''),
      reviewed_at = now(),
      reviewed_by = 'LEXIAA ADMIN'
  where id = p_request_id;

  insert into public.lexiaa_messages(recipient_id,title,body)
  values (v_req.user_id, v_title, v_body);

  return jsonb_build_object(
    'success',true,
    'status',p_decision,
    'amount',v_req.amount,
    'balance',case when p_decision='approved' then (v_credit->>'balance')::numeric else null end
  );
end;
$$;

revoke all on function public.ng_wallet_topup_review(uuid,text,text) from public, anon, authenticated;
grant execute on function public.ng_wallet_topup_review(uuid,text,text) to service_role;
