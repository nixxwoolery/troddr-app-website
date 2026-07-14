-- Support the post-event feedback push ("How was <event>?").
--
-- event_notification_deliveries is the per-(event,user) dedupe ledger for event
-- pushes. It previously only knew the pre-event reminder types; add 'post_event'
-- so notify-event-feedback can record — and skip re-sending — the after-the-fact
-- feedback nudge. A unique index makes the function's upsert idempotent so a
-- retried nightly run never double-pushes.

alter table public.event_notification_deliveries
  drop constraint if exists event_notification_deliveries_notification_type_check;
alter table public.event_notification_deliveries
  add constraint event_notification_deliveries_notification_type_check
  check (notification_type = any (array['t_minus_2'::text, 'day_of'::text, 'post_event'::text]));
create unique index if not exists event_notification_deliveries_unique_idx
  on public.event_notification_deliveries (event_id, user_id, notification_type);
