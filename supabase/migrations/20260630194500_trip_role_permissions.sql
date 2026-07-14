-- ---------------------------------------------------------------------------
-- Trip collaborator roles: editor vs viewer
--
-- trip_collaborators.role already exists (check: owner/editor/viewer, default
-- editor) but nothing enforced it. Previously ANY accepted collaborator could
-- invite others AND edit the itinerary (is_trip_collaborator gated everything).
--
-- This migration makes role mean something:
--   • editors (+ owner) can invite others and edit the trip
--   • viewers can read the trip but not invite or edit
--   • the owner still manages everyone's role / removes people
--     (unchanged — handled by the existing "Trip owner manages collaborators"
--      FOR ALL policy)
-- ---------------------------------------------------------------------------

-- ── Helper: is the current user an owner or an accepted editor of this trip? ──
-- SECURITY DEFINER + fixed search_path, mirroring is_trip_owner /
-- is_trip_collaborator so evaluating it inside a policy doesn't re-fire
-- itineraries' RLS and recurse.
create or replace function public.is_trip_editor(_trip_id uuid)
returns boolean
language sql
stable
security definer
set search_path to 'public'
as $$
  select public.is_trip_owner(_trip_id)
      or exists (
        select 1
        from public.trip_collaborators
        where trip_id = _trip_id
          and invitee_id = auth.uid()
          and status = 'accepted'
          and role in ('owner', 'editor')
      );
$$;
grant all on function public.is_trip_editor(uuid) to anon, authenticated, service_role;
-- ── Invites: only owner/editors may mint invite rows ─────────────────────────
-- Replaces the member-insert policy that let any accepted collaborator invite.
drop policy if exists "trip_collaborators_member_insert" on public.trip_collaborators;
drop policy if exists "trip_collaborators_owner_insert"  on public.trip_collaborators;
-- legacy, superseded
create policy "trip_collaborators_editor_insert"
  on public.trip_collaborators
  for insert
  with check (
    invited_by = auth.uid()
    and public.is_trip_editor(trip_id)
  );
-- ── itinerary_places: viewers read-only, editors write ───────────────────────
-- The old FOR ALL collaborators policy let every collaborator write. Split it:
-- collaborators (incl. viewers) may SELECT; only editors may write.
drop policy if exists "itinerary_places_collaborators_all" on public.itinerary_places;
create policy "itinerary_places_collaborators_select"
  on public.itinerary_places
  for select
  using (public.is_trip_collaborator(itinerary_id));
create policy "itinerary_places_editors_write"
  on public.itinerary_places
  for all
  using (public.is_trip_editor(itinerary_id))
  with check (public.is_trip_editor(itinerary_id));
-- ── itinerary_events: viewers read-only, editors write ───────────────────────
-- SELECT policy stays as-is (owner or accepted collaborator). Narrow the write
-- policies from "owner or collaborator" to "owner or editor".
drop policy if exists "itinerary_events_insert" on public.itinerary_events;
drop policy if exists "itinerary_events_update" on public.itinerary_events;
drop policy if exists "itinerary_events_delete" on public.itinerary_events;
create policy "itinerary_events_insert"
  on public.itinerary_events
  for insert
  with check (public.is_trip_editor(itinerary_id));
create policy "itinerary_events_update"
  on public.itinerary_events
  for update
  using (public.is_trip_editor(itinerary_id))
  with check (public.is_trip_editor(itinerary_id));
create policy "itinerary_events_delete"
  on public.itinerary_events
  for delete
  using (public.is_trip_editor(itinerary_id));
