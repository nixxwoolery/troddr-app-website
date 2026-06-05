-- ============================================================
-- Automate event_partner_submissions approval.
--
-- When an admin sets status = 'approved' on a submission row,
-- the trigger either:
--   (a) UPDATES the linked events row (if event_id is already set)
--   (b) INSERTS a new events row from the submission and links it back
--
-- Idempotent: re-saving an already-approved submission does nothing.
-- ============================================================

-- 1. Link column so a submission can map to an existing event.
alter table public.event_partner_submissions
  add column if not exists event_id uuid
    references public.events(id) on delete set null;

create index if not exists eps_event_id_idx
  on public.event_partner_submissions(event_id);

-- ============================================================
-- 2. Slug helper. Lowercases, strips non-alphanum, dedupes.
-- ============================================================
create or replace function public.generate_unique_event_slug(p_title text)
returns text
language plpgsql
as $$
declare
  v_base text;
  v_slug text;
  v_n    int := 0;
begin
  v_base := lower(coalesce(trim(p_title), ''));
  v_base := regexp_replace(v_base, '[^a-z0-9\s-]', '', 'g');
  v_base := regexp_replace(v_base, '\s+', '-', 'g');
  v_base := regexp_replace(v_base, '-+', '-', 'g');
  v_base := trim(both '-' from v_base);
  v_base := substring(v_base, 1, 80);
  if v_base = '' then v_base := 'event'; end if;

  v_slug := v_base;
  while exists(select 1 from public.events where slug = v_slug) loop
    v_n := v_n + 1;
    v_slug := v_base || '-' || v_n;
  end loop;
  return v_slug;
end;
$$;

-- ============================================================
-- 3. The trigger function.
-- ============================================================
create or replace function public.copy_submission_to_event()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id    uuid;
  v_start_date  date;
  v_end_date    date;
  v_lat         double precision;
  v_lng         double precision;
  v_capacity    integer;
  v_min_age     integer;
  v_gallery     text[];
  v_slug        text;
begin
  -- Only fire on transition INTO 'approved'.
  if new.status is distinct from 'approved' then
    return new;
  end if;
  if old.status is not null and old.status = 'approved' then
    return new;
  end if;

  -- Safe casts (catch bad text values from intake form)
  begin v_start_date := nullif(trim(coalesce(new.event_start_date, '')), '')::date;
  exception when others then v_start_date := null; end;
  begin v_end_date := nullif(trim(coalesce(new.event_end_date, '')), '')::date;
  exception when others then v_end_date := null; end;
  begin v_lat := nullif(trim(coalesce(new.venue_lat, '')), '')::double precision;
  exception when others then v_lat := null; end;
  begin v_lng := nullif(trim(coalesce(new.venue_lng, '')), '')::double precision;
  exception when others then v_lng := null; end;
  begin v_capacity := nullif(trim(coalesce(new.estimated_attendance, '')), '')::integer;
  exception when others then v_capacity := null; end;
  begin
    v_min_age := nullif(regexp_replace(coalesce(new.age_restriction, ''), '[^0-9]', '', 'g'), '')::integer;
  exception when others then v_min_age := null; end;

  -- Gallery URLs: jsonb array -> text[]
  begin
    v_gallery := array(select jsonb_array_elements_text(coalesce(new.gallery_urls, '[]'::jsonb)));
  exception when others then v_gallery := array[]::text[]; end;

  ------------------------------------------------------------
  -- (a) Update an existing linked event
  ------------------------------------------------------------
  if new.event_id is not null then
    update public.events set
      title              = coalesce(nullif(trim(new.event_name), ''), title),
      description        = coalesce(nullif(trim(new.event_description), ''), description),
      start_date         = coalesce(v_start_date, start_date),
      end_date           = coalesce(v_end_date,   end_date),
      venue_name         = coalesce(nullif(trim(new.venue_name), ''), venue_name),
      venue_address      = coalesce(nullif(trim(new.venue_address), ''), venue_address),
      venue_lat          = coalesce(v_lat, venue_lat),
      venue_lng          = coalesce(v_lng, venue_lng),
      website_url        = coalesce(nullif(trim(new.website), ''), website_url),
      instagram_url      = coalesce(nullif(trim(new.instagram), ''), instagram_url),
      ticket_url         = coalesce(nullif(trim(new.tickets_url), ''), ticket_url),
      organizer_name     = coalesce(nullif(trim(new.organizer_name), ''), organizer_name),
      contact_email      = coalesce(nullif(trim(new.contact_email), ''), contact_email),
      contact_phone      = coalesce(nullif(trim(new.contact_phone), ''), contact_phone),
      event_type         = coalesce(nullif(trim(new.event_type), ''), event_type),
      featured_image_url = coalesce(nullif(trim(new.hero_url), ''), featured_image_url),
      capacity           = coalesce(v_capacity, capacity),
      min_age            = coalesce(v_min_age, min_age),
      image_urls         = case
                              when array_length(v_gallery, 1) is not null and array_length(v_gallery, 1) > 0
                                then v_gallery
                              else image_urls
                           end,
      floor_plan_url     = coalesce(nullif(trim(new.floor_plan_url), ''), floor_plan_url),
      faq                = case
                              when new.faqs is not null and new.faqs <> '[]'::jsonb
                                then new.faqs
                              else faq
                           end,
      updated_at         = now()
    where id = new.event_id;

  ------------------------------------------------------------
  -- (b) Insert a fresh event row from the submission
  ------------------------------------------------------------
  else
    v_slug := public.generate_unique_event_slug(
      coalesce(nullif(trim(new.event_name), ''), 'event'));

    insert into public.events (
      slug, title, description, status,
      start_date, end_date,
      venue_name, venue_address, venue_lat, venue_lng,
      country, timezone,
      website_url, instagram_url, ticket_url,
      organizer_name, contact_email, contact_phone,
      event_type, featured_image_url, image_urls,
      capacity, min_age, faq, floor_plan_url
    ) values (
      v_slug,
      coalesce(nullif(trim(new.event_name), ''), 'Untitled event'),
      nullif(trim(new.event_description), ''),
      'published',
      coalesce(v_start_date, current_date),
      coalesce(v_end_date, v_start_date, current_date),
      nullif(trim(new.venue_name), ''),
      nullif(trim(new.venue_address), ''),
      v_lat, v_lng,
      'Jamaica', 'America/Jamaica',
      nullif(trim(new.website), ''),
      nullif(trim(new.instagram), ''),
      nullif(trim(new.tickets_url), ''),
      nullif(trim(new.organizer_name), ''),
      nullif(trim(new.contact_email), ''),
      nullif(trim(new.contact_phone), ''),
      nullif(trim(new.event_type), ''),
      nullif(trim(new.hero_url), ''),
      coalesce(v_gallery, array[]::text[]),
      v_capacity,
      v_min_age,
      new.faqs,
      nullif(trim(new.floor_plan_url), '')
    )
    returning id into v_event_id;

    -- Link the submission back to the freshly created event
    new.event_id := v_event_id;
  end if;

  return new;
end;
$$;

-- ============================================================
-- 4. Wire the trigger. Fires BEFORE UPDATE so we can set
--    new.event_id when a new event is created.
-- ============================================================
drop trigger if exists trg_copy_submission_to_event
  on public.event_partner_submissions;

create trigger trg_copy_submission_to_event
  before update of status on public.event_partner_submissions
  for each row
  execute function public.copy_submission_to_event();

-- ============================================================
-- 5. Convenience RPC: approve a submission by id from the admin
--    side, in case you want an explicit call (e.g. from a
--    future admin dashboard). Same effect as updating status.
-- ============================================================
create or replace function public.approve_event_submission(p_submission_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
  v_event_slug text;
begin
  update public.event_partner_submissions
     set status = 'approved',
         submitted_at = coalesce(submitted_at, now()),
         updated_at = now()
   where id = p_submission_id
   returning event_id into v_event_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Submission not found');
  end if;

  select slug into v_event_slug from public.events where id = v_event_id;

  return jsonb_build_object(
    'ok',        true,
    'event_id',  v_event_id,
    'event_slug', v_event_slug
  );
end;
$$;

-- This RPC is admin-only by design. Don't grant to anon.
-- grant execute on function public.approve_event_submission(uuid) to service_role;

-- ============================================================
-- Maintenance helper: backfill / re-trigger for a submission
-- (useful if you've updated the mapping logic above).
-- ============================================================
-- update public.event_partner_submissions
--    set status = 'reviewing'
--  where id = '<submission-id>';
-- update public.event_partner_submissions
--    set status = 'approved'
--  where id = '<submission-id>';
