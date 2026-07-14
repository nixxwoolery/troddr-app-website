-- Partner parking-lot management RPCs (anon key + SECURITY DEFINER token auth).

create or replace function public.get_partner_parking(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_event_id uuid;
  v_event    jsonb;
  v_lots     jsonb;
begin
  select id into v_event_id from public.events where partner_access_token = p_token;
  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  select jsonb_build_object(
           'id', e.id,
           'slug', e.slug,
           'title', e.title,
           'floor_plan_url', e.floor_plan_url,
           'map_calibration', e.map_calibration
         )
    into v_event
    from public.events e
   where e.id = v_event_id;

  select coalesce(jsonb_agg(to_jsonb(l) order by l.sort_order, l.created_at), '[]'::jsonb)
    into v_lots
    from public.event_parking_lots l
   where l.event_id = v_event_id;

  return jsonb_build_object('ok', true, 'event', v_event, 'lots', v_lots);
end;
$$;

alter function public.get_partner_parking(text) owner to postgres;

create or replace function public.save_partner_parking_lots(p_token text, p_lots jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_event_id uuid;
  v_keep     uuid[];
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
    (id, event_id, name, x, y, lat, lng, capacity, status_override, sort_order)
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
    coalesce(nullif(elem->>'sort_order', '')::integer, 0)
  from jsonb_array_elements(coalesce(p_lots, '[]'::jsonb)) elem
  on conflict (id) do update
    set name            = excluded.name,
        x               = excluded.x,
        y               = excluded.y,
        lat             = excluded.lat,
        lng             = excluded.lng,
        capacity        = excluded.capacity,
        status_override = excluded.status_override,
        sort_order      = excluded.sort_order;

  return jsonb_build_object('ok', true, 'event_id', v_event_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;

alter function public.save_partner_parking_lots(text, jsonb) owner to postgres;

grant execute on function public.get_partner_parking(text) to anon, authenticated, service_role;
grant execute on function public.save_partner_parking_lots(text, jsonb) to anon, authenticated, service_role;;
