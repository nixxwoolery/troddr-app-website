-- Event parking lot display options
-- Lets promoters decide which parking details are visible to guests.

alter table public.event_parking_lots
  add column if not exists show_status boolean not null default true,
  add column if not exists show_capacity boolean not null default true,
  add column if not exists show_price boolean not null default true,
  add column if not exists show_vehicle_count boolean not null default false;

update public.event_parking_lots
   set show_status = coalesce(show_status, true),
       show_capacity = coalesce(show_capacity, true),
       show_price = coalesce(show_price, true),
       show_vehicle_count = coalesce(show_vehicle_count, false);

alter table public.event_parking_lots
  alter column show_status set default true,
  alter column show_status set not null,
  alter column show_capacity set default true,
  alter column show_capacity set not null,
  alter column show_price set default true,
  alter column show_price set not null,
  alter column show_vehicle_count set default false,
  alter column show_vehicle_count set not null;

create or replace function public.get_partner_parking(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event record;
begin
  select *
    into v_event
    from public.events
   where partner_access_token = p_token
   limit 1;

  if v_event.id is null then
    return jsonb_build_object('ok', false, 'error', 'event_not_found');
  end if;

  return jsonb_build_object(
    'ok', true,
    'event', jsonb_build_object(
      'id', v_event.id,
      'slug', v_event.slug,
      'title', v_event.title,
      'parking_image_url', v_event.parking_image_url,
      'parking_image_urls', coalesce(v_event.parking_image_urls, '[]'::jsonb)
    ),
    'lots', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', l.id,
        'name', l.name,
        'capacity', l.capacity,
        'status_override', l.status_override,
        'x', l.x,
        'y', l.y,
        'lat', l.lat,
        'lng', l.lng,
        'price', l.price,
        'currency', l.currency,
        'tier', l.tier,
        'show_vehicle_count', coalesce(l.show_vehicle_count, false),
        'show_status', coalesce(l.show_status, true),
        'show_capacity', coalesce(l.show_capacity, true),
        'show_price', coalesce(l.show_price, true),
        'sort_order', l.sort_order
      ) order by l.sort_order nulls last, l.created_at, l.name)
      from public.event_parking_lots l
      where l.event_id = v_event.id
    ), '[]'::jsonb)
  );
end;
$$;

create or replace function public.save_partner_parking_lots(p_token text, p_lots jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
  v_lot jsonb;
  v_id uuid;
  v_seen uuid[] := array[]::uuid[];
begin
  select id
    into v_event_id
    from public.events
   where partner_access_token = p_token
   limit 1;

  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'event_not_found');
  end if;

  if jsonb_typeof(coalesce(p_lots, '[]'::jsonb)) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'lots_must_be_array');
  end if;

  for v_lot in select * from jsonb_array_elements(coalesce(p_lots, '[]'::jsonb))
  loop
    v_id := coalesce(nullif(v_lot->>'id', '')::uuid, gen_random_uuid());
    v_seen := array_append(v_seen, v_id);

    insert into public.event_parking_lots (
      id, event_id, name, capacity, status_override, x, y, lat, lng,
      price, currency, tier, show_vehicle_count, show_status, show_capacity,
      show_price, sort_order
    )
    values (
      v_id,
      v_event_id,
      coalesce(nullif(btrim(v_lot->>'name'), ''), 'Parking'),
      nullif(v_lot->>'capacity', '')::integer,
      nullif(v_lot->>'status_override', ''),
      nullif(v_lot->>'x', '')::double precision,
      nullif(v_lot->>'y', '')::double precision,
      nullif(v_lot->>'lat', '')::double precision,
      nullif(v_lot->>'lng', '')::double precision,
      nullif(v_lot->>'price', '')::numeric,
      coalesce(nullif(btrim(v_lot->>'currency'), ''), 'USD'),
      nullif(btrim(v_lot->>'tier'), ''),
      coalesce((v_lot->>'show_vehicle_count')::boolean, false),
      coalesce((v_lot->>'show_status')::boolean, true),
      coalesce((v_lot->>'show_capacity')::boolean, true),
      coalesce((v_lot->>'show_price')::boolean, true),
      nullif(v_lot->>'sort_order', '')::integer
    )
    on conflict (id) do update set
      name = excluded.name,
      capacity = excluded.capacity,
      status_override = excluded.status_override,
      x = excluded.x,
      y = excluded.y,
      lat = excluded.lat,
      lng = excluded.lng,
      price = excluded.price,
      currency = excluded.currency,
      tier = excluded.tier,
      show_vehicle_count = excluded.show_vehicle_count,
      show_status = excluded.show_status,
      show_capacity = excluded.show_capacity,
      show_price = excluded.show_price,
      sort_order = excluded.sort_order
    where event_parking_lots.event_id = v_event_id;
  end loop;

  delete from public.event_parking_lots
   where event_id = v_event_id
     and not (id = any(v_seen));

  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.get_partner_parking(text) to anon, authenticated;
grant execute on function public.save_partner_parking_lots(text, jsonb) to anon, authenticated;
