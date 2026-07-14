-- Extend the existing suggested_places queue for the lightweight
-- "Not on TRODDR yet?" search flow. TRODDR remains curated: suggestions are
-- private curation signals and never become public places automatically.

alter table public.suggested_places
  add column if not exists intent text check (intent in ('been', 'want_to_go')),
  add column if not exists user_rating text check (user_rating in ('loved', 'ok', 'not_for_me')),
  add column if not exists experience_note text,
  add column if not exists source_context text not null default 'search'
    check (source_context in ('search', 'taste_notes', 'plans', 'suggest_spot')),
  add column if not exists source_metadata jsonb not null default '{}'::jsonb,
  add column if not exists notify_when_added boolean not null default false,
  add column if not exists notified_when_added_at timestamptz,
  add column if not exists matched_place_id uuid references public.places(id) on delete set null,
  add column if not exists matched_at timestamptz,
  add column if not exists matched_by uuid references auth.users(id) on delete set null;
create index if not exists suggested_places_context_created_idx
  on public.suggested_places (source_context, created_at desc);
create index if not exists suggested_places_notify_match_idx
  on public.suggested_places (matched_place_id)
  where notify_when_added and notified_when_added_at is null;
create index if not exists suggested_places_name_location_idx
  on public.suggested_places (lower(spot_name), lower(location));
alter table public.notification_log
  add column if not exists suggested_place_id uuid references public.suggested_places(id) on delete set null;
create index if not exists notification_log_suggested_place_idx
  on public.notification_log (suggested_place_id, user_id, notification_type);
drop policy if exists "suggested_places_select_own" on public.suggested_places;
create policy "suggested_places_select_own"
  on public.suggested_places for select
  using (auth.uid() = user_id);
drop policy if exists "suggested_places_update_own" on public.suggested_places;
create policy "suggested_places_update_own"
  on public.suggested_places for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
