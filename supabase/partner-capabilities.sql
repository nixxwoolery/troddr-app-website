-- ============================================================
-- Partner Capabilities RPC (polymorphic + partner-aware)
-- Resolves either a place or an event token, and if the resolved
-- entity has a partner_id, hospitality_group, or parent_place_id,
-- also returns sibling entities so the dashboard can show a group
-- / location picker.
-- ============================================================

create or replace function public.get_partner_capabilities_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place        places%rowtype;
  v_event        events%rowtype;
  v_has_loyalty  boolean;
  v_has_vendors  boolean;
  v_partner_id   uuid;
  v_partner_name text;
  v_partner_jsonb jsonb;
  v_current_id   uuid;
  v_group_key    text;
  v_root_place_id uuid;
begin
  ------------------------------------------------------------
  -- 1. Resolve token to entity (place first, then event)
  ------------------------------------------------------------
  select * into v_place
    from public.places
   where partner_access_token = p_token;

  if v_place.id is null then
    select * into v_event
      from public.events
     where partner_access_token = p_token;
  end if;

  if v_place.id is null and v_event.id is null then
    return null;
  end if;

  v_partner_id := coalesce(v_place.partner_id, v_event.partner_id);
  v_current_id := coalesce(v_place.id, v_event.id);
  v_group_key := nullif(trim(coalesce(v_place.hospitality_group, '')), '');
  v_root_place_id := coalesce(v_place.parent_place_id, v_place.id);

  ------------------------------------------------------------
  -- 2. Build the partner block (sibling entity picker)
  ------------------------------------------------------------
  if v_partner_id is not null or v_group_key is not null or v_place.parent_place_id is not null then
    if v_partner_id is not null then
      select name into v_partner_name from public.partners where id = v_partner_id;
    end if;
    if v_partner_name is null and v_group_key is not null then
      v_partner_name := v_group_key;
    end if;
    if v_partner_name is null and v_root_place_id is not null then
      select name into v_partner_name from public.places where id = v_root_place_id;
    end if;

    v_partner_jsonb := jsonb_build_object(
      'id',         v_partner_id,
      'name',       v_partner_name,
      'current_id', v_current_id,
      'hospitality_group', v_group_key,
      'root_place_id', v_root_place_id,
      'entities', (
        with all_e as (
          select 'place'      as type,
                 id, name, slug,
                 partner_access_token as token,
                 coalesce(nullif(place_role, ''), category) as label
            from public.places
           where (
             (v_partner_id is not null and partner_id = v_partner_id)
             or (v_group_key is not null and hospitality_group = v_group_key)
             or (v_root_place_id is not null and (id = v_root_place_id or parent_place_id = v_root_place_id))
           )
          union all
          select 'event'      as type,
                 id, title as name, slug,
                 partner_access_token as token,
                 event_type as label
            from public.events
           where v_partner_id is not null and partner_id = v_partner_id
        )
        select coalesce(
          jsonb_agg(
            jsonb_build_object(
              'type',  type,
              'id',    id,
              'name',  name,
              'slug',  slug,
              'token', token,
              'label', label
            )
            order by type, name),
          '[]'::jsonb)
        from all_e
      )
    );
  else
    v_partner_jsonb := null;
  end if;

  ------------------------------------------------------------
  -- 3. Place response
  ------------------------------------------------------------
  if v_place.id is not null then
    v_has_loyalty := exists (
      select 1 from public.loyalty_programs
       where place_id = v_place.id and is_active = true
    );

    return jsonb_build_object(
      'type', 'place',
      'place', jsonb_build_object(
        'id',   v_place.id,
        'name', v_place.name,
        'slug', v_place.slug
      ),
      'capabilities', jsonb_build_object(
        'listing',  true,
        'bookings', (
          v_place.bookings_email is not null
          or v_place.booking_link is not null
          or v_place.day_pass_available = true
        ),
        'loyalty',  v_has_loyalty,
        'feedback', true,
        'specials', true,
        'billing',  true
      ),
      'program', (
        select jsonb_build_object(
          'primary_color',   primary_color,
          'accent_color',    accent_color,
          'text_color',      text_color,
          'secondary_color', secondary_color
        )
        from public.loyalty_programs
        where place_id = v_place.id and is_active = true
        order by created_at desc
        limit 1
      ),
      'partner', v_partner_jsonb
    );
  end if;

  ------------------------------------------------------------
  -- 4. Event response
  ------------------------------------------------------------
  -- Parse tabs defensively: column could be text, json, or jsonb.
  declare v_tabs_jsonb jsonb;
  begin
    begin
      v_tabs_jsonb := coalesce(
        nullif(v_event.tabs::text, '')::jsonb,
        '[]'::jsonb);
    exception when others then
      v_tabs_jsonb := '[]'::jsonb;
    end;

    v_has_vendors := coalesce(
      (select bool_or(t->>'key' = 'vendors')
         from jsonb_array_elements(v_tabs_jsonb) t),
      false);
  end;

  return jsonb_build_object(
    'type', 'event',
    'event', jsonb_build_object(
      'id',    v_event.id,
      'title', v_event.title,
      'slug',  v_event.slug
    ),
    'capabilities', jsonb_build_object(
      'event',   true,
      'vendors', v_has_vendors
    ),
    'partner', v_partner_jsonb
  );
end;
$$;

grant execute on function public.get_partner_capabilities_by_token(text) to anon;
