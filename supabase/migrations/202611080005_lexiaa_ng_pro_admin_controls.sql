-- Admin controls for existing LEXIAA N.G Pro memberships.
alter table public.ng_pro_memberships
  add column if not exists admin_note text;

comment on column public.ng_pro_memberships.admin_note is
  'Catatan admin saat mengubah masa aktif atau menonaktifkan keanggotaan Pro.';
