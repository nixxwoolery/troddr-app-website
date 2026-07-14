-- Promoter-controlled presentation plus Waze-style qualitative reports.
alter table public.event_parking_lots
  add column if not exists tier text,
  add column if not exists show_vehicle_count boolean not null default false;
alter table public.parking_reports
  drop constraint if exists parking_reports_kind_check;
alter table public.parking_reports
  add constraint parking_reports_kind_check
  check (kind in (
    'parked', 'left',
    'spaces', 'available', 'filling', 'almost_full', 'full'
  ));
-- Give the existing Sumfest products stable lot identities. The promoter can
-- edit names, positions, capacities, prices and visibility from the dashboard.
update public.event_parking_lots
   set name = 'Silver Parking 1', tier = 'silver', price = 10, currency = 'USD'
 where event_id = '3109c96c-6144-434b-918a-aca3cb0c2f46'
   and lower(name) = 'silver parking';
update public.event_parking_lots
   set name = 'Gold Parking 1', tier = 'gold', price = 25, currency = 'USD'
 where event_id = '3109c96c-6144-434b-918a-aca3cb0c2f46'
   and lower(name) = 'gold parking';
update public.event_parking_lots
   set tier = 'medallion', price = 200, currency = 'USD'
 where event_id = '3109c96c-6144-434b-918a-aca3cb0c2f46'
   and lower(name) = 'medallion';
insert into public.event_parking_lots
  (event_id, name, tier, price, currency, sort_order)
select
  '3109c96c-6144-434b-918a-aca3cb0c2f46',
  'Silver Parking 2',
  'silver',
  10,
  'USD',
  2
where not exists (
  select 1 from public.event_parking_lots
   where event_id = '3109c96c-6144-434b-918a-aca3cb0c2f46'
     and lower(name) = 'silver parking 2'
);
insert into public.event_parking_lots
  (event_id, name, tier, price, currency, sort_order)
select
  '3109c96c-6144-434b-918a-aca3cb0c2f46',
  'Gold Parking 2',
  'gold',
  25,
  'USD',
  4
where not exists (
  select 1 from public.event_parking_lots
   where event_id = '3109c96c-6144-434b-918a-aca3cb0c2f46'
     and lower(name) = 'gold parking 2'
);
-- Partner saves now carry every editable lot field.
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
    (id, event_id, name, tier, x, y, lat, lng, capacity, status_override,
     show_vehicle_count, sort_order, price, currency)
  select
    coalesce(nullif(elem->>'id', '')::uuid, gen_random_uuid()),
    v_event_id,
    coalesce(nullif(elem->>'name', ''), 'Parking'),
    nullif(elem->>'tier', ''),
    nullif(elem->>'x', '')::numeric,
    nullif(elem->>'y', '')::numeric,
    nullif(elem->>'lat', '')::double precision,
    nullif(elem->>'lng', '')::double precision,
    nullif(elem->>'capacity', '')::integer,
    nullif(elem->>'status_override', ''),
    coalesce((elem->>'show_vehicle_count')::boolean, false),
    coalesce(nullif(elem->>'sort_order', '')::integer, 0),
    nullif(elem->>'price', '')::numeric,
    upper(nullif(elem->>'currency', ''))
  from jsonb_array_elements(coalesce(p_lots, '[]'::jsonb)) elem
  on conflict (id) do update
    set name = excluded.name,
        tier = excluded.tier,
        x = excluded.x,
        y = excluded.y,
        lat = excluded.lat,
        lng = excluded.lng,
        capacity = excluded.capacity,
        status_override = excluded.status_override,
        show_vehicle_count = excluded.show_vehicle_count,
        sort_order = excluded.sort_order,
        price = excluded.price,
        currency = excluded.currency
  where l.event_id = v_event_id;

  return jsonb_build_object('ok', true, 'event_id', v_event_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;
