-- Lexiaa Account Finder directory
-- Run once in Supabase Dashboard > SQL Editor.
create table if not exists public.lexiaa_profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username text not null unique,
  display_name text not null default 'Pengguna Lexiaa',
  avatar_url text,
  old_registered boolean not null default true,
  nextgen_joined_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

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
begin
  v_username := lower(regexp_replace(coalesce(new.raw_user_meta_data->>'username', ''), '[^a-zA-Z0-9_.-]', '', 'g'));
  if v_username = '' then
    v_username := 'lexiaa_' || substr(replace(new.id::text, '-', ''), 1, 10);
  end if;
  v_display_name := nullif(trim(coalesce(new.raw_user_meta_data->>'display_name', '')), '');
  if v_display_name is null then v_display_name := 'Pengguna Lexiaa'; end if;

  insert into public.lexiaa_profiles(id, username, display_name, old_registered)
  values(new.id, v_username, v_display_name, true)
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists lexiaa_auth_user_created on auth.users;
create trigger lexiaa_auth_user_created
after insert on auth.users
for each row execute procedure public.lexiaa_handle_new_auth_user();

-- Backfill accounts that already existed before the directory was installed.
insert into public.lexiaa_profiles(id, username, display_name, old_registered)
select
  u.id,
  'lexiaa_' || substr(replace(u.id::text, '-', ''), 1, 10),
  coalesce(nullif(trim(u.raw_user_meta_data->>'display_name'), ''), 'Pengguna Lexiaa'),
  true
from auth.users u
on conflict (id) do nothing;

create index if not exists lexiaa_profiles_created_at_idx on public.lexiaa_profiles(created_at desc);
create index if not exists lexiaa_profiles_nextgen_idx on public.lexiaa_profiles(nextgen_joined_at desc);
