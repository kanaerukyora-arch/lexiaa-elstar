-- LEXIAA N.G video preview thumbnails
-- Run once in Supabase SQL Editor after the original video VIP migration.

alter table public.ng_videos
  add column if not exists thumbnail_path text;

update storage.buckets
set allowed_mime_types = array['video/mp4','video/webm','image/jpeg']
where id = 'lexiaa-ng-videos';
