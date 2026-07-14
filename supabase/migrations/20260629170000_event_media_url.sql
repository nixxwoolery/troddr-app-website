alter table public.events
  add column if not exists media_url text;
comment on column public.events.media_url is
  'Public event media URL used by the app Home tab media player when no photo gallery is available.';
