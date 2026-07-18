-- Optional, event-specific GPS coordinates for temporary vendor placements.
alter table public.event_vendors
  add column if not exists latitude numeric,
  add column if not exists longitude numeric;

alter table public.event_vendors
  drop constraint if exists event_vendors_latitude_check,
  drop constraint if exists event_vendors_longitude_check;

alter table public.event_vendors
  add constraint event_vendors_latitude_check check (latitude is null or latitude between -90 and 90),
  add constraint event_vendors_longitude_check check (longitude is null or longitude between -180 and 180);

create or replace function public.get_event_vendor_coordinates(
  p_token text,
  p_event_vendor_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_latitude numeric;
  v_longitude numeric;
begin
  select ev.latitude, ev.longitude
    into v_latitude, v_longitude
    from public.event_vendors ev
    join public.events e on e.id = ev.event_id
   where ev.id = p_event_vendor_id
     and e.partner_access_token = p_token;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'vendor_not_found_for_event');
  end if;

  return jsonb_build_object('ok', true, 'latitude', v_latitude, 'longitude', v_longitude);
end;
$$;

create or replace function public.set_event_vendor_coordinates(
  p_token text,
  p_event_vendor_id uuid,
  p_latitude numeric default null,
  p_longitude numeric default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
begin
  if (p_latitude is null) <> (p_longitude is null) then
    return jsonb_build_object('ok', false, 'error', 'both_coordinates_required');
  end if;
  if p_latitude is not null and (p_latitude < -90 or p_latitude > 90 or p_longitude < -180 or p_longitude > 180) then
    return jsonb_build_object('ok', false, 'error', 'invalid_coordinates');
  end if;

  select ev.event_id into v_event_id
    from public.event_vendors ev
    join public.events e on e.id = ev.event_id
   where ev.id = p_event_vendor_id
     and e.partner_access_token = p_token
   for update of ev;

  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'vendor_not_found_for_event');
  end if;

  update public.event_vendors
     set latitude = p_latitude,
         longitude = p_longitude,
         updated_at = now()
   where id = p_event_vendor_id and event_id = v_event_id;

  return jsonb_build_object('ok', true, 'event_vendor_id', p_event_vendor_id,
                            'latitude', p_latitude, 'longitude', p_longitude);
end;
$$;

grant execute on function public.get_event_vendor_coordinates(text, uuid) to anon, authenticated;
grant execute on function public.set_event_vendor_coordinates(text, uuid, numeric, numeric) to anon, authenticated;

comment on column public.event_vendors.latitude is 'Optional event-specific GPS latitude for this vendor placement.';
comment on column public.event_vendors.longitude is 'Optional event-specific GPS longitude for this vendor placement.';
