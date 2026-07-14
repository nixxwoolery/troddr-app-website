-- Event parking capacity: organizer-owned lots + append-only user reports.

create table if not exists public.event_parking_lots (
  id              uuid primary key default gen_random_uuid(),
  event_id        uuid not null references public.events(id) on delete cascade,
  name            text not null,
  x               numeric,
  y               numeric,
  lat             double precision,
  lng             double precision,
  capacity        integer check (capacity is null or capacity >= 0),
  status_override text check (
    status_override is null
    or status_override in ('available', 'filling', 'nearly_full', 'full', 'closed')
  ),
  sort_order      integer not null default 0,
  created_at      timestamp with time zone not null default now()
);

alter table public.event_parking_lots owner to postgres;

create index if not exists idx_event_parking_lots_event
  on public.event_parking_lots using btree (event_id);

alter table public.event_parking_lots enable row level security;

drop policy if exists event_parking_lots_public_read on public.event_parking_lots;
create policy event_parking_lots_public_read
  on public.event_parking_lots for select using (true);

grant all on table public.event_parking_lots to anon;
grant all on table public.event_parking_lots to authenticated;
grant all on table public.event_parking_lots to service_role;

create table if not exists public.parking_reports (
  id          uuid primary key default gen_random_uuid(),
  event_id    uuid not null references public.events(id) on delete cascade,
  lot_id      uuid not null references public.event_parking_lots(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  kind        text not null check (kind in ('parked', 'left', 'full', 'spaces')),
  car_lat     double precision,
  car_lng     double precision,
  level       text,
  "row"       text,
  space       text,
  created_at  timestamp with time zone not null default now()
);

alter table public.parking_reports owner to postgres;
alter table public.parking_reports replica identity full;

create index if not exists idx_parking_reports_event_created
  on public.parking_reports using btree (event_id, created_at desc);
create index if not exists idx_parking_reports_event_lot
  on public.parking_reports using btree (event_id, lot_id);
create index if not exists idx_parking_reports_event_user_created
  on public.parking_reports using btree (event_id, user_id, created_at desc);

create or replace function public._parking_reports_set_created_at()
returns trigger
language plpgsql
as $$
begin
  new.created_at := now();
  return new;
end;
$$;

drop trigger if exists parking_reports_set_created_at on public.parking_reports;
create trigger parking_reports_set_created_at
  before insert on public.parking_reports
  for each row execute function public._parking_reports_set_created_at();

alter table public.parking_reports enable row level security;

drop policy if exists parking_reports_select_all on public.parking_reports;
create policy parking_reports_select_all
  on public.parking_reports for select using (true);

drop policy if exists parking_reports_insert_own on public.parking_reports;
create policy parking_reports_insert_own
  on public.parking_reports for insert with check (auth.uid() = user_id);

drop policy if exists parking_reports_update_own on public.parking_reports;
create policy parking_reports_update_own
  on public.parking_reports for update using (auth.uid() = user_id) with check (auth.uid() = user_id);

drop policy if exists parking_reports_delete_own on public.parking_reports;
create policy parking_reports_delete_own
  on public.parking_reports for delete using (auth.uid() = user_id);

grant all on table public.parking_reports to anon;
grant all on table public.parking_reports to authenticated;
grant all on table public.parking_reports to service_role;

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'parking_reports'
     )
  then
    alter publication supabase_realtime add table public.parking_reports;
  end if;
end $$;;
