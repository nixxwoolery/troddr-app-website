-- Per-event list of zone names that require a VIP ticket. A vendor is VIP-only
-- when its event_vendors.zone matches one of these (case-insensitive in app).
-- Null/empty = the event has no access tiers (all zones open to everyone).
alter table public.events add column if not exists vip_zones text[];

comment on column public.events.vip_zones is
  'Zone names (matching event_vendors.zone) that require a VIP ticket. App badges those vendors and can filter them out for general-ticket holders.';;
