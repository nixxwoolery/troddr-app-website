-- ============================================================
-- Event Analytics RPC for partner-event.html
-- Resolves events.partner_access_token.
-- ============================================================

create or replace function public.get_partner_event_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event   events%rowtype;
  v_now     timestamptz := now();
  v_starts  timestamptz;
  v_ends    timestamptz;
  v_days    int;
  v_is_past boolean;
  v_tabs    jsonb;
begin
  select * into v_event
    from public.events
   where partner_access_token = p_token;

  if v_event.id is null then
    return null;
  end if;

  -- Defensive timestamp composition
  begin
    v_starts := (v_event.start_date::timestamp
                 + coalesce(v_event.start_time, '00:00'::time))
                at time zone coalesce(nullif(v_event.timezone, ''), 'America/Jamaica');
    v_ends   := (coalesce(v_event.end_date, v_event.start_date)::timestamp
                 + coalesce(v_event.end_time, '23:59'::time))
                at time zone coalesce(nullif(v_event.timezone, ''), 'America/Jamaica');
  exception when others then
    v_starts := v_event.start_date::timestamptz;
    v_ends   := coalesce(v_event.end_date, v_event.start_date)::timestamptz;
  end;

  v_days    := floor(extract(epoch from (v_starts - v_now)) / 86400)::int;
  v_is_past := v_ends < v_now;

  -- Parse tabs defensively: column could be text, json, or jsonb.
  begin
    v_tabs := coalesce(nullif(v_event.tabs::text, '')::jsonb, '[]'::jsonb);
  exception when others then
    v_tabs := '[]'::jsonb;
  end;

  return jsonb_build_object(

    'event', (to_jsonb(v_event) - 'partner_access_token'),

    'stats', jsonb_build_object(
      'view_count',       coalesce(v_event.view_count, 0),
      'interested_count', coalesce(v_event.interested_count, 0),
      'going_count',      coalesce(v_event.going_count, 0),
      'capacity',         v_event.capacity,
      'is_sold_out',      coalesce(v_event.is_sold_out, false),
      'days_until_event', v_days,
      'is_past',          v_is_past,
      'is_today',         (v_starts::date = v_now::date),
      'has_tickets',      coalesce(v_event.has_online_tickets, false),
      'price_min',        v_event.ticket_price_min,
      'price_max',        v_event.ticket_price_max,
      'currency',         coalesce(nullif(v_event.currency, ''), 'JMD'),

      'capacity_fill_rate',
        (case
          when v_event.capacity is null or v_event.capacity = 0 then null
          else round(
            (coalesce(v_event.going_count, 0)::numeric / v_event.capacity) * 100,
            1)
        end),

      'view_to_interest_rate',
        (case
          when coalesce(v_event.view_count, 0) = 0 then null
          else round(
            (coalesce(v_event.interested_count, 0)::numeric / v_event.view_count) * 100,
            1)
        end),

      'interest_to_going_rate',
        (case
          when coalesce(v_event.interested_count, 0) = 0 then null
          else round(
            (coalesce(v_event.going_count, 0)::numeric / v_event.interested_count) * 100,
            1)
        end)
    ),

    'tabs', v_tabs,

    'capabilities', jsonb_build_object(
      'event',   true,
      'vendors', coalesce(
        (select bool_or(t->>'key' = 'vendors')
           from jsonb_array_elements(v_tabs) t),
        false)
    ),

    -- ── Vendors lineup with per-vendor menu + per-item ratings ─
    'vendors', (
      with vendor_base as (
        select distinct on (vendor_id)
          vendor_id, vendor_name, vendor_description, vendor_type,
          logo_url, cover_image_url, instagram, website,
          place_id, place_slug, place_name, place_image, place_category,
          event_vendor_id, booth_number, vendor_is_featured
        from public.event_vendors_with_menu
        where event_id = v_event.id
      )
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'vendor_id',       vb.vendor_id,
            'name',            vb.vendor_name,
            'description',     vb.vendor_description,
            'vendor_type',     vb.vendor_type,
            'logo_url',        vb.logo_url,
            'cover_image_url', vb.cover_image_url,
            'instagram',       vb.instagram,
            'website',         vb.website,
            'place_id',        vb.place_id,
            'place_slug',      vb.place_slug,
            'place_name',      vb.place_name,
            'place_image',     vb.place_image,
            'place_category',  vb.place_category,
            'event_vendor_id', vb.event_vendor_id,
            'booth_number',    vb.booth_number,
            'is_featured',     vb.vendor_is_featured,

            -- Total ratings across all this vendor's items
            'total_ratings', (
              select count(*) from public.user_vendor_item_ratings r
               where r.event_id = v_event.id
                 and r.vendor_id = vb.vendor_id::text
            ),

            -- Menu items with per-item ratings
            'menu_items', (
              select coalesce(jsonb_agg(item_obj order by sort_key, name nulls last), '[]'::jsonb)
              from (
                select distinct on (menu_item_id)
                  menu_item_id,
                  menu_item_name as name,
                  menu_item_description as description,
                  price, currency, menu_category as category,
                  tags, is_special, is_sold_out,
                  menu_image_url as image_url,
                  sort_order as sort_key,
                  jsonb_build_object(
                    'menu_item_id', menu_item_id,
                    'name',         menu_item_name,
                    'description',  menu_item_description,
                    'price',        price,
                    'currency',     currency,
                    'category',     menu_category,
                    'tags',         tags,
                    'is_special',   is_special,
                    'is_sold_out',  is_sold_out,
                    'image_url',    menu_image_url,
                    'rating_count', (
                      select count(*) from public.user_vendor_item_ratings r
                       where r.event_id = v_event.id
                         and r.vendor_id = vb.vendor_id::text
                         and r.item_name = evm.menu_item_name
                    ),
                    'rating_breakdown', (
                      select coalesce(jsonb_object_agg(rating, n), '{}'::jsonb)
                      from (
                        select rating, count(*) as n
                          from public.user_vendor_item_ratings r
                         where r.event_id = v_event.id
                           and r.vendor_id = vb.vendor_id::text
                           and r.item_name = evm.menu_item_name
                         group by rating
                      ) rb
                    )
                  ) as item_obj
                from public.event_vendors_with_menu evm
                where evm.event_id = v_event.id
                  and evm.vendor_id = vb.vendor_id
                  and evm.menu_item_id is not null
              ) items
            )
          )
          order by vb.vendor_is_featured desc nulls last, vb.vendor_name
        ),
        '[]'::jsonb)
      from vendor_base vb
    ),

    'vendor_stats', (
      with rows as (
        select distinct on (vendor_id)
          vendor_id, vendor_is_featured, place_id, logo_url, cover_image_url
        from public.event_vendors_with_menu
        where event_id = v_event.id
      )
      select jsonb_build_object(
        'total',         (select count(*) from rows),
        'featured',      (select count(*) from rows where vendor_is_featured = true),
        'with_place',    (select count(*) from rows where place_id is not null),
        'with_imagery',  (select count(*) from rows where coalesce(logo_url, cover_image_url) is not null)
      )
    ),

    'menu_stats', (
      with rows as (
        select menu_item_id, vendor_id
        from public.event_vendors_with_menu
        where event_id = v_event.id and menu_item_id is not null
      )
      select jsonb_build_object(
        'items_total',     (select count(distinct menu_item_id) from rows),
        'vendors_with_menu', (select count(distinct vendor_id) from rows)
      )
    ),

    -- ── Top-rated menu items (real interaction signal) ─
    'top_rated_items', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'vendor_id', vendor_id,
            'item_name', item_name,
            'count',     n,
            'breakdown', breakdown
          )
          order by n desc),
        '[]'::jsonb)
      from (
        select
          vendor_id,
          item_name,
          count(*) as n,
          jsonb_object_agg(rating, rating_count) as breakdown
        from (
          select vendor_id, item_name, rating, count(*) as rating_count
            from public.user_vendor_item_ratings
           where event_id = v_event.id
           group by vendor_id, item_name, rating
        ) per_rating
        group by vendor_id, item_name
        order by sum(rating_count) desc
        limit 15
      ) t
    ),

    'rating_summary', (
      select jsonb_build_object(
        'total_ratings',
          (select count(*) from public.user_vendor_item_ratings where event_id = v_event.id),
        'unique_raters',
          (select count(distinct user_id) from public.user_vendor_item_ratings where event_id = v_event.id),
        'by_rating',
          (select coalesce(jsonb_object_agg(rating, n), '{}'::jsonb)
             from (
               select rating, count(*) as n
                 from public.user_vendor_item_ratings
                where event_id = v_event.id
                group by rating
             ) r)
      )
    ),

    -- ── Sponsors ─
    'sponsors', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id',           s.id,
            'name',         s.name,
            'logo_url',     s.logo_url,
            'website',      s.website,
            'brand_color',  s.brand_color,
            'tier',         es.tier,
            'tier_label',   es.display_tier_label,
            'is_featured',  es.is_featured,
            'tagline',      es.custom_tagline
          )
          order by es.display_order, es.tier),
        '[]'::jsonb)
      from public.event_sponsors es
      join public.sponsors s on s.id = es.sponsor_id
      where es.event_id = v_event.id and coalesce(es.is_active, true) = true
    )
  );
end;
$$;

grant execute on function public.get_partner_event_by_token(text) to anon;
