-- ============================================================
-- Event Onboarding RPC: lets an event partner update their
-- event row from the dashboard.
-- ============================================================

create or replace function public._normalize_event_type(p_raw text)
returns text
language sql
immutable
as $$
  select case lower(regexp_replace(coalesce(trim(p_raw), ''), '[\s&-]+', ' ', 'g'))
    when ''                  then null
    when 'music'             then 'music'
    when 'concert'           then 'music'
    when 'live music'        then 'music'
    when 'food'              then 'food and drink'
    when 'food and drink'    then 'food and drink'
    when 'drink'             then 'food and drink'
    when 'drinks'            then 'food and drink'
    when 'culinary'          then 'food and drink'
    when 'art'               then 'art'
    when 'art and culture'   then 'art'
    when 'culture'           then 'art'
    when 'sports'            then 'sports'
    when 'sport'             then 'sports'
    when 'comedy'            then 'comedy'
    when 'festival'          then 'festival'
    when 'conference'        then 'conference'
    when 'networking'        then 'networking'
    when 'workshop'          then 'workshop'
    when 'party'             then 'party'
    when 'nightlife'         then 'nightlife'
    when 'family'            then 'family'
    when 'wellness'          then 'wellness'
    when 'community'         then 'community'
    when 'carnival'          then 'carnival'
    else null
  end;
$$;

do $$
declare
  v_constraint record;
begin
  for v_constraint in
    select conname
      from pg_constraint
     where conrelid = 'public.events'::regclass
       and contype = 'c'
       and pg_get_constraintdef(oid) ilike '%start_time%'
       and pg_get_constraintdef(oid) ilike '%end_time%'
  loop
    execute format('alter table public.events drop constraint %I', v_constraint.conname);
  end loop;

  if not exists (
    select 1
      from pg_constraint
     where conrelid = 'public.events'::regclass
       and conname = 'events_valid_event_chronology'
  ) then
    alter table public.events
      add constraint events_valid_event_chronology check (
        start_date is null
        or end_date is null
        or end_date > start_date
        or (
          end_date = start_date
          and (
            start_time is null
            or end_time is null
            or end_time >= start_time
          )
        )
      );
  end if;
end;
$$;

drop function if exists public.update_partner_event(
  text, text, text, text, date, date, time, time, boolean, text,
  text, text, text, text, text,
  boolean, numeric, numeric, text, boolean, boolean, text, integer,
  integer, text, boolean, boolean,
  text, text, text, text, text, text, text, text, text
);

create or replace function public.update_partner_event(
  p_token              text,
  p_title              text default null,
  p_description        text default null,
  p_short_description  text default null,
  p_start_date         date default null,
  p_end_date           date default null,
  p_start_time         time default null,
  p_end_time           time default null,
  p_is_all_day         boolean default null,
  p_timezone           text default null,
  p_venue_name         text default null,
  p_venue_address      text default null,
  p_parish             text default null,
  p_town               text default null,
  p_country            text default null,
  p_is_free            boolean default null,
  p_ticket_price_min   numeric default null,
  p_ticket_price_max   numeric default null,
  p_currency           text default null,
  p_has_online_tickets boolean default null,
  p_is_sold_out        boolean default null,
  p_ticket_url         text default null,
  p_capacity           integer default null,
  p_min_age            integer default null,
  p_dress_code         text default null,
  p_food_available     boolean default null,
  p_alcohol_served     boolean default null,
  p_organizer_name     text default null,
  p_contact_email      text default null,
  p_contact_phone      text default null,
  p_support_email      text default null,
  p_support_phone      text default null,
  p_support_url        text default null,
  p_website_url        text default null,
  p_instagram_url      text default null,
  p_featured_image_url text default null,
  p_event_type         text default null,
  p_info_sections      jsonb default null,
  p_faq                jsonb default null,
  p_parking_image_url  text default null,
  p_parking_image_urls jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event events%rowtype;
  v_updated_count int;
  v_start_date date;
  v_end_date date;
  v_start_time time;
  v_end_time time;
begin
  select * into v_event from public.events where partner_access_token = p_token;
  if v_event.id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;

  v_start_date := coalesce(p_start_date, v_event.start_date);
  v_end_date := coalesce(p_end_date, v_event.end_date);
  v_start_time := coalesce(p_start_time, v_event.start_time);
  v_end_time := coalesce(p_end_time, v_event.end_time);

  if v_start_date is not null and v_end_date is not null and v_end_date < v_start_date then
    return jsonb_build_object('ok', false, 'error', 'End date must be on or after start date');
  end if;

  if v_start_date is not null
     and v_end_date is not null
     and v_end_date = v_start_date
     and v_start_time is not null
     and v_end_time is not null
     and v_end_time < v_start_time then
    return jsonb_build_object('ok', false, 'error', 'For overnight events, set the end date to the following day');
  end if;

  update public.events set
    title              = coalesce(nullif(trim(p_title), ''), title),
    description        = case when p_description is not null then nullif(trim(p_description), '') else description end,
    short_description  = case when p_short_description is not null then nullif(trim(p_short_description), '') else short_description end,
    start_date         = v_start_date,
    end_date           = v_end_date,
    start_time         = v_start_time,
    end_time           = v_end_time,
    is_all_day         = coalesce(p_is_all_day, is_all_day),
    timezone           = coalesce(nullif(trim(p_timezone), ''), timezone),
    venue_name         = case when p_venue_name is not null then nullif(trim(p_venue_name), '') else venue_name end,
    venue_address      = case when p_venue_address is not null then nullif(trim(p_venue_address), '') else venue_address end,
    parish             = case when p_parish is not null then nullif(trim(p_parish), '') else parish end,
    town               = case when p_town is not null then nullif(trim(p_town), '') else town end,
    country            = case when p_country is not null then nullif(trim(p_country), '') else country end,
    is_free            = coalesce(p_is_free, is_free),
    ticket_price_min   = case when p_ticket_price_min is not null then p_ticket_price_min else ticket_price_min end,
    ticket_price_max   = case when p_ticket_price_max is not null then p_ticket_price_max else ticket_price_max end,
    currency           = case when p_currency is not null then nullif(trim(p_currency), '') else currency end,
    has_online_tickets = coalesce(p_has_online_tickets, has_online_tickets),
    is_sold_out        = coalesce(p_is_sold_out, is_sold_out),
    ticket_url         = case when p_ticket_url is not null then nullif(trim(p_ticket_url), '') else ticket_url end,
    capacity           = case when p_capacity is not null then p_capacity else capacity end,
    min_age            = case when p_min_age is not null then p_min_age else min_age end,
    dress_code         = case when p_dress_code is not null then nullif(trim(p_dress_code), '') else dress_code end,
    food_available     = coalesce(p_food_available, food_available),
    alcohol_served     = coalesce(p_alcohol_served, alcohol_served),
    organizer_name     = case when p_organizer_name is not null then nullif(trim(p_organizer_name), '') else organizer_name end,
    contact_email      = case when p_contact_email is not null then nullif(trim(p_contact_email), '') else contact_email end,
    contact_phone      = case when p_contact_phone is not null then nullif(trim(p_contact_phone), '') else contact_phone end,
    support_email      = case when p_support_email is not null then nullif(trim(p_support_email), '') else support_email end,
    support_phone      = case when p_support_phone is not null then nullif(trim(p_support_phone), '') else support_phone end,
    support_url        = case when p_support_url is not null then nullif(trim(p_support_url), '') else support_url end,
    website_url        = case when p_website_url is not null then nullif(trim(p_website_url), '') else website_url end,
    instagram_url      = case when p_instagram_url is not null then nullif(trim(p_instagram_url), '') else instagram_url end,
    featured_image_url = case when p_featured_image_url is not null then nullif(trim(p_featured_image_url), '') else featured_image_url end,
    event_type         = case when p_event_type is not null then coalesce(public._normalize_event_type(p_event_type), event_type) else event_type end,
    info_sections      = case when p_info_sections is not null then p_info_sections else info_sections end,
    faq                = case when p_faq is not null then p_faq else faq end,
    parking_image_url  = case when p_parking_image_url is not null then nullif(trim(p_parking_image_url), '') else parking_image_url end,
    parking_image_urls = case when p_parking_image_urls is not null then p_parking_image_urls else parking_image_urls end,
    updated_at         = now()
  where id = v_event.id;

  get diagnostics v_updated_count = row_count;

  return jsonb_build_object(
    'ok', true,
    'updated_count', v_updated_count,
    'message', 'Event updated successfully.'
  );
end;
$$;

grant execute on function public.update_partner_event(
  text, text, text, text, date, date, time, time, boolean, text,
  text, text, text, text, text,
  boolean, numeric, numeric, text, boolean, boolean, text, integer,
  integer, text, boolean, boolean,
  text, text, text, text, text, text, text, text, text, text,
  jsonb, jsonb, text, jsonb
) to anon;
