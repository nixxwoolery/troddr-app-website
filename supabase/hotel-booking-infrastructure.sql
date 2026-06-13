-- ================================================================
-- TRODDR — Hotel Booking Infrastructure
-- Phase 2: Professional boutique hotel booking operations platform
--
-- Adds inventory management, availability calendars, booking lifecycle
-- improvements, payment tracking (no card capture), and all RPCs
-- needed for partner dashboard + admin setup + guest availability.
--
-- Safe to run multiple times: IF NOT EXISTS / OR REPLACE throughout.
-- Run this migration BEFORE deploying updated booking HTML pages.
-- ================================================================


-- ────────────────────────────────────────────────────────────────
-- 1. HOTEL ROOM TYPES
-- Must be created before the bookings FK columns below.
-- ────────────────────────────────────────────────────────────────

create table if not exists public.hotel_room_types (
  id             uuid         primary key default gen_random_uuid(),
  place_id       uuid         not null references public.places(id) on delete cascade,
  name           text         not null,
  description    text,
  max_guests     integer      not null default 2,
  base_occupancy integer               default 1,
  room_count     integer      not null default 1,
  amenities      text[]       not null default '{}',
  images         text[]       not null default '{}',
  is_active      boolean      not null default true,
  display_order  integer               default 0,
  created_at     timestamptz  not null default now(),
  updated_at     timestamptz  not null default now()
);

create index if not exists idx_hotel_room_types_place
  on public.hotel_room_types(place_id);


-- ────────────────────────────────────────────────────────────────
-- 2. HOTEL RATE PLANS
-- ────────────────────────────────────────────────────────────────

create table if not exists public.hotel_rate_plans (
  id                   uuid        primary key default gen_random_uuid(),
  room_type_id         uuid        not null references public.hotel_room_types(id) on delete cascade,
  place_id             uuid        not null references public.places(id) on delete cascade,
  name                 text        not null,
  description          text,
  cancellation_policy  text,
  meal_plan            text,
  inclusions           text,
  is_refundable        boolean     not null default true,
  is_active            boolean     not null default true,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create index if not exists idx_hotel_rate_plans_room_type
  on public.hotel_rate_plans(room_type_id);


-- ────────────────────────────────────────────────────────────────
-- 3. EXTEND PLACES TABLE — booking configuration per property
-- ────────────────────────────────────────────────────────────────

alter table public.places
  add column if not exists accepts_stay_bookings     boolean      not null default false,
  add column if not exists booking_mode              text         not null default 'request_only',
  add column if not exists booking_contact_name      text,
  add column if not exists check_in_time             text,
  add column if not exists check_out_time            text,
  add column if not exists min_nights                integer      not null default 1,
  add column if not exists max_guests                integer,
  add column if not exists cancellation_policy_text  text,
  add column if not exists deposit_instructions      text,
  add column if not exists deposit_required          boolean      not null default false,
  add column if not exists deposit_default_amount    numeric(12,2),
  add column if not exists deposit_currency          text         not null default 'USD',
  add column if not exists commission_terms          text,
  add column if not exists taxes_fees_notes          text,
  add column if not exists hold_expiry_minutes       integer      not null default 10,
  add column if not exists internal_booking_notes    text;

comment on column public.places.booking_mode is
  'request_only | manual_availability | instant_manual_inventory';


-- ────────────────────────────────────────────────────────────────
-- 4. EXTEND BOOKINGS TABLE — full lifecycle + payment tracking
-- ────────────────────────────────────────────────────────────────

alter table public.bookings
  drop constraint if exists bookings_status_check;

alter table public.bookings
  add constraint bookings_status_check check (status in (
    'pending',
    'held',
    'confirmed',
    'declined',
    'counter_proposed',
    'counter_accepted',
    'counter_rejected',
    'cancelled',
    'cancelled_by_guest',
    'cancelled_by_partner',
    'expired',
    'no_show',
    'checked_in',
    'checked_out',
    'completed'
  ));

alter table public.bookings
  add column if not exists room_type_id           uuid,
  add column if not exists rate_plan_id           uuid,
  add column if not exists rooms_requested        integer      not null default 1,
  add column if not exists adults                 integer,
  add column if not exists children               integer      not null default 0,
  add column if not exists hold_id                uuid,
  add column if not exists nightly_rate           numeric(12,2),
  add column if not exists total_nights           integer,
  add column if not exists quoted_currency        text         not null default 'USD',
  add column if not exists taxes_amount           numeric(12,2),
  add column if not exists fees_amount            numeric(12,2),
  add column if not exists discount_amount        numeric(12,2),
  add column if not exists final_total            numeric(12,2),
  add column if not exists deposit_required       boolean      not null default false,
  add column if not exists deposit_amount         numeric(12,2),
  add column if not exists deposit_currency       text         not null default 'USD',
  add column if not exists deposit_due_at         timestamptz,
  add column if not exists payment_instructions   text,
  add column if not exists manual_payment_status  text         not null default 'not_required',
  add column if not exists payment_reference      text,
  add column if not exists partner_internal_notes text,
  add column if not exists internal_notes         text,
  add column if not exists cancelled_by           text,
  add column if not exists cancellation_reason    text,
  add column if not exists expires_at             timestamptz,
  add column if not exists needs_troddr_attention boolean      not null default false,
  add column if not exists attention_reason       text,
  add column if not exists counter_date           date,
  add column if not exists counter_time           text,
  add column if not exists supplier_confirmation_number text;

alter table public.bookings
  drop constraint if exists bookings_manual_payment_status_check;
alter table public.bookings
  add constraint bookings_manual_payment_status_check check (
    manual_payment_status in ('not_required','requested','received','refunded','disputed')
  );

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'bookings_room_type_id_fkey'
  ) then
    alter table public.bookings
      add constraint bookings_room_type_id_fkey
      foreign key (room_type_id) references public.hotel_room_types(id);
  end if;
end;
$$;

do $$
begin
  if not exists (
    select 1 from pg_constraint where conname = 'bookings_rate_plan_id_fkey'
  ) then
    alter table public.bookings
      add constraint bookings_rate_plan_id_fkey
      foreign key (rate_plan_id) references public.hotel_rate_plans(id);
  end if;
end;
$$;


-- ────────────────────────────────────────────────────────────────
-- 5. HOTEL AVAILABILITY CALENDAR
-- ────────────────────────────────────────────────────────────────

create table if not exists public.hotel_availability (
  id                    uuid        primary key default gen_random_uuid(),
  place_id              uuid        not null references public.places(id) on delete cascade,
  room_type_id          uuid        not null references public.hotel_room_types(id) on delete cascade,
  stay_date             date        not null,
  available_rooms       integer     not null default 0,
  is_closed             boolean     not null default false,
  is_blackout           boolean     not null default false,
  closed_to_arrival     boolean     not null default false,
  closed_to_departure   boolean     not null default false,
  min_nights            integer              default 1,
  max_nights            integer,
  base_nightly_rate     numeric(12,2),
  currency              text        not null default 'USD',
  notes                 text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  unique(room_type_id, stay_date)
);

create index if not exists idx_hotel_availability_date_range
  on public.hotel_availability(room_type_id, stay_date);


-- ────────────────────────────────────────────────────────────────
-- 6. BOOKING ROOM ALLOCATIONS
-- ────────────────────────────────────────────────────────────────

create table if not exists public.booking_room_allocations (
  id               uuid        primary key default gen_random_uuid(),
  booking_id       uuid        not null references public.bookings(id) on delete cascade,
  room_type_id     uuid        not null references public.hotel_room_types(id),
  rate_plan_id     uuid                 references public.hotel_rate_plans(id),
  rooms_allocated  integer     not null default 1,
  check_in_date    date        not null,
  check_out_date   date        not null,
  nightly_rate     numeric(12,2),
  currency         text        not null default 'USD',
  created_at       timestamptz not null default now()
);

create index if not exists idx_room_allocations_booking
  on public.booking_room_allocations(booking_id);
create index if not exists idx_room_allocations_room_dates
  on public.booking_room_allocations(room_type_id, check_in_date, check_out_date);


-- ────────────────────────────────────────────────────────────────
-- 7. BOOKING TIMELINE EVENTS — full audit log
-- ────────────────────────────────────────────────────────────────

create table if not exists public.booking_timeline_events (
  id          uuid        primary key default gen_random_uuid(),
  booking_id  uuid        not null references public.bookings(id) on delete cascade,
  old_status  text,
  new_status  text,
  actor_type  text        not null default 'system',
  actor_id    uuid,
  actor_email text,
  message     text,
  metadata    jsonb,
  created_at  timestamptz not null default now()
);

create index if not exists idx_timeline_events_booking
  on public.booking_timeline_events(booking_id, created_at desc);


-- ────────────────────────────────────────────────────────────────
-- 8. INVENTORY HOLDS
-- ────────────────────────────────────────────────────────────────

create table if not exists public.hotel_inventory_holds (
  id              uuid        primary key default gen_random_uuid(),
  place_id        uuid        not null references public.places(id) on delete cascade,
  room_type_id    uuid        not null references public.hotel_room_types(id) on delete cascade,
  booking_id      uuid                 references public.bookings(id) on delete set null,
  rooms_held      integer     not null default 1,
  check_in_date   date        not null,
  check_out_date  date        not null,
  session_id      text,
  expires_at      timestamptz not null,
  released_at     timestamptz,
  is_converted    boolean     not null default false,
  created_at      timestamptz not null default now()
);

create index if not exists idx_inventory_holds_active
  on public.hotel_inventory_holds(room_type_id, check_in_date, check_out_date)
  where released_at is null and is_converted = false;


-- ────────────────────────────────────────────────────────────────
-- 9. CANCELLATION POLICIES
-- ────────────────────────────────────────────────────────────────

create table if not exists public.booking_cancellation_policies (
  id                        uuid        primary key default gen_random_uuid(),
  place_id                  uuid                 references public.places(id) on delete cascade,
  rate_plan_id              uuid                 references public.hotel_rate_plans(id) on delete cascade,
  policy_name               text        not null,
  policy_text               text        not null,
  free_cancel_hours         integer,
  is_non_refundable         boolean     not null default false,
  deposit_forfeiture_notes  text,
  partner_override_notes    text,
  is_default                boolean     not null default false,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now()
);


-- ────────────────────────────────────────────────────────────────
-- 10. NOTIFICATION LOGS
-- ────────────────────────────────────────────────────────────────

create table if not exists public.booking_notification_logs (
  id               uuid        primary key default gen_random_uuid(),
  booking_id       uuid                 references public.bookings(id) on delete cascade,
  template         text        not null,
  recipient_email  text        not null,
  status           text        not null default 'sent',
  error_message    text,
  retry_count      integer     not null default 0,
  created_at       timestamptz not null default now()
);


-- ────────────────────────────────────────────────────────────────
-- 11. RLS — all new tables locked to security-definer RPCs only
-- ────────────────────────────────────────────────────────────────

alter table public.hotel_room_types              enable row level security;
alter table public.hotel_rate_plans              enable row level security;
alter table public.hotel_availability            enable row level security;
alter table public.booking_room_allocations      enable row level security;
alter table public.booking_timeline_events       enable row level security;
alter table public.hotel_inventory_holds         enable row level security;
alter table public.booking_cancellation_policies enable row level security;
alter table public.booking_notification_logs     enable row level security;


-- ────────────────────────────────────────────────────────────────
-- 12. TIMELINE AUTO-LOGGER TRIGGER
-- ────────────────────────────────────────────────────────────────

create or replace function public.tg_booking_timeline()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'INSERT' then
    insert into public.booking_timeline_events (
      booking_id, old_status, new_status, actor_type, message
    ) values (
      NEW.id, null, NEW.status, 'system', 'Booking created'
    );
  elsif tg_op = 'UPDATE' and NEW.status is distinct from OLD.status then
    insert into public.booking_timeline_events (
      booking_id, old_status, new_status, actor_type, message
    ) values (
      NEW.id, OLD.status, NEW.status, 'system', null
    );
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_booking_timeline on public.bookings;
create trigger trg_booking_timeline
  after insert or update of status on public.bookings
  for each row
  execute function public.tg_booking_timeline();


-- ────────────────────────────────────────────────────────────────
-- 13. CLEANUP EXPIRED HOLDS & HELD BOOKINGS
-- ────────────────────────────────────────────────────────────────

create or replace function public.cleanup_expired_holds()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_count integer;
begin
  update public.hotel_inventory_holds
     set released_at = now()
   where released_at is null
     and is_converted = false
     and expires_at < now();
  get diagnostics v_count = row_count;

  update public.bookings
     set status = 'expired'
   where status = 'held'
     and expires_at is not null
     and expires_at < now();

  return v_count;
end;
$$;


-- ────────────────────────────────────────────────────────────────
-- 14. GET PARTNER BOOKINGS V2
-- ────────────────────────────────────────────────────────────────

create or replace function public.get_partner_bookings_v2(
  p_token       text,
  p_status      text    default null,
  p_type        text    default null,
  p_from_date   date    default null,
  p_to_date     date    default null,
  p_guest_name  text    default null,
  p_limit       integer default 200,
  p_offset      integer default 0
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
    return jsonb_build_object('error', 'invalid_token');
  end if;

  return jsonb_build_object(
    'place_id',     v_place.id,
    'place_name',   v_place.name,
    'booking_mode', coalesce(v_place.booking_mode, 'request_only'),
    'stats', jsonb_build_object(
      'total',           (select count(*) from public.bookings where place_id = v_place.id),
      'pending',         (select count(*) from public.bookings where place_id = v_place.id and status = 'pending'),
      'held',            (select count(*) from public.bookings where place_id = v_place.id and status = 'held'),
      'confirmed',       (select count(*) from public.bookings where place_id = v_place.id
                          and status in ('confirmed','counter_accepted','checked_in','checked_out')),
      'needs_attention', (select count(*) from public.bookings where place_id = v_place.id
                          and needs_troddr_attention = true),
      'this_month',      (select count(*) from public.bookings where place_id = v_place.id
                          and created_at >= date_trunc('month', now()))
    ),
    'bookings', (
      select coalesce(jsonb_agg(row_to_json(bv.*)), '[]'::jsonb)
      from (
        select
          b.id, b.token, b.status, b.booking_type,
          b.visit_date, b.checkout_date, b.visit_time,
          b.party_size, b.adults, b.children, b.rooms_requested,
          b.guest_name, b.guest_email, b.guest_phone,
          b.notes, b.room_preference,
          b.total_quoted, b.final_total, b.quoted_currency,
          b.nightly_rate, b.total_nights,
          b.taxes_amount, b.fees_amount,
          b.deposit_required, b.deposit_amount, b.deposit_currency,
          b.deposit_due_at, b.manual_payment_status, b.payment_reference,
          b.payment_instructions,
          b.supplier_confirmation_number,
          b.partner_message, b.partner_internal_notes,
          b.counter_date, b.counter_time,
          b.cancelled_by, b.cancellation_reason,
          b.needs_troddr_attention, b.attention_reason,
          b.expires_at, b.created_at, b.updated_at,
          rt.name  as room_type_name,
          rp.name  as rate_plan_name,
          (select count(*)::int from public.booking_timeline_events te
            where te.booking_id = b.id) as timeline_count
        from public.bookings b
        left join public.hotel_room_types rt on rt.id = b.room_type_id
        left join public.hotel_rate_plans  rp on rp.id = b.rate_plan_id
        where b.place_id = v_place.id
          and (p_status    is null or b.status       = p_status)
          and (p_type      is null or b.booking_type = p_type)
          and (p_from_date is null or b.visit_date  >= p_from_date)
          and (p_to_date   is null or b.visit_date  <= p_to_date)
          and (p_guest_name is null
               or lower(b.guest_name) like lower('%' || p_guest_name || '%'))
        order by
          case when b.status = 'pending' then 0
               when b.status = 'held'    then 1
               else 2 end,
          b.created_at desc
        limit p_limit offset p_offset
      ) bv
    )
  );
end;
$$;

grant execute on function public.get_partner_bookings_v2(text,text,text,date,date,text,integer,integer) to anon;


-- ────────────────────────────────────────────────────────────────
-- 15. GET BOOKING DETAIL BY TOKEN
-- ────────────────────────────────────────────────────────────────

create or replace function public.get_booking_detail_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_booking bookings%rowtype;
  v_place   places%rowtype;
begin
  select * into v_booking from public.bookings where token = p_token;
  if v_booking.id is null then
    return jsonb_build_object('error', 'not_found');
  end if;
  select * into v_place from public.places where id = v_booking.place_id;

  return jsonb_build_object(
    'booking', row_to_json(v_booking.*),
    'place', jsonb_build_object(
      'id',                      v_place.id,
      'name',                    v_place.name,
      'address',                 v_place.address,
      'town',                    v_place.town,
      'parish',                  v_place.parish,
      'image',                   v_place.image,
      'check_in_time',           v_place.check_in_time,
      'check_out_time',          v_place.check_out_time,
      'cancellation_policy_text',v_place.cancellation_policy_text,
      'deposit_instructions',    v_place.deposit_instructions,
      'taxes_fees_notes',        v_place.taxes_fees_notes,
      'partner_access_token',    v_place.partner_access_token
    ),
    'room_type', (
      select row_to_json(rt.*)
      from public.hotel_room_types rt where rt.id = v_booking.room_type_id
    ),
    'rate_plan', (
      select row_to_json(rp.*)
      from public.hotel_rate_plans rp where rp.id = v_booking.rate_plan_id
    ),
    'timeline', (
      select coalesce(
        jsonb_agg(row_to_json(te.*) order by te.created_at asc),
        '[]'::jsonb
      )
      from public.booking_timeline_events te where te.booking_id = v_booking.id
    ),
    'cancellation_policy', (
      select row_to_json(cp.*)
      from public.booking_cancellation_policies cp
      where cp.place_id = v_place.id
        and (cp.rate_plan_id = v_booking.rate_plan_id or cp.rate_plan_id is null)
      order by cp.rate_plan_id desc nulls last, cp.is_default desc
      limit 1
    )
  );
end;
$$;

grant execute on function public.get_booking_detail_by_token(text) to anon;


-- ────────────────────────────────────────────────────────────────
-- 16. PARTNER UPDATE BOOKING
-- p_action: confirm | decline | counter | cancel |
--           mark_no_show | mark_completed | mark_checked_in | mark_checked_out
-- p_data:   jsonb with any optional field updates
-- ────────────────────────────────────────────────────────────────

create or replace function public.partner_update_booking(
  p_partner_token text,
  p_booking_id    uuid,
  p_action        text   default null,
  p_data          jsonb  default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place      places%rowtype;
  v_booking    bookings%rowtype;
  v_new_status text;
begin
  select * into v_place from public.places where partner_access_token = p_partner_token;
  if v_place.id is null then
    return jsonb_build_object('error', 'invalid_token');
  end if;

  select * into v_booking from public.bookings
   where id = p_booking_id and place_id = v_place.id;
  if v_booking.id is null then
    return jsonb_build_object('error', 'booking_not_found');
  end if;

  v_new_status := case p_action
    when 'confirm'          then 'confirmed'
    when 'decline'          then 'declined'
    when 'counter'          then 'counter_proposed'
    when 'cancel'           then 'cancelled_by_partner'
    when 'mark_no_show'     then 'no_show'
    when 'mark_completed'   then 'completed'
    when 'mark_checked_in'  then 'checked_in'
    when 'mark_checked_out' then 'checked_out'
    else null
  end;

  update public.bookings set
    status                       = coalesce(v_new_status,                              status),
    partner_message              = coalesce(p_data->>'message',                        partner_message),
    counter_date                 = coalesce((p_data->>'counter_date')::date,           counter_date),
    counter_time                 = coalesce(p_data->>'counter_time',                   counter_time),
    supplier_confirmation_number = coalesce(p_data->>'supplier_confirmation_number',   supplier_confirmation_number),
    partner_internal_notes       = coalesce(p_data->>'partner_internal_notes',         partner_internal_notes),
    total_quoted                 = coalesce((p_data->>'total_quoted')::numeric,        total_quoted),
    final_total                  = coalesce((p_data->>'final_total')::numeric,         final_total),
    nightly_rate                 = coalesce((p_data->>'nightly_rate')::numeric,        nightly_rate),
    total_nights                 = coalesce((p_data->>'total_nights')::integer,        total_nights),
    taxes_amount                 = coalesce((p_data->>'taxes_amount')::numeric,        taxes_amount),
    fees_amount                  = coalesce((p_data->>'fees_amount')::numeric,         fees_amount),
    quoted_currency              = coalesce(p_data->>'quoted_currency',                quoted_currency),
    deposit_required             = coalesce((p_data->>'deposit_required')::boolean,    deposit_required),
    deposit_amount               = coalesce((p_data->>'deposit_amount')::numeric,      deposit_amount),
    deposit_currency             = coalesce(p_data->>'deposit_currency',               deposit_currency),
    deposit_due_at               = coalesce((p_data->>'deposit_due_at')::timestamptz,  deposit_due_at),
    payment_instructions         = coalesce(p_data->>'payment_instructions',           payment_instructions),
    manual_payment_status        = coalesce(p_data->>'manual_payment_status',          manual_payment_status),
    payment_reference            = coalesce(p_data->>'payment_reference',              payment_reference),
    room_type_id                 = coalesce((p_data->>'room_type_id')::uuid,           room_type_id),
    rate_plan_id                 = coalesce((p_data->>'rate_plan_id')::uuid,           rate_plan_id),
    rooms_requested              = coalesce((p_data->>'rooms_requested')::integer,     rooms_requested),
    cancelled_by                 = case when p_action = 'cancel' then 'partner' else cancelled_by end,
    cancellation_reason          = coalesce(p_data->>'cancellation_reason',            cancellation_reason),
    needs_troddr_attention       = coalesce((p_data->>'needs_troddr_attention')::boolean, needs_troddr_attention),
    updated_at                   = now()
  where id = p_booking_id;

  -- Stamp actor info on the timeline row the trigger already inserted
  if v_new_status is not null then
    update public.booking_timeline_events
       set actor_type  = 'partner',
           actor_email = p_data->>'responder_email',
           message     = p_data->>'message'
     where booking_id = p_booking_id
       and new_status  = v_new_status
       and actor_type  = 'system'
       and created_at  = (
         select max(created_at) from public.booking_timeline_events
          where booking_id = p_booking_id and new_status = v_new_status
       );
  else
    -- Non-status update — log as a partner note
    insert into public.booking_timeline_events (
      booking_id, old_status, new_status, actor_type, actor_email, message
    ) values (
      p_booking_id,
      v_booking.status, v_booking.status,
      'partner',
      p_data->>'responder_email',
      coalesce(p_data->>'message', 'Booking details updated')
    );
  end if;

  return jsonb_build_object(
    'ok',         true,
    'booking_id', p_booking_id,
    'new_status', coalesce(v_new_status, v_booking.status)
  );
end;
$$;

grant execute on function public.partner_update_booking(text, uuid, text, jsonb) to anon;


-- ────────────────────────────────────────────────────────────────
-- 17. EXPORT PARTNER BOOKINGS (flat JSON → client-side CSV)
-- ────────────────────────────────────────────────────────────────

create or replace function public.export_partner_bookings(
  p_token     text,
  p_from_date date default null,
  p_to_date   date default null
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
    return jsonb_build_object('error', 'invalid_token');
  end if;

  return jsonb_build_object(
    'place_name',  v_place.name,
    'exported_at', now(),
    'rows', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'booking_id',           b.id,
          'status',               b.status,
          'type',                 b.booking_type,
          'guest_name',           b.guest_name,
          'guest_email',          b.guest_email,
          'guest_phone',          b.guest_phone,
          'check_in',             b.visit_date,
          'check_out',            b.checkout_date,
          'nights',               b.total_nights,
          'adults',               b.adults,
          'children',             b.children,
          'rooms',                b.rooms_requested,
          'room_type',            rt.name,
          'rate_plan',            rp.name,
          'nightly_rate',         b.nightly_rate,
          'quoted_total',         b.total_quoted,
          'final_total',          b.final_total,
          'currency',             b.quoted_currency,
          'taxes',                b.taxes_amount,
          'fees',                 b.fees_amount,
          'deposit_required',     b.deposit_required,
          'deposit_amount',       b.deposit_amount,
          'payment_status',       b.manual_payment_status,
          'payment_reference',    b.payment_reference,
          'supplier_conf_number', b.supplier_confirmation_number,
          'partner_notes',        b.partner_message,
          'cancellation_reason',  b.cancellation_reason,
          'submitted_at',         b.created_at
        ) order by b.created_at desc
      ), '[]'::jsonb)
      from public.bookings b
      left join public.hotel_room_types rt on rt.id = b.room_type_id
      left join public.hotel_rate_plans  rp on rp.id = b.rate_plan_id
      where b.place_id = v_place.id
        and (p_from_date is null or b.visit_date >= p_from_date)
        and (p_to_date   is null or b.visit_date <= p_to_date)
    )
  );
end;
$$;

grant execute on function public.export_partner_bookings(text, date, date) to anon;


-- ────────────────────────────────────────────────────────────────
-- 18. GUEST STAY AVAILABILITY SEARCH
-- ────────────────────────────────────────────────────────────────

create or replace function public.search_stay_availability(
  p_place_id uuid,
  p_check_in  date,
  p_check_out date,
  p_adults    integer default 2,
  p_children  integer default 0,
  p_rooms     integer default 1
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place   places%rowtype;
  v_nights  integer;
begin
  select * into v_place from public.places where id = p_place_id;
  if v_place.id is null then
    return jsonb_build_object('error', 'place_not_found');
  end if;

  v_nights := p_check_out - p_check_in;
  if v_nights <= 0 then
    return jsonb_build_object('error', 'invalid_dates');
  end if;
  if v_nights < coalesce(v_place.min_nights, 1) then
    return jsonb_build_object(
      'error',            'min_nights_not_met',
      'min_nights',       v_place.min_nights,
      'nights_requested', v_nights
    );
  end if;

  return jsonb_build_object(
    'place', jsonb_build_object(
      'id',                      v_place.id,
      'name',                    v_place.name,
      'booking_mode',            coalesce(v_place.booking_mode, 'request_only'),
      'min_nights',              coalesce(v_place.min_nights, 1),
      'check_in_time',           v_place.check_in_time,
      'check_out_time',          v_place.check_out_time,
      'cancellation_policy_text',v_place.cancellation_policy_text,
      'deposit_instructions',    v_place.deposit_instructions,
      'taxes_fees_notes',        v_place.taxes_fees_notes
    ),
    'search', jsonb_build_object(
      'check_in', p_check_in, 'check_out', p_check_out,
      'nights', v_nights, 'adults', p_adults,
      'children', p_children, 'rooms', p_rooms
    ),
    'room_types', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'room_type',               row_to_json(rt.*),
          'fits_guests',             rt.max_guests >= (p_adults + p_children),
          'available_all_nights',   (
            select count(*) from public.hotel_availability av
             where av.room_type_id = rt.id
               and av.stay_date >= p_check_in and av.stay_date < p_check_out
               and av.is_closed = false and av.is_blackout = false
               and av.available_rooms >= p_rooms
               and (av.min_nights is null or v_nights >= av.min_nights)
          ) = v_nights,
          'nights_with_availability',(
            select count(*)::int from public.hotel_availability av
             where av.room_type_id = rt.id
               and av.stay_date >= p_check_in and av.stay_date < p_check_out
               and av.is_closed = false and av.is_blackout = false
               and av.available_rooms >= p_rooms
          ),
          'avg_nightly_rate', (
            select round(avg(av.base_nightly_rate)::numeric, 2)
              from public.hotel_availability av
             where av.room_type_id = rt.id
               and av.stay_date >= p_check_in and av.stay_date < p_check_out
               and av.base_nightly_rate is not null
          ),
          'estimated_total', (
            select round(sum(av.base_nightly_rate)::numeric, 2)
              from public.hotel_availability av
             where av.room_type_id = rt.id
               and av.stay_date >= p_check_in and av.stay_date < p_check_out
               and av.base_nightly_rate is not null
          ),
          'rate_plans', (
            select coalesce(jsonb_agg(row_to_json(rp.*) order by rp.created_at), '[]'::jsonb)
            from public.hotel_rate_plans rp
            where rp.room_type_id = rt.id and rp.is_active = true
          )
        ) order by rt.display_order, rt.name
      ), '[]'::jsonb)
      from public.hotel_room_types rt
      where rt.place_id = p_place_id and rt.is_active = true
        and rt.max_guests >= p_adults
    )
  );
end;
$$;

grant execute on function public.search_stay_availability(uuid, date, date, integer, integer, integer) to anon;


-- ────────────────────────────────────────────────────────────────
-- 19. INVENTORY HOLD / RELEASE
-- ────────────────────────────────────────────────────────────────

create or replace function public.create_inventory_hold(
  p_place_id     uuid,
  p_room_type_id uuid,
  p_check_in     date,
  p_check_out    date,
  p_rooms        integer default 1,
  p_session_id   text    default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place       places%rowtype;
  v_room_type   hotel_room_types%rowtype;
  v_expiry_mins integer;
  v_hold_id     uuid;
begin
  select * into v_place from public.places where id = p_place_id;
  select * into v_room_type from public.hotel_room_types
   where id = p_room_type_id and place_id = p_place_id;
  if v_room_type.id is null then
    return jsonb_build_object('error', 'room_type_not_found');
  end if;
  v_expiry_mins := coalesce(v_place.hold_expiry_minutes, 10);
  insert into public.hotel_inventory_holds (
    place_id, room_type_id, rooms_held,
    check_in_date, check_out_date, session_id, expires_at
  ) values (
    p_place_id, p_room_type_id, p_rooms,
    p_check_in, p_check_out, p_session_id,
    now() + (v_expiry_mins || ' minutes')::interval
  ) returning id into v_hold_id;
  return jsonb_build_object(
    'ok', true, 'hold_id', v_hold_id,
    'expires_at', now() + (v_expiry_mins || ' minutes')::interval,
    'expiry_minutes', v_expiry_mins
  );
end;
$$;

grant execute on function public.create_inventory_hold(uuid, uuid, date, date, integer, text) to anon;

create or replace function public.release_inventory_hold(p_hold_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  update public.hotel_inventory_holds
     set released_at = now()
   where id = p_hold_id and released_at is null;
  return jsonb_build_object('ok', found);
end;
$$;

grant execute on function public.release_inventory_hold(uuid) to anon;


-- ────────────────────────────────────────────────────────────────
-- 20. ADMIN RPCs
-- ────────────────────────────────────────────────────────────────

create or replace function public.admin_configure_place_booking(
  p_admin_token             text,
  p_place_id                uuid,
  p_accepts_stay_bookings   boolean  default null,
  p_booking_mode            text     default null,
  p_bookings_email          text     default null,
  p_booking_contact_name    text     default null,
  p_check_in_time           text     default null,
  p_check_out_time          text     default null,
  p_min_nights              integer  default null,
  p_max_guests              integer  default null,
  p_cancellation_policy     text     default null,
  p_deposit_instructions    text     default null,
  p_deposit_required        boolean  default null,
  p_deposit_default_amount  numeric  default null,
  p_deposit_currency        text     default null,
  p_commission_terms        text     default null,
  p_taxes_fees_notes        text     default null,
  p_hold_expiry_minutes     integer  default null,
  p_internal_booking_notes  text     default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  update public.places set
    accepts_stay_bookings   = coalesce(p_accepts_stay_bookings,  accepts_stay_bookings),
    booking_mode            = coalesce(p_booking_mode,           booking_mode),
    bookings_email          = coalesce(p_bookings_email,         bookings_email),
    booking_contact_name    = coalesce(p_booking_contact_name,   booking_contact_name),
    check_in_time           = coalesce(p_check_in_time,          check_in_time),
    check_out_time          = coalesce(p_check_out_time,         check_out_time),
    min_nights              = coalesce(p_min_nights,             min_nights),
    max_guests              = coalesce(p_max_guests,             max_guests),
    cancellation_policy_text= coalesce(p_cancellation_policy,   cancellation_policy_text),
    deposit_instructions    = coalesce(p_deposit_instructions,   deposit_instructions),
    deposit_required        = coalesce(p_deposit_required,       deposit_required),
    deposit_default_amount  = coalesce(p_deposit_default_amount, deposit_default_amount),
    deposit_currency        = coalesce(p_deposit_currency,       deposit_currency),
    commission_terms        = coalesce(p_commission_terms,       commission_terms),
    taxes_fees_notes        = coalesce(p_taxes_fees_notes,       taxes_fees_notes),
    hold_expiry_minutes     = coalesce(p_hold_expiry_minutes,    hold_expiry_minutes),
    internal_booking_notes  = coalesce(p_internal_booking_notes, internal_booking_notes)
  where id = p_place_id;
  if not found then return jsonb_build_object('error', 'place_not_found'); end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.admin_upsert_room_type(
  p_admin_token    text,
  p_id             uuid    default null,
  p_place_id       uuid    default null,
  p_name           text    default null,
  p_description    text    default null,
  p_max_guests     integer default null,
  p_base_occupancy integer default null,
  p_room_count     integer default null,
  p_amenities      text[]  default null,
  p_images         text[]  default null,
  p_is_active      boolean default null,
  p_display_order  integer default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  if p_id is not null then
    update public.hotel_room_types set
      name           = coalesce(p_name,           name),
      description    = coalesce(p_description,    description),
      max_guests     = coalesce(p_max_guests,      max_guests),
      base_occupancy = coalesce(p_base_occupancy,  base_occupancy),
      room_count     = coalesce(p_room_count,      room_count),
      amenities      = coalesce(p_amenities,       amenities),
      images         = coalesce(p_images,          images),
      is_active      = coalesce(p_is_active,       is_active),
      display_order  = coalesce(p_display_order,   display_order),
      updated_at     = now()
    where id = p_id;
    v_id := p_id;
  else
    if p_place_id is null or p_name is null then
      return jsonb_build_object('error', 'place_id and name required');
    end if;
    insert into public.hotel_room_types (
      place_id, name, description, max_guests, base_occupancy,
      room_count, amenities, images, is_active, display_order
    ) values (
      p_place_id, p_name, p_description,
      coalesce(p_max_guests, 2), coalesce(p_base_occupancy, 1),
      coalesce(p_room_count, 1), coalesce(p_amenities, '{}'),
      coalesce(p_images, '{}'), coalesce(p_is_active, true),
      coalesce(p_display_order, 0)
    ) returning id into v_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function public.admin_upsert_rate_plan(
  p_admin_token         text,
  p_id                  uuid    default null,
  p_room_type_id        uuid    default null,
  p_place_id            uuid    default null,
  p_name                text    default null,
  p_description         text    default null,
  p_cancellation_policy text    default null,
  p_meal_plan           text    default null,
  p_inclusions          text    default null,
  p_is_refundable       boolean default null,
  p_is_active           boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  if p_id is not null then
    update public.hotel_rate_plans set
      name                = coalesce(p_name,                name),
      description         = coalesce(p_description,         description),
      cancellation_policy = coalesce(p_cancellation_policy, cancellation_policy),
      meal_plan           = coalesce(p_meal_plan,           meal_plan),
      inclusions          = coalesce(p_inclusions,          inclusions),
      is_refundable       = coalesce(p_is_refundable,       is_refundable),
      is_active           = coalesce(p_is_active,           is_active),
      updated_at          = now()
    where id = p_id;
    v_id := p_id;
  else
    if p_room_type_id is null or p_place_id is null or p_name is null then
      return jsonb_build_object('error', 'room_type_id, place_id, and name required');
    end if;
    insert into public.hotel_rate_plans (
      room_type_id, place_id, name, description,
      cancellation_policy, meal_plan, inclusions, is_refundable, is_active
    ) values (
      p_room_type_id, p_place_id, p_name, p_description,
      p_cancellation_policy, p_meal_plan, p_inclusions,
      coalesce(p_is_refundable, true), coalesce(p_is_active, true)
    ) returning id into v_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function public.admin_set_availability(
  p_admin_token        text,
  p_room_type_id       uuid,
  p_place_id           uuid,
  p_dates              date[],
  p_available_rooms    integer  default null,
  p_is_closed          boolean  default null,
  p_is_blackout        boolean  default null,
  p_min_nights         integer  default null,
  p_base_nightly_rate  numeric  default null,
  p_currency           text     default 'USD',
  p_notes              text     default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_date  date;
  v_count integer := 0;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  foreach v_date in array p_dates loop
    insert into public.hotel_availability (
      place_id, room_type_id, stay_date,
      available_rooms, is_closed, is_blackout,
      min_nights, base_nightly_rate, currency, notes
    ) values (
      p_place_id, p_room_type_id, v_date,
      coalesce(p_available_rooms, 0),
      coalesce(p_is_closed, false),
      coalesce(p_is_blackout, false),
      coalesce(p_min_nights, 1),
      p_base_nightly_rate,
      coalesce(p_currency, 'USD'),
      p_notes
    )
    on conflict (room_type_id, stay_date) do update set
      available_rooms   = case when p_available_rooms   is not null then p_available_rooms   else hotel_availability.available_rooms end,
      is_closed         = case when p_is_closed         is not null then p_is_closed         else hotel_availability.is_closed end,
      is_blackout       = case when p_is_blackout       is not null then p_is_blackout       else hotel_availability.is_blackout end,
      min_nights        = case when p_min_nights        is not null then p_min_nights        else hotel_availability.min_nights end,
      base_nightly_rate = case when p_base_nightly_rate is not null then p_base_nightly_rate else hotel_availability.base_nightly_rate end,
      currency          = case when p_currency          is not null then p_currency          else hotel_availability.currency end,
      notes             = case when p_notes             is not null then p_notes             else hotel_availability.notes end,
      updated_at        = now();
    v_count := v_count + 1;
  end loop;
  return jsonb_build_object('ok', true, 'dates_updated', v_count);
end;
$$;

create or replace function public.admin_get_place_booking_config(
  p_admin_token text,
  p_place_id    uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place places%rowtype;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  select * into v_place from public.places where id = p_place_id;
  if v_place.id is null then return jsonb_build_object('error', 'place_not_found'); end if;

  return jsonb_build_object(
    'place', jsonb_build_object(
      'id',                      v_place.id,
      'name',                    v_place.name,
      'slug',                    v_place.slug,
      'bookings_email',          v_place.bookings_email,
      'accepts_stay_bookings',   v_place.accepts_stay_bookings,
      'booking_mode',            v_place.booking_mode,
      'booking_contact_name',    v_place.booking_contact_name,
      'check_in_time',           v_place.check_in_time,
      'check_out_time',          v_place.check_out_time,
      'min_nights',              v_place.min_nights,
      'max_guests',              v_place.max_guests,
      'cancellation_policy_text',v_place.cancellation_policy_text,
      'deposit_instructions',    v_place.deposit_instructions,
      'deposit_required',        v_place.deposit_required,
      'deposit_default_amount',  v_place.deposit_default_amount,
      'deposit_currency',        v_place.deposit_currency,
      'commission_terms',        v_place.commission_terms,
      'taxes_fees_notes',        v_place.taxes_fees_notes,
      'hold_expiry_minutes',     v_place.hold_expiry_minutes,
      'internal_booking_notes',  v_place.internal_booking_notes,
      'partner_access_token',    v_place.partner_access_token
    ),
    'room_types', (
      select coalesce(jsonb_agg(row_to_json(rt.*) order by rt.display_order, rt.created_at), '[]'::jsonb)
      from public.hotel_room_types rt where rt.place_id = p_place_id
    ),
    'rate_plans', (
      select coalesce(jsonb_agg(row_to_json(rp.*) order by rp.created_at), '[]'::jsonb)
      from public.hotel_rate_plans rp where rp.place_id = p_place_id
    ),
    'cancellation_policies', (
      select coalesce(jsonb_agg(row_to_json(cp.*) order by cp.is_default desc, cp.created_at), '[]'::jsonb)
      from public.booking_cancellation_policies cp where cp.place_id = p_place_id
    ),
    'availability_60d', (
      select coalesce(jsonb_agg(row_to_json(av.*) order by av.room_type_id, av.stay_date), '[]'::jsonb)
      from public.hotel_availability av
      where av.place_id = p_place_id
        and av.stay_date between current_date and current_date + interval '60 days'
    ),
    'recent_bookings', (
      select coalesce(jsonb_agg(
        jsonb_build_object('id', b.id, 'status', b.status, 'guest_name', b.guest_name,
                           'visit_date', b.visit_date, 'created_at', b.created_at)
        order by b.created_at desc
      ), '[]'::jsonb)
      from public.bookings b
      where b.place_id = p_place_id and b.created_at >= now() - interval '30 days'
      limit 20
    )
  );
end;
$$;

create or replace function public.admin_search_places_for_booking(
  p_admin_token text,
  p_query       text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  return jsonb_build_object(
    'places', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'id', p.id, 'name', p.name, 'slug', p.slug,
          'town', p.town, 'parish', p.parish, 'category', p.category,
          'bookings_email', p.bookings_email,
          'accepts_stay_bookings', p.accepts_stay_bookings,
          'booking_mode', p.booking_mode
        ) order by p.name
      ), '[]'::jsonb)
      from public.places p
      where p_query is null
         or lower(p.name) like lower('%' || p_query || '%')
         or lower(coalesce(p.town, '')) like lower('%' || p_query || '%')
    )
  );
end;
$$;

create or replace function public.admin_upsert_cancellation_policy(
  p_admin_token              text,
  p_id                       uuid    default null,
  p_place_id                 uuid    default null,
  p_rate_plan_id             uuid    default null,
  p_policy_name              text    default null,
  p_policy_text              text    default null,
  p_free_cancel_hours        integer default null,
  p_is_non_refundable        boolean default null,
  p_deposit_forfeiture_notes text    default null,
  p_is_default               boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_id uuid;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  if p_id is not null then
    update public.booking_cancellation_policies set
      policy_name              = coalesce(p_policy_name,              policy_name),
      policy_text              = coalesce(p_policy_text,              policy_text),
      free_cancel_hours        = coalesce(p_free_cancel_hours,        free_cancel_hours),
      is_non_refundable        = coalesce(p_is_non_refundable,        is_non_refundable),
      deposit_forfeiture_notes = coalesce(p_deposit_forfeiture_notes, deposit_forfeiture_notes),
      is_default               = coalesce(p_is_default,               is_default),
      updated_at               = now()
    where id = p_id;
    v_id := p_id;
  else
    if p_policy_name is null or p_policy_text is null then
      return jsonb_build_object('error', 'policy_name and policy_text required');
    end if;
    insert into public.booking_cancellation_policies (
      place_id, rate_plan_id, policy_name, policy_text,
      free_cancel_hours, is_non_refundable, deposit_forfeiture_notes, is_default
    ) values (
      p_place_id, p_rate_plan_id, p_policy_name, p_policy_text,
      p_free_cancel_hours, coalesce(p_is_non_refundable, false),
      p_deposit_forfeiture_notes, coalesce(p_is_default, false)
    ) returning id into v_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;


-- ────────────────────────────────────────────────────────────────
-- 21. BACK-FILL: mark existing places that receive Troddr bookings
-- ────────────────────────────────────────────────────────────────

update public.places
   set accepts_stay_bookings = true
 where accepts_stay_bookings = false
   and bookings_email is not null
   and length(trim(bookings_email)) > 0;

-- ================================================================
-- END hotel-booking-infrastructure.sql
-- ================================================================
