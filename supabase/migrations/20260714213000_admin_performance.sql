-- ============================================================
-- TRODDR Admin — Content performance
-- Idempotent. Safe to re-run.
-- ============================================================

create or replace function public.admin_get_performance(
  p_admin_token text,
  p_days integer default 30
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_days integer := greatest(1, least(coalesce(p_days, 30), 365));
  v_today date := (now() at time zone 'America/Jamaica')::date;
  v_from timestamptz;
  v_previous_from timestamptz;
begin
  if not public._is_admin(p_admin_token) then return null; end if;
  v_from := (v_today - (v_days - 1))::timestamp at time zone 'America/Jamaica';
  v_previous_from := v_from - make_interval(days => v_days);

  return jsonb_build_object(
    'window_days', v_days,
    'generated_at', now(),
    'audiences', jsonb_build_object(
      'eat', (select count(distinct coalesce(ae.user_id::text, 'anon:' || ae.session_id)) from public.analytics_events ae join public.places p on p.id::text=ae.entity_id where ae.event_name='place_viewed' and lower(p.category)='eat' and ae.created_at>=v_from),
      'stay', (select count(distinct coalesce(ae.user_id::text, 'anon:' || ae.session_id)) from public.analytics_events ae join public.places p on p.id::text=ae.entity_id where ae.event_name='place_viewed' and lower(p.category)='stay' and ae.created_at>=v_from),
      'play', (select count(distinct coalesce(ae.user_id::text, 'anon:' || ae.session_id)) from public.analytics_events ae join public.places p on p.id::text=ae.entity_id where ae.event_name='place_viewed' and lower(p.category)='play' and ae.created_at>=v_from),
      'guides', (select count(distinct coalesce(ae.user_id::text, 'anon:' || ae.session_id)) from public.analytics_events ae where ae.event_name='guide_viewed' and ae.created_at>=v_from),
      'events', (select count(distinct coalesce(ae.user_id::text, 'anon:' || ae.session_id)) from public.analytics_events ae where ae.event_name='event_viewed' and ae.created_at>=v_from)
    ),
    'unattributed', jsonb_build_object(
      'places', (select count(*) from public.analytics_events ae left join public.places p on p.id::text=ae.entity_id where ae.event_name in ('place_viewed','place_saved') and ae.created_at>=v_from and p.id is null),
      'guides', (select count(*) from public.analytics_events ae left join public.guides g on g.id::text=ae.source_context->>'guide_id' or g.slug=ae.entity_id where ae.event_name='guide_viewed' and ae.created_at>=v_from and g.id is null),
      'events', (select count(*) from public.analytics_events ae left join public.events e on e.id::text=ae.entity_id where ae.event_name in ('event_viewed','event_saved') and ae.created_at>=v_from and e.id is null)
    ),
    'places', (
      with activity as (
        select ae.entity_id,
               count(*) filter (where ae.event_name='place_viewed' and ae.created_at>=v_from) as views,
               count(*) filter (where ae.event_name='place_viewed' and ae.created_at>=v_previous_from and ae.created_at<v_from) as previous_views,
               count(*) filter (where ae.event_name='place_saved' and ae.created_at>=v_from) as saves,
               count(*) filter (where ae.event_name='place_saved' and ae.created_at>=v_previous_from and ae.created_at<v_from) as previous_saves,
               count(distinct coalesce(ae.user_id::text, 'anon:' || ae.session_id)) filter (where ae.created_at>=v_from) as users
          from public.analytics_events ae
         where ae.event_name in ('place_viewed','place_saved') and ae.created_at >= v_previous_from
         group by ae.entity_id
      ), trip_activity as (
        select ip.place_id::text as entity_id,
               count(*) filter (where ip.created_at>=v_from) as trip_adds,
               count(*) filter (where ip.created_at>=v_previous_from and ip.created_at<v_from) as previous_trip_adds,
               count(distinct ip.itinerary_id) filter (where ip.created_at>=v_from) as trips
          from public.itinerary_places ip
         where ip.place_id is not null and ip.is_note = false and ip.created_at >= v_previous_from
         group by ip.place_id
      )
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', p.id, 'name', p.name, 'slug', p.slug, 'category', lower(p.category),
        'town', p.town, 'parish', p.parish, 'views', coalesce(a.views,0),
        'previous_views', coalesce(a.previous_views,0), 'saves', coalesce(a.saves,0),
        'previous_saves', coalesce(a.previous_saves,0), 'users', coalesce(a.users,0),
        'trip_adds', coalesce(t.trip_adds,0), 'previous_trip_adds', coalesce(t.previous_trip_adds,0),
        'trips', coalesce(t.trips,0)
      ) order by coalesce(a.views,0) desc, coalesce(t.trip_adds,0) desc, p.name), '[]'::jsonb)
        from public.places p
        left join activity a on a.entity_id = p.id::text
        left join trip_activity t on t.entity_id = p.id::text
       where lower(p.category) in ('eat','stay','play')
         and coalesce(p.is_hidden,false)=false
    ),
    'guides', (
      with activity as (
        select coalesce(ae.source_context->>'guide_id', ae.entity_id) as tracking_id,
               count(*) filter (where ae.created_at>=v_from) as views,
               count(*) filter (where ae.created_at>=v_previous_from and ae.created_at<v_from) as previous_views,
               count(distinct coalesce(ae.user_id::text, 'anon:' || ae.session_id)) filter (where ae.created_at>=v_from) as users
          from public.analytics_events ae
         where ae.event_name='guide_viewed' and ae.created_at>=v_previous_from
         group by 1
      )
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', g.id, 'name', coalesce(g.title,g.slug), 'slug', g.slug, 'location', g.location,
        'views', coalesce(a.views,0), 'previous_views', coalesce(a.previous_views,0), 'users', coalesce(a.users,0)
      ) order by coalesce(a.views,0) desc, coalesce(g.title,g.slug)), '[]'::jsonb)
      from public.guides g
      left join activity a on a.tracking_id in (g.id::text,g.slug)
    ),
    'events', (
      with activity as (
        select ae.entity_id,
               count(*) filter (where ae.event_name = 'event_viewed' and ae.created_at>=v_from) as views,
               count(*) filter (where ae.event_name = 'event_viewed' and ae.created_at<v_from) as previous_views,
               count(distinct coalesce(ae.user_id::text, 'anon:' || ae.session_id))
                 filter (where ae.event_name = 'event_viewed' and ae.created_at>=v_from) as users,
               count(*) filter (where ae.event_name = 'event_saved' and ae.created_at>=v_from) as saves,
               count(*) filter (where ae.event_name = 'event_saved' and ae.created_at<v_from) as previous_saves
          from public.analytics_events ae
         where ae.event_name in ('event_viewed','event_saved') and ae.created_at >= v_previous_from
         group by ae.entity_id
      ), trip_activity as (
        select ie.event_id::text as entity_id, count(*) as trip_adds,
               count(distinct ie.itinerary_id) as trips
          from public.itinerary_events ie
         where ie.created_at >= v_from
         group by ie.event_id
      )
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', e.id, 'name', e.title, 'slug', e.slug, 'start_date', e.start_date,
        'town', e.town, 'views', coalesce(a.views,0), 'previous_views', coalesce(a.previous_views,0), 'users', coalesce(a.users,0),
        'saves', coalesce(a.saves,0), 'previous_saves', coalesce(a.previous_saves,0), 'trip_adds', coalesce(t.trip_adds,0),
        'trips', coalesce(t.trips,0)
      ) order by coalesce(a.views,0) desc, coalesce(a.saves,0) desc, e.title), '[]'::jsonb)
        from public.events e
        left join activity a on a.entity_id = e.id::text
        left join trip_activity t on t.entity_id = e.id::text
       where e.deleted_at is null
         and coalesce(e.status,'published')='published'
    )
  );
end;
$$;

grant execute on function public.admin_get_performance(text, integer) to anon, authenticated, service_role;
