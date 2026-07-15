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
  v_allowed constant text[] := array['home','schedule','map','vendors','my_plan','tickets','info','sponsors','events','concierge'];
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
  v_allowed_tabs constant text[] := array['home','schedule','map','vendors','my_plan','tickets','info','sponsors','events','concierge'];
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
