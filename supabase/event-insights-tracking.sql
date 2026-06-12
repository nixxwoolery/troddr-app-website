-- ============================================================
-- TRODDR Event Insights — canonical analytics collection
-- ------------------------------------------------------------
-- Paid Event Insights reporting needs CONSISTENT collection.
-- This defines one canonical event-analytics table with a fixed
-- event-name taxonomy, a tracking RPC for the app/web, push
-- notification logging (with category + caps), and the rollup
-- views used by the live dashboard and post-event reports:
--   - per-event rollups (counts + unique attendees)
--   - event SERIES rollups across child events (parent_event_id)
--   - sponsor rollups + activation funnel per sponsor
--   - retention after event (where attributable)
-- ============================================================

-- Parent/child event series (JFDF-style: parent + N child events).
alter table public.events
  add column if not exists parent_event_id uuid references public.events(id) on delete set null;

create index if not exists events_parent_event_idx on public.events(parent_event_id);

-- ------------------------------------------------------------
-- Canonical analytics events
-- ------------------------------------------------------------
create table if not exists public.event_analytics_events (
  id              uuid primary key default gen_random_uuid(),
  event_id        uuid not null references public.events(id) on delete cascade,
  -- Fixed taxonomy. Add names here AND in track_event_metric().
  event_name      text not null check (event_name in (
                    'event_open',
                    'tab_view',                -- requires tab_key (every event tab)
                    'interest_interested',
                    'interest_going',
                    'interest_went',
                    'ticket_click',
                    'schedule_save',
                    'schedule_remove',
                    'map_view',
                    'map_marker_click',
                    'map_vendor_click',
                    'vendor_tab_view',
                    'vendor_card_click',
                    'vendor_view',
                    'vendor_social_click',
                    'vendor_listing_click',
                    'sponsor_view',
                    'sponsor_link_click',
                    'activation_checkin',
                    'activation_redemption',
                    'band_view',
                    'band_link_click',
                    'band_subtab_select',
                    'event_pass_view',
                    'event_pass_qr_open',
                    'outbound_link_click',     -- requires target_url; carries event/vendor/sponsor context
                    'push_sent',
                    'push_opened'
                  )),
  -- Attribution: authenticated user OR anonymous device id. At
  -- least one should be present for unique-attendee counting.
  user_id         uuid,
  anon_device_id  text,
  session_id      text,
  -- Context dimensions
  tab_key         text,
  vendor_id       uuid,
  sponsor_id      uuid,
  activation_id   uuid,
  band_id         uuid,
  notification_id uuid,
  notification_category text check (notification_category is null or
                    notification_category in ('reminder', 'promo', 'logistics', 'emergency')),
  target_url      text,
  metadata        jsonb not null default '{}'::jsonb,
  created_at      timestamptz not null default now()
);

create index if not exists eae_event_name_idx
  on public.event_analytics_events(event_id, event_name, created_at);
create index if not exists eae_sponsor_idx
  on public.event_analytics_events(sponsor_id) where sponsor_id is not null;
create index if not exists eae_vendor_idx
  on public.event_analytics_events(vendor_id) where vendor_id is not null;
create index if not exists eae_user_idx
  on public.event_analytics_events(user_id) where user_id is not null;

alter table public.event_analytics_events enable row level security;
-- No policies: writes go through the RPC, reads through views/RPCs.

-- ------------------------------------------------------------
-- Push notifications (caps + categories)
-- Caps per product: Lite 2, Pro 5, Major Hub 10, Flagship 15-25.
-- Rule: a B2C user must not get both a generic reminder and a
-- marketing push for the same event moment — enforced at send
-- time by checking pushes in the same window; emergency/logistics
-- are exempt but must be categorized + approved.
-- ------------------------------------------------------------
create table if not exists public.event_push_notifications (
  id           uuid primary key default gen_random_uuid(),
  event_id     uuid not null references public.events(id) on delete cascade,
  title        text not null,
  body         text,
  category     text not null check (category in ('reminder', 'promo', 'logistics', 'emergency')),
  approved     boolean not null default false,   -- emergency/logistics need explicit approval
  scheduled_at timestamptz,
  sent_at      timestamptz,
  sent_count   integer not null default 0,
  opened_count integer not null default 0,
  created_at   timestamptz not null default now()
);

create index if not exists event_push_event_idx on public.event_push_notifications(event_id);
alter table public.event_push_notifications enable row level security;

-- Pushes that count against the event's plan cap (emergency and
-- logistics sends are exempt from the cap).
create or replace function public.event_push_cap_usage(p_event_id uuid)
returns integer
language sql
stable
security definer
set search_path = public
as $$
  select count(*)::integer from public.event_push_notifications
   where event_id = p_event_id
     and sent_at is not null
     and category in ('reminder', 'promo');
$$;

-- ------------------------------------------------------------
-- Tracking RPC (app + web). Anonymous-friendly.
-- ------------------------------------------------------------
create or replace function public.track_event_metric(
  p_event_id       uuid,
  p_event_name     text,
  p_anon_device_id text default null,
  p_session_id     text default null,
  p_tab_key        text default null,
  p_vendor_id      uuid default null,
  p_sponsor_id     uuid default null,
  p_activation_id  uuid default null,
  p_band_id        uuid default null,
  p_notification_id uuid default null,
  p_notification_category text default null,
  p_target_url     text default null,
  p_metadata       jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.event_analytics_events
    (event_id, event_name, user_id, anon_device_id, session_id,
     tab_key, vendor_id, sponsor_id, activation_id, band_id,
     notification_id, notification_category, target_url, metadata)
  values
    (p_event_id, p_event_name, auth.uid(), nullif(trim(coalesce(p_anon_device_id, '')), ''),
     nullif(trim(coalesce(p_session_id, '')), ''),
     p_tab_key, p_vendor_id, p_sponsor_id, p_activation_id, p_band_id,
     p_notification_id, p_notification_category, p_target_url,
     coalesce(p_metadata, '{}'::jsonb));
  return jsonb_build_object('ok', true);
exception when others then
  -- Never break the consumer app over analytics.
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end;
$$;

grant execute on function public.track_event_metric(
  uuid, text, text, text, text, uuid, uuid, uuid, uuid, uuid, text, text, jsonb
) to anon, authenticated;

-- ------------------------------------------------------------
-- Rollup views
-- ------------------------------------------------------------

-- Per event x metric: total + unique attendees (user_id, else device).
create or replace view public.event_analytics_rollup as
select
  e.event_id,
  e.event_name,
  count(*)                                                  as total,
  count(distinct coalesce(e.user_id::text, e.anon_device_id)) as unique_attendees
from public.event_analytics_events e
group by e.event_id, e.event_name;

-- Series rollup: parent event aggregates itself + all children.
create or replace view public.event_series_rollup as
select
  coalesce(ev.parent_event_id, ev.id) as parent_event_id,
  a.event_name,
  count(*)                            as total,
  count(distinct coalesce(a.user_id::text, a.anon_device_id)) as unique_attendees,
  count(distinct a.event_id)          as events_with_activity
from public.event_analytics_events a
join public.events ev on ev.id = a.event_id
group by coalesce(ev.parent_event_id, ev.id), a.event_name;

-- Sponsor rollup: every sponsor-attributed metric per event.
create or replace view public.sponsor_analytics_rollup as
select
  e.event_id,
  e.sponsor_id,
  e.event_name,
  count(*)                                                  as total,
  count(distinct coalesce(e.user_id::text, e.anon_device_id)) as unique_attendees
from public.event_analytics_events e
where e.sponsor_id is not null
group by e.event_id, e.sponsor_id, e.event_name;

-- Activation funnel per sponsor: view -> link click -> check-in -> redemption.
create or replace view public.sponsor_activation_funnel as
select
  e.event_id,
  e.sponsor_id,
  e.activation_id,
  count(*) filter (where e.event_name = 'sponsor_view')          as views,
  count(*) filter (where e.event_name = 'sponsor_link_click')    as link_clicks,
  count(*) filter (where e.event_name = 'activation_checkin')    as checkins,
  count(*) filter (where e.event_name = 'activation_redemption') as redemptions,
  count(distinct coalesce(e.user_id::text, e.anon_device_id))
    filter (where e.event_name = 'activation_checkin')           as unique_checkins,
  count(distinct coalesce(e.user_id::text, e.anon_device_id))
    filter (where e.event_name = 'activation_redemption')        as unique_redemptions
from public.event_analytics_events e
where e.sponsor_id is not null
group by e.event_id, e.sponsor_id, e.activation_id;

-- Retention after event: of identifiable attendees active during
-- the event window, how many were active anywhere in the 30 days
-- after it ended (best-effort; only where ids are attributable).
create or replace view public.event_retention_30d as
with attendees as (
  select distinct a.event_id, coalesce(a.user_id::text, a.anon_device_id) as attendee
  from public.event_analytics_events a
  where coalesce(a.user_id::text, a.anon_device_id) is not null
),
windows as (
  select ev.id as event_id,
         coalesce(ev.end_date, ev.start_date)::date as ended_on
  from public.events ev
)
select
  w.event_id,
  count(distinct att.attendee) as event_attendees,
  count(distinct att.attendee) filter (where exists (
    select 1 from public.event_analytics_events later
     where coalesce(later.user_id::text, later.anon_device_id) = att.attendee
       and later.created_at::date > w.ended_on
       and later.created_at::date <= w.ended_on + 30
  )) as retained_30d
from attendees att
join windows w on w.event_id = att.event_id
group by w.event_id;

-- Paid reporting reads (admin/edge functions hold service role; the
-- partner dashboard reads through entitlement-gated RPCs elsewhere).
grant select on public.event_analytics_rollup,
                public.event_series_rollup,
                public.sponsor_analytics_rollup,
                public.sponsor_activation_funnel,
                public.event_retention_30d
  to authenticated;
