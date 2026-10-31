-- LEXIAA MUSIC PLAYLISTS
-- Jalankan di Supabase SQL Editor pada project yang sama dengan website utama.
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
    check (spotify_url ~* '^https?://(open\\.)?spotify\\.com/(playlist|album)/[A-Za-z0-9]+')
);

alter table public.music_playlists enable row level security;

drop policy if exists "Public can read active music playlists" on public.music_playlists;
create policy "Public can read active music playlists"
on public.music_playlists for select
to anon, authenticated
using (is_active = true);

-- Tidak ada policy INSERT/UPDATE/DELETE untuk anon/authenticated.
-- Penambahan dan pengelolaan playlist dilakukan oleh admin melalui sesi admin tepercaya.
grant select on public.music_playlists to anon, authenticated;

-- Contoh data uji (ganti URL dengan playlist Spotify milik admin):
-- insert into public.music_playlists (title, description, spotify_url, cover_url)
-- values ('LEXIAA NIGHT VIBES', 'Playlist pilihan LEXIAA', 'https://open.spotify.com/playlist/ID_PLAYLIST', null);
