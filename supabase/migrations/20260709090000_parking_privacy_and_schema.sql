-- Keep exact parked-car coordinates private while preserving anonymous,
-- confidence-aware occupancy reporting.

alter table public.event_parking_lots
  add column if not exists price numeric check (price is null or price >= 0),
  add column if not exists currency text;
-- A report's lot must belong to the same event as the report.
create unique index if not exists idx_event_parking_lots_event_id_id
  on public.event_parking_lots (event_id, id);
alter table public.parking_reports
  drop constraint if exists parking_reports_event_lot_fkey;
alter table public.parking_reports
  add constraint parking_reports_event_lot_fkey
  foreign key (event_id, lot_id)
  references public.event_parking_lots (event_id, id)
  on delete cascade;
-- Raw reports contain exact car coordinates and are visible only to their
-- owner. Occupancy consumers use the anonymizing RPC below.
drop policy if exists parking_reports_select_all on public.parking_reports;
drop policy if exists parking_reports_select_own on public.parking_reports;
create policy parking_reports_select_own
  on public.parking_reports
  for select
  using (auth.uid() = user_id);
create or replace function public.get_event_parking_reports(
  p_event_id uuid,
  p_since timestamp with time zone
)
returns table (
  id uuid,
  lot_id uuid,
  reporter_key text,
  kind text,
  car_lat double precision,
  car_lng double precision,
  level text,
  "row" text,
  space text,
  created_at timestamp with time zone,
  is_mine boolean
)
language sql
stable
security definer
set search_path = public
as $$
  select
    r.id,
    r.lot_id,
    md5(r.user_id::text || ':' || r.event_id::text) as reporter_key,
    r.kind,
    case when r.user_id = auth.uid() then r.car_lat else null end,
    case when r.user_id = auth.uid() then r.car_lng else null end,
    case when r.user_id = auth.uid() then r.level else null end,
    case when r.user_id = auth.uid() then r."row" else null end,
    case when r.user_id = auth.uid() then r.space else null end,
    r.created_at,
    r.user_id = auth.uid() as is_mine
  from public.parking_reports r
  where r.event_id = p_event_id
    and r.created_at >= greatest(p_since, now() - interval '24 hours')
  order by r.created_at desc
  limit 5000;
$$;
revoke all on function public.get_event_parking_reports(uuid, timestamp with time zone) from public;
grant execute on function public.get_event_parking_reports(uuid, timestamp with time zone)
  to anon, authenticated, service_role;
-- Include the new commercial fields in partner saves.
create or replace function public.save_partner_parking_lots(p_token text, p_lots jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_event_id uuid;
  v_keep uuid[];
begin
  select id into v_event_id from public.events where partner_access_token = p_token;
  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  select coalesce(array_agg((elem->>'id')::uuid), '{}')
    into v_keep
    from jsonb_array_elements(coalesce(p_lots, '[]'::jsonb)) elem
   where coalesce(elem->>'id', '') <> '';

  delete from public.event_parking_lots
   where event_id = v_event_id
     and not (id = any(v_keep));

  insert into public.event_parking_lots as l
    (id, event_id, name, x, y, lat, lng, capacity, status_override, sort_order, price, currency)
  select
    coalesce(nullif(elem->>'id', '')::uuid, gen_random_uuid()),
    v_event_id,
    coalesce(nullif(elem->>'name', ''), 'Parking'),
    nullif(elem->>'x', '')::numeric,
    nullif(elem->>'y', '')::numeric,
    nullif(elem->>'lat', '')::double precision,
    nullif(elem->>'lng', '')::double precision,
    nullif(elem->>'capacity', '')::integer,
    nullif(elem->>'status_override', ''),
    coalesce(nullif(elem->>'sort_order', '')::integer, 0),
    nullif(elem->>'price', '')::numeric,
    upper(nullif(elem->>'currency', ''))
  from jsonb_array_elements(coalesce(p_lots, '[]'::jsonb)) elem
  on conflict (id) do update
    set name = excluded.name,
        x = excluded.x,
        y = excluded.y,
        lat = excluded.lat,
        lng = excluded.lng,
        capacity = excluded.capacity,
        status_override = excluded.status_override,
        sort_order = excluded.sort_order,
        price = excluded.price,
        currency = excluded.currency
  where l.event_id = v_event_id;

  return jsonb_build_object('ok', true, 'event_id', v_event_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;
