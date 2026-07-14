-- Post-event feedback: one row per (user, event), collected by the in-app
-- modal after the user attended (marked "Went" or interacted during the
-- event). Mirrors the visited_feedback pattern for places: dimension
-- ratings + quick tags + a would-return vote.

create table if not exists public.event_feedback (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users (id) on delete cascade,
  event_id uuid not null references public.events (id) on delete cascade,

  -- "Loved it" / "Not for me" — nullable so a ratings-only submit is valid.
  vote text check (vote in ('up', 'down')),

  rating_experience   smallint check (rating_experience   between 1 and 5),
  rating_organization smallint check (rating_organization between 1 and 5),
  rating_value        smallint check (rating_value        between 1 and 5),
  rating_food         smallint check (rating_food         between 1 and 5),

  quick_tags text[] not null default '{}',

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  unique (user_id, event_id)
);
create index if not exists event_feedback_event_id_idx
  on public.event_feedback (event_id);
alter table public.event_feedback enable row level security;
-- Users manage only their own feedback. Organizer-facing aggregation reads
-- happen server-side (dashboard / RPC with elevated role), not via RLS.
create policy "event_feedback_select_own"
  on public.event_feedback for select
  using (auth.uid() = user_id);
create policy "event_feedback_insert_own"
  on public.event_feedback for insert
  with check (auth.uid() = user_id);
create policy "event_feedback_update_own"
  on public.event_feedback for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
-- Keep updated_at honest on edits.
create or replace function public.event_feedback_set_updated_at()
returns trigger
language plpgsql
security definer set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;
drop trigger if exists event_feedback_updated_at on public.event_feedback;
create trigger event_feedback_updated_at
  before update on public.event_feedback
  for each row execute function public.event_feedback_set_updated_at();
