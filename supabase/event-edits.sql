-- ============================================================
-- event-edits : RPCs for the Manage Sponsors / Tickets /
-- Transportation / Schedule editors on the partner-event
-- dashboard's Edits chapter. All token-gated to the event.
-- ============================================================

-- ── Schema (defensive; columns may already exist) ───────────
alter table public.ticket_locations add column if not exists latitude   double precision;
alter table public.ticket_locations add column if not exists longitude  double precision;
alter table public.ticket_locations add column if not exists place_slug text;

-- ── Helper : resolve token → event_id ───────────────────────
create or replace function public._partner_event_id_from_token(p_token text)
returns uuid
language sql
security definer
set search_path = public
as $$
  select id from public.events where partner_access_token = p_token limit 1;
$$;

grant execute on function public._partner_event_id_from_token(text) to anon, authenticated;


-- ============================================================
-- SPONSORS
-- ============================================================

-- Upsert : if p_event_sponsor_id is null, INSERT a new sponsor + event_sponsor.
-- Otherwise UPDATE the existing rows.
create or replace function public.upsert_event_sponsor(
  p_token              text,
  p_event_sponsor_id   uuid default null,
  p_sponsor_name       text default null,
  p_tier               text default null,
  p_display_tier_label text default null,
  p_custom_tagline     text default null,
  p_logo_url           text default null,
  p_website            text default null,
  p_instagram          text default null,
  p_is_featured        boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id   uuid;
  v_sponsor_id uuid;
  v_es_id      uuid;
  v_slug       text;
  v_tier       text;
  v_tier_label text;
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;
  if p_sponsor_name is null or btrim(p_sponsor_name) = '' then
    return jsonb_build_object('ok', false, 'error', 'sponsor_name_required');
  end if;
  v_tier := case lower(coalesce(nullif(btrim(p_tier), ''), 'partner'))
    when 'title' then 'presenting'
    when 'platinum' then 'presenting'
    when 'gold' then 'major'
    when 'silver' then 'supporting'
    when 'bronze' then 'supporting'
    when 'presenting' then 'presenting'
    when 'major' then 'major'
    when 'supporting' then 'supporting'
    when 'community' then 'community'
    else 'partner'
  end;
  v_tier_label := coalesce(
    nullif(btrim(p_display_tier_label), ''),
    case lower(coalesce(nullif(btrim(p_tier), ''), 'partner'))
      when 'title' then 'Title Sponsor'
      when 'platinum' then 'Platinum Sponsor'
      when 'gold' then 'Gold Sponsor'
      when 'silver' then 'Silver Sponsor'
      when 'bronze' then 'Bronze Sponsor'
      else null
    end
  );

  if p_event_sponsor_id is null then
    -- Create a sponsor row + event_sponsor link
    v_slug := regexp_replace(lower(btrim(p_sponsor_name)) || '-' || substr(encode(extensions.gen_random_bytes(3), 'hex'), 1, 6), '[^a-z0-9-]+', '-', 'g');
    insert into public.sponsors (name, slug, logo_url, website, description, instagram, is_active)
         values (
           btrim(p_sponsor_name),
           v_slug,
           nullif(btrim(p_logo_url), ''),
           nullif(btrim(p_website), ''),
           nullif(btrim(p_custom_tagline), ''),
           nullif(btrim(p_instagram), ''),
           true
         )
      returning id into v_sponsor_id;

    insert into public.event_sponsors (event_id, sponsor_id, tier, display_tier_label, custom_tagline, is_featured, is_active)
         values (
           v_event_id,
           v_sponsor_id,
           v_tier,
           v_tier_label,
           nullif(btrim(p_custom_tagline), ''),
           coalesce(p_is_featured, false),
           true
         )
      returning id into v_es_id;
  else
    -- Update : confirm ownership, then update both tables
    select id, sponsor_id into v_es_id, v_sponsor_id
      from public.event_sponsors
     where id = p_event_sponsor_id and event_id = v_event_id;
    if v_es_id is null then
      return jsonb_build_object('ok', false, 'error', 'sponsor_not_on_event');
    end if;

    update public.event_sponsors
       set tier               = v_tier,
           display_tier_label = v_tier_label,
           custom_tagline     = nullif(btrim(p_custom_tagline), ''),
           is_featured        = coalesce(p_is_featured,        is_featured),
           is_active          = true,
           updated_at         = now()
     where id = v_es_id;

    update public.sponsors
       set name        = btrim(p_sponsor_name),
           logo_url    = nullif(btrim(p_logo_url), ''),
           website     = nullif(btrim(p_website), ''),
           instagram   = nullif(btrim(p_instagram), ''),
           description = nullif(btrim(p_custom_tagline), ''),
           is_active   = true,
           updated_at  = now()
     where id = v_sponsor_id;
  end if;

  return jsonb_build_object('ok', true, 'event_sponsor_id', v_es_id, 'sponsor_id', v_sponsor_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;

grant execute on function public.upsert_event_sponsor(text, uuid, text, text, text, text, text, text, text, boolean)
  to anon, authenticated;


create or replace function public.delete_event_sponsor(
  p_token            text,
  p_event_sponsor_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_event_id uuid;
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  delete from public.event_sponsors where id = p_event_sponsor_id and event_id = v_event_id;
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.delete_event_sponsor(text, uuid) to anon, authenticated;


-- ============================================================
-- TICKET LOCATIONS
-- ============================================================

-- Drop the previous 11-arg signature so the extended one below does not become
-- a second overload (which would make PostgREST calls ambiguous).
drop function if exists public.upsert_ticket_location(
  text, uuid, text, boolean, text, text, text, text, text, text, text);

create or replace function public.upsert_ticket_location(
  p_token         text,
  p_id            uuid default null,
  p_name          text default null,
  p_is_online     boolean default false,
  p_ticket_url    text default null,
  p_provider_type text default null,
  p_address       text default null,
  p_town          text default null,
  p_parish        text default null,
  p_contact_phone text default null,
  p_opening_hours text default null,
  p_latitude      double precision default null,
  p_longitude     double precision default null,
  p_place_slug    text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
  v_id       uuid;
  v_slug     text := nullif(btrim(p_place_slug), '');
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  if p_name is null or btrim(p_name) = '' then
    return jsonb_build_object('ok', false, 'error', 'name_required');
  end if;

  -- When a slug is supplied it must point at a real listing.
  if v_slug is not null and not exists (select 1 from public.places where slug = v_slug) then
    return jsonb_build_object('ok', false, 'error', 'unknown_place_slug');
  end if;

  if p_id is null then
    insert into public.ticket_locations (
      event_id, name, address, parish, town, contact_phone, opening_hours,
      is_online, ticket_url, provider_type, latitude, longitude, place_slug, is_active
    ) values (
      v_event_id, p_name, p_address, p_parish, p_town, p_contact_phone, p_opening_hours,
      coalesce(p_is_online, false), p_ticket_url, p_provider_type, p_latitude, p_longitude, v_slug, true
    ) returning id into v_id;
  else
    update public.ticket_locations
       set name           = coalesce(p_name,          name),
           address        = coalesce(p_address,       address),
           parish         = coalesce(p_parish,        parish),
           town           = coalesce(p_town,          town),
           contact_phone  = coalesce(p_contact_phone, contact_phone),
           opening_hours  = coalesce(p_opening_hours, opening_hours),
           is_online      = coalesce(p_is_online,     is_online),
           ticket_url     = coalesce(p_ticket_url,    ticket_url),
           provider_type  = coalesce(p_provider_type, provider_type),
           latitude       = coalesce(p_latitude,      latitude),
           longitude      = coalesce(p_longitude,     longitude),
           -- null param leaves it; empty string clears the link.
           place_slug     = case when p_place_slug is null then place_slug else v_slug end,
           updated_at     = now()
     where id = p_id and event_id = v_event_id
     returning id into v_id;
    if v_id is null then return jsonb_build_object('ok', false, 'error', 'not_on_event'); end if;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;
grant execute on function public.upsert_ticket_location(
  text, uuid, text, boolean, text, text, text, text, text, text, text,
  double precision, double precision, text)
  to anon, authenticated;

-- Live place-slug validation for the editor's place picker.
create or replace function public.validate_place_slug(p_slug text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(
    (select jsonb_build_object('exists', true, 'slug', slug, 'name', name)
       from public.places where slug = nullif(btrim(p_slug), '') limit 1),
    jsonb_build_object('exists', false, 'slug', nullif(btrim(p_slug), ''), 'name', null)
  );
$$;
grant execute on function public.validate_place_slug(text) to anon, authenticated;


create or replace function public.delete_ticket_location(p_token text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_event_id uuid;
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  delete from public.ticket_locations where id = p_id and event_id = v_event_id;
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.delete_ticket_location(text, uuid) to anon, authenticated;


-- ============================================================
-- TRANSPORT ROUTES
-- ============================================================

create or replace function public.upsert_transport_route(
  p_token     text,
  p_id        uuid default null,
  p_name      text default null,
  p_color     text default '#0a7aff',
  p_direction text default 'both',
  p_frequency text default null
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
    insert into public.event_transport_routes (event_id, name, color, direction, frequency)
         values (v_event_id, p_name, coalesce(p_color, '#0a7aff'), p_direction, p_frequency)
      returning id into v_id;
  else
    update public.event_transport_routes
       set name      = coalesce(p_name,      name),
           color     = coalesce(p_color,     color),
           direction = coalesce(p_direction, direction),
           frequency = coalesce(p_frequency, frequency)
     where id = p_id and event_id = v_event_id
     returning id into v_id;
    if v_id is null then return jsonb_build_object('ok', false, 'error', 'not_on_event'); end if;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;
grant execute on function public.upsert_transport_route(text, uuid, text, text, text, text)
  to anon, authenticated;


create or replace function public.delete_transport_route(p_token text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_event_id uuid;
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  delete from public.event_transport_routes where id = p_id and event_id = v_event_id;
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.delete_transport_route(text, uuid) to anon, authenticated;


-- ============================================================
-- SCHEDULE DAYS
-- ============================================================

create or replace function public.upsert_schedule_day(
  p_token        text,
  p_id           uuid default null,
  p_date         date default null,
  p_label        text default null,
  p_description  text default null,
  p_gates_open   time default null,
  p_gates_close  time default null,
  p_is_cancelled boolean default false
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
  if p_date is null then return jsonb_build_object('ok', false, 'error', 'date_required'); end if;

  if p_id is null then
    insert into public.event_schedule_days (event_id, date, label, description, gates_open, gates_close, is_cancelled)
         values (v_event_id, p_date, p_label, p_description, p_gates_open, p_gates_close, coalesce(p_is_cancelled, false))
      returning id into v_id;
  else
    update public.event_schedule_days
       set date         = coalesce(p_date,         date),
           label        = coalesce(p_label,        label),
           description  = coalesce(p_description,  description),
           gates_open   = coalesce(p_gates_open,   gates_open),
           gates_close  = coalesce(p_gates_close,  gates_close),
           is_cancelled = coalesce(p_is_cancelled, is_cancelled),
           updated_at   = now()
     where id = p_id and event_id = v_event_id
     returning id into v_id;
    if v_id is null then return jsonb_build_object('ok', false, 'error', 'not_on_event'); end if;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;
grant execute on function public.upsert_schedule_day(text, uuid, date, text, text, time, time, boolean)
  to anon, authenticated;


create or replace function public.delete_schedule_day(p_token text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_event_id uuid;
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  delete from public.event_schedule_days where id = p_id and event_id = v_event_id;
  return jsonb_build_object('ok', true);
end;
$$;
grant execute on function public.delete_schedule_day(text, uuid) to anon, authenticated;


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


-- ============================================================
-- EXTEND partner-event-extras RPC TO INCLUDE schedule_days
--
-- The dashboard's "Manage Schedule" editor reads from
-- extras.schedule_days and extras.schedule_items. Add these aggregations to your existing
-- get_partner_event_extras_by_token RPC:
--
--   'schedule_days', coalesce((
--     select jsonb_agg(jsonb_build_object(
--       'id',           d.id,
--       'date',         d.date,
--       'date_display', d.date_display,
--       'label',        d.label,
--       'description',  d.description,
--       'gates_open',   d.gates_open,
--       'gates_close',  d.gates_close,
--       'is_cancelled', d.is_cancelled,
--       'items_count',  (select count(*) from public.event_schedule_items i where i.day_id = d.id)
--     ) order by d.date)
--     from public.event_schedule_days d
--     where d.event_id = v_event_id
--   ), '[]'::jsonb),
-- ============================================================
