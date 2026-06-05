-- ============================================================
-- Specials submission workflow: partners upload, we approve.
-- ============================================================

-- Add submission_status to existing specials.
-- Existing specials default to 'approved' so they keep showing.
alter table public.specials
  add column if not exists submission_status text not null default 'approved'
    check (submission_status in ('draft', 'pending', 'approved', 'rejected'));

create index if not exists specials_submission_status_idx
  on public.specials (submission_status);

-- Also track who submitted, when, and any admin note.
alter table public.specials
  add column if not exists submitted_at      timestamptz,
  add column if not exists submitted_via     text,
  add column if not exists review_note       text,
  add column if not exists reviewed_at       timestamptz,
  add column if not exists reviewed_by       text;

-- ============================================================
-- RPC: partner submits a new special.
-- Resolves token to a place, inserts the row with status='pending'.
-- ============================================================
create or replace function public.submit_partner_special(
  p_token               text,
  p_title               text,
  p_description         text,
  p_special_type        text,
  p_start_date          timestamptz,
  p_end_date            timestamptz,
  p_start_time          time default null,
  p_end_time            time default null,
  p_image_url           text default null,
  p_discount_percentage numeric default null,
  p_discount_amount     numeric default null,
  p_price_amount        numeric default null,
  p_currency            text default null,
  p_event_category      text default null,
  p_tags                text[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place places%rowtype;
  v_special_id uuid;
  v_image_urls text[];
begin
  -- Validate
  if p_title is null or length(trim(p_title)) = 0 then
    return jsonb_build_object('ok', false, 'error', 'Title is required');
  end if;
  if p_start_date is null or p_end_date is null then
    return jsonb_build_object('ok', false, 'error', 'Start and end dates are required');
  end if;
  if p_end_date < p_start_date then
    return jsonb_build_object('ok', false, 'error', 'End date must be on or after start date');
  end if;
  if p_special_type is null or p_special_type not in
     ('partnership','local_discount','seasonal','general','event','travel_special') then
    return jsonb_build_object('ok', false, 'error', 'Pick a valid special type');
  end if;

  -- Resolve token
  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;

  v_image_urls := case
    when p_image_url is null or length(trim(p_image_url)) = 0 then array[]::text[]
    else array[trim(p_image_url)]
  end;

  insert into public.specials (
    place_id, title, description, special_type,
    start_date, end_date, start_time, end_time,
    image_urls,
    discount_percentage, discount_amount,
    price_amount, currency,
    event_category, event_tags,
    active, submission_status,
    submitted_at, submitted_via, country, town, parish
  )
  values (
    v_place.id,
    trim(p_title),
    nullif(trim(coalesce(p_description, '')), ''),
    p_special_type,
    p_start_date, p_end_date,
    p_start_time, p_end_time,
    v_image_urls,
    p_discount_percentage,
    p_discount_amount,
    p_price_amount,
    coalesce(nullif(trim(coalesce(p_currency,'')), ''), 'JMD'),
    nullif(trim(coalesce(p_event_category, '')), ''),
    coalesce(p_tags, '{}'::text[]),
    false,                          -- not active until approved
    'pending',
    now(),
    'partner_dashboard',
    v_place.country, v_place.town, v_place.parish
  )
  returning id into v_special_id;

  return jsonb_build_object(
    'ok', true,
    'id', v_special_id,
    'status', 'pending',
    'message', 'Submitted for approval. We''ll review within 1 business day.'
  );
end;
$$;

grant execute on function public.submit_partner_special(
  text, text, text, text, timestamptz, timestamptz, time, time,
  text, numeric, numeric, numeric, text, text, text[]
) to anon;
