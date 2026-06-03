-- ============================================================
-- Partner Capabilities RPC (polymorphic: place OR event)
-- Returns the partner type, identity, sidebar capabilities, and brand colors.
-- Called by every partner-* page on load.
-- ============================================================

create or replace function public.get_partner_capabilities_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place      places%rowtype;
  v_event      events%rowtype;
  v_has_loyalty boolean;
  v_has_vendors boolean;
begin
  ------------------------------------------------------------
  -- Try place token
  ------------------------------------------------------------
  select * into v_place
    from public.places
   where partner_access_token = p_token;

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
        'feedback', true
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
      )
    );
  end if;

  ------------------------------------------------------------
  -- Try event token
  ------------------------------------------------------------
  select * into v_event
    from public.events
   where partner_access_token = p_token;

  if v_event.id is not null then
    v_has_vendors := coalesce(
      (select bool_or(t->>'key' = 'vendors')
         from jsonb_array_elements(
           coalesce(nullif(v_event.tabs, '')::jsonb, '[]'::jsonb)
         ) t),
      false);

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
      )
    );
  end if;

  return null;
end;
$$;

grant execute on function public.get_partner_capabilities_by_token(text) to anon;
