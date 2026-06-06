-- ============================================================
-- Partner-side edits for existing entities.
--   1. update_partner_special     : edit an approved special
--   2. update_partner_place_contact : edit the contact/links
--      portion of a place (NOT the curated content)
-- ============================================================

-- ============================================================
-- 1. update_partner_special
-- Lets a partner edit any of their existing specials (regardless
-- of current submission_status). Field is updated only when the
-- caller passes a non-null value. submission_status is preserved.
-- ============================================================
create or replace function public.update_partner_special(
  p_token               text,
  p_special_id          uuid,
  p_title               text default null,
  p_description         text default null,
  p_special_type        text default null,
  p_start_date          timestamptz default null,
  p_end_date            timestamptz default null,
  p_start_time          time default null,
  p_end_time            time default null,
  p_image_url           text default null,
  p_discount_percentage numeric default null,
  p_discount_amount     numeric default null,
  p_price_amount        numeric default null,
  p_currency            text default null,
  p_event_category      text default null,
  p_tags                text[] default null,
  p_capacity            integer default null,
  p_recurring_days      text[] default null,
  p_age_restriction     text default null,
  p_host_name           text default null,
  p_event_slug          text default null,
  p_ticket_link         text default null,
  p_rsvp_link           text default null,
  p_clear_capacity      boolean default false,
  p_clear_image         boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place    places%rowtype;
  v_special  specials%rowtype;
  v_image_urls text[];
begin
  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;

  select * into v_special from public.specials where id = p_special_id;
  if v_special.id is null then
    return jsonb_build_object('ok', false, 'error', 'Special not found');
  end if;
  if v_special.place_id is distinct from v_place.id then
    return jsonb_build_object('ok', false, 'error', 'You do not own this special');
  end if;

  if p_special_type is not null and p_special_type not in
     ('partnership','local_discount','seasonal','general','event','travel_special') then
    return jsonb_build_object('ok', false, 'error', 'Pick a valid special type');
  end if;
  if p_end_date is not null and p_start_date is not null and p_end_date < p_start_date then
    return jsonb_build_object('ok', false, 'error', 'End date must be on or after start date');
  end if;

  -- Image handling: explicit clear, OR new url (becomes first image), OR no change
  v_image_urls := v_special.image_urls;
  if p_clear_image then
    v_image_urls := array[]::text[];
  elsif p_image_url is not null and length(trim(p_image_url)) > 0 then
    v_image_urls := array[trim(p_image_url)] || coalesce(
      (select array_agg(x) from unnest(v_special.image_urls) x offset 1),
      array[]::text[]
    );
  end if;

  update public.specials set
    title               = coalesce(nullif(trim(p_title), ''), title),
    description         = case when p_description is not null then nullif(trim(p_description), '') else description end,
    special_type        = coalesce(p_special_type, special_type),
    start_date          = coalesce(p_start_date, start_date),
    end_date            = coalesce(p_end_date, end_date),
    start_time          = case when p_start_time is not null then p_start_time else start_time end,
    end_time            = case when p_end_time   is not null then p_end_time   else end_time end,
    image_urls          = v_image_urls,
    discount_percentage = case when p_discount_percentage is not null then p_discount_percentage else discount_percentage end,
    discount_amount     = case when p_discount_amount     is not null then p_discount_amount     else discount_amount end,
    price_amount        = case when p_price_amount        is not null then p_price_amount        else price_amount end,
    currency            = coalesce(nullif(trim(p_currency), ''), currency),
    event_category      = case when p_event_category is not null then nullif(trim(p_event_category), '') else event_category end,
    event_tags          = coalesce(p_tags, event_tags),
    capacity            = case when p_clear_capacity then null
                               when p_capacity is not null then p_capacity
                               else capacity end,
    recurring_days      = coalesce(p_recurring_days, recurring_days),
    age_restriction     = case when p_age_restriction is not null then nullif(trim(p_age_restriction), '') else age_restriction end,
    host_name           = case when p_host_name       is not null then nullif(trim(p_host_name), '')       else host_name end,
    event_slug          = case when p_event_slug      is not null then nullif(trim(p_event_slug), '')      else event_slug end,
    ticket_link         = case when p_ticket_link     is not null then nullif(trim(p_ticket_link), '')     else ticket_link end,
    rsvp_link           = case when p_rsvp_link       is not null then nullif(trim(p_rsvp_link), '')       else rsvp_link end
  where id = p_special_id;

  return jsonb_build_object('ok', true, 'id', p_special_id, 'message', 'Special updated.');
end;
$$;

grant execute on function public.update_partner_special(
  text, uuid, text, text, text, timestamptz, timestamptz, time, time, text,
  numeric, numeric, numeric, text, text, text[], integer, text[], text, text, text, text, text, boolean, boolean
) to anon;

-- ============================================================
-- 2. update_partner_place_contact
-- Only contact/links fields are editable by the partner.
-- Curated content (description, address, photos, curator_note,
-- cuisine, category, etc.) is NOT editable here : address changes
-- and similar revisions are submitted via the messages flow.
-- ============================================================
create or replace function public.update_partner_place_contact(
  p_token                  text,
  p_phone_number           text default null,
  p_website                text default null,
  p_instagram_url          text default null,
  p_menu_link              text default null,
  p_booking_link           text default null,
  p_booking_contact_email  text default null,
  p_bookings_email         text default null,
  p_day_pass_link          text default null,
  p_day_pass_notes         text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place places%rowtype;
begin
  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;

  update public.places set
    phone_number          = case when p_phone_number          is not null then nullif(trim(p_phone_number), '')          else phone_number end,
    website               = case when p_website               is not null then nullif(trim(p_website), '')               else website end,
    instagram_url         = case when p_instagram_url         is not null then nullif(trim(p_instagram_url), '')         else instagram_url end,
    menu_link             = case when p_menu_link             is not null then nullif(trim(p_menu_link), '')             else menu_link end,
    booking_link          = case when p_booking_link          is not null then nullif(trim(p_booking_link), '')          else booking_link end,
    booking_contact_email = case when p_booking_contact_email is not null then nullif(trim(p_booking_contact_email), '') else booking_contact_email end,
    bookings_email        = case when p_bookings_email        is not null then nullif(trim(p_bookings_email), '')        else bookings_email end,
    day_pass_link         = case when p_day_pass_link         is not null then nullif(trim(p_day_pass_link), '')         else day_pass_link end,
    day_pass_notes        = case when p_day_pass_notes        is not null then nullif(trim(p_day_pass_notes), '')        else day_pass_notes end
  where id = v_place.id;

  return jsonb_build_object('ok', true, 'message', 'Contact info updated.');
end;
$$;

grant execute on function public.update_partner_place_contact(
  text, text, text, text, text, text, text, text, text, text
) to anon;
