create or replace function public.admin_list_events(p_admin_token text)
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

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id',          e.id,
      'title',       e.title,
      'slug',        e.slug,
      'start_date',  e.start_date,
      'end_date',    e.end_date,
      'status',      e.status,
      'venue_name',  e.venue_name,
      'town',        e.town,
      'is_featured', e.is_featured,
      'is_live',     (e.start_date <= v_today and coalesce(e.end_date, e.start_date) >= v_today),
      'parent_event_id', e.parent_event_id,
      'views_30d',  (select count(*) from public.analytics_events ae
                      where ae.event_name = 'event_viewed'
                        and ae.entity_id = e.id::text
                        and ae.created_at >= now() - interval '30 days'),
      'saves',      (select count(*) from public.saved_events se where se.event_id = e.id),
      'interested', (select count(*) from public.event_interests ei where ei.event_id = e.id),
      'feedback',   (select count(*) from public.event_feedback ef where ef.event_id = e.id),
      'updates',    (select count(*) from public.event_updates eu where eu.event_id = e.id)
    ) order by
        (e.start_date <= v_today and coalesce(e.end_date, e.start_date) >= v_today) desc,
        (coalesce(e.end_date, e.start_date) >= v_today) desc,
        case when coalesce(e.end_date, e.start_date) >= v_today then e.start_date end asc,
        e.start_date desc), '[]'::jsonb)
    from public.events e
    where e.deleted_at is null
  );
end;
$$;;
