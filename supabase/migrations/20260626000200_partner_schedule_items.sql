-- Let event partners manage artist/set-time schedule items from the dashboard.

do $$
begin
  if exists (
    select 1
      from information_schema.columns
     where table_schema = 'public'
       and table_name = 'event_schedule_items'
       and column_name = 'track_id'
       and is_nullable = 'NO'
  ) then
    alter table public.event_schedule_items alter column track_id drop not null;
  end if;
end;
$$;

create or replace function public.upsert_schedule_item(
  p_token          text,
  p_id             uuid default null,
  p_day_id         uuid default null,
  p_title          text default null,
  p_subtitle       text default null,
  p_start_time     timestamptz default null,
  p_end_time       timestamptz default null,
  p_venue_override text default null,
  p_category       text default null,
  p_image_url      text default null,
  p_is_featured    boolean default false,
  p_is_must_see    boolean default false,
  p_is_published   boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
  v_id uuid;
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  if coalesce(btrim(p_title), '') = '' then return jsonb_build_object('ok', false, 'error', 'title_required'); end if;
  if p_day_id is null then return jsonb_build_object('ok', false, 'error', 'day_required'); end if;
  if not exists (select 1 from public.event_schedule_days where id = p_day_id and event_id = v_event_id) then
    return jsonb_build_object('ok', false, 'error', 'day_not_on_event');
  end if;

  if p_id is null then
    insert into public.event_schedule_items (
      event_id, day_id, title, subtitle, start_time, end_time, venue_override,
      category, image_url, is_featured, is_must_see, is_published
    )
    values (
      v_event_id, p_day_id, btrim(p_title), nullif(btrim(p_subtitle), ''),
      p_start_time, p_end_time, nullif(btrim(p_venue_override), ''),
      nullif(btrim(p_category), ''), nullif(btrim(p_image_url), ''),
      coalesce(p_is_featured, false), coalesce(p_is_must_see, false),
      coalesce(p_is_published, true)
    )
    returning id into v_id;
  else
    update public.event_schedule_items
       set day_id         = coalesce(p_day_id, day_id),
           title          = coalesce(nullif(btrim(p_title), ''), title),
           subtitle       = case when p_subtitle is not null then nullif(btrim(p_subtitle), '') else subtitle end,
           start_time     = case when p_start_time is not null then p_start_time else start_time end,
           end_time       = case when p_end_time is not null then p_end_time else end_time end,
           venue_override = case when p_venue_override is not null then nullif(btrim(p_venue_override), '') else venue_override end,
           category       = case when p_category is not null then nullif(btrim(p_category), '') else category end,
           image_url      = case when p_image_url is not null then nullif(btrim(p_image_url), '') else image_url end,
           is_featured    = coalesce(p_is_featured, is_featured),
           is_must_see    = coalesce(p_is_must_see, is_must_see),
           is_published   = coalesce(p_is_published, is_published)
     where id = p_id and event_id = v_event_id
     returning id into v_id;
    if v_id is null then return jsonb_build_object('ok', false, 'error', 'item_not_on_event'); end if;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;

grant execute on function public.upsert_schedule_item(
  text, uuid, uuid, text, text, timestamptz, timestamptz, text, text, text, boolean, boolean, boolean
) to anon, authenticated;

create or replace function public.delete_schedule_item(p_token text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_event_id uuid;
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  delete from public.event_schedule_items where id = p_id and event_id = v_event_id;
  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.delete_schedule_item(text, uuid) to anon, authenticated;

create or replace function public.bulk_import_schedule_items(
  p_token text,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
  v_item jsonb;
  v_day_id uuid;
  v_day_date date;
  v_inserted int := 0;
  v_skipped int := 0;
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  if jsonb_typeof(coalesce(p_items, '[]'::jsonb)) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'items_must_be_array');
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    if coalesce(btrim(v_item->>'title'), '') = '' then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    v_day_id := nullif(v_item->>'day_id', '')::uuid;
    if v_day_id is null and nullif(v_item->>'date', '') is not null then
      v_day_date := (v_item->>'date')::date;
      select id into v_day_id
        from public.event_schedule_days
       where event_id = v_event_id and date = v_day_date
       order by created_at
       limit 1;

      if v_day_id is null then
        insert into public.event_schedule_days (event_id, date, label)
        values (v_event_id, v_day_date, nullif(btrim(v_item->>'day_label'), ''))
        returning id into v_day_id;
      end if;
    end if;

    if v_day_id is null or not exists (
      select 1 from public.event_schedule_days where id = v_day_id and event_id = v_event_id
    ) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    insert into public.event_schedule_items (
      event_id, day_id, title, subtitle, start_time, end_time, venue_override,
      category, image_url, is_featured, is_must_see, is_published
    )
    values (
      v_event_id,
      v_day_id,
      btrim(v_item->>'title'),
      nullif(btrim(v_item->>'subtitle'), ''),
      nullif(v_item->>'start_time', '')::timestamptz,
      nullif(v_item->>'end_time', '')::timestamptz,
      nullif(btrim(coalesce(v_item->>'venue_override', v_item->>'stage')), ''),
      nullif(btrim(coalesce(v_item->>'category', 'artist')), ''),
      nullif(btrim(v_item->>'image_url'), ''),
      coalesce((v_item->>'is_featured')::boolean, false),
      coalesce((v_item->>'is_must_see')::boolean, false),
      coalesce((v_item->>'is_published')::boolean, true)
    );
    v_inserted := v_inserted + 1;
  end loop;

  return jsonb_build_object('ok', true, 'inserted', v_inserted, 'skipped', v_skipped);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM, 'inserted', v_inserted, 'skipped', v_skipped);
end;
$$;

grant execute on function public.bulk_import_schedule_items(text, jsonb) to anon, authenticated;

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
          'is_published',   i.is_published
        )
        order by i.start_time nulls last, i.title
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

notify pgrst, 'reload schema';
