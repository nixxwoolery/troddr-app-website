-- Extend the partner save RPC to persist price + currency alongside the lot.
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
    coalesce(nullif(elem->>'currency', ''), 'USD')
  from jsonb_array_elements(coalesce(p_lots, '[]'::jsonb)) elem
  on conflict (id) do update
    set name            = excluded.name,
        x               = excluded.x,
        y               = excluded.y,
        lat             = excluded.lat,
        lng             = excluded.lng,
        capacity        = excluded.capacity,
        status_override = excluded.status_override,
        sort_order      = excluded.sort_order,
        price           = excluded.price,
        currency        = excluded.currency;

  return jsonb_build_object('ok', true, 'event_id', v_event_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;;
