-- Optional eyewitness count for "spaces available" reports. This is never
-- treated as an authoritative live capacity.
alter table public.parking_reports
  add column if not exists available_spaces integer
  check (available_spaces is null or available_spaces between 1 and 10000);
-- Published Sumfest parking products.
update public.event_parking_lots
   set price = case lower(name)
                 when 'silver parking' then 10
                 when 'gold parking' then 25
                 when 'medallion' then 200
               end,
       currency = 'USD'
 where event_id = '3109c96c-6144-434b-918a-aca3cb0c2f46'
   and lower(name) in ('silver parking', 'gold parking', 'medallion');
drop function if exists public.get_event_parking_reports(uuid, timestamp with time zone);
create function public.get_event_parking_reports(
  p_event_id uuid,
  p_since timestamp with time zone
)
returns table (
  id uuid,
  lot_id uuid,
  reporter_key text,
  kind text,
  available_spaces integer,
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
    md5(r.user_id::text || ':' || r.event_id::text),
    r.kind,
    r.available_spaces,
    case when r.user_id = auth.uid() then r.car_lat else null end,
    case when r.user_id = auth.uid() then r.car_lng else null end,
    case when r.user_id = auth.uid() then r.level else null end,
    case when r.user_id = auth.uid() then r."row" else null end,
    case when r.user_id = auth.uid() then r.space else null end,
    r.created_at,
    r.user_id = auth.uid()
  from public.parking_reports r
  where r.event_id = p_event_id
    and r.created_at >= greatest(p_since, now() - interval '24 hours')
  order by r.created_at desc
  limit 5000;
$$;
revoke all on function public.get_event_parking_reports(uuid, timestamp with time zone) from public;
grant execute on function public.get_event_parking_reports(uuid, timestamp with time zone)
  to anon, authenticated, service_role;
