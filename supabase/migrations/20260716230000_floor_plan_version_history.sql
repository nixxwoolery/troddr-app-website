-- Recoverable version history for event floor plans.
create table if not exists public.event_floor_plan_versions (
  id bigserial primary key,
  event_id uuid not null references public.events(id) on delete cascade,
  version_number integer not null,
  floor_plan_url text,
  floor_plan_markers jsonb not null default '[]'::jsonb,
  source text not null default 'partner',
  restored_from_version integer,
  created_at timestamptz not null default now(),
  unique (event_id, version_number)
);

create index if not exists event_floor_plan_versions_event_created_idx
  on public.event_floor_plan_versions(event_id, created_at desc);

alter table public.event_floor_plan_versions enable row level security;
revoke all on public.event_floor_plan_versions from anon, authenticated;

-- Preserve the current state of every existing map as its first version.
insert into public.event_floor_plan_versions
  (event_id, version_number, floor_plan_url, floor_plan_markers, source, created_at)
select id, 1, floor_plan_url, coalesce(floor_plan_markers, '[]'::jsonb), 'migration', coalesce(updated_at, now())
from public.events e
where (floor_plan_url is not null or jsonb_array_length(coalesce(floor_plan_markers, '[]'::jsonb)) > 0)
  and not exists (select 1 from public.event_floor_plan_versions v where v.event_id = e.id);

create or replace function public.update_event_floor_plan(
  p_token text, p_floor_plan_url text, p_floor_plan_markers jsonb
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_event_id uuid; v_version integer;
begin
  select id into v_event_id from public.events where partner_access_token = p_token for update;
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;

  update public.events set floor_plan_url = p_floor_plan_url,
    floor_plan_markers = coalesce(p_floor_plan_markers, '[]'::jsonb), updated_at = now()
  where id = v_event_id;

  select coalesce(max(version_number), 0) + 1 into v_version
  from public.event_floor_plan_versions where event_id = v_event_id;
  insert into public.event_floor_plan_versions
    (event_id, version_number, floor_plan_url, floor_plan_markers, source)
  values (v_event_id, v_version, p_floor_plan_url, coalesce(p_floor_plan_markers, '[]'::jsonb), 'partner');
  return jsonb_build_object('ok', true, 'event_id', v_event_id, 'version_number', v_version);
exception when others then return jsonb_build_object('ok', false, 'error', SQLERRM); end;
$$;

create or replace function public.get_event_floor_plan_versions(p_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_event_id uuid;
begin
  select id into v_event_id from public.events where partner_access_token = p_token;
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  return jsonb_build_object('ok', true, 'versions', coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', id, 'version_number', version_number, 'created_at', created_at,
      'marker_count', jsonb_array_length(floor_plan_markers), 'has_background', floor_plan_url is not null,
      'source', source, 'restored_from_version', restored_from_version
    ) order by version_number desc)
    from public.event_floor_plan_versions where event_id = v_event_id
  ), '[]'::jsonb));
end;
$$;

create or replace function public.update_event_floor_plan_via_invite(
  p_invite_token text, p_floor_plan_markers jsonb
) returns jsonb language plpgsql security definer set search_path = public as $$
declare v_inv public.event_map_invites%rowtype; v_url text; v_version integer;
begin
  select * into v_inv from public.event_map_invites where token = p_invite_token;
  if v_inv.token is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_inv.revoked_at is not null then return jsonb_build_object('ok', false, 'error', 'revoked'); end if;
  if v_inv.expires_at <= now() then return jsonb_build_object('ok', false, 'error', 'expired'); end if;
  if not ('markers' = any(v_inv.scopes)) then return jsonb_build_object('ok', false, 'error', 'scope_denied'); end if;

  select floor_plan_url into v_url from public.events where id = v_inv.event_id for update;
  update public.events set floor_plan_markers = coalesce(p_floor_plan_markers, '[]'::jsonb), updated_at = now()
    where id = v_inv.event_id;
  select coalesce(max(version_number), 0) + 1 into v_version
    from public.event_floor_plan_versions where event_id = v_inv.event_id;
  insert into public.event_floor_plan_versions
    (event_id, version_number, floor_plan_url, floor_plan_markers, source)
  values (v_inv.event_id, v_version, v_url, coalesce(p_floor_plan_markers, '[]'::jsonb), 'designer');
  return jsonb_build_object('ok', true, 'version_number', v_version);
exception when others then return jsonb_build_object('ok', false, 'error', SQLERRM); end;
$$;

create or replace function public.restore_event_floor_plan_version(p_token text, p_version_number integer)
returns jsonb language plpgsql security definer set search_path = public as $$
declare v_event_id uuid; v_old public.event_floor_plan_versions%rowtype; v_version integer;
begin
  select id into v_event_id from public.events where partner_access_token = p_token for update;
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  select * into v_old from public.event_floor_plan_versions
   where event_id = v_event_id and version_number = p_version_number;
  if v_old.id is null then return jsonb_build_object('ok', false, 'error', 'version_not_found'); end if;

  update public.events set floor_plan_url = v_old.floor_plan_url,
    floor_plan_markers = v_old.floor_plan_markers, updated_at = now() where id = v_event_id;
  select coalesce(max(version_number), 0) + 1 into v_version
    from public.event_floor_plan_versions where event_id = v_event_id;
  insert into public.event_floor_plan_versions
    (event_id, version_number, floor_plan_url, floor_plan_markers, source, restored_from_version)
  values (v_event_id, v_version, v_old.floor_plan_url, v_old.floor_plan_markers, 'restore', p_version_number);
  return jsonb_build_object('ok', true, 'version_number', v_version, 'restored_from_version', p_version_number);
exception when others then return jsonb_build_object('ok', false, 'error', SQLERRM); end;
$$;

grant execute on function public.get_event_floor_plan_versions(text) to anon, authenticated;
grant execute on function public.restore_event_floor_plan_version(text, integer) to anon, authenticated;
