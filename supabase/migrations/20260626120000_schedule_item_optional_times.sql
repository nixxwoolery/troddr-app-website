-- Lineup items (artists/set times) are often added before times are confirmed
-- (TBA slots), so start_time / end_time must be optional. The original schema
-- marked both NOT NULL, which made upsert_schedule_item / bulk_import_schedule_items
-- fail with a not-null violation when the partner saved a timeless lineup entry.

alter table public.event_schedule_items alter column start_time drop not null;
alter table public.event_schedule_items alter column end_time drop not null;

notify pgrst, 'reload schema';
