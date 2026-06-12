-- ============================================================
-- TRODDR Company Billing & Manual Subscription System
-- ------------------------------------------------------------
-- Manual (non-Stripe) billing per COMPANY ACCOUNT:
--   admin issues invoice -> company reports payment ->
--   admin verifies -> subscription/entitlements activate.
--
-- Auth model:
--   - Company dashboard uses Supabase Auth (auth.uid()).
--     Company users are pre-registered by email in company_users
--     and linked to their auth user on first sign-in.
--   - Admin actions use the existing admin_tokens / _is_admin()
--     bearer-token model (see admin-review.sql).
--   - Partner access tokens are NOT used here; they remain only
--     for lightweight booking-response links.
--
-- Invariant: a user-reported payment NEVER activates access.
-- It only moves the invoice to payment_reported. Only
-- admin_review_payment(decision => 'approve') activates the
-- subscription and entitlements.
--
-- Run order: this file, then company-billing-seed.sql.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Company accounts
-- ------------------------------------------------------------
create table if not exists public.company_accounts (
  id            uuid primary key default gen_random_uuid(),
  name          text not null,
  billing_email text not null,
  contact_name  text,
  contact_phone text,
  status        text not null default 'active'
    check (status in ('active', 'suspended', 'archived')),
  notes         text,            -- internal admin notes
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- Approved locations attached to a company account.
-- Attach/detach is ADMIN ONLY: there is no company-facing RPC
-- that writes to this table.
create table if not exists public.company_locations (
  id                 uuid primary key default gen_random_uuid(),
  company_account_id uuid not null references public.company_accounts(id) on delete cascade,
  place_id           uuid not null references public.places(id) on delete cascade,
  label              text,
  status             text not null default 'approved'
    check (status in ('approved', 'removed')),
  approved_at        timestamptz not null default now(),
  approved_by        text,
  created_at         timestamptz not null default now(),
  unique (company_account_id, place_id)
);

create index if not exists company_locations_company_idx
  on public.company_locations(company_account_id);

-- Company users (dashboard sign-ins). Admin pre-registers the
-- email; the row is linked to auth.users on first sign-in.
-- Extra admin seats are REQUEST ONLY (company_requests below).
create table if not exists public.company_users (
  id                 uuid primary key default gen_random_uuid(),
  company_account_id uuid not null references public.company_accounts(id) on delete cascade,
  email              text not null,
  name               text,
  role               text not null default 'admin'
    check (role in ('admin', 'member')),
  user_id            uuid references auth.users(id) on delete set null,
  status             text not null default 'invited'
    check (status in ('invited', 'active', 'removed')),
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (company_account_id, email)
);

create index if not exists company_users_company_idx on public.company_users(company_account_id);
create index if not exists company_users_user_idx    on public.company_users(user_id);
create index if not exists company_users_email_idx   on public.company_users(lower(email));

-- ------------------------------------------------------------
-- 2. Plans, products, entitlements
-- ------------------------------------------------------------
create table if not exists public.subscription_plans (
  key                text primary key,           -- e.g. 'fp_single'
  name               text not null,
  description        text,
  included_locations integer not null default 1,
  included_admins    integer not null default 1,
  monthly_price      numeric,                    -- price per month, billed monthly
  annual_price       numeric,                    -- price per year, billed annually
  currency           text not null default 'USD',
  entitlements       jsonb not null default '[]'::jsonb, -- array of entitlement keys
  is_active          boolean not null default true,
  sort_order         integer not null default 0,
  created_at         timestamptz not null default now()
);

-- Catalog of entitlement keys. Feature access checks use keys,
-- never plan names.
create table if not exists public.entitlement_definitions (
  key         text primary key,
  name        text not null,
  description text,
  category    text not null default 'core'
    check (category in ('core', 'listing', 'insights', 'event', 'sponsor')),
  is_active   boolean not null default true
);

-- Sellable products (invoice line item catalog). Ranged products
-- (e.g. "from $10,000") store min/max and the admin sets the
-- actual unit amount on the invoice line.
create table if not exists public.billing_products (
  code         text primary key,                -- e.g. 'otr_basic_monthly'
  item_type    text not null check (item_type in (
                 'founding_partner_subscription',
                 'otr_basic', 'otr_premium',
                 'location_insights', 'company_insights',
                 'event_lite', 'event_pro', 'major_event_hub', 'flagship_event',
                 'carnival_hub', 'carnival_band_hub', 'carnival_event_listing', 'carnival_event_pro',
                 'event_series_hub', 'event_insights', 'premium_event_map',
                 'sponsor_activation', 'sponsor_report',
                 'custom')),
  name         text not null,
  description  text,
  unit_amount  numeric,                          -- fixed price (null when ranged)
  min_amount   numeric,                          -- ranged price floor
  max_amount   numeric,                          -- ranged price ceiling (null = open)
  currency     text not null default 'USD',
  billing_unit text not null default 'one_time'
    check (billing_unit in ('one_time', 'month', 'year', 'per_location_month', 'per_location_year', 'per_day')),
  entitlements jsonb not null default '[]'::jsonb, -- keys granted when invoice is PAID
  metadata     jsonb not null default '{}'::jsonb, -- e.g. {"push_cap": 5}
  is_active    boolean not null default true,
  sort_order   integer not null default 0
);

-- ------------------------------------------------------------
-- 3. Subscriptions + materialized entitlements
-- ------------------------------------------------------------
-- One subscription row per company account.
create table if not exists public.subscriptions (
  id                   uuid primary key default gen_random_uuid(),
  company_account_id   uuid not null unique references public.company_accounts(id) on delete cascade,
  plan_key             text references public.subscription_plans(key),
  billing_cycle        text check (billing_cycle in ('monthly', 'annual')),
  status               text not null default 'invoice_issued'
    check (status in ('invoice_issued', 'payment_pending_review', 'active',
                      'past_due', 'read_only', 'expired', 'canceled')),
  current_period_start date,
  paid_through         date,        -- access is full through this date when active
  activated_at         timestamptz,
  canceled_at          timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

-- Entitlements granted to a company. Materialized (not derived
-- live from plan) so admins can audit and manually adjust.
create table if not exists public.company_entitlements (
  id                 uuid primary key default gen_random_uuid(),
  company_account_id uuid not null references public.company_accounts(id) on delete cascade,
  entitlement_key    text not null references public.entitlement_definitions(key),
  source             text not null default 'manual'
    check (source in ('plan', 'addon', 'manual')),
  is_active          boolean not null default true,
  starts_at          date not null default current_date,
  expires_at         date,                       -- null = until revoked
  source_invoice_id  uuid,
  notes              text,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (company_account_id, entitlement_key)
);

create index if not exists company_entitlements_company_idx
  on public.company_entitlements(company_account_id);

-- ------------------------------------------------------------
-- 4. Invoices
-- ------------------------------------------------------------
create table if not exists public.invoice_counters (
  year        integer primary key,
  last_number integer not null default 0
);

create table if not exists public.invoices (
  id                   uuid primary key default gen_random_uuid(),
  company_account_id   uuid not null references public.company_accounts(id) on delete restrict,
  invoice_number       text unique,              -- assigned when issued: TRODDR-INV-YYYY-0001
  status               text not null default 'draft'
    check (status in ('draft', 'issued', 'payment_reported', 'paid',
                      'rejected', 'void', 'overdue')),
  currency             text not null default 'USD',
  issue_date           date,
  due_date             date,
  period_start         date,                     -- billing period covered
  period_end           date,
  subtotal             numeric not null default 0,
  discount_amount      numeric not null default 0,
  discount_note        text,
  total                numeric not null default 0,
  notes                text,                     -- printed on the invoice
  payment_instructions text,                     -- bank details etc., printed
  internal_notes       text,                     -- admin only, never shown to company
  issued_at            timestamptz,
  paid_at              timestamptz,
  created_at           timestamptz not null default now(),
  updated_at           timestamptz not null default now()
);

create index if not exists invoices_company_idx on public.invoices(company_account_id);
create index if not exists invoices_status_idx  on public.invoices(status);

create table if not exists public.invoice_line_items (
  id           uuid primary key default gen_random_uuid(),
  invoice_id   uuid not null references public.invoices(id) on delete cascade,
  item_type    text not null check (item_type in (
                 'founding_partner_subscription',
                 'otr_basic', 'otr_premium',
                 'location_insights', 'company_insights',
                 'event_lite', 'event_pro', 'major_event_hub', 'flagship_event',
                 'carnival_hub', 'carnival_band_hub', 'carnival_event_listing', 'carnival_event_pro',
                 'event_series_hub', 'event_insights', 'premium_event_map',
                 'sponsor_activation', 'sponsor_report',
                 'custom')),
  product_code text references public.billing_products(code),
  description  text not null,
  quantity     numeric not null default 1,
  unit_amount  numeric not null default 0,
  amount       numeric not null default 0,       -- quantity * unit_amount (may be negative for discounts)
  period_start date,                             -- overrides invoice period for this line
  period_end   date,
  metadata     jsonb not null default '{}'::jsonb, -- e.g. {"plan_key":"fp_duo","billing_cycle":"annual","place_id":"..."}
  sort_order   integer not null default 0,
  created_at   timestamptz not null default now()
);

create index if not exists invoice_line_items_invoice_idx
  on public.invoice_line_items(invoice_id);

-- ------------------------------------------------------------
-- 5. Payment confirmations (company-reported, admin-reviewed)
-- ------------------------------------------------------------
create table if not exists public.payment_confirmations (
  id                 uuid primary key default gen_random_uuid(),
  invoice_id         uuid not null references public.invoices(id) on delete cascade,
  company_account_id uuid not null references public.company_accounts(id) on delete cascade,
  submitted_by       uuid references public.company_users(id) on delete set null,
  payment_method     text not null
    check (payment_method in ('bank_transfer', 'cash', 'cheque', 'card', 'mobile_money', 'other')),
  paid_on            date not null,
  reference_number   text not null,
  receipt_url        text,
  notes              text,
  status             text not null default 'submitted'
    check (status in ('submitted', 'approved', 'rejected', 'needs_clarification')),
  review_note        text,
  reviewed_at        timestamptz,
  reviewed_by        text,
  created_at         timestamptz not null default now()
);

create index if not exists payment_confirmations_invoice_idx
  on public.payment_confirmations(invoice_id);
create index if not exists payment_confirmations_status_idx
  on public.payment_confirmations(status);

-- ------------------------------------------------------------
-- 6. Company requests (request-only upsells; no self-purchase)
-- ------------------------------------------------------------
create table if not exists public.company_requests (
  id                 uuid primary key default gen_random_uuid(),
  company_account_id uuid not null references public.company_accounts(id) on delete cascade,
  requested_by       uuid references public.company_users(id) on delete set null,
  request_type       text not null
    check (request_type in ('extra_admins', 'insights', 'event_coverage',
                            'sponsor_activation', 'sponsor_report', 'other')),
  message            text,
  status             text not null default 'new'
    check (status in ('new', 'in_progress', 'resolved')),
  created_at         timestamptz not null default now(),
  resolved_at        timestamptz
);

create index if not exists company_requests_status_idx
  on public.company_requests(status);

-- ------------------------------------------------------------
-- 7. Audit log
-- ------------------------------------------------------------
create table if not exists public.billing_audit_log (
  id                 uuid primary key default gen_random_uuid(),
  actor_type         text not null check (actor_type in ('admin', 'company_user', 'system')),
  actor_label        text,                       -- admin token label / company user email
  company_account_id uuid references public.company_accounts(id) on delete set null,
  invoice_id         uuid,
  subscription_id    uuid,
  action             text not null,
  details            jsonb not null default '{}'::jsonb,
  created_at         timestamptz not null default now()
);

create index if not exists billing_audit_company_idx
  on public.billing_audit_log(company_account_id, created_at desc);

-- ------------------------------------------------------------
-- 8. Receipt uploads bucket (company users only)
-- ------------------------------------------------------------
insert into storage.buckets (id, name, public)
values ('payment-receipts', 'payment-receipts', true)
on conflict (id) do nothing;

drop policy if exists "authenticated can upload payment receipts" on storage.objects;
create policy "authenticated can upload payment receipts"
on storage.objects for insert to authenticated
with check (bucket_id = 'payment-receipts');

drop policy if exists "anyone can read payment receipts" on storage.objects;
create policy "anyone can read payment receipts"
on storage.objects for select to anon, authenticated
using (bucket_id = 'payment-receipts');

-- ------------------------------------------------------------
-- 9. RLS: lock every table down. All access goes through the
--    security-definer RPCs below (same model as admin_tokens).
-- ------------------------------------------------------------
alter table public.company_accounts        enable row level security;
alter table public.company_locations       enable row level security;
alter table public.company_users           enable row level security;
alter table public.subscription_plans      enable row level security;
alter table public.entitlement_definitions enable row level security;
alter table public.billing_products        enable row level security;
alter table public.subscriptions           enable row level security;
alter table public.company_entitlements    enable row level security;
alter table public.invoice_counters        enable row level security;
alter table public.invoices                enable row level security;
alter table public.invoice_line_items      enable row level security;
alter table public.payment_confirmations   enable row level security;
alter table public.company_requests        enable row level security;
alter table public.billing_audit_log       enable row level security;

-- ============================================================
-- HELPERS
-- ============================================================

create or replace function public._billing_audit(
  p_actor_type   text,
  p_actor_label  text,
  p_company_id   uuid,
  p_action       text,
  p_details      jsonb default '{}'::jsonb,
  p_invoice_id   uuid default null,
  p_subscription uuid default null
)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.billing_audit_log
    (actor_type, actor_label, company_account_id, invoice_id, subscription_id, action, details)
  values
    (p_actor_type, p_actor_label, p_company_id, p_invoice_id, p_subscription,
     p_action, coalesce(p_details, '{}'::jsonb));
$$;

create or replace function public._admin_label(p_token text)
returns text
language sql
security definer
set search_path = public
as $$
  select coalesce(label, 'admin') from public.admin_tokens
   where token = p_token and is_active = true;
$$;

-- Invoice number: TRODDR-INV-YYYY-0001, per-year counter.
create or replace function public.next_invoice_number()
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_year integer := extract(year from now())::integer;
  v_num  integer;
begin
  insert into public.invoice_counters (year, last_number)
  values (v_year, 1)
  on conflict (year) do update
    set last_number = public.invoice_counters.last_number + 1
  returning last_number into v_num;

  return format('TRODDR-INV-%s-%s', v_year, lpad(v_num::text, 4, '0'));
end;
$$;

-- Allowed invoice status transitions. Raises on anything else.
create or replace function public._assert_invoice_transition(p_from text, p_to text)
returns void
language plpgsql
as $$
declare
  v_ok boolean;
begin
  if p_from = p_to then return; end if;
  v_ok := case p_from
    when 'draft'            then p_to in ('issued', 'void')
    when 'issued'           then p_to in ('payment_reported', 'overdue', 'paid', 'void')
    when 'overdue'          then p_to in ('payment_reported', 'paid', 'void')
    when 'payment_reported' then p_to in ('paid', 'rejected', 'issued', 'void')
    when 'rejected'         then p_to in ('payment_reported', 'issued', 'void')
    when 'paid'             then p_to in ('void')
    else false  -- void is terminal
  end;
  if not v_ok then
    raise exception 'Invalid invoice status transition: % -> %', p_from, p_to;
  end if;
end;
$$;

-- Effective invoice status for display: issued + past due date
-- shows as overdue without mutating the row.
create or replace function public._invoice_effective_status(p_status text, p_due date)
returns text
language sql
stable
as $$
  select case
    when p_status = 'issued' and p_due is not null and p_due < current_date then 'overdue'
    else p_status
  end;
$$;

-- Company access state. Full access only while the subscription
-- is active AND inside the paid-through window. Lapsed/inactive
-- accounts fall to read-only. Never extends access on its own.
create or replace function public.company_access_state(p_company_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_sub    subscriptions%rowtype;
  v_access text;
  v_status text;
begin
  select * into v_sub
    from public.subscriptions
   where company_account_id = p_company_id;

  if v_sub.id is null then
    return jsonb_build_object('access', 'none', 'status', null, 'paid_through', null);
  end if;

  v_status := v_sub.status;

  if v_sub.status = 'active' then
    if v_sub.paid_through is null or v_sub.paid_through < current_date then
      -- Lapsed: 7-day grace shows past_due, then read_only.
      if v_sub.paid_through is not null
         and v_sub.paid_through >= current_date - interval '7 days' then
        v_status := 'past_due';
      else
        v_status := 'read_only';
      end if;
      v_access := 'read_only';
    else
      v_access := 'full';
    end if;
  elsif v_sub.status in ('invoice_issued', 'payment_pending_review') then
    -- Renewal in flight: keep full access only while still paid.
    v_access := case
      when v_sub.paid_through is not null and v_sub.paid_through >= current_date
      then 'full' else 'read_only' end;
  else
    -- past_due / read_only / expired / canceled
    v_access := 'read_only';
  end if;

  return jsonb_build_object(
    'access',       v_access,
    'status',       v_status,
    'stored_status', v_sub.status,
    'plan_key',     v_sub.plan_key,
    'billing_cycle', v_sub.billing_cycle,
    'paid_through', v_sub.paid_through
  );
end;
$$;

-- Entitlement check used by feature code. True only when the
-- entitlement is active, unexpired, AND the company has full
-- (not read-only) access. dashboard_access is the exception:
-- it stays true in read-only mode so users can still sign in
-- and see historical data + invoices.
create or replace function public.company_has_entitlement(p_company_id uuid, p_key text)
returns boolean
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_has    boolean;
  v_access text;
begin
  select exists(
    select 1 from public.company_entitlements
     where company_account_id = p_company_id
       and entitlement_key = p_key
       and is_active = true
       and starts_at <= current_date
       and (expires_at is null or expires_at >= current_date)
  ) into v_has;

  if not v_has then return false; end if;
  if p_key = 'dashboard_access' then return true; end if;

  v_access := public.company_access_state(p_company_id)->>'access';
  return v_access = 'full';
end;
$$;

-- Resolve the calling auth user to a company_users row, linking
-- the auth user id on first sign-in (admin pre-registers email).
create or replace function public._resolve_company_user()
returns public.company_users
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_email text := coalesce(auth.jwt() ->> 'email', '');
  v_row   company_users%rowtype;
  v_link  uuid;
begin
  if v_uid is null then return null; end if;

  select * into v_row
    from public.company_users
   where user_id = v_uid and status <> 'removed'
   order by created_at
   limit 1;
  if v_row.id is not null then return v_row; end if;

  -- First sign-in: link by email (oldest invite wins if the same
  -- email was invited to more than one company).
  if v_email <> '' then
    select id into v_link
      from public.company_users
     where lower(email) = lower(v_email)
       and user_id is null
       and status = 'invited'
     order by created_at
     limit 1;
    if v_link is not null then
      update public.company_users
         set user_id = v_uid,
             status = 'active',
             updated_at = now()
       where id = v_link
      returning * into v_row;
    end if;
  end if;

  return v_row;
end;
$$;

-- ============================================================
-- ACTIVATION (admin approval only path to access)
-- ============================================================

create or replace function public._grant_entitlement(
  p_company_id uuid,
  p_key        text,
  p_source     text,
  p_starts     date,
  p_expires    date,
  p_invoice_id uuid,
  p_notes      text default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  if not exists (select 1 from public.entitlement_definitions where key = p_key) then
    raise warning 'Unknown entitlement key skipped: %', p_key;
    return;
  end if;

  insert into public.company_entitlements
    (company_account_id, entitlement_key, source, is_active, starts_at, expires_at, source_invoice_id, notes)
  values
    (p_company_id, p_key, p_source, true, coalesce(p_starts, current_date), p_expires, p_invoice_id, p_notes)
  on conflict (company_account_id, entitlement_key) do update
    set is_active  = true,
        source     = excluded.source,
        starts_at  = least(public.company_entitlements.starts_at, excluded.starts_at),
        -- Extend, never shrink. null = until revoked, wins.
        expires_at = case
          when public.company_entitlements.expires_at is null or excluded.expires_at is null then null
          else greatest(public.company_entitlements.expires_at, excluded.expires_at)
        end,
        source_invoice_id = excluded.source_invoice_id,
        updated_at = now();
end;
$$;

-- Called ONLY from admin_review_payment(approve) / admin paid.
-- Activates subscription + entitlements from a paid invoice.
-- Access resumes from the invoiced period: no backfill of
-- unpaid gaps (paid_through simply jumps to the new period_end).
create or replace function public._activate_paid_invoice(p_invoice_id uuid, p_actor_label text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inv   invoices%rowtype;
  v_line  record;
  v_plan  subscription_plans%rowtype;
  v_sub   subscriptions%rowtype;
  v_start date;
  v_end   date;
  v_cycle text;
  v_key   text;
  v_grants jsonb;
begin
  select * into v_inv from public.invoices where id = p_invoice_id;
  if v_inv.id is null then raise exception 'Invoice not found'; end if;
  if v_inv.status <> 'paid' then
    raise exception 'Only paid invoices can activate access (invoice is %)', v_inv.status;
  end if;

  for v_line in
    select * from public.invoice_line_items
     where invoice_id = p_invoice_id
     order by sort_order, created_at
  loop
    v_start := coalesce(v_line.period_start, v_inv.period_start, current_date);
    v_end   := coalesce(v_line.period_end,   v_inv.period_end);

    -- Subscription line: upsert the company subscription.
    if v_line.item_type = 'founding_partner_subscription' then
      v_cycle := coalesce(v_line.metadata ->> 'billing_cycle', 'annual');
      select * into v_plan
        from public.subscription_plans
       where key = v_line.metadata ->> 'plan_key';

      if v_end is null then
        v_end := case when v_cycle = 'monthly'
                      then (v_start + interval '1 month - 1 day')::date
                      else (v_start + interval '1 year - 1 day')::date end;
      end if;

      insert into public.subscriptions
        (company_account_id, plan_key, billing_cycle, status,
         current_period_start, paid_through, activated_at)
      values
        (v_inv.company_account_id, v_plan.key, v_cycle, 'active', v_start, v_end, now())
      on conflict (company_account_id) do update
        set plan_key             = coalesce(excluded.plan_key, public.subscriptions.plan_key),
            billing_cycle        = excluded.billing_cycle,
            status               = 'active',
            current_period_start = excluded.current_period_start,
            paid_through         = excluded.paid_through,
            activated_at         = coalesce(public.subscriptions.activated_at, now()),
            canceled_at          = null,
            updated_at           = now()
      returning * into v_sub;

      -- Plan entitlements run through paid_through.
      if v_plan.key is not null then
        for v_key in select jsonb_array_elements_text(v_plan.entitlements)
        loop
          perform public._grant_entitlement(
            v_inv.company_account_id, v_key, 'plan', v_start, v_end, p_invoice_id,
            'Plan: ' || v_plan.name);
        end loop;
      end if;

      perform public._billing_audit('system', p_actor_label, v_inv.company_account_id,
        'subscription_activated',
        jsonb_build_object('plan_key', v_plan.key, 'billing_cycle', v_cycle,
                           'period_start', v_start, 'paid_through', v_end),
        p_invoice_id, v_sub.id);
    end if;

    -- Product / line entitlement grants.
    v_grants := coalesce(
      (select bp.entitlements from public.billing_products bp where bp.code = v_line.product_code),
      v_line.metadata -> 'entitlements',
      '[]'::jsonb);

    if v_line.item_type <> 'founding_partner_subscription'
       and jsonb_typeof(v_grants) = 'array' then
      for v_key in select jsonb_array_elements_text(v_grants)
      loop
        perform public._grant_entitlement(
          v_inv.company_account_id, v_key, 'addon', v_start, v_end, p_invoice_id,
          'Invoice line: ' || v_line.description);
      end loop;
    end if;
  end loop;

  perform public._billing_audit('system', p_actor_label, v_inv.company_account_id,
    'invoice_activated_entitlements', jsonb_build_object('invoice_number', v_inv.invoice_number),
    p_invoice_id, null);
end;
$$;

-- ============================================================
-- COMPANY-FACING RPCs (Supabase auth, granted to authenticated)
-- ============================================================

-- One round-trip that powers the whole company Billing page.
create or replace function public.get_company_billing()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user    company_users%rowtype;
  v_company company_accounts%rowtype;
  v_plan    subscription_plans%rowtype;
  v_access  jsonb;
begin
  v_user := public._resolve_company_user();
  if v_user.id is null then
    return jsonb_build_object('ok', false, 'error', 'no_company',
      'message', 'Your sign-in is not linked to a company account yet. Contact TRODDR to get set up.');
  end if;

  select * into v_company from public.company_accounts where id = v_user.company_account_id;
  v_access := public.company_access_state(v_company.id);

  select sp.* into v_plan
    from public.subscriptions s
    join public.subscription_plans sp on sp.key = s.plan_key
   where s.company_account_id = v_company.id;

  return jsonb_build_object(
    'ok', true,
    'company', jsonb_build_object(
      'id', v_company.id, 'name', v_company.name,
      'billing_email', v_company.billing_email, 'status', v_company.status),
    'me', jsonb_build_object(
      'id', v_user.id, 'email', v_user.email, 'name', v_user.name, 'role', v_user.role),
    'access', v_access,
    'plan', case when v_plan.key is null then null else jsonb_build_object(
      'key', v_plan.key, 'name', v_plan.name,
      'included_locations', v_plan.included_locations,
      'included_admins', v_plan.included_admins,
      'monthly_price', v_plan.monthly_price, 'annual_price', v_plan.annual_price,
      'currency', v_plan.currency) end,
    'subscription', (
      select jsonb_build_object(
        'plan_key', s.plan_key, 'billing_cycle', s.billing_cycle,
        'status', v_access ->> 'status', 'stored_status', s.status,
        'current_period_start', s.current_period_start,
        'paid_through', s.paid_through, 'activated_at', s.activated_at)
      from public.subscriptions s where s.company_account_id = v_company.id),
    'locations', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', cl.id, 'place_id', cl.place_id,
        'name', coalesce(cl.label, p.name), 'slug', p.slug,
        'town', p.town, 'parish', p.parish,
        'approved_at', cl.approved_at) order by p.name), '[]'::jsonb)
      from public.company_locations cl
      left join public.places p on p.id = cl.place_id
      where cl.company_account_id = v_company.id and cl.status = 'approved'),
    'users', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', cu.id, 'email', cu.email, 'name', cu.name,
        'role', cu.role, 'status', cu.status) order by cu.created_at), '[]'::jsonb)
      from public.company_users cu
      where cu.company_account_id = v_company.id and cu.status <> 'removed'),
    'entitlements', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'key', ce.entitlement_key,
        'name', ed.name,
        'category', ed.category,
        'source', ce.source,
        'starts_at', ce.starts_at,
        'expires_at', ce.expires_at,
        'active_now', (ce.is_active and ce.starts_at <= current_date
                       and (ce.expires_at is null or ce.expires_at >= current_date))
      ) order by ed.category, ce.entitlement_key), '[]'::jsonb)
      from public.company_entitlements ce
      join public.entitlement_definitions ed on ed.key = ce.entitlement_key
      where ce.company_account_id = v_company.id and ce.is_active = true),
    'invoices', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', i.id,
        'invoice_number', i.invoice_number,
        'status', public._invoice_effective_status(i.status, i.due_date),
        'currency', i.currency,
        'issue_date', i.issue_date, 'due_date', i.due_date,
        'period_start', i.period_start, 'period_end', i.period_end,
        'subtotal', i.subtotal, 'discount_amount', i.discount_amount,
        'discount_note', i.discount_note, 'total', i.total,
        'notes', i.notes, 'payment_instructions', i.payment_instructions,
        'paid_at', i.paid_at,
        'line_items', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'item_type', li.item_type, 'description', li.description,
            'quantity', li.quantity, 'unit_amount', li.unit_amount,
            'amount', li.amount, 'period_start', li.period_start,
            'period_end', li.period_end) order by li.sort_order, li.created_at), '[]'::jsonb)
          from public.invoice_line_items li where li.invoice_id = i.id),
        'payment_confirmation', (
          select jsonb_build_object(
            'id', pc.id, 'status', pc.status, 'payment_method', pc.payment_method,
            'paid_on', pc.paid_on, 'reference_number', pc.reference_number,
            'review_note', pc.review_note, 'created_at', pc.created_at)
          from public.payment_confirmations pc
          where pc.invoice_id = i.id
          order by pc.created_at desc limit 1)
      ) order by i.issue_date desc nulls last, i.created_at desc), '[]'::jsonb)
      from public.invoices i
      where i.company_account_id = v_company.id
        and i.status <> 'draft'),
    'requests', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', r.id, 'request_type', r.request_type, 'message', r.message,
        'status', r.status, 'created_at', r.created_at) order by r.created_at desc), '[]'::jsonb)
      from public.company_requests r
      where r.company_account_id = v_company.id)
  );
end;
$$;

-- Lightweight entitlement lookup for other authenticated surfaces.
create or replace function public.get_my_entitlements()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user company_users%rowtype;
begin
  v_user := public._resolve_company_user();
  if v_user.id is null then return jsonb_build_object('ok', false, 'error', 'no_company'); end if;
  return jsonb_build_object(
    'ok', true,
    'company_id', v_user.company_account_id,
    'access', public.company_access_state(v_user.company_account_id),
    'entitlements', (
      select coalesce(jsonb_agg(ce.entitlement_key), '[]'::jsonb)
      from public.company_entitlements ce
      where ce.company_account_id = v_user.company_account_id
        and ce.is_active = true
        and ce.starts_at <= current_date
        and (ce.expires_at is null or ce.expires_at >= current_date)));
end;
$$;

-- Internal worker so the same logic is testable without a JWT.
-- IMPORTANT: never activates anything. Invoice -> payment_reported,
-- subscription -> payment_pending_review. That's all.
create or replace function public._submit_payment_confirmation(
  p_company_user_id uuid,
  p_invoice_id      uuid,
  p_payment_method  text,
  p_paid_on         date,
  p_reference       text,
  p_receipt_url     text default null,
  p_notes           text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user   company_users%rowtype;
  v_inv    invoices%rowtype;
  v_conf   payment_confirmations%rowtype;
  v_latest payment_confirmations%rowtype;
begin
  select * into v_user from public.company_users where id = p_company_user_id;
  if v_user.id is null then
    return jsonb_build_object('ok', false, 'error', 'Company user not found');
  end if;

  select * into v_inv from public.invoices where id = p_invoice_id;
  if v_inv.id is null or v_inv.company_account_id <> v_user.company_account_id then
    return jsonb_build_object('ok', false, 'error', 'Invoice not found');
  end if;

  if p_payment_method is null or p_payment_method not in
     ('bank_transfer', 'cash', 'cheque', 'card', 'mobile_money', 'other') then
    return jsonb_build_object('ok', false, 'error', 'Pick a valid payment method');
  end if;
  if p_paid_on is null or p_paid_on > current_date then
    return jsonb_build_object('ok', false, 'error', 'Payment date cannot be in the future');
  end if;
  if p_reference is null or length(trim(p_reference)) = 0 then
    return jsonb_build_object('ok', false, 'error', 'A payment reference number is required');
  end if;

  -- Re-reporting is allowed after rejection or a clarification request.
  if v_inv.status in ('issued', 'overdue', 'rejected') then
    null; -- ok
  elsif v_inv.status = 'payment_reported' then
    select * into v_latest from public.payment_confirmations
     where invoice_id = v_inv.id order by created_at desc limit 1;
    if v_latest.status is distinct from 'needs_clarification' then
      return jsonb_build_object('ok', false, 'error',
        'A payment confirmation is already under review for this invoice');
    end if;
  else
    return jsonb_build_object('ok', false, 'error',
      'This invoice is not awaiting payment (status: ' || v_inv.status || ')');
  end if;

  insert into public.payment_confirmations
    (invoice_id, company_account_id, submitted_by, payment_method,
     paid_on, reference_number, receipt_url, notes)
  values
    (v_inv.id, v_inv.company_account_id, v_user.id, p_payment_method,
     p_paid_on, trim(p_reference), nullif(trim(coalesce(p_receipt_url, '')), ''),
     nullif(trim(coalesce(p_notes, '')), ''))
  returning * into v_conf;

  if v_inv.status <> 'payment_reported' then
    perform public._assert_invoice_transition(v_inv.status, 'payment_reported');
    update public.invoices
       set status = 'payment_reported', updated_at = now()
     where id = v_inv.id;
  end if;

  -- Flag the subscription as pending review WITHOUT granting access.
  update public.subscriptions
     set status = 'payment_pending_review', updated_at = now()
   where company_account_id = v_inv.company_account_id
     and status in ('invoice_issued', 'past_due', 'read_only', 'expired')
     and exists (
       select 1 from public.invoice_line_items li
        where li.invoice_id = v_inv.id
          and li.item_type = 'founding_partner_subscription');

  perform public._billing_audit('company_user', v_user.email, v_inv.company_account_id,
    'payment_reported',
    jsonb_build_object('method', p_payment_method, 'paid_on', p_paid_on,
                       'reference', trim(p_reference), 'confirmation_id', v_conf.id),
    v_inv.id, null);

  return jsonb_build_object('ok', true, 'confirmation_id', v_conf.id,
    'invoice_status', 'payment_reported',
    'message', 'Thanks! TRODDR will verify your payment and activate your account. Nothing is active until we confirm.');
end;
$$;

create or replace function public.submit_payment_confirmation(
  p_invoice_id     uuid,
  p_payment_method text,
  p_paid_on        date,
  p_reference      text,
  p_receipt_url    text default null,
  p_notes          text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user company_users%rowtype;
begin
  v_user := public._resolve_company_user();
  if v_user.id is null then
    return jsonb_build_object('ok', false, 'error', 'Not signed in to a company account');
  end if;
  return public._submit_payment_confirmation(
    v_user.id, p_invoice_id, p_payment_method, p_paid_on,
    p_reference, p_receipt_url, p_notes);
end;
$$;

-- Request-only upsells (extra admins, insights, event coverage,
-- sponsor products). No self-service purchase path exists.
create or replace function public.submit_billing_request(
  p_request_type text,
  p_message      text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user company_users%rowtype;
  v_id   uuid;
begin
  v_user := public._resolve_company_user();
  if v_user.id is null then
    return jsonb_build_object('ok', false, 'error', 'Not signed in to a company account');
  end if;
  if p_request_type not in ('extra_admins', 'insights', 'event_coverage',
                            'sponsor_activation', 'sponsor_report', 'other') then
    return jsonb_build_object('ok', false, 'error', 'Invalid request type');
  end if;

  insert into public.company_requests (company_account_id, requested_by, request_type, message)
  values (v_user.company_account_id, v_user.id, p_request_type,
          nullif(trim(coalesce(p_message, '')), ''))
  returning id into v_id;

  perform public._billing_audit('company_user', v_user.email, v_user.company_account_id,
    'request_submitted', jsonb_build_object('request_type', p_request_type, 'request_id', v_id));

  return jsonb_build_object('ok', true, 'id', v_id,
    'message', 'Request sent. TRODDR will follow up by email.');
end;
$$;

-- ============================================================
-- ADMIN RPCs (admin_tokens bearer model, granted to anon)
-- ============================================================

-- Catalog for the invoice generator UI.
create or replace function public.admin_get_billing_catalog(p_admin_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._is_admin(p_admin_token) then return null; end if;
  return jsonb_build_object(
    'plans', (
      select coalesce(jsonb_agg(to_jsonb(sp) order by sp.sort_order), '[]'::jsonb)
      from public.subscription_plans sp where sp.is_active),
    'products', (
      select coalesce(jsonb_agg(to_jsonb(bp) order by bp.sort_order, bp.name), '[]'::jsonb)
      from public.billing_products bp where bp.is_active),
    'entitlements', (
      select coalesce(jsonb_agg(to_jsonb(ed) order by ed.category, ed.key), '[]'::jsonb)
      from public.entitlement_definitions ed where ed.is_active));
end;
$$;

-- Overview powering the admin billing dashboard.
create or replace function public.admin_billing_overview(p_admin_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._is_admin(p_admin_token) then return null; end if;

  return jsonb_build_object(
    'counts', jsonb_build_object(
      'pending_reviews', (select count(*) from public.payment_confirmations where status = 'submitted'),
      'open_requests',   (select count(*) from public.company_requests where status in ('new', 'in_progress')),
      'draft_invoices',  (select count(*) from public.invoices where status = 'draft'),
      'overdue_invoices', (select count(*) from public.invoices
                            where public._invoice_effective_status(status, due_date) = 'overdue')),
    'companies', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', ca.id, 'name', ca.name, 'billing_email', ca.billing_email, 'status', ca.status,
        'access', public.company_access_state(ca.id),
        'locations', (select count(*) from public.company_locations cl
                       where cl.company_account_id = ca.id and cl.status = 'approved'),
        'users', (select count(*) from public.company_users cu
                   where cu.company_account_id = ca.id and cu.status <> 'removed'),
        'open_invoices', (select count(*) from public.invoices i
                           where i.company_account_id = ca.id
                             and i.status in ('issued', 'payment_reported', 'overdue'))
      ) order by ca.name), '[]'::jsonb)
      from public.company_accounts ca where ca.status <> 'archived'),
    'pending_reviews', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', pc.id, 'invoice_id', pc.invoice_id, 'status', pc.status,
        'payment_method', pc.payment_method, 'paid_on', pc.paid_on,
        'reference_number', pc.reference_number, 'receipt_url', pc.receipt_url,
        'notes', pc.notes, 'created_at', pc.created_at,
        'submitted_by', (select cu.email from public.company_users cu where cu.id = pc.submitted_by),
        'company', (select jsonb_build_object('id', ca.id, 'name', ca.name)
                     from public.company_accounts ca where ca.id = pc.company_account_id),
        'invoice', (select jsonb_build_object('invoice_number', i.invoice_number, 'total', i.total,
                                              'currency', i.currency, 'status', i.status)
                     from public.invoices i where i.id = pc.invoice_id)
      ) order by pc.created_at), '[]'::jsonb)
      from public.payment_confirmations pc
      where pc.status in ('submitted', 'needs_clarification')),
    'requests', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', r.id, 'request_type', r.request_type, 'message', r.message,
        'status', r.status, 'created_at', r.created_at,
        'company', (select jsonb_build_object('id', ca.id, 'name', ca.name)
                     from public.company_accounts ca where ca.id = r.company_account_id),
        'requested_by', (select cu.email from public.company_users cu where cu.id = r.requested_by)
      ) order by r.created_at desc), '[]'::jsonb)
      from public.company_requests r
      where r.status in ('new', 'in_progress')),
    'recent_invoices', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', i.id, 'invoice_number', i.invoice_number,
        'status', public._invoice_effective_status(i.status, i.due_date),
        'total', i.total, 'currency', i.currency,
        'issue_date', i.issue_date, 'due_date', i.due_date,
        'company', (select jsonb_build_object('id', ca.id, 'name', ca.name)
                     from public.company_accounts ca where ca.id = i.company_account_id)
      ) order by i.created_at desc), '[]'::jsonb)
      from (select * from public.invoices order by created_at desc limit 60) i),
    'audit', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', a.id, 'actor_type', a.actor_type, 'actor_label', a.actor_label,
        'action', a.action, 'details', a.details, 'created_at', a.created_at,
        'company', (select ca.name from public.company_accounts ca where ca.id = a.company_account_id)
      ) order by a.created_at desc), '[]'::jsonb)
      from (select * from public.billing_audit_log order by created_at desc limit 100) a));
end;
$$;

-- Full detail for one company (admin drill-down).
create or replace function public.admin_get_company(p_admin_token text, p_company_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._is_admin(p_admin_token) then return null; end if;

  return (
    select jsonb_build_object(
      'company', to_jsonb(ca),
      'access', public.company_access_state(ca.id),
      'subscription', (select to_jsonb(s) from public.subscriptions s
                        where s.company_account_id = ca.id),
      'plan', (select to_jsonb(sp) from public.subscriptions s
                 join public.subscription_plans sp on sp.key = s.plan_key
                where s.company_account_id = ca.id),
      'locations', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', cl.id, 'place_id', cl.place_id, 'label', cl.label,
          'name', p.name, 'slug', p.slug, 'town', p.town,
          'approved_at', cl.approved_at) order by p.name), '[]'::jsonb)
        from public.company_locations cl
        left join public.places p on p.id = cl.place_id
        where cl.company_account_id = ca.id and cl.status = 'approved'),
      'users', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', cu.id, 'email', cu.email, 'name', cu.name, 'role', cu.role,
          'status', cu.status, 'linked', cu.user_id is not null) order by cu.created_at), '[]'::jsonb)
        from public.company_users cu
        where cu.company_account_id = ca.id and cu.status <> 'removed'),
      'entitlements', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', ce.id, 'key', ce.entitlement_key, 'source', ce.source,
          'is_active', ce.is_active, 'starts_at', ce.starts_at,
          'expires_at', ce.expires_at, 'notes', ce.notes) order by ce.entitlement_key), '[]'::jsonb)
        from public.company_entitlements ce where ce.company_account_id = ca.id),
      'invoices', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', i.id, 'invoice_number', i.invoice_number,
          'status', public._invoice_effective_status(i.status, i.due_date),
          'raw_status', i.status,
          'currency', i.currency, 'issue_date', i.issue_date, 'due_date', i.due_date,
          'period_start', i.period_start, 'period_end', i.period_end,
          'subtotal', i.subtotal, 'discount_amount', i.discount_amount,
          'discount_note', i.discount_note, 'total', i.total,
          'notes', i.notes, 'payment_instructions', i.payment_instructions,
          'internal_notes', i.internal_notes, 'paid_at', i.paid_at,
          'line_items', (
            select coalesce(jsonb_agg(to_jsonb(li) order by li.sort_order, li.created_at), '[]'::jsonb)
            from public.invoice_line_items li where li.invoice_id = i.id),
          'confirmations', (
            select coalesce(jsonb_agg(jsonb_build_object(
              'id', pc.id, 'status', pc.status, 'payment_method', pc.payment_method,
              'paid_on', pc.paid_on, 'reference_number', pc.reference_number,
              'receipt_url', pc.receipt_url, 'notes', pc.notes,
              'review_note', pc.review_note, 'created_at', pc.created_at)
              order by pc.created_at desc), '[]'::jsonb)
            from public.payment_confirmations pc where pc.invoice_id = i.id)
        ) order by i.created_at desc), '[]'::jsonb)
        from public.invoices i where i.company_account_id = ca.id),
      'requests', (
        select coalesce(jsonb_agg(to_jsonb(r) order by r.created_at desc), '[]'::jsonb)
        from public.company_requests r where r.company_account_id = ca.id),
      'audit', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'actor_type', a.actor_type, 'actor_label', a.actor_label, 'action', a.action,
          'details', a.details, 'created_at', a.created_at) order by a.created_at desc), '[]'::jsonb)
        from (select * from public.billing_audit_log
               where company_account_id = p_company_id
               order by created_at desc limit 100) a))
    from public.company_accounts ca where ca.id = p_company_id);
end;
$$;

-- Create / update a company account.
create or replace function public.admin_upsert_company(
  p_admin_token   text,
  p_company_id    uuid,            -- null to create
  p_name          text,
  p_billing_email text,
  p_contact_name  text default null,
  p_contact_phone text default null,
  p_status        text default 'active',
  p_notes         text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id    uuid;
  v_label text;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  if p_name is null or length(trim(p_name)) = 0 then
    return jsonb_build_object('ok', false, 'error', 'Company name is required');
  end if;
  if p_billing_email is null or position('@' in p_billing_email) = 0 then
    return jsonb_build_object('ok', false, 'error', 'A valid billing email is required');
  end if;
  if p_status not in ('active', 'suspended', 'archived') then
    return jsonb_build_object('ok', false, 'error', 'Invalid status');
  end if;
  v_label := public._admin_label(p_admin_token);

  if p_company_id is null then
    insert into public.company_accounts (name, billing_email, contact_name, contact_phone, status, notes)
    values (trim(p_name), lower(trim(p_billing_email)), p_contact_name, p_contact_phone, p_status, p_notes)
    returning id into v_id;
    perform public._billing_audit('admin', v_label, v_id, 'company_created',
      jsonb_build_object('name', trim(p_name)));
  else
    update public.company_accounts
       set name = trim(p_name),
           billing_email = lower(trim(p_billing_email)),
           contact_name = p_contact_name,
           contact_phone = p_contact_phone,
           status = p_status,
           notes = p_notes,
           updated_at = now()
     where id = p_company_id
    returning id into v_id;
    if v_id is null then return jsonb_build_object('ok', false, 'error', 'Company not found'); end if;
    perform public._billing_audit('admin', v_label, v_id, 'company_updated',
      jsonb_build_object('name', trim(p_name), 'status', p_status));
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- Place search for attaching locations.
create or replace function public.admin_search_places(p_admin_token text, p_query text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._is_admin(p_admin_token) then return null; end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'name', p.name, 'slug', p.slug, 'town', p.town, 'parish', p.parish)
      order by p.name), '[]'::jsonb)
    from (
      select * from public.places
       where name ilike '%' || coalesce(p_query, '') || '%'
       order by name limit 20) p);
end;
$$;

-- Attach an approved location (ADMIN ONLY — no company path).
create or replace function public.admin_attach_location(
  p_admin_token text,
  p_company_id  uuid,
  p_place_id    uuid,
  p_label       text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label text;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  v_label := public._admin_label(p_admin_token);

  insert into public.company_locations (company_account_id, place_id, label, approved_by)
  values (p_company_id, p_place_id, nullif(trim(coalesce(p_label, '')), ''), v_label)
  on conflict (company_account_id, place_id) do update
    set status = 'approved', approved_at = now(), approved_by = v_label,
        label = coalesce(excluded.label, public.company_locations.label);

  perform public._billing_audit('admin', v_label, p_company_id, 'location_attached',
    jsonb_build_object('place_id', p_place_id));
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.admin_detach_location(
  p_admin_token text,
  p_company_id  uuid,
  p_place_id    uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label text;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  v_label := public._admin_label(p_admin_token);

  update public.company_locations
     set status = 'removed'
   where company_account_id = p_company_id and place_id = p_place_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'Location not attached'); end if;

  perform public._billing_audit('admin', v_label, p_company_id, 'location_detached',
    jsonb_build_object('place_id', p_place_id));
  return jsonb_build_object('ok', true);
end;
$$;

-- Add / update a company user (dashboard sign-in by email).
create or replace function public.admin_upsert_company_user(
  p_admin_token text,
  p_company_id  uuid,
  p_email       text,
  p_name        text default null,
  p_role        text default 'admin'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label text;
  v_id    uuid;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  if p_email is null or position('@' in p_email) = 0 then
    return jsonb_build_object('ok', false, 'error', 'A valid email is required');
  end if;
  if p_role not in ('admin', 'member') then
    return jsonb_build_object('ok', false, 'error', 'Invalid role');
  end if;
  v_label := public._admin_label(p_admin_token);

  insert into public.company_users (company_account_id, email, name, role)
  values (p_company_id, lower(trim(p_email)), p_name, p_role)
  on conflict (company_account_id, email) do update
    set name = coalesce(excluded.name, public.company_users.name),
        role = excluded.role,
        status = case when public.company_users.status = 'removed'
                      then 'invited' else public.company_users.status end,
        updated_at = now()
  returning id into v_id;

  perform public._billing_audit('admin', v_label, p_company_id, 'company_user_upserted',
    jsonb_build_object('email', lower(trim(p_email)), 'role', p_role));
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function public.admin_remove_company_user(
  p_admin_token     text,
  p_company_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label text;
  v_row   company_users%rowtype;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  v_label := public._admin_label(p_admin_token);

  update public.company_users
     set status = 'removed', updated_at = now()
   where id = p_company_user_id
  returning * into v_row;
  if v_row.id is null then return jsonb_build_object('ok', false, 'error', 'User not found'); end if;

  perform public._billing_audit('admin', v_label, v_row.company_account_id,
    'company_user_removed', jsonb_build_object('email', v_row.email));
  return jsonb_build_object('ok', true);
end;
$$;

-- Create or update a DRAFT invoice. p_invoice shape:
-- { "company_account_id": "...", "currency": "USD",
--   "issue_date": "...", "due_date": "...",
--   "period_start": "...", "period_end": "...",
--   "discount_amount": 0, "discount_note": "...",
--   "notes": "...", "payment_instructions": "...", "internal_notes": "...",
--   "line_items": [ { "item_type": "...", "product_code": "...",
--       "description": "...", "quantity": 1, "unit_amount": 588,
--       "period_start": null, "period_end": null,
--       "metadata": {"plan_key": "fp_single", "billing_cycle": "annual"} } ] }
create or replace function public.admin_save_invoice(
  p_admin_token text,
  p_invoice_id  uuid,          -- null to create
  p_invoice     jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label    text;
  v_inv      invoices%rowtype;
  v_id       uuid := p_invoice_id;
  v_line     jsonb;
  v_subtotal numeric := 0;
  v_discount numeric := coalesce((p_invoice ->> 'discount_amount')::numeric, 0);
  v_i        integer := 0;
  v_qty      numeric;
  v_unit     numeric;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  v_label := public._admin_label(p_admin_token);

  if v_id is not null then
    select * into v_inv from public.invoices where id = v_id;
    if v_inv.id is null then return jsonb_build_object('ok', false, 'error', 'Invoice not found'); end if;
    if v_inv.status <> 'draft' then
      return jsonb_build_object('ok', false, 'error', 'Only draft invoices can be edited');
    end if;
  end if;

  if jsonb_typeof(p_invoice -> 'line_items') is distinct from 'array'
     or jsonb_array_length(p_invoice -> 'line_items') = 0 then
    return jsonb_build_object('ok', false, 'error', 'At least one line item is required');
  end if;

  for v_line in select * from jsonb_array_elements(p_invoice -> 'line_items')
  loop
    v_qty  := coalesce((v_line ->> 'quantity')::numeric, 1);
    v_unit := coalesce((v_line ->> 'unit_amount')::numeric, 0);
    v_subtotal := v_subtotal + round(v_qty * v_unit, 2);
  end loop;

  if v_id is null then
    insert into public.invoices
      (company_account_id, currency, issue_date, due_date, period_start, period_end,
       subtotal, discount_amount, discount_note, total,
       notes, payment_instructions, internal_notes)
    values
      ((p_invoice ->> 'company_account_id')::uuid,
       coalesce(nullif(trim(coalesce(p_invoice ->> 'currency', '')), ''), 'USD'),
       (p_invoice ->> 'issue_date')::date,
       (p_invoice ->> 'due_date')::date,
       (p_invoice ->> 'period_start')::date,
       (p_invoice ->> 'period_end')::date,
       v_subtotal, v_discount, p_invoice ->> 'discount_note',
       round(v_subtotal - v_discount, 2),
       p_invoice ->> 'notes', p_invoice ->> 'payment_instructions',
       p_invoice ->> 'internal_notes')
    returning * into v_inv;
    v_id := v_inv.id;
  else
    update public.invoices
       set currency = coalesce(nullif(trim(coalesce(p_invoice ->> 'currency', '')), ''), 'USD'),
           issue_date = (p_invoice ->> 'issue_date')::date,
           due_date = (p_invoice ->> 'due_date')::date,
           period_start = (p_invoice ->> 'period_start')::date,
           period_end = (p_invoice ->> 'period_end')::date,
           subtotal = v_subtotal,
           discount_amount = v_discount,
           discount_note = p_invoice ->> 'discount_note',
           total = round(v_subtotal - v_discount, 2),
           notes = p_invoice ->> 'notes',
           payment_instructions = p_invoice ->> 'payment_instructions',
           internal_notes = p_invoice ->> 'internal_notes',
           updated_at = now()
     where id = v_id;
    delete from public.invoice_line_items where invoice_id = v_id;
  end if;

  for v_line in select * from jsonb_array_elements(p_invoice -> 'line_items')
  loop
    v_i := v_i + 1;
    v_qty  := coalesce((v_line ->> 'quantity')::numeric, 1);
    v_unit := coalesce((v_line ->> 'unit_amount')::numeric, 0);
    insert into public.invoice_line_items
      (invoice_id, item_type, product_code, description, quantity, unit_amount,
       amount, period_start, period_end, metadata, sort_order)
    values
      (v_id,
       v_line ->> 'item_type',
       nullif(trim(coalesce(v_line ->> 'product_code', '')), ''),
       coalesce(nullif(trim(coalesce(v_line ->> 'description', '')), ''), 'Line item'),
       v_qty, v_unit, round(v_qty * v_unit, 2),
       (v_line ->> 'period_start')::date,
       (v_line ->> 'period_end')::date,
       coalesce(v_line -> 'metadata', '{}'::jsonb),
       v_i);
  end loop;

  perform public._billing_audit('admin', v_label, v_inv.company_account_id,
    case when p_invoice_id is null then 'invoice_draft_created' else 'invoice_draft_updated' end,
    jsonb_build_object('invoice_id', v_id, 'total', round(v_subtotal - v_discount, 2)),
    v_id, null);

  return jsonb_build_object('ok', true, 'id', v_id,
    'subtotal', v_subtotal, 'total', round(v_subtotal - v_discount, 2));
end;
$$;

-- Issue a draft invoice: assigns the invoice number, stamps dates,
-- and flags a pending subscription if a plan line is present.
create or replace function public.admin_issue_invoice(p_admin_token text, p_invoice_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label text;
  v_inv   invoices%rowtype;
  v_num   text;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  v_label := public._admin_label(p_admin_token);

  select * into v_inv from public.invoices where id = p_invoice_id for update;
  if v_inv.id is null then return jsonb_build_object('ok', false, 'error', 'Invoice not found'); end if;

  begin
    perform public._assert_invoice_transition(v_inv.status, 'issued');
  exception when others then
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;

  v_num := coalesce(v_inv.invoice_number, public.next_invoice_number());

  update public.invoices
     set status = 'issued',
         invoice_number = v_num,
         issue_date = coalesce(issue_date, current_date),
         due_date = coalesce(due_date, current_date + 14),
         issued_at = now(),
         updated_at = now()
   where id = p_invoice_id;

  -- Subscription invoice issued -> pending subscription row exists
  -- in invoice_issued state (no access change for already-active subs).
  if exists (select 1 from public.invoice_line_items
              where invoice_id = p_invoice_id
                and item_type = 'founding_partner_subscription') then
    insert into public.subscriptions (company_account_id, status)
    values (v_inv.company_account_id, 'invoice_issued')
    on conflict (company_account_id) do nothing;
  end if;

  perform public._billing_audit('admin', v_label, v_inv.company_account_id,
    'invoice_issued', jsonb_build_object('invoice_number', v_num), p_invoice_id, null);

  return jsonb_build_object('ok', true, 'invoice_number', v_num);
end;
$$;

-- Review a company payment confirmation.
-- decision: 'approve' | 'reject' | 'clarify'
-- APPROVAL IS THE ONLY PATH THAT ACTIVATES ACCESS.
create or replace function public.admin_review_payment(
  p_admin_token     text,
  p_confirmation_id uuid,
  p_decision        text,
  p_note            text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label text;
  v_conf  payment_confirmations%rowtype;
  v_inv   invoices%rowtype;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  if p_decision not in ('approve', 'reject', 'clarify') then
    return jsonb_build_object('ok', false, 'error', 'Invalid decision');
  end if;
  v_label := public._admin_label(p_admin_token);

  select * into v_conf from public.payment_confirmations where id = p_confirmation_id for update;
  if v_conf.id is null then return jsonb_build_object('ok', false, 'error', 'Confirmation not found'); end if;
  if v_conf.status not in ('submitted', 'needs_clarification') then
    return jsonb_build_object('ok', false, 'error', 'This confirmation was already reviewed');
  end if;

  select * into v_inv from public.invoices where id = v_conf.invoice_id for update;

  if p_decision = 'approve' then
    begin
      perform public._assert_invoice_transition(v_inv.status, 'paid');
    exception when others then
      return jsonb_build_object('ok', false, 'error', sqlerrm);
    end;

    update public.payment_confirmations
       set status = 'approved', review_note = p_note, reviewed_at = now(), reviewed_by = v_label
     where id = v_conf.id;

    update public.invoices
       set status = 'paid', paid_at = now(), updated_at = now()
     where id = v_inv.id;

    perform public._billing_audit('admin', v_label, v_inv.company_account_id,
      'payment_approved', jsonb_build_object('confirmation_id', v_conf.id,
        'invoice_number', v_inv.invoice_number), v_inv.id, null);

    perform public._activate_paid_invoice(v_inv.id, v_label);
    return jsonb_build_object('ok', true, 'invoice_status', 'paid');

  elsif p_decision = 'reject' then
    begin
      perform public._assert_invoice_transition(v_inv.status, 'rejected');
    exception when others then
      return jsonb_build_object('ok', false, 'error', sqlerrm);
    end;

    update public.payment_confirmations
       set status = 'rejected', review_note = p_note, reviewed_at = now(), reviewed_by = v_label
     where id = v_conf.id;

    update public.invoices set status = 'rejected', updated_at = now() where id = v_inv.id;

    -- Pull the subscription back out of pending-review.
    update public.subscriptions
       set status = 'invoice_issued', updated_at = now()
     where company_account_id = v_inv.company_account_id
       and status = 'payment_pending_review';

    perform public._billing_audit('admin', v_label, v_inv.company_account_id,
      'payment_rejected', jsonb_build_object('confirmation_id', v_conf.id, 'note', p_note),
      v_inv.id, null);
    return jsonb_build_object('ok', true, 'invoice_status', 'rejected');

  else -- clarify: invoice stays payment_reported; company can resubmit.
    update public.payment_confirmations
       set status = 'needs_clarification', review_note = p_note, reviewed_at = now(), reviewed_by = v_label
     where id = v_conf.id;

    perform public._billing_audit('admin', v_label, v_inv.company_account_id,
      'payment_clarification_requested',
      jsonb_build_object('confirmation_id', v_conf.id, 'note', p_note), v_inv.id, null);
    return jsonb_build_object('ok', true, 'invoice_status', v_inv.status);
  end if;
end;
$$;

-- Manual invoice status changes (void, mark overdue, direct paid
-- when payment was verified out-of-band, e.g. seen on the bank
-- statement before the company reported it).
create or replace function public.admin_set_invoice_status(
  p_admin_token text,
  p_invoice_id  uuid,
  p_status      text,
  p_note        text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label text;
  v_inv   invoices%rowtype;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  if p_status not in ('issued', 'paid', 'rejected', 'void', 'overdue') then
    return jsonb_build_object('ok', false, 'error', 'Invalid status');
  end if;
  v_label := public._admin_label(p_admin_token);

  select * into v_inv from public.invoices where id = p_invoice_id for update;
  if v_inv.id is null then return jsonb_build_object('ok', false, 'error', 'Invoice not found'); end if;

  begin
    perform public._assert_invoice_transition(v_inv.status, p_status);
  exception when others then
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;

  update public.invoices
     set status = p_status,
         paid_at = case when p_status = 'paid' then now() else paid_at end,
         internal_notes = case when p_note is null then internal_notes
           else coalesce(internal_notes || e'\n', '') || p_note end,
         updated_at = now()
   where id = p_invoice_id;

  perform public._billing_audit('admin', v_label, v_inv.company_account_id,
    'invoice_status_set', jsonb_build_object('from', v_inv.status, 'to', p_status, 'note', p_note),
    p_invoice_id, null);

  if p_status = 'paid' then
    perform public._activate_paid_invoice(p_invoice_id, v_label);
  end if;

  return jsonb_build_object('ok', true, 'status', p_status);
end;
$$;

-- Manual subscription control: activate / revoke / cancel / expire /
-- read_only, and paid-through adjustments. Admin only; this is the
-- "manually adjust paid-through dates" tool — no automatic backfill
-- ever happens elsewhere.
create or replace function public.admin_set_subscription(
  p_admin_token   text,
  p_company_id    uuid,
  p_action        text,           -- 'activate' | 'revoke' | 'cancel' | 'expire' | 'read_only' | 'adjust_paid_through'
  p_plan_key      text default null,
  p_billing_cycle text default null,
  p_paid_through  date default null,
  p_note          text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label text;
  v_sub   subscriptions%rowtype;
  v_plan  subscription_plans%rowtype;
  v_key   text;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  if p_action not in ('activate', 'revoke', 'cancel', 'expire', 'read_only', 'adjust_paid_through') then
    return jsonb_build_object('ok', false, 'error', 'Invalid action');
  end if;
  v_label := public._admin_label(p_admin_token);

  select * into v_sub from public.subscriptions where company_account_id = p_company_id for update;

  if p_action = 'activate' then
    select * into v_plan from public.subscription_plans
     where key = coalesce(p_plan_key, v_sub.plan_key);

    insert into public.subscriptions
      (company_account_id, plan_key, billing_cycle, status, current_period_start, paid_through, activated_at)
    values
      (p_company_id, v_plan.key, coalesce(p_billing_cycle, 'annual'), 'active',
       current_date, p_paid_through, now())
    on conflict (company_account_id) do update
      set plan_key = coalesce(v_plan.key, public.subscriptions.plan_key),
          billing_cycle = coalesce(p_billing_cycle, public.subscriptions.billing_cycle),
          status = 'active',
          paid_through = coalesce(p_paid_through, public.subscriptions.paid_through),
          activated_at = coalesce(public.subscriptions.activated_at, now()),
          canceled_at = null,
          updated_at = now();

    if v_plan.key is not null then
      for v_key in select jsonb_array_elements_text(v_plan.entitlements)
      loop
        perform public._grant_entitlement(p_company_id, v_key, 'plan',
          current_date, coalesce(p_paid_through, v_sub.paid_through), null,
          'Manual activation by ' || v_label);
      end loop;
    end if;

  elsif p_action = 'adjust_paid_through' then
    if v_sub.id is null then
      return jsonb_build_object('ok', false, 'error', 'No subscription exists for this company');
    end if;
    if p_paid_through is null then
      return jsonb_build_object('ok', false, 'error', 'A paid-through date is required');
    end if;
    update public.subscriptions
       set paid_through = p_paid_through, updated_at = now()
     where company_account_id = p_company_id;
    -- Keep plan entitlements in step with the adjusted window.
    update public.company_entitlements
       set expires_at = p_paid_through, updated_at = now()
     where company_account_id = p_company_id and source = 'plan';

  else -- revoke / cancel / expire / read_only
    if v_sub.id is null then
      return jsonb_build_object('ok', false, 'error', 'No subscription exists for this company');
    end if;
    update public.subscriptions
       set status = case p_action when 'revoke' then 'canceled'
                                  when 'cancel' then 'canceled'
                                  when 'expire' then 'expired'
                                  else 'read_only' end,
           canceled_at = case when p_action in ('revoke', 'cancel') then now() else canceled_at end,
           updated_at = now()
     where company_account_id = p_company_id;

    if p_action = 'revoke' then
      -- Hard revoke also deactivates entitlements.
      update public.company_entitlements
         set is_active = false, updated_at = now()
       where company_account_id = p_company_id;
    end if;
  end if;

  perform public._billing_audit('admin', v_label, p_company_id, 'subscription_' || p_action,
    jsonb_build_object('plan_key', p_plan_key, 'billing_cycle', p_billing_cycle,
                       'paid_through', p_paid_through, 'note', p_note),
    null, v_sub.id);

  return jsonb_build_object('ok', true, 'access', public.company_access_state(p_company_id));
end;
$$;

-- Toggle a single entitlement manually.
create or replace function public.admin_set_entitlement(
  p_admin_token text,
  p_company_id  uuid,
  p_key         text,
  p_active      boolean,
  p_expires_at  date default null,
  p_note        text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label text;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  v_label := public._admin_label(p_admin_token);

  if p_active then
    perform public._grant_entitlement(p_company_id, p_key, 'manual',
      current_date, p_expires_at, null, coalesce(p_note, 'Manual grant by ' || v_label));
  else
    update public.company_entitlements
       set is_active = false, updated_at = now()
     where company_account_id = p_company_id and entitlement_key = p_key;
  end if;

  perform public._billing_audit('admin', v_label, p_company_id,
    case when p_active then 'entitlement_granted' else 'entitlement_revoked' end,
    jsonb_build_object('key', p_key, 'expires_at', p_expires_at, 'note', p_note));

  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.admin_set_request_status(
  p_admin_token text,
  p_request_id  uuid,
  p_status      text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label text;
  v_row   company_requests%rowtype;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  if p_status not in ('new', 'in_progress', 'resolved') then
    return jsonb_build_object('ok', false, 'error', 'Invalid status');
  end if;
  v_label := public._admin_label(p_admin_token);

  update public.company_requests
     set status = p_status,
         resolved_at = case when p_status = 'resolved' then now() else resolved_at end
   where id = p_request_id
  returning * into v_row;
  if v_row.id is null then return jsonb_build_object('ok', false, 'error', 'Request not found'); end if;

  perform public._billing_audit('admin', v_label, v_row.company_account_id,
    'request_status_set', jsonb_build_object('request_id', p_request_id, 'status', p_status));
  return jsonb_build_object('ok', true);
end;
$$;

-- ============================================================
-- GRANTS
-- ============================================================
-- Internal helpers must NOT be callable through PostgREST
-- (Postgres grants EXECUTE to PUBLIC on new functions by default).
revoke execute on function public._billing_audit(text, text, uuid, text, jsonb, uuid, uuid) from public, anon, authenticated;
revoke execute on function public._admin_label(text) from public, anon, authenticated;
revoke execute on function public.next_invoice_number() from public, anon, authenticated;
revoke execute on function public._assert_invoice_transition(text, text) from public, anon, authenticated;
revoke execute on function public._resolve_company_user() from public, anon, authenticated;
revoke execute on function public._grant_entitlement(uuid, text, text, date, date, uuid, text) from public, anon, authenticated;
revoke execute on function public._activate_paid_invoice(uuid, text) from public, anon, authenticated;
revoke execute on function public._submit_payment_confirmation(uuid, uuid, text, date, text, text, text) from public, anon, authenticated;
revoke execute on function public._invoice_effective_status(text, date) from public, anon, authenticated;
revoke execute on function public.company_access_state(uuid) from public, anon;
revoke execute on function public.company_has_entitlement(uuid, text) from public, anon;

-- Company (Supabase auth) RPCs
grant execute on function public.get_company_billing() to authenticated;
grant execute on function public.get_my_entitlements() to authenticated;
grant execute on function public.submit_payment_confirmation(uuid, text, date, text, text, text) to authenticated;
grant execute on function public.submit_billing_request(text, text) to authenticated;

-- Admin (token-checked) RPCs — same anon model as admin-review.sql
grant execute on function public.admin_get_billing_catalog(text) to anon, authenticated;
grant execute on function public.admin_billing_overview(text) to anon, authenticated;
grant execute on function public.admin_get_company(text, uuid) to anon, authenticated;
grant execute on function public.admin_upsert_company(text, uuid, text, text, text, text, text, text) to anon, authenticated;
grant execute on function public.admin_search_places(text, text) to anon, authenticated;
grant execute on function public.admin_attach_location(text, uuid, uuid, text) to anon, authenticated;
grant execute on function public.admin_detach_location(text, uuid, uuid) to anon, authenticated;
grant execute on function public.admin_upsert_company_user(text, uuid, text, text, text) to anon, authenticated;
grant execute on function public.admin_remove_company_user(text, uuid) to anon, authenticated;
grant execute on function public.admin_save_invoice(text, uuid, jsonb) to anon, authenticated;
grant execute on function public.admin_issue_invoice(text, uuid) to anon, authenticated;
grant execute on function public.admin_review_payment(text, uuid, text, text) to anon, authenticated;
grant execute on function public.admin_set_invoice_status(text, uuid, text, text) to anon, authenticated;
grant execute on function public.admin_set_subscription(text, uuid, text, text, text, date, text) to anon, authenticated;
grant execute on function public.admin_set_entitlement(text, uuid, text, boolean, date, text) to anon, authenticated;
grant execute on function public.admin_set_request_status(text, uuid, text) to anon, authenticated;

-- Access checks usable by other backend code / authenticated clients
grant execute on function public.company_has_entitlement(uuid, text) to authenticated;
grant execute on function public.company_access_state(uuid) to authenticated;
