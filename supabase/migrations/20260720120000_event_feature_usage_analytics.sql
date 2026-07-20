-- Event feature usage: a focused tab-click writer for app/web clients and
-- a 30-day admin rollup for the event console.

create index if not exists eae_event_tab_usage_idx
  on public.event_analytics_events(event_id, tab_key, created_at desc)
  where event_name = 'tab_view';

create or replace function public.track_event_tab_click(
  p_event_id uuid,
  p_tab_key text,
  p_anon_device_id text default null,
  p_session_id text default null,
  p_source text default 'app'
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tab_key text;
begin
  v_tab_key := lower(btrim(coalesce(p_tab_key, '')));
  v_tab_key := case v_tab_key
    when 'favorite' then 'my_plan'
    when 'favorites' then 'my_plan'
    when 'favourite' then 'my_plan'
    when 'favourites' then 'my_plan'
    when 'menu' then 'vendors'
    when 'menus' then 'vendors'
    else v_tab_key
  end;

  if v_tab_key = '' or length(v_tab_key) > 64 or v_tab_key !~ '^[a-z0-9_]+$' then
    return jsonb_build_object('ok', false, 'error', 'Invalid tab key');
  end if;

  if not exists (
    select 1 from public.events where id = p_event_id and deleted_at is null
  ) then
    return jsonb_build_object('ok', false, 'error', 'Event not found');
  end if;

  insert into public.event_analytics_events
    (event_id, event_name, user_id, anon_device_id, session_id, tab_key, metadata)
  values
    (p_event_id, 'tab_view', auth.uid(),
     nullif(left(btrim(coalesce(p_anon_device_id, '')), 160), ''),
     nullif(left(btrim(coalesce(p_session_id, '')), 160), ''),
     v_tab_key,
     jsonb_build_object('source', left(coalesce(nullif(btrim(p_source), ''), 'app'), 40)));

  return jsonb_build_object('ok', true, 'tab_key', v_tab_key);
exception when others then
  -- Analytics must never interrupt the attendee experience.
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end;
$$;

revoke all on function public.track_event_tab_click(uuid,text,text,text,text) from public;
grant execute on function public.track_event_tab_click(uuid,text,text,text,text) to anon, authenticated, service_role;

create or replace function public.admin_get_event_feature_usage(
  p_admin_token text,
  p_event_id uuid,
  p_days integer default 30
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_days integer := greatest(1, least(coalesce(p_days, 30), 365));
begin
  if not public._is_admin(p_admin_token) then
    return null;
  end if;

  if not exists (
    select 1 from public.events where id = p_event_id and deleted_at is null
  ) then
    raise exception 'Event not found';
  end if;

  return (
    with normalized as (
      select
        case lower(btrim(tab_key))
          when 'favorite' then 'my_plan'
          when 'favorites' then 'my_plan'
          when 'favourite' then 'my_plan'
          when 'favourites' then 'my_plan'
          when 'menu' then 'vendors'
          when 'menus' then 'vendors'
          else lower(btrim(tab_key))
        end as tab_key,
        coalesce(user_id::text, nullif(anon_device_id, ''), nullif(session_id, '')) as visitor_key,
        created_at
      from public.event_analytics_events
      where event_id = p_event_id
        and event_name = 'tab_view'
        and nullif(btrim(tab_key), '') is not null
        and created_at >= now() - make_interval(days => v_days)
    ), totals as (
      select count(*)::bigint as clicks,
             count(distinct visitor_key)::bigint as visitors
      from normalized
    ), tabs as (
      select tab_key,
             count(*)::bigint as clicks,
             count(distinct visitor_key)::bigint as visitors,
             max(created_at) as last_clicked_at
      from normalized
      group by tab_key
    )
    select jsonb_build_object(
      'days', v_days,
      'total_clicks', totals.clicks,
      'unique_visitors', totals.visitors,
      'tabs', coalesce((
        select jsonb_agg(jsonb_build_object(
          'key', tabs.tab_key,
          'clicks', tabs.clicks,
          'unique_visitors', tabs.visitors,
          'share', case when totals.clicks = 0 then 0
                        else round((tabs.clicks::numeric / totals.clicks::numeric) * 100, 1) end,
          'last_clicked_at', tabs.last_clicked_at
        ) order by tabs.clicks desc, tabs.tab_key)
        from tabs
      ), '[]'::jsonb)
    )
    from totals
  );
end;
$$;

revoke all on function public.admin_get_event_feature_usage(text,uuid,integer) from public;
grant execute on function public.admin_get_event_feature_usage(text,uuid,integer) to anon, authenticated, service_role;

comment on function public.track_event_tab_click(uuid,text,text,text,text) is
  'Record one event-experience tab click. Use stable keys such as map, vendors, my_plan, and parking.';

comment on function public.admin_get_event_feature_usage(text,uuid,integer) is
  'Admin-only feature usage rollup with tab clicks, unique visitors, share, and recency.';
