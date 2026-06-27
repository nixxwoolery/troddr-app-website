-- ============================================================
-- partner-event-extras : RPC returning the additional data sets
-- needed by the new event dashboard sections (Tickets, Transportation,
-- Bands). Kept separate so we don't have to modify the existing
-- get_partner_event_by_token RPC.
--
-- The client (partner-event.html) calls this in addition to
-- get_partner_event_by_token and merges the result.
-- Each section degrades gracefully if this RPC is missing.
-- ============================================================

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
          'id',          r.id,
          'name',        r.name,
          'color',       r.color,
          'direction',   r.direction,
          'frequency',   r.frequency,
          'stops_count', (select count(*) from public.event_transport_stops s where s.route_id = r.id)
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

comment on function public.get_partner_event_extras_by_token(text) is
  'Supplementary data for the partner-event dashboard: ticket_locations, transport_routes, schedule_days, schedule_items, and (for carnivals) mas_bands. Kept separate from get_partner_event_by_token so the main RPC stays untouched.';
