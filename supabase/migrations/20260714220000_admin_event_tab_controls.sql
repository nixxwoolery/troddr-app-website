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
