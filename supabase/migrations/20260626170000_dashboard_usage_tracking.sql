-- Track partner dashboard usage so admins can see access by token prefix and login email.

create table if not exists public.partner_dashboard_access_log (
  id uuid primary key default gen_random_uuid(),
  entity_type text not null check (entity_type in ('event', 'place')),
  entity_id uuid not null,
  entity_name text,
  entity_slug text,
  token_prefix text,
  actor_email text,
  path text,
  user_agent text,
  created_at timestamptz not null default now()
);

create index if not exists partner_dashboard_access_entity_idx
  on public.partner_dashboard_access_log(entity_type, entity_id, created_at desc);

create index if not exists partner_dashboard_access_created_idx
  on public.partner_dashboard_access_log(created_at desc);

alter table public.partner_dashboard_access_log enable row level security;

create or replace function public.track_partner_dashboard_access(
  p_token text,
  p_path text default null,
  p_user_agent text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event record;
  v_place record;
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
begin
  if coalesce(btrim(p_token), '') = '' then
    return jsonb_build_object('ok', false, 'error', 'missing_token');
  end if;

  select id, title as name, slug
    into v_event
    from public.events
   where partner_access_token = p_token
   limit 1;

  if v_event.id is not null then
    insert into public.partner_dashboard_access_log (
      entity_type, entity_id, entity_name, entity_slug, token_prefix, actor_email, path, user_agent
    )
    values (
      'event', v_event.id, v_event.name, v_event.slug, left(p_token, 8), nullif(v_email, ''),
      left(coalesce(p_path, ''), 500), left(coalesce(p_user_agent, ''), 500)
    );
    return jsonb_build_object('ok', true);
  end if;

  select id, name, slug
    into v_place
    from public.places
   where partner_access_token = p_token
   limit 1;

  if v_place.id is not null then
    insert into public.partner_dashboard_access_log (
      entity_type, entity_id, entity_name, entity_slug, token_prefix, actor_email, path, user_agent
    )
    values (
      'place', v_place.id, v_place.name, v_place.slug, left(p_token, 8), nullif(v_email, ''),
      left(coalesce(p_path, ''), 500), left(coalesce(p_user_agent, ''), 500)
    );
    return jsonb_build_object('ok', true);
  end if;

  return jsonb_build_object('ok', false, 'error', 'token_not_found');
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end;
$$;

grant execute on function public.track_partner_dashboard_access(text, text, text) to anon, authenticated;

create or replace function public.admin_dashboard_usage(
  p_admin_token text,
  p_limit integer default 200
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._is_admin(p_admin_token) then
    return null;
  end if;

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id,
      'created_at', created_at,
      'entity_type', entity_type,
      'entity_id', entity_id,
      'entity_name', entity_name,
      'entity_slug', entity_slug,
      'token_prefix', token_prefix,
      'actor_email', actor_email,
      'path', path,
      'user_agent', user_agent
    ) order by created_at desc)
    from (
      select *
        from public.partner_dashboard_access_log
       order by created_at desc
       limit greatest(1, least(coalesce(p_limit, 200), 500))
    ) rows
  ), '[]'::jsonb);
end;
$$;

grant execute on function public.admin_dashboard_usage(text, integer) to anon, authenticated;
