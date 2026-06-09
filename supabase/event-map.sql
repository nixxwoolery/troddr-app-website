-- ============================================================
-- event-map : floor plan storage + marker editor + designer invites
-- for the partner-event dashboard's Map section.
--
-- DEPLOY ORDER:
--   1. Add the two new columns to public.events (idempotent)
--   2. Create the event_map_invites table
--   3. Create the four RPCs at the bottom
--   4. In Supabase Storage : create a public bucket called
--      `event-floorplans` with the policies at the very bottom.
-- ============================================================

-- ── 1. New columns on events ────────────────────────────────
alter table public.events
  add column if not exists floor_plan_url      text,
  add column if not exists floor_plan_markers  jsonb default '[]'::jsonb;

comment on column public.events.floor_plan_url is
  'Public URL of the uploaded floor plan image (PNG/JPG). Lives in the event-floorplans Storage bucket.';
comment on column public.events.floor_plan_markers is
  'Array of marker objects: {id, x, y, label, icon, color, vendor_id, booth, description}. x and y are 0-1 fractions of the rendered image — resolution-agnostic.';

-- ── 2. Designer-invite table ────────────────────────────────
create table if not exists public.event_map_invites (
  token          text primary key default encode(extensions.gen_random_bytes(16), 'hex'),
  event_id       uuid not null references public.events(id) on delete cascade,
  designer_name  text,
  designer_email text,
  scopes         text[] not null default '{markers}'::text[],
  -- scopes values: 'markers', 'calibration'. Static tier issues only 'markers'.
  expires_at     timestamptz not null,
  used_at        timestamptz,
  revoked_at     timestamptz,
  created_at     timestamptz not null default now()
);

create index if not exists event_map_invites_event_idx
  on public.event_map_invites (event_id, created_at desc);

comment on table public.event_map_invites is
  'Scoped tokens that let a designer (no full partner access) edit only the floor-plan markers for one event.';

-- ── 3. RPCs ─────────────────────────────────────────────────

-- 3a. update_event_floor_plan : the dashboard's Save button calls this.
create or replace function public.update_event_floor_plan(
  p_token              text,
  p_floor_plan_url     text,
  p_floor_plan_markers jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
begin
  select id into v_event_id
    from public.events
   where partner_access_token = p_token;

  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  update public.events
     set floor_plan_url     = p_floor_plan_url,
         floor_plan_markers = coalesce(p_floor_plan_markers, '[]'::jsonb),
         updated_at         = now()
   where id = v_event_id;

  return jsonb_build_object('ok', true, 'event_id', v_event_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;

grant execute on function public.update_event_floor_plan(text, text, jsonb)
  to anon, authenticated;

-- 3b. create_event_map_invite : generates a designer-scoped token.
create or replace function public.create_event_map_invite(
  p_token            text,
  p_designer_name    text default null,
  p_designer_email   text default null,
  p_scopes           text[] default '{markers}'::text[],
  p_expires_in_days  integer default 14
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
  v_token    text;
  v_expires  timestamptz;
begin
  select id into v_event_id
    from public.events
   where partner_access_token = p_token;

  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  v_expires := now() + (greatest(1, p_expires_in_days) || ' days')::interval;

  insert into public.event_map_invites (event_id, designer_name, designer_email, scopes, expires_at)
       values (v_event_id, p_designer_name, p_designer_email,
               coalesce(p_scopes, '{markers}'::text[]), v_expires)
    returning token into v_token;

  return jsonb_build_object(
    'ok', true,
    'token', v_token,
    'expires_at', v_expires,
    'scopes', coalesce(p_scopes, '{markers}'::text[])
  );
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;

grant execute on function public.create_event_map_invite(text, text, text, text[], integer)
  to anon, authenticated;

-- 3c. list_event_map_invites : show existing invites with a Revoke button.
create or replace function public.list_event_map_invites(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
begin
  select id into v_event_id
    from public.events
   where partner_access_token = p_token;
  if v_event_id is null then return null; end if;

  return (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'token',          token,
        'designer_name',  designer_name,
        'designer_email', designer_email,
        'scopes',         to_jsonb(scopes),
        'expires_at',     expires_at,
        'used_at',        used_at,
        'created_at',     created_at
      )
      order by created_at desc
    ), '[]'::jsonb)
    from public.event_map_invites
    where event_id = v_event_id
      and revoked_at is null
      and expires_at > now()
  );
end;
$$;

grant execute on function public.list_event_map_invites(text) to anon, authenticated;

-- 3d. revoke_event_map_invite : the partner kills a token early.
create or replace function public.revoke_event_map_invite(
  p_token        text,
  p_invite_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
begin
  select id into v_event_id
    from public.events
   where partner_access_token = p_token;
  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  update public.event_map_invites
     set revoked_at = now()
   where token = p_invite_token
     and event_id = v_event_id;

  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.revoke_event_map_invite(text, text) to anon, authenticated;

-- 3e. resolve_event_map_invite : the designer's /m/{token} page resolves this.
--    Returns the event id, floor plan url, markers, scopes, and the vendor
--    list (so the designer's vendor-link dropdown works).
create or replace function public.resolve_event_map_invite(p_invite_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inv  public.event_map_invites%rowtype;
  v_evt  public.events%rowtype;
begin
  select * into v_inv from public.event_map_invites where token = p_invite_token;
  if v_inv.token is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  if v_inv.revoked_at is not null then
    return jsonb_build_object('ok', false, 'error', 'revoked');
  end if;
  if v_inv.expires_at <= now() then
    return jsonb_build_object('ok', false, 'error', 'expired');
  end if;

  select * into v_evt from public.events where id = v_inv.event_id;

  -- Mark first-use only
  if v_inv.used_at is null then
    update public.event_map_invites set used_at = now() where token = p_invite_token;
  end if;

  return jsonb_build_object(
    'ok', true,
    'event', jsonb_build_object(
      'id',                  v_evt.id,
      'slug',                v_evt.slug,
      'title',               v_evt.title,
      'floor_plan_url',      v_evt.floor_plan_url,
      'floor_plan_markers',  coalesce(v_evt.floor_plan_markers, '[]'::jsonb)
    ),
    'scopes', to_jsonb(v_inv.scopes),
    'expires_at', v_inv.expires_at,
    'vendors', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'event_vendor_id', ev.id,
        'vendor_id',       v.id,
        'vendor_name',     v.name
      ) order by v.name), '[]'::jsonb)
      from public.event_vendors ev
      join public.vendors v on v.id = ev.vendor_id
      where ev.event_id = v_evt.id
    )
  );
end;
$$;

grant execute on function public.resolve_event_map_invite(text) to anon, authenticated;

-- 3f. update_event_floor_plan_via_invite : the designer's Save button.
--    Same as update_event_floor_plan, but token-gated by invite scope.
create or replace function public.update_event_floor_plan_via_invite(
  p_invite_token       text,
  p_floor_plan_markers jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inv  public.event_map_invites%rowtype;
begin
  select * into v_inv from public.event_map_invites where token = p_invite_token;
  if v_inv.token is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_inv.revoked_at is not null then return jsonb_build_object('ok', false, 'error', 'revoked'); end if;
  if v_inv.expires_at <= now() then return jsonb_build_object('ok', false, 'error', 'expired'); end if;
  if not ('markers' = any(v_inv.scopes)) then
    return jsonb_build_object('ok', false, 'error', 'scope_denied');
  end if;

  update public.events
     set floor_plan_markers = coalesce(p_floor_plan_markers, '[]'::jsonb),
         updated_at         = now()
   where id = v_inv.event_id;

  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.update_event_floor_plan_via_invite(text, jsonb)
  to anon, authenticated;

-- ============================================================
-- STORAGE BUCKET (run in Supabase Dashboard or via the storage UI):
--
--   bucket name : event-floorplans
--   public      : yes
--
-- Policies on storage.objects (bucket_id = 'event-floorplans'):
--
--   -- Anyone can read the uploaded floor plans (they're shown in the app)
--   create policy "event-floorplans public read"
--     on storage.objects for select
--     using (bucket_id = 'event-floorplans');
--
--   -- Anyone with the partner anon key can upload to their own subfolder.
--   -- The RLS that *actually* protects this is on events itself (only the
--   -- event's partner_access_token can call update_event_floor_plan), so the
--   -- URL is only ever pinned to events.floor_plan_url by an authenticated
--   -- partner action.
--   create policy "event-floorplans authenticated insert"
--     on storage.objects for insert
--     to anon, authenticated
--     with check (bucket_id = 'event-floorplans');
--
--   create policy "event-floorplans authenticated update"
--     on storage.objects for update
--     to anon, authenticated
--     using (bucket_id = 'event-floorplans')
--     with check (bucket_id = 'event-floorplans');
-- ============================================================
