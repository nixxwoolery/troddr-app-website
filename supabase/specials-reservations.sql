-- ============================================================
-- Specials reservations-lite + extended fields.
-- Adds capacity tracking + recurring days + tied event + age
-- restriction to submitted specials. Reservation claims come
-- from special_interactions where status = 'going'.
-- ============================================================

-- 1. New column for capacity
alter table public.specials
  add column if not exists capacity integer;

-- 2. Extended submit RPC. Replaces the earlier submit_partner_special.
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
  p_tags                text[] default null,
  -- new
  p_capacity            integer default null,
  p_recurring_days      text[] default null,
  p_age_restriction     text default null,
  p_host_name           text default null,
  p_event_slug          text default null,
  p_ticket_link         text default null,
  p_rsvp_link           text default null,
  p_image_urls          text[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place      places%rowtype;
  v_special_id uuid;
  v_image_urls text[];
begin
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
  if p_capacity is not null and p_capacity < 0 then
    return jsonb_build_object('ok', false, 'error', 'Capacity must be a positive number');
  end if;

  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;

  -- Merge p_image_url + p_image_urls. p_image_url takes the first slot if present.
  v_image_urls := coalesce(p_image_urls, array[]::text[]);
  if p_image_url is not null and length(trim(p_image_url)) > 0 then
    v_image_urls := array[trim(p_image_url)] || v_image_urls;
  end if;

  insert into public.specials (
    place_id, title, description, special_type,
    start_date, end_date, start_time, end_time,
    recurring_days,
    image_urls,
    discount_percentage, discount_amount,
    price_amount, currency,
    event_category, event_tags,
    capacity, age_restriction, host_name,
    event_slug, ticket_link, rsvp_link,
    active, submission_status,
    submitted_at, submitted_via,
    country, town, parish
  )
  values (
    v_place.id,
    trim(p_title),
    nullif(trim(coalesce(p_description, '')), ''),
    p_special_type,
    p_start_date, p_end_date,
    p_start_time, p_end_time,
    coalesce(p_recurring_days, '{}'::text[]),
    v_image_urls,
    p_discount_percentage,
    p_discount_amount,
    p_price_amount,
    coalesce(nullif(trim(coalesce(p_currency, '')), ''), 'JMD'),
    nullif(trim(coalesce(p_event_category, '')), ''),
    coalesce(p_tags, '{}'::text[]),
    p_capacity,
    nullif(trim(coalesce(p_age_restriction, '')), ''),
    nullif(trim(coalesce(p_host_name, '')), ''),
    nullif(trim(coalesce(p_event_slug, '')), ''),
    nullif(trim(coalesce(p_ticket_link, '')), ''),
    nullif(trim(coalesce(p_rsvp_link, '')), ''),
    false,
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
  text, numeric, numeric, numeric, text, text, text[],
  integer, text[], text, text, text, text, text, text[]
) to anon;

-- 3. Patch the specials analytics RPC to expose capacity + remaining.
--    "Reservations claimed" = special_interactions where status = 'going'.
create or replace function public.get_partner_specials_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place places%rowtype;
  v_now   timestamptz := now();
begin
  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then return null; end if;

  return jsonb_build_object(
    'place', jsonb_build_object('id', v_place.id, 'name', v_place.name, 'slug', v_place.slug),

    'program', (
      select jsonb_build_object(
        'primary_color',   primary_color,
        'accent_color',    accent_color,
        'text_color',      text_color,
        'secondary_color', secondary_color
      )
      from public.loyalty_programs
      where place_id = v_place.id and is_active = true
      order by created_at desc limit 1
    ),

    'summary', (
      select jsonb_build_object(
        'total',     count(*),
        'active',    count(*) filter (
          where coalesce(submission_status, 'approved') = 'approved'
            and coalesce(active, true) = true
            and v_now between start_date and end_date),
        'upcoming',  count(*) filter (
          where coalesce(submission_status, 'approved') = 'approved'
            and coalesce(active, true) = true
            and v_now < start_date),
        'ended',     count(*) filter (where v_now > end_date),
        'inactive',  count(*) filter (
          where coalesce(submission_status, 'approved') = 'approved'
            and coalesce(active, true) = false),
        'pending',   count(*) filter (where submission_status = 'pending'),
        'rejected',  count(*) filter (where submission_status = 'rejected'),
        'draft',     count(*) filter (where submission_status = 'draft'),
        'total_visits',
          (select count(*) from public.special_visits
            where special_id in (select id from public.specials where place_id = v_place.id)),
        'total_interactions',
          (select count(*) from public.special_interactions
            where special_id in (select id from public.specials where place_id = v_place.id)),
        'total_ratings',
          (select count(*) from public.special_interactions
            where special_id in (select id from public.specials where place_id = v_place.id)
              and rating is not null)
      )
      from public.specials
      where place_id = v_place.id
    ),

    'specials', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',                  s.id,
        'title',               s.title,
        'description',         s.description,
        'special_type',        s.special_type,
        'special_slug',        s.special_slug,
        'start_date',          s.start_date,
        'end_date',            s.end_date,
        'start_time',          s.start_time,
        'end_time',            s.end_time,
        'recurring_days',      s.recurring_days,
        'is_active',           coalesce(s.active, true),
        'submission_status',   coalesce(s.submission_status, 'approved'),
        'submitted_at',        s.submitted_at,
        'review_note',         s.review_note,
        'image_url',
          (case when s.image_urls is not null and array_length(s.image_urls, 1) > 0
                then s.image_urls[1] else null end),
        'image_urls',          s.image_urls,
        'discount_percentage', s.discount_percentage,
        'discount_amount',     s.discount_amount,
        'price_amount',        s.price_amount,
        'price_type',          s.price_type,
        'currency',            coalesce(nullif(s.currency, ''), 'JMD'),
        'event_category',      s.event_category,
        'event_tags',          s.event_tags,
        'priority',            coalesce(s.priority, 0),
        'age_restriction',     s.age_restriction,
        'host_name',           s.host_name,
        'event_slug',          s.event_slug,
        'ticket_link',         s.ticket_link,
        'rsvp_link',           s.rsvp_link,
        'capacity',            s.capacity,
        'claimed_count',
          (select count(*) from public.special_interactions
            where special_id = s.id and status = 'going'),
        'remaining',
          (case
            when s.capacity is null then null
            else greatest(0,
              s.capacity - coalesce(
                (select count(*) from public.special_interactions
                  where special_id = s.id and status = 'going'),
                0))
          end),
        'lifecycle', (
          case
            when coalesce(s.submission_status, 'approved') = 'pending'  then 'pending'
            when coalesce(s.submission_status, 'approved') = 'rejected' then 'rejected'
            when coalesce(s.submission_status, 'approved') = 'draft'    then 'draft'
            when not coalesce(s.active, true) then 'inactive'
            when v_now < s.start_date then 'upcoming'
            when v_now > s.end_date then 'ended'
            else 'active'
          end
        ),
        'visits_count',
          (select count(*) from public.special_visits where special_id = s.id),
        'unique_visitors',
          (select count(distinct user_id) from public.special_visits where special_id = s.id),
        'interested_count',
          (select count(*) from public.special_interactions where special_id = s.id and status = 'interested'),
        'going_count',
          (select count(*) from public.special_interactions where special_id = s.id and status = 'going'),
        'attended_count',
          (select count(*) from public.special_interactions where special_id = s.id and status = 'attended'),
        'upvotes',
          (select count(*) from public.special_interactions where special_id = s.id and vote = 'up'),
        'downvotes',
          (select count(*) from public.special_interactions where special_id = s.id and vote = 'down'),
        'rating_avg',
          (select round(avg(rating)::numeric, 2) from public.special_interactions
            where special_id = s.id and rating is not null),
        'rating_count',
          (select count(*) from public.special_interactions
            where special_id = s.id and rating is not null),
        'avg_ratings', (
          select jsonb_build_object(
            'value',         round(avg(rating_value)::numeric,         2),
            'vibe',          round(avg(rating_vibe)::numeric,          2),
            'experience',    round(avg(rating_experience)::numeric,    2),
            'organisation',  round(avg(rating_organisation)::numeric,  2),
            'taste',         round(avg(rating_taste)::numeric,         2),
            'portions',      round(avg(rating_portions)::numeric,      2),
            'presentation',  round(avg(rating_presentation)::numeric,  2),
            'drinks',        round(avg(rating_drinks)::numeric,        2)
          )
          from public.special_interactions where special_id = s.id
        ),
        'top_tags', (
          select coalesce(
            jsonb_agg(jsonb_build_object('tag', tag, 'count', n) order by n desc),
            '[]'::jsonb)
          from (
            select tag, count(*) as n
            from (
              select unnest(quick_tags) as tag
              from public.special_interactions
              where special_id = s.id
            ) tags
            where tag is not null and tag <> ''
            group by tag
            order by count(*) desc
            limit 6
          ) t
        )
      ) order by
          (case when coalesce(s.submission_status, 'approved') = 'pending' then -1
                when coalesce(s.active, true) = true and v_now between s.start_date and s.end_date then 0
                when coalesce(s.active, true) = true and v_now < s.start_date then 1
                else 2 end),
          s.priority desc nulls last,
          s.start_date desc
      ), '[]'::jsonb)
      from public.specials s
      where s.place_id = v_place.id
    )
  );
end;
$$;

grant execute on function public.get_partner_specials_by_token(text) to anon;
