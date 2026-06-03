-- ============================================================
-- Partners table + partner_id on places/events
-- Backwards-compatible: existing per-entity tokens keep working.
-- Multi-entity partners get sibling entities surfaced in the picker.
-- ============================================================

create table if not exists public.partners (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  contact_email text,
  notes         text,
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);

alter table public.places
  add column if not exists partner_id uuid references public.partners(id) on delete set null;

alter table public.events
  add column if not exists partner_id uuid references public.partners(id) on delete set null;

create index if not exists places_partner_id_idx on public.places(partner_id);
create index if not exists events_partner_id_idx on public.events(partner_id);

-- ============================================================
-- Example: grouping Soup King + Sumfest + Kingston Kitchen under
-- one demo partner so the entity picker has something to show.
-- ============================================================
-- insert into public.partners (name, contact_email)
-- values ('Touchstone Demo Partner', 'hello@troddr.com')
-- returning id;
--
-- -- Then update the three entities with the returned id:
-- update public.places set partner_id = '<id>' where slug = 'soup-king';
-- update public.events set partner_id = '<id>' where slug in ('reggae-sumfest', 'kingston-kitchen-night-market');
