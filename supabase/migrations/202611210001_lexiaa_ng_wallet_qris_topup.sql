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
