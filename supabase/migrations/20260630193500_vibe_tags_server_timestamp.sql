-- ---------------------------------------------------------------------------
-- vibe_tags: force a server-authoritative created_at
--
-- Line status decays by (now - created_at). The client used to send its own
-- device clock as created_at, so a phone with a fast clock produced
-- future-dated reports that every other viewer silently dropped (negative age),
-- and a slow clock made reports decay early. created_at's column DEFAULT now()
-- only fires on INSERT, not on the upsert's ON CONFLICT update path (a user
-- re-reporting), so a default alone can't fix it.
--
-- This BEFORE INSERT OR UPDATE trigger stamps now() on every write, making the
-- server the single clock for everyone regardless of what the client sends.
-- ---------------------------------------------------------------------------

create or replace function public._vibe_tags_set_created_at()
returns trigger
language plpgsql
as $$
begin
  new.created_at := now();
  return new;
end;
$$;
drop trigger if exists vibe_tags_set_created_at on public.vibe_tags;
create trigger vibe_tags_set_created_at
  before insert or update on public.vibe_tags
  for each row execute function public._vibe_tags_set_created_at();
