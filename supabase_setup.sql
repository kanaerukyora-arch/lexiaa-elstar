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

-- LEXIAA origin story: one-time code, bound to the authenticated Supabase user.
create table if not exists public.lexiaa_origin_codes (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  code_hash text not null unique,
  status text not null default 'issued' check (status in ('issued','used','expired')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default (now() + interval '10 minutes'),
  used_at timestamptz
);
alter table public.lexiaa_origin_codes enable row level security;
revoke all on public.lexiaa_origin_codes from anon, authenticated;

create or replace function public.lexiaa_issue_origin_code()
returns text
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  v_code text;
  v_hash text;
begin
  if v_uid is null then raise exception 'Login diperlukan.'; end if;
  update public.lexiaa_origin_codes
    set status='expired'
    where user_id=v_uid and status='issued';
  loop
    v_code := upper(substr(encode(gen_random_bytes(8),'hex'),1,8));
    v_hash := encode(digest(v_code,'sha256'),'hex');
    begin
      insert into public.lexiaa_origin_codes(user_id,code_hash,expires_at)
      values(v_uid,v_hash,now()+interval '10 minutes');
      exit;
    exception when unique_violation then
      -- Generate another code if the random value ever collides.
    end;
  end loop;
  return v_code;
end;
$$;

create or replace function public.lexiaa_consume_origin_code(p_code text)
returns boolean
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_uid uuid := auth.uid();
  v_hash text;
  v_rows integer;
begin
  if v_uid is null then raise exception 'Login diperlukan.'; end if;
  if p_code is null or length(trim(p_code)) <> 8 then return false; end if;
  v_hash := encode(digest(upper(trim(p_code)),'sha256'),'hex');
  update public.lexiaa_origin_codes
    set status='used', used_at=now()
    where user_id=v_uid and code_hash=v_hash
      and status='issued' and expires_at>now();
  get diagnostics v_rows = row_count;
  return v_rows = 1;
end;
$$;
revoke all on function public.lexiaa_issue_origin_code() from public;
revoke all on function public.lexiaa_consume_origin_code(text) from public;
grant execute on function public.lexiaa_issue_origin_code() to authenticated;
grant execute on function public.lexiaa_consume_origin_code(text) to authenticated;
