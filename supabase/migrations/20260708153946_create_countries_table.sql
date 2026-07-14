create table if not exists public.countries (
  slug        text primary key,
  name        text not null unique,
  flag_emoji  text,
  center_lat  double precision,
  center_lng  double precision,
  is_live     boolean not null default false,
  sort_order  int not null default 0,
  created_at  timestamptz not null default now()
);

alter table public.countries enable row level security;

-- Countries list is public reference data: anyone can read, no client writes.
create policy "countries_public_read"
  on public.countries for select
  using (true);

-- Seed the current live country.
insert into public.countries (slug, name, flag_emoji, center_lat, center_lng, is_live, sort_order)
values ('jamaica', 'Jamaica', '🇯🇲', 18.1096, -77.2975, true, 0)
on conflict (slug) do nothing;

-- Clean the two bad rows in places so the picker never sees them.
update public.places set country = 'Jamaica'
  where country = 'Jamaicq' or country is null;;
