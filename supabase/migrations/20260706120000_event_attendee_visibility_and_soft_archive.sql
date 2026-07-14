-- Keep attended events visible to their attendees, and stop hard-deletes from
-- silently erasing everyone's history.
--
-- Background: an event that is "removed" (soft-deleted via deleted_at, or its
-- status flipped off 'published') disappears entirely for the people who
-- attended it — the only SELECT policy on `events` is
--   USING (status = 'published' AND deleted_at IS NULL)
-- so Event History (myEvents.tsx) and the post-event feedback flow, which both
-- read the live `events` row, render nothing. Worse, a *hard* DELETE cascades
-- through every attendee-scoped table (event_interests, user_event_activity,
-- event_feedback, user_schedule_plans, saved items, ratings — all ON DELETE
-- CASCADE), wiping attendance and feedback for every user, not just the caller.
--
-- Two fixes here:
--   1. An additive SELECT policy so a user can always read an event they
--      personally engaged with, regardless of status / deleted_at. RLS policies
--      are OR-ed, so the public "published only" view is unchanged for everyone
--      else.
--   2. A BEFORE DELETE guard that converts a hard delete of an event that still
--      has attendee data into a soft-archive (deleted_at + status='archived'),
--      preserving the rows the cascade would otherwise destroy. Events with no
--      attendee footprint (test/spam/draft) still delete normally.

-- ── 1. Attendees can always see events they engaged with ────────────────────
drop policy if exists "Attendees can view their attended events" on public.events;
create policy "Attendees can view their attended events"
  on public.events
  for select
  to authenticated
  using (
    exists (select 1 from public.event_interests ei
              where ei.event_id = events.id and ei.user_id = auth.uid())
    or exists (select 1 from public.user_event_activity ua
              where ua.event_id = events.id and ua.user_id = auth.uid())
    or exists (select 1 from public.event_feedback ef
              where ef.event_id = events.id and ef.user_id = auth.uid())
    or exists (select 1 from public.user_schedule_plans sp
              where sp.event_id = events.id and sp.user_id = auth.uid())
    or exists (select 1 from public.user_saved_menu_items si
              where si.event_id = events.id and si.user_id = auth.uid())
    or exists (select 1 from public.user_vendor_item_ratings vr
              where vr.event_id = events.id and vr.user_id = auth.uid())
  );
-- ── 2. Convert hard-delete-with-attendees into soft-archive ─────────────────
-- SECURITY DEFINER so the EXISTS probes see *all* attendee rows regardless of
-- the caller's RLS (a dashboard admin cannot see other users' user-scoped rows
-- under RLS, which would otherwise make the guard miss them and allow the
-- destructive cascade).
create or replace function public.events_soft_archive_with_attendees()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if exists (select 1 from public.event_interests        where event_id = old.id)
     or exists (select 1 from public.user_event_activity  where event_id = old.id)
     or exists (select 1 from public.event_feedback       where event_id = old.id)
     or exists (select 1 from public.user_schedule_plans  where event_id = old.id)
     or exists (select 1 from public.user_saved_menu_items where event_id = old.id)
     or exists (select 1 from public.user_vendor_item_ratings where event_id = old.id)
  then
    -- Preserve the attendee footprint: archive instead of destroying it.
    update public.events
       set deleted_at = coalesce(deleted_at, now()),
           status     = 'archived'
     where id = old.id;
    raise notice 'events: id % has attendee data — soft-archived instead of deleted', old.id;
    return null;  -- cancel the DELETE; the row stays, now archived
  end if;

  return old;     -- no attendee data — allow the delete
end;
$$;
drop trigger if exists events_soft_archive_guard on public.events;
create trigger events_soft_archive_guard
  before delete on public.events
  for each row
  execute function public.events_soft_archive_with_attendees();
