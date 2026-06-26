-- Passes editor backend.
--
-- partner-event.html (savePass/deletePass/renderPassesEditor) is wired to an
-- event_passes table, upsert_event_pass / delete_event_pass RPCs, and a
-- `passes` key on get_partner_event_extras_by_token -- none of which existed.
-- The whole Passes section was UI-only: the list never loaded and every save
-- failed. This creates the table + RPCs and exposes passes in the read.
--
-- It also redefines get_partner_event_extras_by_token to surface the new band
-- fields added in 20260626130000 (instagram, launch_date, is_featured).

create table if not exists public.event_passes (
  id            uuid primary key default gen_random_uuid(),
  event_id      uuid not null references public.events(id) on delete cascade,
  name          text not null,
  tier          text,
  description   text,
  price         numeric(10,2),
  currency      text,
  color         text,
  is_featured   boolean not null default false,
  display_order integer not null default 0,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create index if not exists idx_event_passes_event on public.event_passes (event_id);

alter table public.event_passes enable row level security;

-- Public read (attendee app); writes go through the security-definer RPCs below,
-- mirroring the mas_bands policy pattern.
drop policy if exists event_passes_public_read on public.event_passes;
create policy event_passes_public_read on public.event_passes
  for select using (true);

drop policy if exists event_passes_admin_write on public.event_passes;
create policy event_passes_admin_write on public.event_passes
  using (auth.role() = 'service_role');

create or replace function public.upsert_event_pass(
  p_token       text,
  p_id          uuid    default null,
  p_name        text    default null,
  p_tier        text    default null,
  p_description text    default null,
  p_price       numeric default null,
  p_currency    text    default null,
  p_color       text    default null,
  p_is_featured boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
  v_id       uuid;
  v_name     text := nullif(btrim(p_name), '');
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;

  if p_id is null then
    if v_name is null then return jsonb_build_object('ok', false, 'error', 'name_required'); end if;

    insert into public.event_passes (event_id, name, tier, description, price, currency, color, is_featured)
    values (
      v_event_id,
      v_name,
      nullif(btrim(p_tier), ''),
      nullif(btrim(p_description), ''),
      p_price,
      nullif(btrim(p_currency), ''),
      nullif(btrim(p_color), ''),
      coalesce(p_is_featured, false)
    )
    returning id into v_id;
  else
    update public.event_passes
       set name        = coalesce(v_name, name),
           tier        = case when p_tier is not null then nullif(btrim(p_tier), '') else tier end,
           description = case when p_description is not null then nullif(btrim(p_description), '') else description end,
           price       = case when p_price is not null then p_price else price end,
           currency    = case when p_currency is not null then nullif(btrim(p_currency), '') else currency end,
           color       = case when p_color is not null then nullif(btrim(p_color), '') else color end,
           is_featured = coalesce(p_is_featured, is_featured),
           updated_at  = now()
     where id = p_id and event_id = v_event_id
     returning id into v_id;
    if v_id is null then return jsonb_build_object('ok', false, 'error', 'pass_not_on_event'); end if;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;

grant execute on function public.upsert_event_pass(
  text, uuid, text, text, text, numeric, text, text, boolean
) to anon, authenticated;

create or replace function public.delete_event_pass(p_token text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_event_id uuid;
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  delete from public.event_passes where id = p_id and event_id = v_event_id;
  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.delete_event_pass(text, uuid) to anon, authenticated;

-- Redefine the partner extras read to (a) surface the new band fields and
-- (b) return the passes list the dashboard expects.
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

    'passes', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',          p.id,
          'name',        p.name,
          'tier',        p.tier,
          'description', p.description,
          'price',       p.price,
          'currency',    p.currency,
          'color',       p.color,
          'is_featured', p.is_featured
        )
        order by p.is_featured desc, p.display_order, p.created_at
      )
      from public.event_passes p
      where p.event_id = v_event_id
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
              'instagram',              mb.ig_handle,
              'registration_deadline',  mb.registration_deadline,
              'registration_url',       mb.registration_url,
              'launch_date',            mb.launch_date,
              'is_featured',            mb.is_featured
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
