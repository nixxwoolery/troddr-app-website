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

    'stats', (
      with
        viewers as (
          select count(*) as n
            from public.user_event_interactions
           where event_id = v_event.id and interaction_type = 'viewed'
        ),
        saves as (
          select count(*) as n from public.saved_events where event_id = v_event.id
        ),
        saves_7d as (
          select count(*) as n from public.saved_events
           where event_id = v_event.id and created_at >= v_now - interval '7 days'
        ),
        interests as (
          select status, count(*) as n
            from public.event_interests
           where event_id = v_event.id
           group by status
        ),
        interests_7d as (
          select count(*) as n from public.event_interests
           where event_id = v_event.id and created_at >= v_now - interval '7 days'
        ),
        going_7d as (
          select count(*) as n from public.event_interests
           where event_id = v_event.id
             and status = 'going'
             and updated_at >= v_now - interval '7 days'
        ),
        checkins as (
          select count(*) as n
            from public.user_event_activity
           where event_id = v_event.id and activity_type = 'checked_in'
        ),
        shares as (
          select count(*) as n from public.user_event_activity
           where event_id = v_event.id and activity_type = 'shared'
        ),
        bookmarks as (
          select count(*) as n from public.user_event_activity
           where event_id = v_event.id and activity_type = 'bookmarked'
        )
      select jsonb_build_object(
        -- Hard event metadata
        'capacity',         v_event.capacity,
        'is_sold_out',      coalesce(v_event.is_sold_out, false),
        'days_until_event', v_days,
        'is_past',          v_is_past,
        'is_today',         (v_starts::date = v_now::date),
        'has_tickets',      coalesce(v_event.has_online_tickets, false),
        'price_min',        v_event.ticket_price_min,
        'price_max',        v_event.ticket_price_max,
        'currency',         coalesce(nullif(v_event.currency, ''), 'JMD'),

        -- Real engagement (from new tables)
        'view_count',       coalesce(v_event.view_count, 0),
        'unique_viewers',   (select n from viewers),
        'saved_count',      (select n from saves),
        'interested_count', coalesce((select n from interests where status = 'interested'), 0),
        'going_count',      coalesce((select n from interests where status = 'going'), 0),
        'went_count',       coalesce((select n from interests where status = 'went'), 0),
        'checkin_count',    (select n from checkins),
        'shares_count',     (select n from shares),
        'bookmarks_count',  (select n from bookmarks),
        'saves_7d',         (select n from saves_7d),
        'interests_7d',     (select n from interests_7d),
        'going_7d',         (select n from going_7d),

        'checkin_by_method', (
          select coalesce(jsonb_object_agg(coalesce(checkin_method, 'self'), n), '{}'::jsonb)
          from (
            select checkin_method, count(*) as n
              from public.user_event_activity
             where event_id = v_event.id and activity_type = 'checked_in'
             group by checkin_method
          ) m
        ),

        'capacity_fill_rate',
          (case
            when v_event.capacity is null or v_event.capacity = 0 then null
            else round(
              (coalesce((select n from interests where status = 'going'), 0)::numeric
                / v_event.capacity) * 100,
              1)
          end),

        'view_to_interest_rate',
          (case
            when (select n from viewers) = 0 then null
            else round(
              ((select coalesce(sum(n), 0) from interests where status in ('interested','going','went'))::numeric
                / (select n from viewers)) * 100,
              1)
          end),

        'interest_to_going_rate',
          (case
            when coalesce((select n from interests where status = 'interested'), 0) = 0 then null
            else round(
              (coalesce((select n from interests where status = 'going'), 0)::numeric
                / (select n from interests where status = 'interested')) * 100,
              1)
          end),

        'going_to_attended_rate',
          (case
            when coalesce((select n from interests where status = 'going'), 0) = 0 then null
            else round(
              ((select n from checkins)::numeric
                / (select n from interests where status = 'going')) * 100,
              1)
          end)
      )
    ),

    -- ── Audience location (from interactions.country) ─
    'top_countries', (
      select coalesce(
        jsonb_agg(jsonb_build_object('country', country, 'count', n) order by n desc),
        '[]'::jsonb)
      from (
        select country, count(*) as n
          from public.user_event_interactions
         where event_id = v_event.id
           and country is not null and country <> ''
         group by country
         order by count(*) desc
         limit 10
      ) c
    ),

    -- ── Activity trend (last 30 days, bucketed by day) ─
    'activity_trend', (
      select coalesce(
        jsonb_agg(jsonb_build_object('date', d, 'count', n) order by d),
        '[]'::jsonb)
      from (
        select to_char(created_at::date, 'YYYY-MM-DD') as d, count(*) as n
          from public.user_event_activity
         where event_id = v_event.id
           and created_at >= v_now - interval '30 days'
         group by created_at::date
      ) t
    ),

    -- ── Schedule overview ─
    'schedule', jsonb_build_object(
      'days_count', (
        select count(*) from public.event_schedule_days where event_id = v_event.id
      ),
      'items_count', (
        select count(*) from public.event_schedule_items where event_id = v_event.id
      ),
      'featured_count', (
        select count(*) from public.event_schedule_items
         where event_id = v_event.id and is_featured = true
      ),
      'must_see_count', (
        select count(*) from public.event_schedule_items
         where event_id = v_event.id and is_must_see = true
      ),
      'days', (
        select coalesce(
          jsonb_agg(jsonb_build_object(
            'id',            d.id,
            'date',          d.date,
            'label',         d.label,
            'date_display',  d.date_display,
            'gates_open',    d.gates_open,
            'gates_close',   d.gates_close,
            'is_cancelled',  d.is_cancelled,
            'day_number',    d.day_number,
            'items_count',   (select count(*) from public.event_schedule_items
                               where day_id = d.id and is_published = true),
            'must_see_count',(select count(*) from public.event_schedule_items
                               where day_id = d.id and is_must_see = true)
          ) order by d.date),
          '[]'::jsonb)
        from public.event_schedule_days d
        where d.event_id = v_event.id
      ),
      'next_item', (
        select jsonb_build_object(
          'id',          id,
          'title',       title,
          'subtitle',    subtitle,
          'start_time',  start_time,
          'end_time',    end_time,
          'venue_override', venue_override,
          'image_url',   image_url,
          'is_must_see', is_must_see
        )
        from public.event_schedule_items
        where event_id = v_event.id
          and is_published = true
          and start_time > v_now
        order by start_time
        limit 1
      ),

      'total_saved', (
        select count(*) from public.user_saved_schedule_items
         where event_id = v_event.id
      ),

      'unique_savers', (
        select count(distinct user_id) from public.user_saved_schedule_items
         where event_id = v_event.id
      ),

      'top_saved_items', (
        select coalesce(
          jsonb_agg(jsonb_build_object(
            'id',             sc.schedule_item_id,
            'count',          sc.n,
            'title',          si.title,
            'subtitle',       si.subtitle,
            'start_time',     si.start_time,
            'venue_override', si.venue_override,
            'is_must_see',    si.is_must_see,
            'is_featured',    si.is_featured,
            'image_url',      si.image_url,
            'category',       si.category
          ) order by sc.n desc),
          '[]'::jsonb)
        from (
          select schedule_item_id, count(*) as n
            from public.user_saved_schedule_items
           where event_id = v_event.id
           group by schedule_item_id
           order by count(*) desc
           limit 10
        ) sc
        join public.event_schedule_items si on si.id = sc.schedule_item_id
        where si.is_published = true
      )
    ),

    -- ── Updates (organizer-pushed messages) ─
    'updates', (
      select coalesce(
        jsonb_agg(jsonb_build_object(
          'id',         id,
          'title',      title,
          'message',    message,
          'created_at', created_at
        ) order by created_at desc),
        '[]'::jsonb)
      from (
        select * from public.event_updates
        where event_id = v_event.id
        order by created_at desc
        limit 20
      ) u
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
          vendor_id,
          coalesce((select nullif(btrim(ev.display_name), '')
                      from public.event_vendors ev
                     where ev.id = evm_base.event_vendor_id), vendor_name) as vendor_name,
          vendor_description, vendor_type,
          coalesce((select ev.filter_tags
                      from public.event_vendors ev
                     where ev.id = evm_base.event_vendor_id), '{}'::text[]) as filter_tags,
          logo_url, cover_image_url, instagram, website,
          place_id, place_slug, place_name, place_image, place_category,
          event_vendor_id, booth_number, vendor_is_featured
        from public.event_vendors_with_menu evm_base
        where event_id = v_event.id
      )
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'vendor_id',       vb.vendor_id,
            'name',            vb.vendor_name,
            'description',     vb.vendor_description,
            'vendor_type',     vb.vendor_type,
            'filter_tags',     vb.filter_tags,
            'filters',         vb.filter_tags,
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
            'zone', (
              select ev.zone from public.event_vendors ev
               where ev.id = vb.event_vendor_id
            ),
            'is_featured',     vb.vendor_is_featured,

            -- Per-vendor activity. The app has used both vendor ids and
            -- event_vendor ids for entity_id, so count either shape.
            -- NOTE: activity_type 'visited' is deliberately NOT counted as a
            -- view — in the app that name belongs to the My Plan "Visited"
            -- check-off (written as 'going', see visited_count below).
            'view_count', (
              select count(*) from public.user_event_activity a
               where a.event_id = v_event.id
                 and a.entity_type in ('vendor', 'event_vendor')
                 and a.entity_id in (vb.vendor_id, vb.event_vendor_id)
                 and a.action = 'viewed'
            ),
            'save_count', (
              select count(*) from public.user_event_activity a
               where a.event_id = v_event.id
                 and a.entity_type in ('vendor', 'event_vendor')
                 and a.entity_id in (vb.vendor_id, vb.event_vendor_id)
                 and (a.activity_type = 'bookmarked' or a.action = 'saved')
            ),
            'menu_clicks', (
              select count(*) from public.user_event_activity a
               where a.event_id = v_event.id
                 and a.entity_type in ('vendor', 'event_vendor', 'vendor_menu')
                 and a.entity_id in (vb.vendor_id, vb.event_vendor_id)
                 and a.action in ('menu_click', 'menu_clicked', 'menu_viewed')
            ),

            -- "My Plan" signals from the mobile app. The app's UI labels do
            -- NOT match the stored activity_type names — this is the
            -- confirmed mapping (do not "fix" it to match intuition):
            --   app "Interested"  → activity_type 'bookmarked'
            --   app "Visited"     → activity_type 'going'
            --   app "Favourites"  → activity_type 'interested'
            --   app "Want to try" → rows in user_saved_menu_items (per vendor)
            -- All activity rows are written with action = null. Some app
            -- builds omit event_id, so also accept a null event_id when the
            -- row points at this event's event_vendor id (those ids are
            -- event-scoped, so the match stays unambiguous).
            'interested_count', (
              select count(*) from public.user_event_activity a
               where a.entity_type in ('vendor', 'event_vendor')
                 and a.entity_id in (vb.vendor_id, vb.event_vendor_id)
                 and a.activity_type = 'bookmarked'
                 and (a.event_id = v_event.id
                      or (a.event_id is null and a.entity_id = vb.event_vendor_id))
            ),
            'visited_count', (
              select count(*) from public.user_event_activity a
               where a.entity_type in ('vendor', 'event_vendor')
                 and a.entity_id in (vb.vendor_id, vb.event_vendor_id)
                 and a.activity_type = 'going'
                 and (a.event_id = v_event.id
                      or (a.event_id is null and a.entity_id = vb.event_vendor_id))
            ),
            'favourite_count', (
              select count(*) from public.user_event_activity a
               where a.entity_type in ('vendor', 'event_vendor')
                 and a.entity_id in (vb.vendor_id, vb.event_vendor_id)
                 and a.activity_type = 'interested'
                 and (a.event_id = v_event.id
                      or (a.event_id is null and a.entity_id = vb.event_vendor_id))
            ),
            'want_to_try_count', (
              select count(*) from public.user_saved_menu_items s
               where s.vendor_id in (vb.vendor_id, vb.event_vendor_id)
                 and (s.event_id = v_event.id
                      or (s.event_id is null and s.vendor_id = vb.event_vendor_id))
            ),

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

    -- ── Sponsors (with activations + real engagement) ─
    'sponsors', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id',                 s.id,
            'sponsor_id',         s.id,
            'event_sponsor_id',   es.id,
            'name',               s.name,
            'sponsor_name',       s.name,
            'logo_url',           s.logo_url,
            'website',            s.website,
            'instagram',          s.instagram,
            'brand_color',        s.brand_color,
            'tier',               es.tier,
            'tier_label',         es.display_tier_label,
            'display_tier_label', es.display_tier_label,
            'is_featured',        es.is_featured,
            'tagline',            es.custom_tagline,
            'custom_tagline',     es.custom_tagline,
            'description',        s.description,
            'activations', (
              select coalesce(
                jsonb_agg(jsonb_build_object(
                  'id',             a.id,
                  'name',           a.name,
                  'description',    a.description,
                  'zone',           a.zone,
                  'days_active',    a.days_active,
                  'start_time',     a.start_time,
                  'end_time',       a.end_time,
                  'troddr_offer',   a.troddr_offer,
                  'checkin_method', a.checkin_method,
                  'display_order',  a.display_order,
                  'has_qr',         (a.qr_code_token is not null),
                  'has_nfc',        (a.nfc_token is not null),
                  'redemptions', (
                    select count(*) from public.user_event_activity
                     where event_id = v_event.id
                       and entity_type = 'sponsor_activation'
                       and entity_id = a.id
                  )
                ) order by a.display_order),
                '[]'::jsonb)
              from public.event_sponsor_activations a
              where a.event_sponsor_id = es.id
                and coalesce(a.is_active, true) = true
            )
          )
          order by es.display_order, es.tier),
        '[]'::jsonb)
      from public.event_sponsors es
      join public.sponsors s on s.id = es.sponsor_id
      where es.event_id = v_event.id
        and coalesce(es.is_active, true) = true
        and coalesce(s.is_active, true) = true
    )
  );
end;
$$;

grant execute on function public.get_partner_event_by_token(text) to anon;
