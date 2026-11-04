-- Lexiaa Account Finder directory
-- Run once in Supabase Dashboard > SQL Editor.
create table if not exists public.lexiaa_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text unique,
  display_name text,
  email_hint text,
  email text,
  avatar_url text,
  old_registered boolean not null default true,
  nextgen_joined_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

alter table public.lexiaa_profiles add column if not exists email_hint text;
alter table public.lexiaa_profiles add column if not exists email text;
alter table public.lexiaa_profiles alter column username drop not null;
alter table public.lexiaa_profiles alter column display_name drop not null;
alter table public.lexiaa_profiles enable row level security;
grant select, insert, update on public.lexiaa_profiles to authenticated;

drop policy if exists "Authenticated users can discover Lexiaa profiles" on public.lexiaa_profiles;
create policy "Authenticated users can discover Lexiaa profiles"
on public.lexiaa_profiles for select to authenticated using (true);

drop policy if exists "Users can insert their own Lexiaa profile" on public.lexiaa_profiles;
create policy "Users can insert their own Lexiaa profile"
on public.lexiaa_profiles for insert to authenticated with check (auth.uid() = id);

drop policy if exists "Users can update their own Lexiaa profile" on public.lexiaa_profiles;
create policy "Users can update their own Lexiaa profile"
on public.lexiaa_profiles for update to authenticated using (auth.uid() = id) with check (auth.uid() = id);

create or replace function public.lexiaa_handle_new_auth_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_username text;
  v_display_name text;
  v_email_hint text;
begin
  v_username := lower(regexp_replace(coalesce(new.raw_user_meta_data->>'username', ''), '[^a-zA-Z0-9_.-]', '', 'g'));
  if v_username = '' then
    v_username := 'lexiaa_' || substr(replace(new.id::text, '-', ''), 1, 10);
  end if;
  v_display_name := nullif(trim(coalesce(new.raw_user_meta_data->>'display_name', '')), '');
  v_email_hint := case when coalesce(new.email, '') like '%@%' then left(split_part(new.email, '@', 1), 2) || repeat('*', greatest(length(split_part(new.email, '@', 1)) - 2, 2)) || '@' || split_part(new.email, '@', 2) else null end;

  insert into public.lexiaa_profiles(id, username, display_name, email_hint, email, old_registered)
  values(new.id, nullif(v_username, 'lexiaa_' || substr(replace(new.id::text, '-', ''), 1, 10)), v_display_name, v_email_hint, new.email, true)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists lexiaa_auth_user_created on auth.users;
create trigger lexiaa_auth_user_created
after insert on auth.users
for each row execute procedure public.lexiaa_handle_new_auth_user();

-- Backfill accounts that already existed before the directory was installed.
insert into public.lexiaa_profiles(id, username, display_name, email_hint, email, old_registered)
select
  u.id,
  nullif(lower(regexp_replace(coalesce(u.raw_user_meta_data->>'username', ''), '[^a-zA-Z0-9_.-]', '', 'g')), ''),
  nullif(trim(coalesce(u.raw_user_meta_data->>'display_name', '')), ''),
  case when coalesce(u.email, '') like '%@%' then left(split_part(u.email, '@', 1), 2) || repeat('*', greatest(length(split_part(u.email, '@', 1)) - 2, 2)) || '@' || split_part(u.email, '@', 2) else null end,
  u.email,
  true
from auth.users u
on conflict (id) do update set
  email_hint = coalesce(public.lexiaa_profiles.email_hint, excluded.email_hint),
  email = coalesce(excluded.email, public.lexiaa_profiles.email),
  username = coalesce(public.lexiaa_profiles.username, excluded.username),
  display_name = coalesce(public.lexiaa_profiles.display_name, excluded.display_name);

create index if not exists lexiaa_profiles_created_at_idx on public.lexiaa_profiles(created_at desc);
create index if not exists lexiaa_profiles_nextgen_idx on public.lexiaa_profiles(nextgen_joined_at desc);
