-- ============================================================
-- Billing: Foundation loyalty specials allowance
-- ------------------------------------------------------------
-- Product rule:
--   - Foundation loyalty partners get 2 included specials per
--     restaurant/location per billing cycle.
--   - Billing rolls up to the partner account.
--   - Extra-special usage is reserved on submission and becomes
--     invoice-ready only when an admin approves the special.
-- ============================================================

create table if not exists public.billing_accounts (
  id                             uuid primary key default gen_random_uuid(),
  partner_id                     uuid not null unique references public.partners(id) on delete cascade,
  plan_key                       text not null default 'foundation_loyalty',
  included_specials_per_location integer not null default 2,
  extra_special_price_amount     numeric,
  currency                       text not null default 'JMD',
  status                         text not null default 'active'
    check (status in ('active', 'past_due', 'paused', 'cancelled')),
  payment_provider               text,
  payment_customer_id            text,
  created_at                     timestamptz not null default now(),
  updated_at                     timestamptz not null default now()
);

create index if not exists billing_accounts_partner_idx
  on public.billing_accounts(partner_id);

create table if not exists public.billing_usage (
  id                 uuid primary key default gen_random_uuid(),
  billing_account_id uuid not null references public.billing_accounts(id) on delete cascade,
  partner_id         uuid not null references public.partners(id) on delete cascade,
  place_id           uuid references public.places(id) on delete set null,
  event_id           uuid references public.events(id) on delete set null,
  source_type        text not null,
  source_id          uuid not null,
  usage_type         text not null,
  status             text not null default 'pending_approval'
    check (status in ('pending_approval', 'ready_to_invoice', 'invoiced', 'paid', 'void')),
  amount             numeric,
  currency           text not null default 'JMD',
  cycle_start        date not null,
  cycle_end          date not null,
  description        text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

create index if not exists billing_usage_partner_cycle_idx
  on public.billing_usage(partner_id, cycle_start, cycle_end);

create index if not exists billing_usage_place_cycle_idx
  on public.billing_usage(place_id, cycle_start, cycle_end);

create unique index if not exists billing_usage_source_unique
  on public.billing_usage(source_type, source_id, usage_type);

alter table public.specials
  add column if not exists billing_account_id uuid references public.billing_accounts(id) on delete set null,
  add column if not exists billing_usage_id   uuid references public.billing_usage(id) on delete set null,
  add column if not exists billing_status     text not null default 'included'
    check (billing_status in ('included', 'pending_billable', 'billable', 'void')),
  add column if not exists billing_amount     numeric,
  add column if not exists billing_currency   text not null default 'JMD',
  add column if not exists billing_note       text;

create index if not exists specials_billing_usage_idx
  on public.specials(billing_usage_id);

-- Ensure every partner has a Foundation billing account unless one exists.
insert into public.billing_accounts (partner_id)
select p.id
from public.partners p
where not exists (
  select 1 from public.billing_accounts ba where ba.partner_id = p.id
);

create or replace function public.reserve_special_billing(
  p_place_id   uuid,
  p_special_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place        places%rowtype;
  v_account      billing_accounts%rowtype;
  v_cycle_start  date := date_trunc('month', now())::date;
  v_cycle_end    date := (date_trunc('month', now()) + interval '1 month - 1 day')::date;
  v_used         integer;
  v_usage_id     uuid;
begin
  select * into v_place from public.places where id = p_place_id;
  if v_place.id is null then
    return jsonb_build_object('ok', false, 'error', 'Place not found');
  end if;

  -- No partner means no roll-up billing account yet. Keep the special included.
  if v_place.partner_id is null then
    update public.specials
       set billing_status = 'included',
           billing_note   = 'Included: this location is not attached to a billing partner yet.'
     where id = p_special_id;
    return jsonb_build_object('ok', true, 'billing_status', 'included');
  end if;

  insert into public.billing_accounts (partner_id)
  values (v_place.partner_id)
  on conflict (partner_id) do nothing;

  select * into v_account
    from public.billing_accounts
   where partner_id = v_place.partner_id;

  -- Per-location allowance. Rejected/void specials do not consume the allowance.
  select count(*) into v_used
    from public.specials s
   where s.place_id = v_place.id
     and s.id <> p_special_id
     and coalesce(s.submission_status, 'approved') in ('pending', 'approved')
     and coalesce(s.billing_status, 'included') <> 'void'
     and s.submitted_at::date between v_cycle_start and v_cycle_end;

  if v_used < coalesce(v_account.included_specials_per_location, 2) then
    update public.specials
       set billing_account_id = v_account.id,
           billing_status     = 'included',
           billing_amount     = 0,
           billing_currency   = v_account.currency,
           billing_note       = format(
             'Included special %s of %s for this restaurant/location this billing cycle.',
             v_used + 1,
             coalesce(v_account.included_specials_per_location, 2)
           )
     where id = p_special_id;

    return jsonb_build_object(
      'ok', true,
      'billing_status', 'included',
      'included_used', v_used + 1,
      'included_limit', coalesce(v_account.included_specials_per_location, 2)
    );
  end if;

  insert into public.billing_usage (
    billing_account_id, partner_id, place_id,
    source_type, source_id, usage_type,
    status, amount, currency,
    cycle_start, cycle_end, description
  )
  values (
    v_account.id, v_place.partner_id, v_place.id,
    'special', p_special_id, 'extra_foundation_special',
    'pending_approval',
    v_account.extra_special_price_amount,
    v_account.currency,
    v_cycle_start, v_cycle_end,
    format('Extra special for %s after %s included specials this cycle.',
      v_place.name,
      coalesce(v_account.included_specials_per_location, 2)
    )
  )
  on conflict (source_type, source_id, usage_type) do update
     set status      = excluded.status,
         amount      = excluded.amount,
         currency    = excluded.currency,
         updated_at  = now()
  returning id into v_usage_id;

  update public.specials
     set billing_account_id = v_account.id,
         billing_usage_id   = v_usage_id,
         billing_status     = 'pending_billable',
         billing_amount     = v_account.extra_special_price_amount,
         billing_currency   = v_account.currency,
         billing_note       = format(
           'Billable extra special: this restaurant/location has already used %s included specials this billing cycle.',
           coalesce(v_account.included_specials_per_location, 2)
         )
   where id = p_special_id;

  return jsonb_build_object(
    'ok', true,
    'billing_status', 'pending_billable',
    'included_used', v_used,
    'included_limit', coalesce(v_account.included_specials_per_location, 2),
    'billing_usage_id', v_usage_id,
    'amount', v_account.extra_special_price_amount,
    'currency', v_account.currency
  );
end;
$$;

grant execute on function public.reserve_special_billing(uuid, uuid) to anon;

-- Replace submit_partner_special so every submission reserves billing.
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
  v_place       places%rowtype;
  v_special_id uuid;
  v_image_urls text[];
  v_billing    jsonb;
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

  v_billing := public.reserve_special_billing(v_place.id, v_special_id);

  return jsonb_build_object(
    'ok', true,
    'id', v_special_id,
    'status', 'pending',
    'billing', v_billing,
    'message', 'Submitted for approval. We''ll review within 1 business day.'
  );
end;
$$;

grant execute on function public.submit_partner_special(
  text, text, text, text, timestamptz, timestamptz, time, time,
  text, numeric, numeric, numeric, text, text, text[],
  integer, text[], text, text, text, text, text, text[]
) to anon;

-- Patch admin approval so billable usage becomes invoice-ready only
-- after approval. Rejections void the pending billing usage.
create or replace function public.admin_set_special_status(
  p_admin_token text,
  p_special_id  uuid,
  p_status      text,
  p_review_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  if p_status not in ('draft','pending','approved','rejected') then
    return jsonb_build_object('ok', false, 'error', 'Invalid status');
  end if;

  update public.specials
     set submission_status = p_status,
         active = case
                    when p_status = 'approved' then true
                    when p_status = 'rejected' then false
                    else active
                  end,
         billing_status = case
                    when p_status = 'approved' and billing_status = 'pending_billable' then 'billable'
                    when p_status = 'rejected' and billing_status = 'pending_billable' then 'void'
                    else billing_status
                  end,
         review_note  = case when p_review_note is null then review_note else p_review_note end,
         reviewed_at  = now(),
         reviewed_by  = 'admin'
   where id = p_special_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Special not found');
  end if;

  update public.billing_usage bu
     set status = case
                    when p_status = 'approved' then 'ready_to_invoice'
                    when p_status = 'rejected' then 'void'
                    else status
                  end,
         updated_at = now()
    from public.specials s
   where s.id = p_special_id
     and s.billing_usage_id = bu.id
     and bu.status in ('pending_approval', 'ready_to_invoice');

  return jsonb_build_object('ok', true, 'status', p_status);
end;
$$;

grant execute on function public.admin_set_special_status(text, uuid, text, text) to anon;
