-- ============================================================
-- event-vendors : RPC for editing a vendor entry on an event,
-- called from the partner-event dashboard's vendor edit modal.
-- ============================================================

alter table public.event_vendors
  add column if not exists filter_tags text[] not null default '{}';
alter table public.event_vendors
  add column if not exists display_name text;

create or replace view public.event_vendors_with_menu as
 select e.id as event_id,
    e.slug as event_slug,
    e.title as event_title,
    e.town as event_town,
    e.parish as event_parish,
    e.start_date,
    e.end_date,
    e.currency as event_currency,
    v.id as vendor_id,
    v.name as vendor_name,
    v.description as vendor_description,
    v.vendor_type,
    v.logo_url,
    v.cover_image_url,
    v.instagram,
    v.website,
    v.place_id as vendor_place_id,
    p.id as place_id,
    p.slug as place_slug,
    p.name as place_name,
    p.image as place_image,
    p.category as place_category,
    ev.id as event_vendor_id,
    ev.booth_number,
    ev.is_featured as vendor_is_featured,
    mi.id as menu_item_id,
    mi.name as menu_item_name,
    mi.description as menu_item_description,
    mi.price,
    coalesce(mi.currency, e.currency) as currency,
    mi.category as menu_category,
    mi.tags,
    mi.is_special,
    mi.is_sold_out,
    mi.image_url as menu_image_url,
    mi.sort_order,
    mi.price_label
   from public.events e
     join public.event_vendors ev on ev.event_id = e.id
     join public.vendors v on v.id = ev.vendor_id
     left join public.places p on p.id = v.place_id
     left join public.vendor_menu_items mi on mi.event_vendor_id = ev.id;

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
        'logo_url',    v.logo_url,
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
drop function if exists public.upsert_event_vendor(
  text, uuid, uuid, text, text, text, text, boolean, text, text[]);

create or replace function public.upsert_event_vendor(
  p_token              text,
  p_event_vendor_id    uuid    default null,
  p_vendor_id          uuid    default null,
  p_vendor_name        text    default null,
  p_logo_url           text    default null,
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
      if p_vendor_type is not null or p_vendor_description is not null or p_logo_url is not null then
        update public.vendors
           set vendor_type = coalesce(p_vendor_type,        vendor_type),
               description = coalesce(p_vendor_description, description),
               logo_url    = case when p_logo_url is not null then nullif(btrim(p_logo_url), '') else logo_url end,
               updated_at  = now()
         where id = v_vendor_id;
      end if;
    elsif p_vendor_type is not null or p_vendor_description is not null or p_logo_url is not null then
      update public.vendors
         set vendor_type = coalesce(p_vendor_type,        vendor_type),
             description = coalesce(p_vendor_description, description),
             logo_url    = case when p_logo_url is not null then nullif(btrim(p_logo_url), '') else logo_url end,
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
      insert into public.vendors (name, vendor_type, description, logo_url)
      values (trim(p_vendor_name), p_vendor_type, p_vendor_description, nullif(btrim(p_logo_url), ''))
      returning id into v_vendor_id;
    elsif p_logo_url is not null or p_vendor_type is not null or p_vendor_description is not null then
      update public.vendors
         set vendor_type = coalesce(p_vendor_type, vendor_type),
             description = coalesce(p_vendor_description, description),
             logo_url    = case when p_logo_url is not null then nullif(btrim(p_logo_url), '') else logo_url end,
             updated_at  = now()
       where id = v_vendor_id;
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
    if p_logo_url is not null or p_vendor_type is not null or p_vendor_description is not null then
      update public.vendors
         set vendor_type = coalesce(p_vendor_type, vendor_type),
             description = coalesce(p_vendor_description, description),
             logo_url    = case when p_logo_url is not null then nullif(btrim(p_logo_url), '') else logo_url end,
             updated_at  = now()
       where id = v_vendor_id;
    end if;
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
  text, uuid, uuid, text, text, text, text, text, boolean, text, text[]
) to anon, authenticated;

comment on function public.upsert_event_vendor is
  'Adds a vendor to an event from the partner dashboard: links an existing directory vendor (p_vendor_id) or creates a new vendor row, then inserts into event_vendors. With p_event_vendor_id set it behaves like update_event_vendor. Token-gated.';

-- ============================================================
-- set_event_vendor_menu_items : replace the menu for one vendor
-- on an event. Called from the partner-event vendor edit modal.
-- ============================================================

drop function if exists public.set_event_vendor_menu_items(text, uuid, jsonb);

create or replace function public.set_event_vendor_menu_items(
  p_token           text,
  p_event_vendor_id uuid,
  p_items           jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
  v_keep_ids uuid[] := '{}';
  v_item jsonb;
  v_item_id uuid;
  v_saved_id uuid;
  v_idx integer := 0;
  v_name text;
  v_tags text[];
begin
  select e.id into v_event_id
    from public.events e
    join public.event_vendors ev on ev.event_id = e.id
   where e.partner_access_token = p_token
     and ev.id = p_event_vendor_id;

  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'vendor_not_found_for_event');
  end if;

  if jsonb_typeof(coalesce(p_items, '[]'::jsonb)) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'menu_items_must_be_array');
  end if;

  for v_item in select value from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
  loop
    v_name := nullif(btrim(v_item->>'name'), '');
    if v_name is null then
      return jsonb_build_object('ok', false, 'error', 'menu_item_name_required');
    end if;

    v_tags := coalesce(
      array(
        select nullif(btrim(value), '')
          from jsonb_array_elements_text(coalesce(v_item->'tags', '[]'::jsonb))
         where nullif(btrim(value), '') is not null
      ),
      '{}'::text[]
    );

    v_item_id := nullif(v_item->>'id', '')::uuid;
    if v_item_id is not null and exists (
      select 1 from public.vendor_menu_items
       where id = v_item_id and event_vendor_id = p_event_vendor_id
    ) then
      update public.vendor_menu_items
         set name        = v_name,
             description = nullif(btrim(v_item->>'description'), ''),
             price       = nullif(v_item->>'price', '')::numeric,
             currency    = coalesce(nullif(btrim(v_item->>'currency'), ''), 'JMD'),
             category    = nullif(btrim(v_item->>'category'), ''),
             is_special  = coalesce((v_item->>'is_special')::boolean, false),
             is_sold_out = coalesce((v_item->>'is_sold_out')::boolean, false),
             image_url   = nullif(btrim(v_item->>'image_url'), ''),
             sort_order  = coalesce(nullif(v_item->>'sort_order', '')::integer, v_idx),
             tags        = v_tags,
             price_label = nullif(btrim(v_item->>'price_label'), ''),
             updated_at  = now()
       where id = v_item_id
       returning id into v_saved_id;
    else
      insert into public.vendor_menu_items (
        event_vendor_id, name, description, price, currency, category,
        is_special, is_sold_out, image_url, sort_order, tags, price_label
      ) values (
        p_event_vendor_id,
        v_name,
        nullif(btrim(v_item->>'description'), ''),
        nullif(v_item->>'price', '')::numeric,
        coalesce(nullif(btrim(v_item->>'currency'), ''), 'JMD'),
        nullif(btrim(v_item->>'category'), ''),
        coalesce((v_item->>'is_special')::boolean, false),
        coalesce((v_item->>'is_sold_out')::boolean, false),
        nullif(btrim(v_item->>'image_url'), ''),
        coalesce(nullif(v_item->>'sort_order', '')::integer, v_idx),
        v_tags,
        nullif(btrim(v_item->>'price_label'), '')
      )
      returning id into v_saved_id;
    end if;

    v_keep_ids := array_append(v_keep_ids, v_saved_id);
    v_idx := v_idx + 1;
  end loop;

  delete from public.vendor_menu_items
   where event_vendor_id = p_event_vendor_id
     and not (id = any(v_keep_ids));

  return jsonb_build_object(
    'ok', true,
    'event_vendor_id', p_event_vendor_id,
    'menu_items', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'menu_item_id', id,
        'id',           id,
        'name',         name,
        'description',  description,
        'price',        price,
        'currency',     currency,
        'category',     category,
        'tags',         tags,
        'is_special',   is_special,
        'is_sold_out',  is_sold_out,
        'image_url',    image_url,
        'sort_order',   sort_order,
        'price_label',  price_label
      ) order by sort_order, name), '[]'::jsonb)
      from public.vendor_menu_items
      where event_vendor_id = p_event_vendor_id
    )
  );
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;

grant execute on function public.set_event_vendor_menu_items(text, uuid, jsonb) to anon, authenticated;

comment on function public.set_event_vendor_menu_items is
  'Replaces menu items for one event_vendor row via the partner-event dashboard. Token-gated to the owning event.';
