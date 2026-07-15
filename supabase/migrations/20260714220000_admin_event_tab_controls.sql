-- Admin controls for the tabs shown in an event experience.

create or replace function public.admin_get_event_tabs(
  p_admin_token text,
  p_event_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tabs jsonb;
begin
  if not public._is_admin(p_admin_token) then return null; end if;
  select tabs into v_tabs from public.events where id=p_event_id and deleted_at is null;
  if not found then raise exception 'Event not found'; end if;
  return jsonb_build_object('tabs',coalesce(v_tabs,'[]'::jsonb),'uses_defaults',v_tabs is null);
end;
$$;

create or replace function public.admin_update_event_tabs(
  p_admin_token text,
  p_event_id uuid,
  p_tabs jsonb,
  p_use_defaults boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tabs jsonb;
  v_allowed constant text[] := array['home','schedule','map','parking','vendors','my_plan','tickets','info','sponsors','events','concierge'];
begin
  if not public._is_admin(p_admin_token) then return null; end if;

  if coalesce(p_use_defaults,false) then
    update public.events set tabs=null, updated_at=now() where id=p_event_id and deleted_at is null;
    if not found then raise exception 'Event not found'; end if;
    return jsonb_build_object('tabs','[]'::jsonb,'uses_defaults',true);
  end if;

  if jsonb_typeof(p_tabs) <> 'array' then raise exception 'Tabs must be an array'; end if;
  if not exists (select 1 from jsonb_array_elements(p_tabs) t where t->>'key'='home') then
    raise exception 'The Home tab must remain enabled';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_tabs) t
     where not ((t->>'key')=any(v_allowed)) or nullif(btrim(t->>'label'),'') is null
  ) then raise exception 'One or more tab configurations are invalid'; end if;
  if (select count(*) from jsonb_array_elements(p_tabs)) <>
     (select count(distinct t->>'key') from jsonb_array_elements(p_tabs) t) then
    raise exception 'Duplicate tabs are not allowed';
  end if;

  select jsonb_agg(jsonb_build_object('key',t.value->>'key','label',left(btrim(t.value->>'label'),40)) order by t.ordinality)
    into v_tabs
    from jsonb_array_elements(p_tabs) with ordinality t(value,ordinality);
  update public.events set tabs=v_tabs, updated_at=now() where id=p_event_id and deleted_at is null;
  if not found then raise exception 'Event not found'; end if;
  return jsonb_build_object('tabs',v_tabs,'uses_defaults',false);
end;
$$;

grant execute on function public.admin_get_event_tabs(text,uuid) to anon,authenticated;
grant execute on function public.admin_update_event_tabs(text,uuid,jsonb,boolean) to anon,authenticated;
grant execute on function public.admin_get_event_tabs(text,uuid) to service_role;
grant execute on function public.admin_update_event_tabs(text,uuid,jsonb,boolean) to service_role;

create or replace function public.admin_create_event(
  p_admin_token text,
  p_title text,
  p_start_date date,
  p_end_date date,
  p_start_time time default null,
  p_end_time time default null,
  p_event_type text default 'general',
  p_status text default 'draft',
  p_venue_name text default null,
  p_town text default null,
  p_parish text default null,
  p_description text default null,
  p_ticket_url text default null,
  p_tabs jsonb default '[{"key":"home","label":"Home"}]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_slug text;
  v_base text;
  v_id uuid;
  v_suffix integer := 1;
  v_allowed_types constant text[] := array['music','food and drink','art','sports','festival','carnival','family','wellness','general'];
  v_allowed_tabs constant text[] := array['home','schedule','map','parking','vendors','my_plan','tickets','info','sponsors','events','concierge'];
begin
  if not public._is_admin(p_admin_token) then return null; end if;
  if nullif(btrim(p_title),'') is null then raise exception 'Event title is required'; end if;
  if p_start_date is null or p_end_date is null or p_end_date<p_start_date then raise exception 'Enter a valid event date range'; end if;
  if p_start_date=p_end_date and p_start_time is not null and p_end_time is not null and p_end_time<p_start_time then raise exception 'End time cannot be before start time'; end if;
  if not (coalesce(p_event_type,'general')=any(v_allowed_types)) then raise exception 'Invalid event type'; end if;
  if coalesce(p_status,'draft') not in ('draft','published') then raise exception 'Invalid event status'; end if;
  if jsonb_typeof(p_tabs)<>'array' or not exists(select 1 from jsonb_array_elements(p_tabs) t where t->>'key'='home') then raise exception 'Home must be included in event tabs'; end if;
  if exists(select 1 from jsonb_array_elements(p_tabs) t where not ((t->>'key')=any(v_allowed_tabs))) then raise exception 'One or more event tabs are invalid'; end if;

  v_base := trim(both '-' from regexp_replace(lower(btrim(p_title)),'[^a-z0-9]+','-','g'));
  if v_base='' then v_base:='event'; end if;
  v_slug:=v_base;
  while exists(select 1 from public.events where slug=v_slug) loop v_suffix:=v_suffix+1; v_slug:=v_base||'-'||v_suffix; end loop;

  insert into public.events(title,slug,description,start_date,end_date,start_time,end_time,event_type,status,venue_name,town,parish,ticket_url,has_online_tickets,country,tabs)
  values(btrim(p_title),v_slug,nullif(btrim(p_description),''),p_start_date,p_end_date,p_start_time,p_end_time,coalesce(p_event_type,'general'),coalesce(p_status,'draft'),nullif(btrim(p_venue_name),''),nullif(btrim(p_town),''),nullif(btrim(p_parish),''),nullif(btrim(p_ticket_url),''),nullif(btrim(p_ticket_url),'') is not null,'Jamaica',p_tabs)
  returning id into v_id;
  return jsonb_build_object('id',v_id,'slug',v_slug,'title',btrim(p_title));
end;
$$;

grant execute on function public.admin_create_event(text,text,date,date,time,time,text,text,text,text,text,text,text,jsonb) to anon,authenticated,service_role;

create or replace function public.admin_get_event_editor(p_admin_token text,p_event_id uuid)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_event public.events%rowtype;
begin
  if not public._is_admin(p_admin_token) then return null; end if;
  select * into v_event from public.events where id=p_event_id and deleted_at is null;
  if not found then raise exception 'Event not found'; end if;
  return jsonb_build_object(
    'event',jsonb_build_object('id',v_event.id,'title',v_event.title,'slug',v_event.slug,'description',v_event.description,'start_date',v_event.start_date,'end_date',v_event.end_date,'start_time',v_event.start_time,'end_time',v_event.end_time,'event_type',v_event.event_type,'status',v_event.status,'venue_name',v_event.venue_name,'venue_address',v_event.venue_address,'town',v_event.town,'parish',v_event.parish,'website_url',v_event.website_url,'ticket_url',v_event.ticket_url,'support_email',v_event.support_email,'support_phone',v_event.support_phone,'featured_image_url',v_event.featured_image_url,'is_featured',v_event.is_featured,'visibility',v_event.visibility,'tabs',v_event.tabs),
    'counts',jsonb_build_object(
      'schedule',(select count(*) from public.event_schedule_items where event_id=p_event_id),
      'vendors',(select count(*) from public.event_vendors where event_id=p_event_id),
      'sponsors',(select count(*) from public.event_sponsors where event_id=p_event_id),
      'passes',(select count(*) from public.event_passes where event_id=p_event_id),
      'parking',(select count(*) from public.event_parking_lots where event_id=p_event_id)
    ),
    'readiness',jsonb_build_object('details',(v_event.description is not null and v_event.venue_name is not null),'media',(v_event.featured_image_url is not null or coalesce(cardinality(v_event.image_urls),0)>0),'schedule',exists(select 1 from public.event_schedule_items where event_id=p_event_id),'tabs',(v_event.tabs is null or jsonb_array_length(v_event.tabs)>0),'support',(v_event.support_email is not null or v_event.support_phone is not null),'tickets',(v_event.is_free or v_event.ticket_url is not null or exists(select 1 from public.event_passes where event_id=p_event_id)),'map',(v_event.floor_plan_url is not null or (v_event.venue_lat is not null and v_event.venue_lng is not null)))
  );
end; $$;

create or replace function public.admin_update_event_details(p_admin_token text,p_event_id uuid,p_details jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $$
declare v_start date;v_end date;v_start_time time;v_end_time time;v_type text;v_status text;
begin
  if not public._is_admin(p_admin_token) then return null; end if;
  v_start=(p_details->>'start_date')::date;v_end=(p_details->>'end_date')::date;
  v_start_time=nullif(p_details->>'start_time','')::time;v_end_time=nullif(p_details->>'end_time','')::time;
  v_type=coalesce(nullif(p_details->>'event_type',''),'general');v_status=coalesce(nullif(p_details->>'status',''),'draft');
  if nullif(btrim(p_details->>'title'),'') is null then raise exception 'Event title is required'; end if;
  if v_start is null or v_end is null or v_end<v_start then raise exception 'Enter a valid event date range'; end if;
  if v_start=v_end and v_start_time is not null and v_end_time is not null and v_end_time<v_start_time then raise exception 'End time cannot be before start time'; end if;
  if v_type not in ('music','food and drink','art','sports','festival','carnival','family','wellness','general') then raise exception 'Invalid event type'; end if;
  if v_status not in ('draft','published','cancelled','postponed','completed') then raise exception 'Invalid event status'; end if;
  update public.events set title=btrim(p_details->>'title'),description=nullif(btrim(p_details->>'description'),''),start_date=v_start,end_date=v_end,start_time=v_start_time,end_time=v_end_time,event_type=v_type,status=v_status,venue_name=nullif(btrim(p_details->>'venue_name'),''),venue_address=nullif(btrim(p_details->>'venue_address'),''),town=nullif(btrim(p_details->>'town'),''),parish=nullif(btrim(p_details->>'parish'),''),website_url=nullif(btrim(p_details->>'website_url'),''),ticket_url=nullif(btrim(p_details->>'ticket_url'),''),has_online_tickets=nullif(btrim(p_details->>'ticket_url'),'') is not null,support_email=nullif(btrim(p_details->>'support_email'),''),support_phone=nullif(btrim(p_details->>'support_phone'),''),featured_image_url=nullif(btrim(p_details->>'featured_image_url'),''),is_featured=coalesce((p_details->>'is_featured')::boolean,false),updated_at=now() where id=p_event_id and deleted_at is null;
  if not found then raise exception 'Event not found'; end if;
  return public.admin_get_event_editor(p_admin_token,p_event_id);
end; $$;

grant execute on function public.admin_get_event_editor(text,uuid) to anon,authenticated,service_role;
grant execute on function public.admin_update_event_details(text,uuid,jsonb) to anon,authenticated,service_role;

comment on column public.events.tabs is 'Ordered event tab configs. Valid keys: home | schedule | map | parking | vendors | my_plan | tickets | info | sponsors | events | concierge.';
