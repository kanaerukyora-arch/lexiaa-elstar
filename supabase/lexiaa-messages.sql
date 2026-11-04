-- Lexiaa New private messages
-- Run in Supabase SQL Editor after deploying the lexiaa-admin Edge Function.
create table if not exists public.lexiaa_messages (
  id uuid primary key default gen_random_uuid(),
  recipient_id uuid not null references auth.users(id) on delete cascade,
  title text not null check (char_length(title) between 1 and 140),
  body text not null check (char_length(body) between 1 and 5000),
  created_at timestamptz not null default now(),
  read_at timestamptz
);
create index if not exists lexiaa_messages_recipient_created_idx
  on public.lexiaa_messages(recipient_id, created_at desc);
alter table public.lexiaa_messages enable row level security;
revoke all on public.lexiaa_messages from anon, authenticated;
grant select on public.lexiaa_messages to authenticated;
grant update (read_at) on public.lexiaa_messages to authenticated;
drop policy if exists "Users read own Lexiaa messages" on public.lexiaa_messages;
create policy "Users read own Lexiaa messages"
on public.lexiaa_messages for select to authenticated
using (recipient_id = (select auth.uid()));
drop policy if exists "Users mark own Lexiaa messages read" on public.lexiaa_messages;
create policy "Users mark own Lexiaa messages read"
on public.lexiaa_messages for update to authenticated
using (recipient_id = (select auth.uid()))
with check (recipient_id = (select auth.uid()));
-- Only the Edge Function service role can insert messages or enumerate recipients.
do $$
begin
  alter publication supabase_realtime add table public.lexiaa_messages;
exception when duplicate_object then null;
when undefined_object then null;
end $$;
