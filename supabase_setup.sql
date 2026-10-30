-- LEXIAA & ELSTAR — Supabase setup
-- 1) Ganti fathanmufadhil04@gmail.com dengan email akun Supabase yang akan jadi admin.
-- 2) Jalankan seluruh SQL ini di Supabase Dashboard > SQL Editor.
-- 3) Bucket privat agar media member tidak bisa diakses hanya dengan URL publik.

create extension if not exists pgcrypto;

create table if not exists public.site_media (
  id uuid primary key default gen_random_uuid(),
  section text not null check (section in ('penemuan','secret','member')),
  title text not null,
  storage_path text not null unique,
  media_type text not null check (media_type in ('image','video')),
  created_at timestamptz not null default now()
);

create table if not exists public.member_access (
  user_id uuid primary key references auth.users(id) on delete cascade,
  granted_at timestamptz not null default now()
);

alter table public.site_media enable row level security;
alter table public.member_access enable row level security;

drop policy if exists "site media read sections" on public.site_media;
create policy "site media read sections" on public.site_media
for select to authenticated
using (
  section in ('penemuan','secret')
  or exists (select 1 from public.member_access ma where ma.user_id = auth.uid())
  or (auth.jwt() ->> 'email') = 'fathanmufadhil04@gmail.com'
);

drop policy if exists "admin insert media" on public.site_media;
create policy "admin insert media" on public.site_media
for insert to authenticated
with check ((auth.jwt() ->> 'email') = 'fathanmufadhil04@gmail.com');

drop policy if exists "admin update media" on public.site_media;
create policy "admin update media" on public.site_media
for update to authenticated
using ((auth.jwt() ->> 'email') = 'fathanmufadhil04@gmail.com')
with check ((auth.jwt() ->> 'email') = 'fathanmufadhil04@gmail.com');

drop policy if exists "admin delete media" on public.site_media;
create policy "admin delete media" on public.site_media
for delete to authenticated
using ((auth.jwt() ->> 'email') = 'fathanmufadhil04@gmail.com');

drop policy if exists "member reads own access" on public.member_access;
create policy "member reads own access" on public.member_access
for select to authenticated
using (user_id = auth.uid() or (auth.jwt() ->> 'email') = 'fathanmufadhil04@gmail.com');

-- Member code is checked on the server, not in the browser JavaScript.
create or replace function public.verify_member_code(p_code text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'Login diperlukan untuk mengaktifkan akses member.';
  end if;

  if p_code is distinct from '999666' then
    return false;
  end if;

  insert into public.member_access(user_id)
  values (auth.uid())
  on conflict (user_id) do nothing;

  return true;
end;
$$;

revoke all on function public.verify_member_code(text) from public;
grant execute on function public.verify_member_code(text) to authenticated;

-- Private bucket. If it already exists, this updates its privacy setting.
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values (
  'lexiaa-media',
  'lexiaa-media',
  false,
  52428800,
  array['image/jpeg','image/png','image/webp','image/gif','image/avif','video/mp4','video/webm','video/quicktime']
)
on conflict (id) do update set
  public = false,
  file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

drop policy if exists "admin uploads lexiaa media" on storage.objects;
create policy "admin uploads lexiaa media" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'lexiaa-media'
  and (auth.jwt() ->> 'email') = 'fathanmufadhil04@gmail.com'
);

drop policy if exists "authorized reads lexiaa media" on storage.objects;
create policy "authorized reads lexiaa media" on storage.objects
for select to authenticated
using (
  bucket_id = 'lexiaa-media'
  and (
    (auth.jwt() ->> 'email') = 'fathanmufadhil04@gmail.com'
    or split_part(name, '/', 1) in ('penemuan','secret')
    or (
      split_part(name, '/', 1) = 'member'
      and exists (select 1 from public.member_access ma where ma.user_id = auth.uid())
    )
  )
);

drop policy if exists "admin deletes lexiaa media" on storage.objects;
create policy "admin deletes lexiaa media" on storage.objects
for delete to authenticated
using (
  bucket_id = 'lexiaa-media'
  and (auth.jwt() ->> 'email') = 'fathanmufadhil04@gmail.com'
);

drop policy if exists "admin updates lexiaa media" on storage.objects;
create policy "admin updates lexiaa media" on storage.objects
for update to authenticated
using (
  bucket_id = 'lexiaa-media'
  and (auth.jwt() ->> 'email') = 'fathanmufadhil04@gmail.com'
)
with check (
  bucket_id = 'lexiaa-media'
  and (auth.jwt() ->> 'email') = 'fathanmufadhil04@gmail.com'
);
