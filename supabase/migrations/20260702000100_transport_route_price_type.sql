-- Add price and type fields to event transportation routes.

alter table public.event_transport_routes
  add column if not exists transport_type text,
  add column if not exists price text;

drop function if exists public.upsert_transport_route(text, uuid, text, text, text, text);

create or replace function public.upsert_transport_route(
  p_token     text,
  p_id        uuid default null,
  p_name      text default null,
  p_color     text default '#0a7aff',
  p_direction text default 'both',
  p_frequency text default null,
  p_transport_type text default null,
  p_price     text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid; v_id uuid;
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  if p_name is null or btrim(p_name) = '' then
    return jsonb_build_object('ok', false, 'error', 'name_required');
  end if;
  if p_direction not in ('both', 'to_event', 'return') then
    return jsonb_build_object('ok', false, 'error', 'invalid_direction');
  end if;

  if p_id is null then
    insert into public.event_transport_routes (event_id, name, color, direction, frequency, transport_type, price)
         values (v_event_id, p_name, coalesce(p_color, '#0a7aff'), p_direction, p_frequency, nullif(btrim(p_transport_type), ''), nullif(btrim(p_price), ''))
      returning id into v_id;
  else
    update public.event_transport_routes
       set name      = coalesce(p_name,      name),
           color     = coalesce(p_color,     color),
           direction = coalesce(p_direction, direction),
           frequency = coalesce(p_frequency, frequency),
           transport_type = nullif(btrim(p_transport_type), ''),
           price = nullif(btrim(p_price), '')
     where id = p_id and event_id = v_event_id
     returning id into v_id;
    if v_id is null then return jsonb_build_object('ok', false, 'error', 'not_on_event'); end if;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;

grant execute on function public.upsert_transport_route(text, uuid, text, text, text, text, text, text)
  to anon, authenticated;

create or replace function public.get_partner_event_extras_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id   uuid;
  v_event_type text;
begin
  select id, event_type
    into v_event_id, v_event_type
    from public.events
   where partner_access_token = p_token;

  if v_event_id is null then
    return null;
  end if;

  return jsonb_build_object(
    'ticket_locations', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',            tl.id,
          'name',          tl.name,
          'address',       tl.address,
          'parish',        tl.parish,
          'town',          tl.town,
          'contact_phone', tl.contact_phone,
          'opening_hours', tl.opening_hours,
          'is_online',     tl.is_online,
          'provider_type', tl.provider_type,
          'ticket_url',    tl.ticket_url,
          'logo_url',      tl.logo_url,
          'latitude',      tl.latitude,
          'longitude',     tl.longitude,
          'place_slug',    tl.place_slug,
          'place_name',    (select name from public.places where slug = tl.place_slug)
        )
        order by tl.display_order, tl.created_at
      )
      from public.ticket_locations tl
      where tl.event_id = v_event_id and coalesce(tl.is_active, true)
    ), '[]'::jsonb),

    'transport_routes', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',             r.id,
          'name',           r.name,
          'transport_type', r.transport_type,
          'price',          r.price,
          'color',          r.color,
          'direction',      r.direction,
          'frequency',      r.frequency,
          'stops_count',    (select count(*) from public.event_transport_stops s where s.route_id = r.id)
        )
        order by r.display_order, r.created_at
      )
      from public.event_transport_routes r
      where r.event_id = v_event_id
    ), '[]'::jsonb),

    'schedule_days', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',             d.id,
          'date',           d.date,
          'date_display',   d.date_display,
          'label',          d.label,
          'description',    d.description,
          'gates_open',     d.gates_open,
          'gates_close',    d.gates_close,
          'is_cancelled',   d.is_cancelled,
          'day_number',     d.day_number,
          'items_count',    (select count(*) from public.event_schedule_items i where i.day_id = d.id),
          'must_see_count', (select count(*) from public.event_schedule_items i where i.day_id = d.id and i.is_must_see = true)
        )
        order by d.date
      )
      from public.event_schedule_days d
      where d.event_id = v_event_id
    ), '[]'::jsonb),

    'schedule_items', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',             i.id,
          'day_id',         i.day_id,
          'title',          i.title,
          'subtitle',       i.subtitle,
          'start_time',     i.start_time,
          'end_time',       i.end_time,
          'venue_override', i.venue_override,
          'category',       i.category,
          'image_url',      i.image_url,
          'is_featured',    i.is_featured,
          'is_must_see',    i.is_must_see,
          'is_published',   i.is_published,
          'display_order',  i.display_order
        )
        order by i.display_order nulls last, i.start_time nulls last, i.title
      )
      from public.event_schedule_items i
      where i.event_id = v_event_id
    ), '[]'::jsonb),

    'bands', case
      when lower(coalesce(v_event_type, '')) = 'carnival' then
        coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'id',                     mb.id,
              'name',                   mb.name,
              'slug',                   mb.slug,
              'tagline',                mb.tagline,
              'logo_url',               mb.logo_url,
              'cover_url',              mb.cover_url,
              'website_url',            mb.website_url,
              'registration_deadline',  mb.registration_deadline,
              'registration_url',       mb.registration_url
            )
            order by mb.sort_order, mb.name
          )
          from public.mas_bands mb
          where mb.season_id = v_event_id
        ), '[]'::jsonb)
      else null
    end
  );
end;
$$;

grant execute on function public.get_partner_event_extras_by_token(text) to anon, authenticated;
