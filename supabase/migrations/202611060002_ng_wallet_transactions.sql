-- LEXIAA N.G wallet transaction history.
-- Run this migration in the Supabase SQL Editor before enabling transaction writers.
create table if not exists public.ng_wallet_transactions (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null references auth.users(id) on delete cascade,
  description text not null,
  amount bigint not null check (amount >= 0),
  direction text not null check (direction in ('credit','debit')),
  status text not null default 'success' check (status in ('success','pending','failed')),
  created_at timestamptz not null default now()
);

create index if not exists ng_wallet_transactions_user_created_idx
  on public.ng_wallet_transactions(auth_user_id, created_at desc);

alter table public.ng_wallet_transactions enable row level security;
revoke all on public.ng_wallet_transactions from anon, authenticated;
grant select on public.ng_wallet_transactions to authenticated;

drop policy if exists "Users can read their own wallet transactions" on public.ng_wallet_transactions;
create policy "Users can read their own wallet transactions"
  on public.ng_wallet_transactions for select to authenticated
  using (auth_user_id = auth.uid());
