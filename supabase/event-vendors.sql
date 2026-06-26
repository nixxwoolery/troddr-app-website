-- ============================================================
-- event-vendors : RPC for editing a vendor entry on an event,
-- called from the partner-event dashboard's vendor edit modal.
-- ============================================================

alter table public.event_vendors
  add column if not exists filter_tags text[] not null default '{}';
alter table public.event_vendors
  add column if not exists display_name text;

drop function if exists public.update_event_vendor(
  text, uuid, text, text, text, text, boolean);

create or replace function public.update_event_vendor(
  p_token              text,
  p_event_vendor_id    uuid,
  p_vendor_name        text default null,
  p_booth_number       text default null,
  p_vendor_type        text default null,
  p_vendor_description text default null,
  p_is_featured        boolean default null,
  p_filter_tags        text[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id  uuid;
  v_vendor_id uuid;
  v_target_vendor_id uuid;
begin
  -- 1. Resolve token → event
  select id into v_event_id
    from public.events
   where partner_access_token = p_token;

  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  -- 2. Confirm this event_vendor row belongs to that event
  select vendor_id into v_vendor_id
    from public.event_vendors
   where id = p_event_vendor_id and event_id = v_event_id;

  if v_vendor_id is null then
    return jsonb_build_object('ok', false, 'error', 'vendor_not_found_for_event');
  end if;

  if p_vendor_name is not null then
    select id into v_target_vendor_id
      from public.vendors
     where lower(btrim(name)) = lower(btrim(p_vendor_name))
       and id <> v_vendor_id
     limit 1;
  end if;

  if v_target_vendor_id is not null then
    if exists (
      select 1
        from public.event_vendors
       where event_id = v_event_id
         and vendor_id = v_target_vendor_id
         and id <> p_event_vendor_id
    ) then
      v_target_vendor_id := null;
    else
      v_vendor_id := v_target_vendor_id;
    end if;
  end if;

  -- 3. Update event-level metadata (booth, featured)
  update public.event_vendors
     set vendor_id     = coalesce(v_target_vendor_id, vendor_id),
         display_name  = coalesce(nullif(btrim(p_vendor_name), ''), display_name),
         booth_number  = coalesce(p_booth_number,  booth_number),
         is_featured   = coalesce(p_is_featured,   is_featured),
         filter_tags   = coalesce(p_filter_tags,   filter_tags),
         updated_at    = now()
   where id = p_event_vendor_id;

  -- 4. Update vendor-level fields (name, type, description) on the vendors row.
  --    Only update the columns the partner actually changed.
  if v_target_vendor_id is not null then
    if p_vendor_type is not null or p_vendor_description is not null then
      update public.vendors
         set vendor_type = coalesce(p_vendor_type,        vendor_type),
             description = coalesce(p_vendor_description, description),
             updated_at  = now()
       where id = v_vendor_id;
    end if;
  elsif p_vendor_type is not null or p_vendor_description is not null then
    update public.vendors
       set vendor_type = coalesce(p_vendor_type,        vendor_type),
           description = coalesce(p_vendor_description, description),
           updated_at  = now()
     where id = v_vendor_id;
  end if;

  return jsonb_build_object('ok', true, 'event_vendor_id', p_event_vendor_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;

grant execute on function public.update_event_vendor(
  text, uuid, text, text, text, text, boolean, text[]
) to anon, authenticated;

comment on function public.update_event_vendor is
  'Lets a partner update one vendor row on their event via the partner-event dashboard edit modal. Updates event_vendors.booth_number/is_featured and (optionally) the vendor''s own name/vendor_type/description. Token-gated to the owning event.';

-- ============================================================
-- get_partner_vendor_directory : vendors a partner can add to
-- their event. Sourced from the platform vendor listing so the
-- Add Vendor dropdown picks from existing vendors (with their
-- info and menus already attached) instead of typing fresh.
-- ============================================================

create or replace function public.get_partner_vendor_directory(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
begin
  select id into v_event_id
    from public.events
   where partner_access_token = p_token;

  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  return jsonb_build_object(
    'ok', true,
    'vendors', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'vendor_id',   v.id,
        'name',        v.name,
        'vendor_type', v.vendor_type,
        'description', v.description,
        -- Already linked to this event? The dropdown disables these.
        'on_event', exists (
          select 1 from public.event_vendors ev
           where ev.event_id = v_event_id and ev.vendor_id = v.id
        )
      ) order by v.name), '[]'::jsonb)
      from public.vendors v
    )
  );
end;
$$;

grant execute on function public.get_partner_vendor_directory(text) to anon, authenticated;

comment on function public.get_partner_vendor_directory is
  'Returns the vendor directory for the Add Vendor dropdown on the partner event dashboard, flagging vendors already linked to the event. Token-gated.';

-- ============================================================
-- upsert_event_vendor : create-or-update a vendor on an event.
--   * p_event_vendor_id set        → update (same as update_event_vendor)
--   * p_event_vendor_id null +
--     p_vendor_id set              → link an existing directory vendor
--   * both null                    → create a brand-new vendor, then link
-- ============================================================

-- Drop any earlier signature so create-or-replace doesn't leave an
-- ambiguous overload behind (PostgREST can't disambiguate those).
drop function if exists public.upsert_event_vendor(
  text, uuid, uuid, text, text, text, text, boolean);
drop function if exists public.upsert_event_vendor(
  text, uuid, uuid, text, text, text, text, boolean, text);

create or replace function public.upsert_event_vendor(
  p_token              text,
  p_event_vendor_id    uuid    default null,
  p_vendor_id          uuid    default null,
  p_vendor_name        text    default null,
  p_booth_number       text    default null,
  p_vendor_type        text    default null,
  p_vendor_description text    default null,
  p_is_featured        boolean default null,
  p_zone               text    default null,
  p_filter_tags        text[]  default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id        uuid;
  v_vendor_id       uuid;
  v_event_vendor_id uuid;
  v_target_vendor_id uuid;
begin
  -- 1. Resolve token → event
  select id into v_event_id
    from public.events
   where partner_access_token = p_token;

  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  -- 2. Update path: edit an existing event_vendors row in place.
  if p_event_vendor_id is not null then
    select vendor_id into v_vendor_id
      from public.event_vendors
     where id = p_event_vendor_id and event_id = v_event_id;

    if v_vendor_id is null then
      return jsonb_build_object('ok', false, 'error', 'vendor_not_found_for_event');
    end if;

    if p_vendor_name is not null then
      select id into v_target_vendor_id
        from public.vendors
       where lower(btrim(name)) = lower(btrim(p_vendor_name))
         and id <> v_vendor_id
       limit 1;
    end if;

  if v_target_vendor_id is not null then
    if exists (
      select 1
        from public.event_vendors
       where event_id = v_event_id
         and vendor_id = v_target_vendor_id
         and id <> p_event_vendor_id
    ) then
        v_target_vendor_id := null;
      else
        v_vendor_id := v_target_vendor_id;
      end if;
    end if;

    update public.event_vendors
       set vendor_id    = coalesce(v_target_vendor_id, vendor_id),
           display_name = coalesce(nullif(btrim(p_vendor_name), ''), display_name),
           booth_number = coalesce(p_booth_number, booth_number),
           is_featured  = coalesce(p_is_featured,  is_featured),
           zone         = coalesce(p_zone,         zone),
           filter_tags  = coalesce(p_filter_tags,  filter_tags),
           updated_at   = now()
     where id = p_event_vendor_id;

    if v_target_vendor_id is not null then
      if p_vendor_type is not null or p_vendor_description is not null then
        update public.vendors
           set vendor_type = coalesce(p_vendor_type,        vendor_type),
               description = coalesce(p_vendor_description, description),
               updated_at  = now()
         where id = v_vendor_id;
      end if;
    elsif p_vendor_type is not null or p_vendor_description is not null then
      update public.vendors
         set vendor_type = coalesce(p_vendor_type,        vendor_type),
             description = coalesce(p_vendor_description, description),
             updated_at  = now()
       where id = v_vendor_id;
    end if;

    return jsonb_build_object('ok', true, 'event_vendor_id', p_event_vendor_id);
  end if;

  -- 3. Create path: existing directory vendor, or brand new.
  v_vendor_id := p_vendor_id;

  if v_vendor_id is null then
    if coalesce(trim(p_vendor_name), '') = '' then
      return jsonb_build_object('ok', false, 'error', 'vendor_name_required');
    end if;

    -- vendors.name is unique globally. If the partner types the name of an
    -- existing vendor instead of choosing it from the directory picker, reuse
    -- that vendor and continue to the event link step below.
    select id into v_vendor_id
      from public.vendors
     where lower(btrim(name)) = lower(btrim(p_vendor_name))
     limit 1;

    if v_vendor_id is null then
      insert into public.vendors (name, vendor_type, description)
      values (trim(p_vendor_name), p_vendor_type, p_vendor_description)
      returning id into v_vendor_id;
    end if;
  else
    -- Make sure the directory vendor actually exists.
    if not exists (select 1 from public.vendors where id = v_vendor_id) then
      return jsonb_build_object('ok', false, 'error', 'vendor_not_found');
    end if;
  end if;

  -- 4. Already linked? (event_vendors has unique (event_id, vendor_id).)
  --    Update the existing row instead of failing on the constraint.
  select id into v_event_vendor_id
    from public.event_vendors
   where event_id = v_event_id and vendor_id = v_vendor_id;

  if v_event_vendor_id is not null then
    update public.event_vendors
       set booth_number = coalesce(p_booth_number, booth_number),
           is_featured  = coalesce(p_is_featured,  is_featured),
           zone         = coalesce(p_zone,         zone),
           display_name = coalesce(nullif(btrim(p_vendor_name), ''), display_name),
           filter_tags  = coalesce(p_filter_tags,  filter_tags),
           updated_at   = now()
     where id = v_event_vendor_id;
    return jsonb_build_object('ok', true, 'event_vendor_id', v_event_vendor_id, 'already_linked', true);
  end if;

  -- 5. Link vendor to event.
  insert into public.event_vendors (event_id, vendor_id, display_name, booth_number, is_featured, zone, filter_tags)
  values (v_event_id, v_vendor_id, nullif(btrim(p_vendor_name), ''), p_booth_number, coalesce(p_is_featured, false), p_zone, coalesce(p_filter_tags, '{}'))
  returning id into v_event_vendor_id;

  return jsonb_build_object('ok', true, 'event_vendor_id', v_event_vendor_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;

grant execute on function public.upsert_event_vendor(
  text, uuid, uuid, text, text, text, text, boolean, text, text[]
) to anon, authenticated;

comment on function public.upsert_event_vendor is
  'Adds a vendor to an event from the partner dashboard: links an existing directory vendor (p_vendor_id) or creates a new vendor row, then inserts into event_vendors. With p_event_vendor_id set it behaves like update_event_vendor. Token-gated.';
