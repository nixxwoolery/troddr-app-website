create or replace function public.admin_get_event_console(
  p_admin_token text,
  p_event_id    uuid
)
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

    'event', (
      select jsonb_build_object(
        'id', e.id, 'title', e.title, 'slug', e.slug,
        'start_date', e.start_date, 'end_date', e.end_date,
        'start_time', e.start_time, 'end_time', e.end_time,
        'status', e.status, 'is_featured', e.is_featured,
        'venue_name', e.venue_name, 'town', e.town, 'parish', e.parish,
        'is_live', (e.start_date <= v_today and coalesce(e.end_date, e.start_date) >= v_today)
      )
      from public.events e where e.id = p_event_id
    ),

    'kpis', jsonb_build_object(
      'views',        (select count(*) from public.analytics_events
                        where event_name = 'event_viewed' and entity_id = p_event_id::text),
      'saves',        (select count(*) from public.saved_events where event_id = p_event_id),
      'interested',   (select count(*) from public.event_interests
                        where event_id = p_event_id and status = 'interested'),
      'going',        (select count(*) from public.event_interests
                        where event_id = p_event_id and status = 'going'),
      'vendor_clicks',(select count(*) from public.analytics_events
                        where event_name = 'vendor_clicked' and entity_id = p_event_id::text),
      'ticket_clicks',(select count(*) from public.analytics_events
                        where event_name = 'ticket_clicked' and entity_id = p_event_id::text),
      'push_audience',(select count(distinct u.id)
                         from public."user" u
                        where u.push_opt_in = true
                          and u.id in (
                            select user_id from public.saved_events where event_id = p_event_id
                            union
                            select user_id from public.event_interests where event_id = p_event_id
                          ))
    ),

    'daily', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'd',      d.day::date,
        'views',  coalesce(a.views, 0),
        'clicks', coalesce(a.clicks, 0)
      ) order by d.day), '[]'::jsonb)
      from generate_series(v_today - 29, v_today, interval '1 day') as d(day)
      left join (
        select (created_at at time zone 'America/Jamaica')::date as day,
               count(*) filter (where event_name = 'event_viewed')   as views,
               count(*) filter (where event_name = 'vendor_clicked') as clicks
          from public.analytics_events
         where entity_id = p_event_id::text
           and created_at >= (v_today - 29)::timestamp at time zone 'America/Jamaica'
         group by 1
      ) a on a.day = d.day::date
    ),

    'top_vendors', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'name', t.name, 'clicks', t.clicks
      ) order by t.clicks desc), '[]'::jsonb)
      from (
        select coalesce(max(ae.source_context->>'vendor_name'), 'Unknown vendor') as name,
               count(*) as clicks
          from public.analytics_events ae
         where ae.event_name = 'vendor_clicked'
           and ae.entity_id = p_event_id::text
           and ae.source_context->>'vendor_id' is not null
         group by ae.source_context->>'vendor_id'
         order by count(*) desc
         limit 10
      ) t
    ),

    'tab_activity', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'name', t.event_name, 'tab', t.tab_key, 'n', t.n
      ) order by t.n desc), '[]'::jsonb)
      from (
        select event_name, tab_key, count(*) as n
          from public.event_analytics_events
         where event_id = p_event_id
         group by event_name, tab_key
         order by count(*) desc
         limit 15
      ) t
    ),

    'updates', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', u.id, 'title', u.title, 'message', u.message, 'created_at', u.created_at
      ) order by u.created_at desc), '[]'::jsonb)
      from (select * from public.event_updates
             where event_id = p_event_id
             order by created_at desc limit 50) u
    ),

    'feedback', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',         f.id,
        'created_at', f.created_at,
        'vote',       f.vote,
        'ratings',    jsonb_strip_nulls(jsonb_build_object(
                        'experience',   f.rating_experience,
                        'organization', f.rating_organization,
                        'value',        f.rating_value,
                        'food',         f.rating_food)),
        'quick_tags', coalesce(to_jsonb(f.quick_tags), '[]'::jsonb),
        'user_id',    f.user_id,
        'username',   coalesce(u.username, u.email, 'anonymous')
      ) order by f.created_at desc), '[]'::jsonb)
      from public.event_feedback f
      left join public."user" u on u.id = f.user_id
      where f.event_id = p_event_id
    ),

    'deliveries', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'type', t.notification_type, 'n', t.n, 'last_sent', t.last_sent
      ) order by t.n desc), '[]'::jsonb)
      from (
        select notification_type, count(*) as n, max(sent_at) as last_sent
          from public.event_notification_deliveries
         where event_id = p_event_id
         group by notification_type
      ) t
    ),

    'parking', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', l.id, 'name', l.name, 'capacity', l.capacity,
        'status_override', l.status_override, 'tier', l.tier,
        'reports_24h', (select count(*) from public.parking_reports pr
                         where pr.lot_id = l.id
                           and pr.created_at >= now() - interval '24 hours')
      ) order by l.sort_order nulls last, l.name), '[]'::jsonb)
      from public.event_parking_lots l
      where l.event_id = p_event_id
    ),

    'interest_users', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'user_id', ei.user_id,
        'status',  ei.status,
        'name',    coalesce(u.username, u.email, 'unknown'),
        'at',      ei.updated_at
      ) order by ei.updated_at desc), '[]'::jsonb)
      from (select * from public.event_interests
             where event_id = p_event_id
             order by updated_at desc limit 300) ei
      left join public."user" u on u.id = ei.user_id
    ),

    'savers', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'user_id', se.user_id,
        'name',    coalesce(u.username, u.email, 'unknown')
      )), '[]'::jsonb)
      from public.saved_events se
      left join public."user" u on u.id = se.user_id
      where se.event_id = p_event_id
    ),

    'saved_items', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'vendor', t.vendor_name, 'item', t.menu_item_name, 'saves', t.n
      ) order by t.n desc), '[]'::jsonb)
      from (
        select vendor_name, menu_item_name, count(*) as n
          from public.user_saved_menu_items
         where event_id = p_event_id
         group by vendor_name, menu_item_name
         order by count(*) desc
         limit 40
      ) t
    )

  );
end;
$$;;
