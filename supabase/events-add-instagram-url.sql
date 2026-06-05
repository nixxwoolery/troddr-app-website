-- ============================================================
-- Add events.instagram_url
-- The event-edit form and the submission trigger both expect
-- this column. Safe to re-run (uses IF NOT EXISTS).
-- ============================================================

alter table public.events
  add column if not exists instagram_url text;
