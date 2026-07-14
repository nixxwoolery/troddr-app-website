create or replace function public.admin_get_overview(p_admin_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_today date := (now() at time zone 'America/Jamaica')::date;
begin
  if not public._is_admin(p_admin_token) then
    return null;
  end if;

  return jsonb_build_object(

    'generated_at', now(),

    'users', jsonb_build_object(
      'total',        (select count(*) from public."user"),
      'new_7d',       (select count(*) from public."user" where created_at >= now() - interval '7 days'),
      'new_30d',      (select count(*) from public."user" where created_at >= now() - interval '30 days'),
      'push_opt_in',  (select count(*) from public."user" where push_opt_in = true),
      'active_today', (select count(distinct coalesce(user_id::text, 'anon:' || session_id))
                         from public.analytics_events
                        where (created_at at time zone 'America/Jamaica')::date = v_today),
      'active_7d',    (select count(distinct coalesce(user_id::text, 'anon:' || session_id))
                         from public.analytics_events
                        where created_at >= now() - interval '7 days'),
      'active_30d',   (select count(distinct coalesce(user_id::text, 'anon:' || session_id))
                         from public.analytics_events
                        where created_at >= now() - interval '30 days')
    ),

    'activity_daily', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'd',     d.day::date,
        'events', coalesce(a.events, 0),
        'users',  coalesce(a.users, 0)
      ) order by d.day), '[]'::jsonb)
      from generate_series(v_today - 29, v_today, interval '1 day') as d(day)
      left join (
        select (created_at at time zone 'America/Jamaica')::date as day,
               count(*) as events,
               count(distinct coalesce(user_id::text, 'anon:' || session_id)) as users
          from public.analytics_events
         where created_at >= (v_today - 29)::timestamp at time zone 'America/Jamaica'
         group by 1
      ) a on a.day = d.day::date
    ),

    'events', jsonb_build_object(
      'live_today', (select count(*) from public.events e
                      where e.deleted_at is null
                        and e.start_date <= v_today
                        and coalesce(e.end_date, e.start_date) >= v_today),
      'upcoming_30d', (select count(*) from public.events e
                        where e.deleted_at is null
                          and e.start_date > v_today
                          and e.start_date <= v_today + 30),
      'total_active', (select count(*) from public.events e where e.deleted_at is null)
    ),

    'catalog', jsonb_build_object(
      'places',          (select count(*) from public.places),
      'vendors',         (select count(*) from public.vendors),
      'guides',          (select count(*) from public.guides),
      'active_specials', (select count(*) from public.specials where active = true)
    ),

    'pending', jsonb_build_object(
      'submissions', (select count(*) from public.event_partner_submissions
                       where status in ('submitted','reviewing')),
      'specials',    (select count(*) from public.specials
                       where submission_status = 'pending'),
      'messages',    (select count(*) from public.partner_messages
                       where status = 'new'),
      'bookings',    (select count(*) from public.bookings
                       where status = 'pending'),
      'bookings_attention', (select count(*) from public.bookings
                              where needs_troddr_attention = true),
      'suggested_places', (select count(*) from public.suggested_places
                            where matched_place_id is null)
    ),

    'feedback', jsonb_build_object(
      'event_total',  (select count(*) from public.event_feedback),
      'event_7d',     (select count(*) from public.event_feedback
                        where created_at >= now() - interval '7 days'),
      'place_total',  (select count(*) from public.visited_feedback),
      'place_7d',     (select count(*) from public.visited_feedback
                        where created_at >= now() - interval '7 days'),
      'app_open',     (select count(*) from public.feedback
                        where coalesce(status, 'open') not in ('resolved','closed','done'))
    ),

    'partners', jsonb_build_object(
      'loyalty', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'place',            p.name,
          'reward',           lp.reward,
          'required_stamps',  lp.required_stamps,
          'is_active',        lp.is_active,
          'linked_locations', lp.link_locations,
          'cards',            (select count(*) from public.user_loyalty_cards c
                                where c.program_id = lp.id),
          'redeemed_cycles',  (select coalesce(sum(c.completed_cycles), 0) from public.user_loyalty_cards c
                                where c.program_id = lp.id),
          'stamps_30d',       (select count(*) from public.loyalty_visits v
                                where v.place_id = lp.place_id
                                  and v.stamped_at >= now() - interval '30 days')
        ) order by lp.created_at), '[]'::jsonb)
        from public.loyalty_programs lp
        left join public.places p on p.id = lp.place_id
      ),
      'checkin_places', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'place',   p.name,
          'checkin', s.checkin_enabled,
          'loyalty', s.loyalty_enabled,
          'nfc',     s.nfc_enabled,
          'insider', (select jsonb_build_object(
                        'guest', i.guest_min, 'familiar', i.familiar_face_min,
                        'regular', i.regular_min, 'favourite', i.house_favourite_min)
                       from public.insider_status_settings i
                      where i.place_id = s.place_id)
        ) order by p.name), '[]'::jsonb)
        from public.place_checkin_settings s
        left join public.places p on p.id = s.place_id
      ),
      'active_perks', (select count(*) from public.partner_perks where active = true)
    )

  );
end;
$$;

create or replace function public.admin_get_analytics(
  p_admin_token text,
  p_days        integer default 30
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_days  integer := greatest(1, least(coalesce(p_days, 30), 365));
  v_today date    := (now() at time zone 'America/Jamaica')::date;
  v_from  timestamptz;
begin
  if not public._is_admin(p_admin_token) then
    return null;
  end if;

  v_from := (v_today - (v_days - 1))::timestamp at time zone 'America/Jamaica';

  return jsonb_build_object(

    'window_days', v_days,
    'generated_at', now(),

    'totals', (
      select jsonb_build_object(
        'events',   count(*),
        'users',    count(distinct coalesce(user_id::text, 'anon:' || session_id)),
        'sessions', count(distinct session_id),
        'signups',  (select count(*) from public."user" where created_at >= v_from)
      )
      from public.analytics_events
      where created_at >= v_from
    ),

    'daily', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'd',      d.day::date,
        'events', coalesce(a.events, 0),
        'users',  coalesce(a.users, 0)
      ) order by d.day), '[]'::jsonb)
      from generate_series(v_today - (v_days - 1), v_today, interval '1 day') as d(day)
      left join (
        select (created_at at time zone 'America/Jamaica')::date as day,
               count(*) as events,
               count(distinct coalesce(user_id::text, 'anon:' || session_id)) as users
          from public.analytics_events
         where created_at >= v_from
         group by 1
      ) a on a.day = d.day::date
    ),

    'by_event', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'name', event_name, 'n', n, 'users', users
      ) order by n desc), '[]'::jsonb)
      from (
        select event_name,
               count(*) as n,
               count(distinct coalesce(user_id::text, 'anon:' || session_id)) as users
          from public.analytics_events
         where created_at >= v_from
         group by event_name
      ) t
    ),

    'by_platform', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'platform', coalesce(device_platform, 'unknown'), 'n', n
      ) order by n desc), '[]'::jsonb)
      from (
        select device_platform, count(*) as n
          from public.analytics_events
         where created_at >= v_from
         group by device_platform
      ) t
    ),

    'top_places', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', t.entity_id, 'name', t.name, 'slug', t.slug, 'views', t.views
      ) order by t.views desc), '[]'::jsonb)
      from (
        select ae.entity_id,
               coalesce(max(p.name), max(ae.source_context->>'slug'), ae.entity_id) as name,
               max(coalesce(p.slug, ae.source_context->>'slug')) as slug,
               count(*) as views
          from public.analytics_events ae
          left join public.places p on p.id::text = ae.entity_id
         where ae.event_name = 'place_viewed'
           and ae.created_at >= v_from
           and ae.entity_id is not null
         group by ae.entity_id
         order by count(*) desc
         limit 12
      ) t
    ),

    'top_events', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', t.entity_id, 'title', t.title, 'slug', t.slug,
        'views', t.views, 'saves', t.saves
      ) order by t.views desc), '[]'::jsonb)
      from (
        select ae.entity_id,
               coalesce(max(e.title), max(ae.source_context->>'event_slug'), ae.entity_id) as title,
               max(coalesce(e.slug, ae.source_context->>'event_slug')) as slug,
               count(*) filter (where ae.event_name = 'event_viewed') as views,
               count(*) filter (where ae.event_name = 'event_saved')  as saves
          from public.analytics_events ae
          left join public.events e on e.id::text = ae.entity_id
         where ae.event_name in ('event_viewed', 'event_saved')
           and ae.created_at >= v_from
           and ae.entity_id is not null
         group by ae.entity_id
         order by count(*) filter (where ae.event_name = 'event_viewed') desc
         limit 12
      ) t
    ),

    'top_vendors', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'vendor_id', t.vendor_id, 'name', t.name,
        'event_title', t.event_title, 'clicks', t.clicks
      ) order by t.clicks desc), '[]'::jsonb)
      from (
        select ae.source_context->>'vendor_id' as vendor_id,
               coalesce(max(ae.source_context->>'vendor_name'), 'Unknown vendor') as name,
               max(e.title) as event_title,
               count(*) as clicks
          from public.analytics_events ae
          left join public.events e on e.id::text = ae.entity_id
         where ae.event_name = 'vendor_clicked'
           and ae.created_at >= v_from
           and ae.source_context->>'vendor_id' is not null
         group by ae.source_context->>'vendor_id'
         order by count(*) desc
         limit 12
      ) t
    ),

    'top_guides', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'slug', t.slug, 'title', t.title, 'views', t.views
      ) order by t.views desc), '[]'::jsonb)
      from (
        select ae.entity_id as slug,
               coalesce(max(g.title), ae.entity_id) as title,
               count(*) as views
          from public.analytics_events ae
          left join public.guides g on g.id::text = ae.source_context->>'guide_id'
         where ae.event_name = 'guide_viewed'
           and ae.created_at >= v_from
           and ae.entity_id is not null
         group by ae.entity_id
         order by count(*) desc
         limit 12
      ) t
    ),

    'top_specials', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', t.special_id, 'title', t.title, 'views', t.views
      ) order by t.views desc), '[]'::jsonb)
      from (
        select coalesce(ae.source_context->>'special_id', ae.entity_id) as special_id,
               coalesce(max(sp.title), ae.entity_id) as title,
               count(*) as views
          from public.analytics_events ae
          left join public.specials sp on sp.id::text = ae.source_context->>'special_id'
         where ae.event_name = 'special_viewed'
           and ae.created_at >= v_from
         group by coalesce(ae.source_context->>'special_id', ae.entity_id), ae.entity_id
         order by count(*) desc
         limit 12
      ) t
    ),

    'search_terms', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'q', t.q, 'n', t.n,
        'avg_results',  t.avg_results,
        'zero_results', t.zero_results
      ) order by t.n desc), '[]'::jsonb)
      from (
        select lower(trim(ae.source_context->>'query')) as q,
               count(*) as n,
               round(avg(nullif(ae.source_context->>'result_count', '')::numeric), 1) as avg_results,
               count(*) filter (where (ae.source_context->>'result_count')::numeric = 0) as zero_results
          from public.analytics_events ae
         where ae.event_name = 'search_performed'
           and ae.created_at >= v_from
           and nullif(trim(ae.source_context->>'query'), '') is not null
         group by lower(trim(ae.source_context->>'query'))
         order by count(*) desc
         limit 25
      ) t
    ),

    'outbound', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'type', t.event_name, 'n', t.n
      ) order by t.n desc), '[]'::jsonb)
      from (
        select event_name, count(*) as n
          from public.analytics_events
         where created_at >= v_from
           and event_name in ('website_clicked','instagram_clicked','directions_clicked',
                              'ticket_clicked','booking_clicked','share_clicked')
         group by event_name
      ) t
    ),

    'outbound_targets', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'name', t.name, 'n', t.n
      ) order by t.n desc), '[]'::jsonb)
      from (
        select coalesce(max(p.name), max(e.title), ae.entity_id) as name,
               count(*) as n
          from public.analytics_events ae
          left join public.places p on p.id::text = ae.entity_id
          left join public.events e on e.id::text = ae.entity_id
         where ae.created_at >= v_from
           and ae.event_name in ('website_clicked','instagram_clicked','directions_clicked',
                                 'ticket_clicked','booking_clicked','share_clicked')
           and ae.entity_id is not null
         group by ae.entity_id
         order by count(*) desc
         limit 15
      ) t
    ),

    'place_views_month', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'name', t.name, 'slug', t.slug, 'views', t.n
      ) order by t.n desc), '[]'::jsonb)
      from (
        select coalesce(max(p.name), max(ae.source_context->>'slug'), ae.entity_id) as name,
               max(coalesce(p.slug, ae.source_context->>'slug')) as slug,
               count(*) as n
          from public.analytics_events ae
          left join public.places p on p.id::text = ae.entity_id
         where ae.event_name = 'place_viewed'
           and ae.entity_id is not null
           and ae.created_at >= date_trunc('month', now() at time zone 'America/Jamaica')
                                  at time zone 'America/Jamaica'
         group by ae.entity_id
         order by count(*) desc
         limit 50
      ) t
    )

  );
end;
$$;;
