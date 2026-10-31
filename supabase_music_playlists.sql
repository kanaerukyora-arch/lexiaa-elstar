-- LEXIAA MUSIC PLAYLISTS
-- Jalankan sekali di Supabase SQL Editor pada project yang sama dengan website utama.
create table if not exists public.music_playlists (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  description text,
  spotify_url text not null,
  cover_url text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint music_playlists_spotify_url_check
    check (spotify_url ~* '^https?://(open[.])?spotify[.]com/playlist/[A-Za-z0-9]+')
);

alter table public.music_playlists enable row level security;

drop policy if exists "Public can read active music playlists" on public.music_playlists;
create policy "Public can read active music playlists"
on public.music_playlists for select
to anon, authenticated
using (is_active = true);

-- Ganti email berikut jika email admin di Admin Studio berbeda.
drop policy if exists "LEXIAA admin can read all playlists" on public.music_playlists;
create policy "LEXIAA admin can read all playlists"
on public.music_playlists for select
to authenticated
using ((auth.jwt() ->> 'email') = 'fathanmufadhil04@gmail.com');

drop policy if exists "LEXIAA admin can insert playlists" on public.music_playlists;
create policy "LEXIAA admin can insert playlists"
on public.music_playlists for insert
to authenticated
with check ((auth.jwt() ->> 'email') = 'fathanmufadhil04@gmail.com');

drop policy if exists "LEXIAA admin can update playlists" on public.music_playlists;
create policy "LEXIAA admin can update playlists"
on public.music_playlists for update
to authenticated
using ((auth.jwt() ->> 'email') = 'fathanmufadhil04@gmail.com')
with check ((auth.jwt() ->> 'email') = 'fathanmufadhil04@gmail.com');

drop policy if exists "LEXIAA admin can delete playlists" on public.music_playlists;
create policy "LEXIAA admin can delete playlists"
on public.music_playlists for delete
to authenticated
using ((auth.jwt() ->> 'email') = 'fathanmufadhil04@gmail.com');

grant select on public.music_playlists to anon, authenticated;
grant insert, update, delete on public.music_playlists to authenticated;

-- Contoh data uji:
-- insert into public.music_playlists (title, description, spotify_url, cover_url)
-- values ('LEXIAA NIGHT VIBES', 'Playlist pilihan LEXIAA', 'https://open.spotify.com/playlist/ID_PLAYLIST', null);
