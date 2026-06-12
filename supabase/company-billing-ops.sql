-- ============================================================
-- TRODDR Company Billing — Business Operations Layer
-- ------------------------------------------------------------
-- Follow-up to company-billing.sql (+ seed). Adds:
--   1.  Company account typing (real commercial entities)
--   2.  company_events ownership (host/organizer/sponsor/...)
--   3.  Admin-configurable payment instructions (per currency)
--   4.  Editable invoice footer copy + billing settings
--   5.  Onboarding (billing info) + company setup requests
--   6.  Notification records + admin queue (email behind an
--       abstraction: rows are written here, a sender drains them)
--   7.  Renewal operations (reminder window, renewal drafts,
--       overdue marking, read-only lapse)
--   8.  Secure receipt uploads (private bucket, company-scoped)
--   9.  Expanded request workflow (quoted/invoiced/... + links)
--   10. Reason-required admin overrides + audit coverage
--   11. Event-dashboard billing RPC (token-based, read-only)
--
-- Run AFTER company-billing.sql + company-billing-seed.sql.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Company accounts: real commercial entities + billing info
-- ------------------------------------------------------------
alter table public.company_accounts
  add column if not exists account_type text not null default 'hospitality_group'
    check (account_type in ('hospitality_group', 'event_host', 'sponsor', 'mixed')),
  add column if not exists source_type text not null default 'manual'
    check (source_type in ('place_group', 'event_organizer', 'sponsor', 'manual')),
  add column if not exists source_id uuid,
  -- Billing / onboarding info
  add column if not exists legal_name         text,
  add column if not exists trading_name       text,
  add column if not exists billing_phone      text,
  add column if not exists country            text,
  add column if not exists address            text,
  add column if not exists tax_id             text,    -- VAT/GCT/TRN — optional for now
  add column if not exists preferred_currency text not null default 'USD'
    check (preferred_currency in ('USD', 'JMD')),
  add column if not exists onboarding_status  text not null default 'billing_info_required'
    check (onboarding_status in ('not_started', 'pending_company_review',
                                 'billing_info_required', 'complete')),
  add column if not exists onboarded_by_role  text;     -- role/title of person who completed onboarding

-- ------------------------------------------------------------
-- 2. Company event ownership (ADMIN-ATTACHED ONLY)
-- ------------------------------------------------------------
create table if not exists public.company_events (
  id                 uuid primary key default gen_random_uuid(),
  company_account_id uuid not null references public.company_accounts(id) on delete cascade,
  event_id           uuid not null references public.events(id) on delete cascade,
  relationship_type  text not null default 'host'
    check (relationship_type in ('host', 'organizer', 'sponsor', 'vendor', 'production_partner')),
  status             text not null default 'approved'
    check (status in ('pending', 'approved', 'inactive', 'removed')),
  -- Founding-partner style comped event hubs: access is free but
  -- insights/maps still show unpaid unless purchased separately.
  comped               boolean not null default false,
  package_product_code text references public.billing_products(code),
  approved_by        text,
  approved_at        timestamptz,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),
  unique (company_account_id, event_id, relationship_type)
);

create index if not exists company_events_company_idx on public.company_events(company_account_id);
create index if not exists company_events_event_idx   on public.company_events(event_id);

alter table public.company_events enable row level security;
-- No policies: admin RPCs only. Company users can never write here.

-- ------------------------------------------------------------
-- 3. Payment instructions (admin-managed, per currency)
--    NO account numbers in source code: seeded null, admin fills
--    them in from the panel.
-- ------------------------------------------------------------
create table if not exists public.payment_instructions (
  id               uuid primary key default gen_random_uuid(),
  bank_name        text not null,
  account_name     text not null,
  branch_name      text,
  currency         text not null check (currency in ('USD', 'JMD')),
  account_type     text,                -- 'Savings', 'Chequing', ...
  account_number   text,                -- entered by admin in the panel, never seeded
  routing_or_swift text,
  payment_notes    text,
  active           boolean not null default true,
  display_order    integer not null default 0,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

alter table public.payment_instructions enable row level security;

insert into public.payment_instructions
  (bank_name, account_name, branch_name, currency, account_type, payment_notes, display_order)
select * from (values
  ('CIBC Caribbean', 'TRODDR Limited', 'Manor Park Branch', 'USD', 'Savings',
   'Account number is provided on your invoice or by emailing billing@troddr.com.', 1),
  ('CIBC Caribbean', 'TRODDR Limited', 'Manor Park Branch', 'JMD', 'Chequing',
   'Account number is provided on your invoice or by emailing billing@troddr.com.', 2)
) as seed(bank_name, account_name, branch_name, currency, account_type, payment_notes, display_order)
where not exists (select 1 from public.payment_instructions);

-- Active instructions for an invoice currency (non-sensitive-safe:
-- account_number may be null and the UI shows the note instead).
create or replace function public.payment_instructions_for_currency(p_currency text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', pi.id, 'bank_name', pi.bank_name, 'account_name', pi.account_name,
    'branch_name', pi.branch_name, 'currency', pi.currency,
    'account_type', pi.account_type, 'account_number', pi.account_number,
    'routing_or_swift', pi.routing_or_swift, 'payment_notes', pi.payment_notes
  ) order by pi.display_order), '[]'::jsonb)
  from public.payment_instructions pi
  where pi.active = true
    and pi.currency = coalesce(p_currency, 'USD');
$$;

-- ------------------------------------------------------------
-- 4. Billing settings (invoice copy, renewal window, receipts)
-- ------------------------------------------------------------
create table if not exists public.billing_settings (
  key        text primary key,
  value      jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.billing_settings enable row level security;

insert into public.billing_settings (key, value) values
  ('invoice_footer_copy', jsonb_build_array(
    'Access is activated after payment verification by TRODDR.',
    'Please include the invoice number in your payment reference.',
    'After payment, return to your dashboard and submit your payment confirmation.',
    'User-reported payment does not activate access until reviewed by TRODDR.')),
  ('renewal_reminder_days', to_jsonb(30)),
  ('receipt_max_mb', to_jsonb(10)),
  ('receipt_allowed_types', jsonb_build_array('pdf', 'jpg', 'jpeg', 'png')),
  ('onsite_support_reference',
    to_jsonb('Onsite support is not in standard packages: USD $750-$1,000/day per person, plus credentials, access, transport, meals. Add as a custom line item when requested.'::text))
on conflict (key) do nothing;

create or replace function public._billing_setting(p_key text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  select value from public.billing_settings where key = p_key;
$$;

-- ------------------------------------------------------------
-- 5. Company setup requests (user-initiated onboarding when no
--    company exists yet — admin reviews and approves/creates)
-- ------------------------------------------------------------
create table if not exists public.company_setup_requests (
  id                 uuid primary key default gen_random_uuid(),
  user_id            uuid,                       -- auth.users id of submitter
  email              text not null,
  legal_name         text not null,
  trading_name       text,
  contact_name       text,
  billing_phone      text,
  country            text,
  address            text,
  tax_id             text,
  preferred_currency text not null default 'USD' check (preferred_currency in ('USD', 'JMD')),
  business_type      text not null default 'hospitality_group'
    check (business_type in ('hospitality_group', 'event_host', 'sponsor', 'mixed')),
  role_title         text,
  message            text,
  status             text not null default 'pending_review'
    check (status in ('pending_review', 'approved', 'rejected')),
  review_note        text,
  reviewed_by        text,
  reviewed_at        timestamptz,
  created_company_id uuid references public.company_accounts(id) on delete set null,
  created_at         timestamptz not null default now()
);

create index if not exists company_setup_requests_user_idx on public.company_setup_requests(user_id);
alter table public.company_setup_requests enable row level security;

-- ------------------------------------------------------------
-- 6. Notification records (email behind a service abstraction:
--    rows are created here; an edge function / future mailer
--    drains status='pending'. Admin panel shows the queue.)
-- ------------------------------------------------------------
create table if not exists public.billing_notifications (
  id                 uuid primary key default gen_random_uuid(),
  notification_type  text not null check (notification_type in (
                       'invoice_issued', 'invoice_overdue', 'payment_reported',
                       'payment_approved', 'payment_rejected', 'clarification_requested',
                       'subscription_activated', 'subscription_read_only',
                       'renewal_invoice_generated', 'request_submitted',
                       'company_setup_request')),
  company_account_id uuid references public.company_accounts(id) on delete set null,
  invoice_id         uuid,
  request_id         uuid,
  recipient_email    text,
  subject            text not null,
  body               text,
  status             text not null default 'pending'
    check (status in ('pending', 'sent', 'failed', 'dismissed')),
  created_at         timestamptz not null default now(),
  sent_at            timestamptz
);

create index if not exists billing_notifications_status_idx
  on public.billing_notifications(status, created_at);

alter table public.billing_notifications enable row level security;

create or replace function public._billing_notify(
  p_type       text,
  p_company_id uuid,
  p_subject    text,
  p_body       text default null,
  p_invoice_id uuid default null,
  p_request_id uuid default null
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_email text;
begin
  select billing_email into v_email from public.company_accounts where id = p_company_id;
  insert into public.billing_notifications
    (notification_type, company_account_id, invoice_id, request_id, recipient_email, subject, body)
  values (p_type, p_company_id, p_invoice_id, p_request_id, v_email, p_subject, p_body);
exception when others then
  -- Notifications must never break the business action.
  raise warning 'billing notification failed: %', sqlerrm;
end;
$$;

-- Triggers create notifications wherever the lifecycle moves, so
-- every path (RPC or manual SQL) produces a record.
create or replace function public._trg_invoice_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label text := coalesce(new.invoice_number, 'Invoice');
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    if new.status = 'issued' and old.status = 'draft' then
      perform public._billing_notify('invoice_issued', new.company_account_id,
        v_label || ' issued — ' || new.currency || ' ' || new.total,
        'Invoice ' || v_label || ' has been issued. Due ' || coalesce(new.due_date::text, 'on receipt') || '.',
        new.id);
    elsif new.status = 'overdue' then
      perform public._billing_notify('invoice_overdue', new.company_account_id,
        v_label || ' is overdue',
        'Invoice ' || v_label || ' passed its due date (' || coalesce(new.due_date::text, '?') || ') without verified payment.',
        new.id);
    elsif new.status = 'payment_reported' then
      perform public._billing_notify('payment_reported', new.company_account_id,
        'Payment reported for ' || v_label,
        'The company reported payment for ' || v_label || '. Review it in the admin billing console.',
        new.id);
    elsif new.status = 'paid' then
      perform public._billing_notify('payment_approved', new.company_account_id,
        'Payment verified for ' || v_label,
        'TRODDR verified the payment for ' || v_label || '. Access has been activated.',
        new.id);
    elsif new.status = 'rejected' then
      perform public._billing_notify('payment_rejected', new.company_account_id,
        'Payment could not be verified for ' || v_label,
        'The reported payment for ' || v_label || ' was rejected. See the note in your dashboard and resubmit.',
        new.id);
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists invoices_notify on public.invoices;
create trigger invoices_notify
  after update on public.invoices
  for each row execute function public._trg_invoice_notify();

create or replace function public._trg_confirmation_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and new.status = 'needs_clarification'
     and old.status is distinct from new.status then
    perform public._billing_notify('clarification_requested', new.company_account_id,
      'TRODDR needs clarification on your payment',
      coalesce(new.review_note, 'Please review your payment confirmation and resubmit.'),
      new.invoice_id);
  end if;
  return new;
end;
$$;

drop trigger if exists payment_confirmations_notify on public.payment_confirmations;
create trigger payment_confirmations_notify
  after update on public.payment_confirmations
  for each row execute function public._trg_confirmation_notify();

create or replace function public._trg_subscription_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if tg_op = 'UPDATE' and new.status is distinct from old.status then
    if new.status = 'active' then
      perform public._billing_notify('subscription_activated', new.company_account_id,
        'Subscription activated',
        'Your TRODDR subscription is active' ||
        coalesce(' through ' || new.paid_through::text, '') || '.');
    elsif new.status = 'read_only' then
      perform public._billing_notify('subscription_read_only', new.company_account_id,
        'Account moved to read-only',
        'Your paid-through date has passed. The dashboard is read-only until a renewal payment is verified.');
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists subscriptions_notify on public.subscriptions;
create trigger subscriptions_notify
  after update on public.subscriptions
  for each row execute function public._trg_subscription_notify();

create or replace function public._trg_request_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._billing_notify('request_submitted', new.company_account_id,
    'New company request: ' || replace(new.request_type, '_', ' '),
    coalesce(new.message, ''), null, new.id);
  return new;
end;
$$;

drop trigger if exists company_requests_notify on public.company_requests;
create trigger company_requests_notify
  after insert on public.company_requests
  for each row execute function public._trg_request_notify();

create or replace function public._trg_setup_request_notify()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.billing_notifications
    (notification_type, recipient_email, subject, body, request_id)
  values ('company_setup_request', new.email,
          'New company setup request: ' || new.legal_name,
          coalesce(new.message, ''), new.id);
  return new;
end;
$$;

drop trigger if exists company_setup_requests_notify on public.company_setup_requests;
create trigger company_setup_requests_notify
  after insert on public.company_setup_requests
  for each row execute function public._trg_setup_request_notify();

-- ------------------------------------------------------------
-- 7. Request workflow expansion
-- ------------------------------------------------------------
alter table public.company_requests
  add column if not exists related_location_id uuid references public.company_locations(id) on delete set null,
  add column if not exists related_event_id    uuid references public.events(id) on delete set null,
  add column if not exists admin_notes         text;

alter table public.company_requests drop constraint if exists company_requests_status_check;
update public.company_requests set status = 'in_review' where status = 'in_progress';
update public.company_requests set status = 'completed' where status = 'resolved';
alter table public.company_requests add constraint company_requests_status_check
  check (status in ('new', 'in_review', 'quoted', 'invoiced', 'completed', 'rejected'));

alter table public.company_requests drop constraint if exists company_requests_request_type_check;
alter table public.company_requests add constraint company_requests_request_type_check
  check (request_type in ('extra_admins', 'insights', 'location_insights', 'company_insights',
                          'event_coverage', 'event_insights',
                          'sponsor_activation', 'sponsor_report', 'billing_help', 'other'));

create or replace function public._assert_request_transition(p_from text, p_to text)
returns void
language plpgsql
as $$
declare v_ok boolean;
begin
  if p_from = p_to then return; end if;
  v_ok := case p_from
    when 'new'       then p_to in ('in_review', 'quoted', 'invoiced', 'completed', 'rejected')
    when 'in_review' then p_to in ('quoted', 'invoiced', 'completed', 'rejected')
    when 'quoted'    then p_to in ('invoiced', 'completed', 'rejected')
    when 'invoiced'  then p_to in ('completed', 'rejected')
    else false  -- completed / rejected are terminal
  end;
  if not v_ok then
    raise exception 'Invalid request status transition: % -> %', p_from, p_to;
  end if;
end;
$$;

-- ------------------------------------------------------------
-- 8. Receipt uploads: metadata + private, company-scoped bucket
-- ------------------------------------------------------------
alter table public.payment_confirmations
  add column if not exists receipt_filename   text,
  add column if not exists receipt_size_bytes bigint,
  add column if not exists receipt_mime       text;

-- Bucket goes PRIVATE. Company users upload/read only inside their
-- own company folder (path: <company_account_id>/...). Admins read
-- via the admin-receipt-url edge function (service role + admin
-- token check) since the token model has no storage JWT.
update storage.buckets set public = false where id = 'payment-receipts';

drop policy if exists "authenticated can upload payment receipts" on storage.objects;
drop policy if exists "anyone can read payment receipts" on storage.objects;

drop policy if exists "company members upload own receipts" on storage.objects;
create policy "company members upload own receipts"
on storage.objects for insert to authenticated
with check (
  bucket_id = 'payment-receipts'
  and lower(coalesce(storage.extension(name), '')) in ('pdf', 'jpg', 'jpeg', 'png')
  and (storage.foldername(name))[1] in (
    select cu.company_account_id::text from public.company_users cu
     where cu.user_id = auth.uid() and cu.status <> 'removed')
);

drop policy if exists "company members read own receipts" on storage.objects;
create policy "company members read own receipts"
on storage.objects for select to authenticated
using (
  bucket_id = 'payment-receipts'
  and (storage.foldername(name))[1] in (
    select cu.company_account_id::text from public.company_users cu
     where cu.user_id = auth.uid() and cu.status <> 'removed')
);

-- ============================================================
-- REPLACED / NEW RPCs
-- ============================================================

-- ------------------------------------------------------------
-- Company accounts: typed creation (hospitality group / event
-- host / sponsor / mixed), with optional source linkage.
-- Creating from an event organizer auto-attaches the event.
-- ------------------------------------------------------------
drop function if exists public.admin_upsert_company(text, uuid, text, text, text, text, text, text);

create or replace function public.admin_upsert_company(
  p_admin_token   text,
  p_company_id    uuid,            -- null to create
  p_name          text,
  p_billing_email text,
  p_contact_name  text default null,
  p_contact_phone text default null,
  p_status        text default 'active',
  p_notes         text default null,
  p_account_type  text default 'hospitality_group',
  p_source_type   text default 'manual',
  p_source_id     uuid default null
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
  if p_account_type not in ('hospitality_group', 'event_host', 'sponsor', 'mixed') then
    return jsonb_build_object('ok', false, 'error', 'Invalid account type');
  end if;
  if p_source_type not in ('place_group', 'event_organizer', 'sponsor', 'manual') then
    return jsonb_build_object('ok', false, 'error', 'Invalid source type');
  end if;
  v_label := public._admin_label(p_admin_token);

  if p_company_id is null then
    insert into public.company_accounts
      (name, billing_email, contact_name, contact_phone, status, notes,
       account_type, source_type, source_id)
    values
      (trim(p_name), lower(trim(p_billing_email)), p_contact_name, p_contact_phone,
       p_status, p_notes, p_account_type, p_source_type, p_source_id)
    returning id into v_id;

    -- Real entity linkage: a company born from an event organizer
    -- owns that event from day one.
    if p_source_type = 'event_organizer' and p_source_id is not null
       and exists (select 1 from public.events where id = p_source_id) then
      insert into public.company_events
        (company_account_id, event_id, relationship_type, status, approved_by, approved_at)
      values (v_id, p_source_id, 'host', 'approved', v_label, now())
      on conflict do nothing;
    end if;

    perform public._billing_audit('admin', v_label, v_id, 'company_created',
      jsonb_build_object('name', trim(p_name), 'account_type', p_account_type,
                         'source_type', p_source_type, 'source_id', p_source_id));
  else
    update public.company_accounts
       set name = trim(p_name),
           billing_email = lower(trim(p_billing_email)),
           contact_name = p_contact_name,
           contact_phone = p_contact_phone,
           status = p_status,
           notes = p_notes,
           account_type = p_account_type,
           source_type = p_source_type,
           source_id = coalesce(p_source_id, source_id),
           updated_at = now()
     where id = p_company_id
    returning id into v_id;
    if v_id is null then return jsonb_build_object('ok', false, 'error', 'Company not found'); end if;
    perform public._billing_audit('admin', v_label, v_id, 'company_updated',
      jsonb_build_object('name', trim(p_name), 'status', p_status, 'account_type', p_account_type));
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- Search helpers for source / attachment pickers.
create or replace function public.admin_search_events(p_admin_token text, p_query text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._is_admin(p_admin_token) then return null; end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', e.id, 'title', e.title, 'slug', e.slug,
      'start_date', e.start_date, 'parent_event_id', e.parent_event_id,
      'child_count', (select count(*) from public.events c where c.parent_event_id = e.id))
      order by e.start_date desc nulls last), '[]'::jsonb)
    from (
      select * from public.events
       where title ilike '%' || coalesce(p_query, '') || '%'
       order by start_date desc nulls last limit 20) e);
end;
$$;

create or replace function public.admin_search_partners(p_admin_token text, p_query text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._is_admin(p_admin_token) then return null; end if;
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'id', p.id, 'name', p.name, 'contact_email', p.contact_email,
      'place_count', (select count(*) from public.places pl where pl.partner_id = p.id))
      order by p.name), '[]'::jsonb)
    from (
      select * from public.partners
       where name ilike '%' || coalesce(p_query, '') || '%'
       order by name limit 20) p);
end;
$$;

-- ------------------------------------------------------------
-- Company events: attach / detach / package (ADMIN ONLY)
-- ------------------------------------------------------------
create or replace function public.admin_attach_event(
  p_admin_token       text,
  p_company_id        uuid,
  p_event_id          uuid,
  p_relationship_type text default 'host',
  p_include_children  boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label    text;
  v_attached integer := 0;
  v_child    uuid;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  if p_relationship_type not in ('host', 'organizer', 'sponsor', 'vendor', 'production_partner') then
    return jsonb_build_object('ok', false, 'error', 'Invalid relationship type');
  end if;
  if not exists (select 1 from public.events where id = p_event_id) then
    return jsonb_build_object('ok', false, 'error', 'Event not found');
  end if;
  v_label := public._admin_label(p_admin_token);

  insert into public.company_events
    (company_account_id, event_id, relationship_type, status, approved_by, approved_at)
  values (p_company_id, p_event_id, p_relationship_type, 'approved', v_label, now())
  on conflict (company_account_id, event_id, relationship_type) do update
    set status = 'approved', approved_by = v_label, approved_at = now(), updated_at = now();
  v_attached := 1;

  -- Event series: optionally attach all child events too.
  if p_include_children then
    for v_child in select id from public.events where parent_event_id = p_event_id
    loop
      insert into public.company_events
        (company_account_id, event_id, relationship_type, status, approved_by, approved_at)
      values (p_company_id, v_child, p_relationship_type, 'approved', v_label, now())
      on conflict (company_account_id, event_id, relationship_type) do update
        set status = 'approved', approved_by = v_label, approved_at = now(), updated_at = now();
      v_attached := v_attached + 1;
    end loop;
  end if;

  perform public._billing_audit('admin', v_label, p_company_id, 'company_event_attached',
    jsonb_build_object('event_id', p_event_id, 'relationship_type', p_relationship_type,
                       'include_children', p_include_children, 'attached', v_attached));
  return jsonb_build_object('ok', true, 'attached', v_attached);
end;
$$;

create or replace function public.admin_detach_event(
  p_admin_token      text,
  p_company_event_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label text;
  v_row   company_events%rowtype;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  v_label := public._admin_label(p_admin_token);

  update public.company_events
     set status = 'removed', updated_at = now()
   where id = p_company_event_id
  returning * into v_row;
  if v_row.id is null then return jsonb_build_object('ok', false, 'error', 'Attachment not found'); end if;

  perform public._billing_audit('admin', v_label, v_row.company_account_id,
    'company_event_removed',
    jsonb_build_object('event_id', v_row.event_id, 'relationship_type', v_row.relationship_type));
  return jsonb_build_object('ok', true);
end;
$$;

-- Set/clear an event's package, including comped (free) hubs.
-- Comping is an admin override and REQUIRES a reason.
create or replace function public.admin_set_event_package(
  p_admin_token      text,
  p_company_event_id uuid,
  p_package_code     text,          -- billing_products.code or null
  p_comped           boolean default false,
  p_note             text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label text;
  v_row   company_events%rowtype;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  if p_comped and (p_note is null or length(trim(p_note)) = 0) then
    return jsonb_build_object('ok', false, 'error', 'A reason/note is required for comped access');
  end if;
  if p_package_code is not null
     and not exists (select 1 from public.billing_products where code = p_package_code) then
    return jsonb_build_object('ok', false, 'error', 'Unknown package code');
  end if;
  v_label := public._admin_label(p_admin_token);

  update public.company_events
     set package_product_code = p_package_code,
         comped = p_comped,
         updated_at = now()
   where id = p_company_event_id
  returning * into v_row;
  if v_row.id is null then return jsonb_build_object('ok', false, 'error', 'Attachment not found'); end if;

  perform public._billing_audit('admin', v_label, v_row.company_account_id, 'event_package_set',
    jsonb_build_object('event_id', v_row.event_id, 'package_code', p_package_code,
                       'comped', p_comped, 'note', p_note));
  return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- Payment instructions admin CRUD
-- ------------------------------------------------------------
create or replace function public.admin_upsert_payment_instruction(
  p_admin_token text,
  p_id          uuid,             -- null to create
  p_fields      jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label text;
  v_id    uuid := p_id;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  if coalesce(p_fields ->> 'currency', '') not in ('USD', 'JMD') then
    return jsonb_build_object('ok', false, 'error', 'Currency must be USD or JMD');
  end if;
  v_label := public._admin_label(p_admin_token);

  if v_id is null then
    insert into public.payment_instructions
      (bank_name, account_name, branch_name, currency, account_type,
       account_number, routing_or_swift, payment_notes, active, display_order)
    values
      (coalesce(p_fields ->> 'bank_name', ''), coalesce(p_fields ->> 'account_name', ''),
       p_fields ->> 'branch_name', p_fields ->> 'currency', p_fields ->> 'account_type',
       nullif(trim(coalesce(p_fields ->> 'account_number', '')), ''),
       nullif(trim(coalesce(p_fields ->> 'routing_or_swift', '')), ''),
       p_fields ->> 'payment_notes',
       coalesce((p_fields ->> 'active')::boolean, true),
       coalesce((p_fields ->> 'display_order')::integer, 0))
    returning id into v_id;
  else
    update public.payment_instructions
       set bank_name = coalesce(p_fields ->> 'bank_name', bank_name),
           account_name = coalesce(p_fields ->> 'account_name', account_name),
           branch_name = p_fields ->> 'branch_name',
           currency = p_fields ->> 'currency',
           account_type = p_fields ->> 'account_type',
           account_number = nullif(trim(coalesce(p_fields ->> 'account_number', '')), ''),
           routing_or_swift = nullif(trim(coalesce(p_fields ->> 'routing_or_swift', '')), ''),
           payment_notes = p_fields ->> 'payment_notes',
           active = coalesce((p_fields ->> 'active')::boolean, active),
           display_order = coalesce((p_fields ->> 'display_order')::integer, display_order),
           updated_at = now()
     where id = v_id;
    if not found then return jsonb_build_object('ok', false, 'error', 'Instruction not found'); end if;
  end if;

  -- Audit WITHOUT the account number (it is sensitive).
  perform public._billing_audit('admin', v_label, null, 'payment_instructions_changed',
    jsonb_build_object('id', v_id, 'bank_name', p_fields ->> 'bank_name',
                       'currency', p_fields ->> 'currency',
                       'account_type', p_fields ->> 'account_type',
                       'active', coalesce((p_fields ->> 'active')::boolean, true)));
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

-- ------------------------------------------------------------
-- Billing settings (invoice copy, renewal window, receipt rules)
-- ------------------------------------------------------------
create or replace function public.admin_set_billing_setting(
  p_admin_token text,
  p_key         text,
  p_value       jsonb
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
  if p_key not in ('invoice_footer_copy', 'renewal_reminder_days',
                   'receipt_max_mb', 'receipt_allowed_types', 'onsite_support_reference') then
    return jsonb_build_object('ok', false, 'error', 'Unknown setting');
  end if;
  v_label := public._admin_label(p_admin_token);

  insert into public.billing_settings (key, value, updated_at)
  values (p_key, p_value, now())
  on conflict (key) do update set value = excluded.value, updated_at = now();

  perform public._billing_audit('admin', v_label, null, 'billing_setting_changed',
    jsonb_build_object('key', p_key, 'value', p_value));
  return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- Onboarding: billing info confirmation for linked users
-- ------------------------------------------------------------
create or replace function public._submit_company_onboarding(
  p_company_user_id uuid,
  p_info            jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user company_users%rowtype;
begin
  select * into v_user from public.company_users where id = p_company_user_id;
  if v_user.id is null then
    return jsonb_build_object('ok', false, 'error', 'Company user not found');
  end if;
  if coalesce(p_info ->> 'legal_name', '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Legal/business name is required');
  end if;
  if coalesce(p_info ->> 'billing_email', '') = '' or position('@' in (p_info ->> 'billing_email')) = 0 then
    return jsonb_build_object('ok', false, 'error', 'A valid billing email is required');
  end if;
  if coalesce(p_info ->> 'preferred_currency', 'USD') not in ('USD', 'JMD') then
    return jsonb_build_object('ok', false, 'error', 'Preferred currency must be USD or JMD');
  end if;
  if coalesce(p_info ->> 'business_type', 'hospitality_group') not in
     ('hospitality_group', 'event_host', 'sponsor', 'mixed') then
    return jsonb_build_object('ok', false, 'error', 'Invalid business type');
  end if;

  -- Onboarding confirms billing details ONLY. It can never touch
  -- approved locations/events — those stay admin-attached.
  update public.company_accounts
     set legal_name = trim(p_info ->> 'legal_name'),
         trading_name = nullif(trim(coalesce(p_info ->> 'trading_name', '')), ''),
         contact_name = nullif(trim(coalesce(p_info ->> 'billing_contact_name', '')), ''),
         billing_email = lower(trim(p_info ->> 'billing_email')),
         billing_phone = nullif(trim(coalesce(p_info ->> 'billing_phone', '')), ''),
         country = nullif(trim(coalesce(p_info ->> 'country', '')), ''),
         address = nullif(trim(coalesce(p_info ->> 'address', '')), ''),
         tax_id = nullif(trim(coalesce(p_info ->> 'tax_id', '')), ''),
         preferred_currency = coalesce(p_info ->> 'preferred_currency', 'USD'),
         account_type = coalesce(p_info ->> 'business_type', account_type),
         onboarded_by_role = nullif(trim(coalesce(p_info ->> 'role_title', '')), ''),
         onboarding_status = 'complete',
         updated_at = now()
   where id = v_user.company_account_id;

  perform public._billing_audit('company_user', v_user.email, v_user.company_account_id,
    'company_billing_info_changed',
    jsonb_build_object('legal_name', p_info ->> 'legal_name',
                       'preferred_currency', p_info ->> 'preferred_currency',
                       'business_type', p_info ->> 'business_type',
                       'completed_by_role', p_info ->> 'role_title'));

  return jsonb_build_object('ok', true, 'onboarding_status', 'complete');
end;
$$;

create or replace function public.submit_company_onboarding(p_info jsonb)
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
  return public._submit_company_onboarding(v_user.id, p_info);
end;
$$;

-- ------------------------------------------------------------
-- Company setup requests (no pre-created company)
-- ------------------------------------------------------------
create or replace function public._submit_company_setup_request(
  p_user_id uuid,
  p_email   text,
  p_info    jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
begin
  if coalesce(p_info ->> 'legal_name', '') = '' then
    return jsonb_build_object('ok', false, 'error', 'Legal/business name is required');
  end if;
  if exists (select 1 from public.company_setup_requests
              where user_id = p_user_id and status = 'pending_review') then
    return jsonb_build_object('ok', false, 'error',
      'You already have a setup request pending review');
  end if;

  insert into public.company_setup_requests
    (user_id, email, legal_name, trading_name, contact_name, billing_phone,
     country, address, tax_id, preferred_currency, business_type, role_title, message)
  values
    (p_user_id, lower(trim(p_email)),
     trim(p_info ->> 'legal_name'),
     nullif(trim(coalesce(p_info ->> 'trading_name', '')), ''),
     nullif(trim(coalesce(p_info ->> 'billing_contact_name', '')), ''),
     nullif(trim(coalesce(p_info ->> 'billing_phone', '')), ''),
     nullif(trim(coalesce(p_info ->> 'country', '')), ''),
     nullif(trim(coalesce(p_info ->> 'address', '')), ''),
     nullif(trim(coalesce(p_info ->> 'tax_id', '')), ''),
     coalesce(p_info ->> 'preferred_currency', 'USD'),
     coalesce(p_info ->> 'business_type', 'hospitality_group'),
     nullif(trim(coalesce(p_info ->> 'role_title', '')), ''),
     nullif(trim(coalesce(p_info ->> 'message', '')), ''))
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id, 'status', 'pending_review',
    'message', 'Thanks! TRODDR will review your company details and set up your account.');
end;
$$;

create or replace function public.submit_company_setup_request(p_info jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid   uuid := auth.uid();
  v_email text := coalesce(auth.jwt() ->> 'email', '');
begin
  if v_uid is null or v_email = '' then
    return jsonb_build_object('ok', false, 'error', 'Sign in first');
  end if;
  if (public._resolve_company_user()).id is not null then
    return jsonb_build_object('ok', false, 'error', 'You already belong to a company account');
  end if;
  return public._submit_company_setup_request(v_uid, v_email, p_info);
end;
$$;

create or replace function public.admin_review_company_setup(
  p_admin_token text,
  p_request_id  uuid,
  p_decision    text,             -- 'approve' | 'reject'
  p_note        text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label   text;
  v_req     company_setup_requests%rowtype;
  v_company uuid;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  if p_decision not in ('approve', 'reject') then
    return jsonb_build_object('ok', false, 'error', 'Invalid decision');
  end if;
  v_label := public._admin_label(p_admin_token);

  select * into v_req from public.company_setup_requests where id = p_request_id for update;
  if v_req.id is null then return jsonb_build_object('ok', false, 'error', 'Request not found'); end if;
  if v_req.status <> 'pending_review' then
    return jsonb_build_object('ok', false, 'error', 'Request already reviewed');
  end if;

  if p_decision = 'reject' then
    update public.company_setup_requests
       set status = 'rejected', review_note = p_note, reviewed_by = v_label, reviewed_at = now()
     where id = p_request_id;
    perform public._billing_audit('admin', v_label, null, 'company_setup_rejected',
      jsonb_build_object('request_id', p_request_id, 'legal_name', v_req.legal_name, 'note', p_note));
    return jsonb_build_object('ok', true, 'status', 'rejected');
  end if;

  -- Approve: create the company from the submitted details and
  -- link the requesting user as its first admin.
  insert into public.company_accounts
    (name, legal_name, trading_name, billing_email, contact_name, billing_phone,
     country, address, tax_id, preferred_currency, account_type, source_type,
     onboarding_status, onboarded_by_role)
  values
    (coalesce(v_req.trading_name, v_req.legal_name), v_req.legal_name, v_req.trading_name,
     v_req.email, v_req.contact_name, v_req.billing_phone,
     v_req.country, v_req.address, v_req.tax_id, v_req.preferred_currency,
     v_req.business_type, 'manual', 'complete', v_req.role_title)
  returning id into v_company;

  insert into public.company_users (company_account_id, email, name, role, user_id, status)
  values (v_company, v_req.email, v_req.contact_name, 'admin', v_req.user_id,
          case when v_req.user_id is null then 'invited' else 'active' end)
  on conflict (company_account_id, email) do nothing;

  update public.company_setup_requests
     set status = 'approved', review_note = p_note, reviewed_by = v_label,
         reviewed_at = now(), created_company_id = v_company
   where id = p_request_id;

  perform public._billing_audit('admin', v_label, v_company, 'company_setup_approved',
    jsonb_build_object('request_id', p_request_id, 'legal_name', v_req.legal_name));

  return jsonb_build_object('ok', true, 'status', 'approved', 'company_id', v_company);
end;
$$;

-- ------------------------------------------------------------
-- Notifications queue admin control
-- ------------------------------------------------------------
create or replace function public.admin_set_notification_status(
  p_admin_token     text,
  p_notification_id uuid,
  p_status          text
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
  if p_status not in ('pending', 'sent', 'failed', 'dismissed') then
    return jsonb_build_object('ok', false, 'error', 'Invalid status');
  end if;
  update public.billing_notifications
     set status = p_status,
         sent_at = case when p_status = 'sent' then now() else sent_at end
   where id = p_notification_id;
  if not found then return jsonb_build_object('ok', false, 'error', 'Notification not found'); end if;
  return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- Renewal operations
-- ------------------------------------------------------------
-- Draft a renewal invoice from the company's current plan/cycle.
-- The new period starts the day AFTER paid_through (no backfill
-- of unpaid gaps — if it lapsed long ago the admin sets dates
-- explicitly in the generator before issuing).
create or replace function public.admin_generate_renewal_invoice(
  p_admin_token text,
  p_company_id  uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label  text;
  v_sub    subscriptions%rowtype;
  v_plan   subscription_plans%rowtype;
  v_start  date;
  v_end    date;
  v_amount numeric;
  v_inv_id uuid;
  v_res    jsonb;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  v_label := public._admin_label(p_admin_token);

  select * into v_sub from public.subscriptions where company_account_id = p_company_id;
  if v_sub.id is null or v_sub.plan_key is null then
    return jsonb_build_object('ok', false, 'error', 'No subscription/plan on file for this company');
  end if;
  select * into v_plan from public.subscription_plans where key = v_sub.plan_key;

  -- Renewal period: continues from paid_through if still current,
  -- otherwise starts fresh today (access resumes from the new
  -- payment period — the gap stays unpaid).
  v_start := case
    when v_sub.paid_through is not null and v_sub.paid_through >= current_date
    then v_sub.paid_through + 1
    else current_date end;
  v_end := case when coalesce(v_sub.billing_cycle, 'annual') = 'monthly'
                then (v_start + interval '1 month - 1 day')::date
                else (v_start + interval '1 year - 1 day')::date end;
  v_amount := case when coalesce(v_sub.billing_cycle, 'annual') = 'monthly'
                   then v_plan.monthly_price else v_plan.annual_price end;

  v_res := public.admin_save_invoice(p_admin_token, null, jsonb_build_object(
    'company_account_id', p_company_id,
    'currency', (select preferred_currency from public.company_accounts where id = p_company_id),
    'due_date', (current_date + 14)::text,
    'period_start', v_start::text,
    'period_end', v_end::text,
    'line_items', jsonb_build_array(jsonb_build_object(
      'item_type', 'founding_partner_subscription',
      'description', v_plan.name || ' renewal (' || coalesce(v_sub.billing_cycle, 'annual') || ')',
      'quantity', 1,
      'unit_amount', v_amount,
      'period_start', v_start::text,
      'period_end', v_end::text,
      'metadata', jsonb_build_object('plan_key', v_plan.key,
                                     'billing_cycle', coalesce(v_sub.billing_cycle, 'annual'),
                                     'renewal', true)))));
  if not (v_res ->> 'ok')::boolean then return v_res; end if;
  v_inv_id := (v_res ->> 'id')::uuid;

  perform public._billing_notify('renewal_invoice_generated', p_company_id,
    'Renewal invoice drafted for ' || v_plan.name,
    'A renewal draft was generated covering ' || v_start || ' to ' || v_end ||
    '. Review and issue it from the admin console.', v_inv_id);

  perform public._billing_audit('admin', v_label, p_company_id, 'renewal_invoice_generated',
    jsonb_build_object('invoice_id', v_inv_id, 'period_start', v_start, 'period_end', v_end),
    v_inv_id, v_sub.id);

  return jsonb_build_object('ok', true, 'id', v_inv_id,
    'period_start', v_start, 'period_end', v_end);
end;
$$;

-- One-button maintenance: marks overdue invoices, drops lapsed
-- subscriptions to read_only (per existing grace rules), and
-- reports which companies are inside the renewal reminder window.
create or replace function public.admin_run_billing_maintenance(p_admin_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label    text;
  v_window   integer := coalesce((public._billing_setting('renewal_reminder_days'))::text::integer, 30);
  v_overdue  integer;
  v_lapsed   integer;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  v_label := public._admin_label(p_admin_token);

  -- Issued invoices past due -> overdue (notification via trigger).
  with marked as (
    update public.invoices
       set status = 'overdue', updated_at = now()
     where status = 'issued' and due_date is not null and due_date < current_date
    returning id)
  select count(*) into v_overdue from marked;

  -- Active subscriptions lapsed past the 7-day grace -> read_only
  -- stored status (matches company_access_state computation).
  with lapsed as (
    update public.subscriptions
       set status = 'read_only', updated_at = now()
     where status = 'active'
       and paid_through is not null
       and paid_through < current_date - 7
    returning id)
  select count(*) into v_lapsed from lapsed;

  if v_overdue > 0 or v_lapsed > 0 then
    perform public._billing_audit('admin', v_label, null, 'billing_maintenance_run',
      jsonb_build_object('invoices_marked_overdue', v_overdue,
                         'subscriptions_read_only', v_lapsed));
  end if;

  return jsonb_build_object(
    'ok', true,
    'invoices_marked_overdue', v_overdue,
    'subscriptions_read_only', v_lapsed,
    'renewal_reminder_days', v_window,
    'renewals_due', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'company_id', s.company_account_id,
        'company_name', ca.name,
        'plan_key', s.plan_key,
        'billing_cycle', s.billing_cycle,
        'paid_through', s.paid_through) order by s.paid_through), '[]'::jsonb)
      from public.subscriptions s
      join public.company_accounts ca on ca.id = s.company_account_id
      where s.status in ('active', 'past_due')
        and s.paid_through is not null
        and s.paid_through <= current_date + v_window
        and not exists (
          -- A renewal already drafted/issued past the current window
          select 1 from public.invoices i
          join public.invoice_line_items li on li.invoice_id = i.id
          where i.company_account_id = s.company_account_id
            and i.status in ('draft', 'issued', 'payment_reported', 'overdue')
            and li.item_type = 'founding_partner_subscription'
            and coalesce(li.period_start, i.period_start) > s.paid_through - 7)));
end;
$$;

-- ------------------------------------------------------------
-- Reason-required overrides (replacing same-signature functions)
-- ------------------------------------------------------------

-- Manual subscription control now REQUIRES a note for paid-through
-- adjustments, manual (comped) activation, and revocation.
create or replace function public.admin_set_subscription(
  p_admin_token   text,
  p_company_id    uuid,
  p_action        text,
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
  -- Manual activation = comped access; adjustments and revokes are
  -- overrides. All of them need a written reason for the audit log.
  if p_action in ('activate', 'adjust_paid_through', 'revoke')
     and (p_note is null or length(trim(p_note)) = 0) then
    return jsonb_build_object('ok', false, 'error',
      'A reason/note is required for ' || replace(p_action, '_', ' '));
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
          'Manual activation by ' || v_label || ': ' || p_note);
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
    update public.company_entitlements
       set expires_at = p_paid_through, updated_at = now()
     where company_account_id = p_company_id and source = 'plan';

  else
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

-- Entitlement overrides REQUIRE a note (grant and revoke).
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
  if p_note is null or length(trim(p_note)) = 0 then
    return jsonb_build_object('ok', false, 'error',
      'A reason/note is required for entitlement overrides');
  end if;
  v_label := public._admin_label(p_admin_token);

  if p_active then
    perform public._grant_entitlement(p_company_id, p_key, 'manual',
      current_date, p_expires_at, null, 'Manual grant by ' || v_label || ': ' || p_note);
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

-- Voiding an invoice REQUIRES a note.
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
  if p_status in ('void', 'rejected') and (p_note is null or length(trim(p_note)) = 0) then
    return jsonb_build_object('ok', false, 'error',
      'A reason/note is required to ' || p_status || ' an invoice');
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

-- Payment rejection REQUIRES a note (clarification already takes one).
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
  if p_decision in ('reject', 'clarify') and (p_note is null or length(trim(p_note)) = 0) then
    return jsonb_build_object('ok', false, 'error',
      'A note for the company is required to ' || p_decision);
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

    update public.subscriptions
       set status = 'invoice_issued', updated_at = now()
     where company_account_id = v_inv.company_account_id
       and status = 'payment_pending_review';

    perform public._billing_audit('admin', v_label, v_inv.company_account_id,
      'payment_rejected', jsonb_build_object('confirmation_id', v_conf.id, 'note', p_note),
      v_inv.id, null);
    return jsonb_build_object('ok', true, 'invoice_status', 'rejected');

  else
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

-- ------------------------------------------------------------
-- Requests: replaced submit + status RPCs (new shapes)
-- ------------------------------------------------------------
drop function if exists public.submit_billing_request(text, text);
create or replace function public.submit_billing_request(
  p_request_type        text,
  p_message             text default null,
  p_related_location_id uuid default null,
  p_related_event_id    uuid default null
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
  if p_request_type not in ('extra_admins', 'location_insights', 'company_insights',
                            'event_coverage', 'event_insights',
                            'sponsor_activation', 'sponsor_report', 'billing_help', 'other') then
    return jsonb_build_object('ok', false, 'error', 'Invalid request type');
  end if;
  -- Related records must belong to this company (no probing).
  if p_related_location_id is not null and not exists (
       select 1 from public.company_locations
        where id = p_related_location_id
          and company_account_id = v_user.company_account_id) then
    return jsonb_build_object('ok', false, 'error', 'Unknown location for this company');
  end if;
  if p_related_event_id is not null and not exists (
       select 1 from public.company_events
        where event_id = p_related_event_id
          and company_account_id = v_user.company_account_id
          and status = 'approved') then
    return jsonb_build_object('ok', false, 'error', 'Unknown event for this company');
  end if;

  insert into public.company_requests
    (company_account_id, requested_by, request_type, message,
     related_location_id, related_event_id)
  values (v_user.company_account_id, v_user.id, p_request_type,
          nullif(trim(coalesce(p_message, '')), ''),
          p_related_location_id, p_related_event_id)
  returning id into v_id;

  perform public._billing_audit('company_user', v_user.email, v_user.company_account_id,
    'request_submitted', jsonb_build_object('request_type', p_request_type, 'request_id', v_id,
      'related_location_id', p_related_location_id, 'related_event_id', p_related_event_id));

  return jsonb_build_object('ok', true, 'id', v_id,
    'message', 'Request sent. TRODDR will follow up by email.');
end;
$$;

drop function if exists public.admin_set_request_status(text, uuid, text);
create or replace function public.admin_set_request_status(
  p_admin_token text,
  p_request_id  uuid,
  p_status      text,
  p_admin_notes text default null
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
  if p_status not in ('new', 'in_review', 'quoted', 'invoiced', 'completed', 'rejected') then
    return jsonb_build_object('ok', false, 'error', 'Invalid status');
  end if;
  v_label := public._admin_label(p_admin_token);

  select * into v_row from public.company_requests where id = p_request_id for update;
  if v_row.id is null then return jsonb_build_object('ok', false, 'error', 'Request not found'); end if;

  begin
    perform public._assert_request_transition(v_row.status, p_status);
  exception when others then
    return jsonb_build_object('ok', false, 'error', sqlerrm);
  end;

  update public.company_requests
     set status = p_status,
         admin_notes = case when p_admin_notes is null then admin_notes
           else coalesce(admin_notes || e'\n', '') || p_admin_notes end,
         resolved_at = case when p_status in ('completed', 'rejected') then now() else resolved_at end
   where id = p_request_id;

  perform public._billing_audit('admin', v_label, v_row.company_account_id,
    'request_status_set', jsonb_build_object('request_id', p_request_id,
      'from', v_row.status, 'to', p_status, 'admin_notes', p_admin_notes));
  return jsonb_build_object('ok', true, 'status', p_status);
end;
$$;

-- ------------------------------------------------------------
-- Payment confirmation: replaced with receipt metadata + rules
-- ------------------------------------------------------------
drop function if exists public.submit_payment_confirmation(uuid, text, date, text, text, text);
drop function if exists public._submit_payment_confirmation(uuid, uuid, text, date, text, text, text);

create or replace function public._submit_payment_confirmation(
  p_company_user_id    uuid,
  p_invoice_id         uuid,
  p_payment_method     text,
  p_paid_on            date,
  p_reference          text,
  p_receipt_path       text default null,
  p_notes              text default null,
  p_receipt_filename   text default null,
  p_receipt_size_bytes bigint default null,
  p_receipt_mime       text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user    company_users%rowtype;
  v_inv     invoices%rowtype;
  v_conf    payment_confirmations%rowtype;
  v_latest  payment_confirmations%rowtype;
  v_max_mb  numeric := coalesce((public._billing_setting('receipt_max_mb'))::text::numeric, 10);
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

  -- Receipt rules: pdf/jpg/png only, size capped by settings.
  if p_receipt_path is not null then
    if p_receipt_mime is not null and lower(p_receipt_mime) not in
       ('application/pdf', 'image/jpeg', 'image/jpg', 'image/png') then
      return jsonb_build_object('ok', false, 'error', 'Receipts must be PDF, JPG, or PNG');
    end if;
    if lower(coalesce(substring(p_receipt_path from '\.([A-Za-z0-9]+)$'), '')) not in
       ('pdf', 'jpg', 'jpeg', 'png') then
      return jsonb_build_object('ok', false, 'error', 'Receipts must be PDF, JPG, or PNG');
    end if;
    if p_receipt_size_bytes is not null and p_receipt_size_bytes > v_max_mb * 1024 * 1024 then
      return jsonb_build_object('ok', false, 'error',
        'Receipt is too large (max ' || v_max_mb || ' MB)');
    end if;
  end if;

  if v_inv.status in ('issued', 'overdue', 'rejected') then
    null;
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
     paid_on, reference_number, receipt_url, notes,
     receipt_filename, receipt_size_bytes, receipt_mime)
  values
    (v_inv.id, v_inv.company_account_id, v_user.id, p_payment_method,
     p_paid_on, trim(p_reference), nullif(trim(coalesce(p_receipt_path, '')), ''),
     nullif(trim(coalesce(p_notes, '')), ''),
     p_receipt_filename, p_receipt_size_bytes, p_receipt_mime)
  returning * into v_conf;

  if v_inv.status <> 'payment_reported' then
    perform public._assert_invoice_transition(v_inv.status, 'payment_reported');
    update public.invoices
       set status = 'payment_reported', updated_at = now()
     where id = v_inv.id;
  end if;

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
  p_invoice_id         uuid,
  p_payment_method     text,
  p_paid_on            date,
  p_reference          text,
  p_receipt_path       text default null,
  p_notes              text default null,
  p_receipt_filename   text default null,
  p_receipt_size_bytes bigint default null,
  p_receipt_mime       text default null
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
    v_user.id, p_invoice_id, p_payment_method, p_paid_on, p_reference,
    p_receipt_path, p_notes, p_receipt_filename, p_receipt_size_bytes, p_receipt_mime);
end;
$$;

-- ------------------------------------------------------------
-- get_company_billing: expanded (events, onboarding, payment
-- instructions, invoice copy, receipt rules, setup requests)
-- ------------------------------------------------------------
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
  v_uid     uuid := auth.uid();
begin
  v_user := public._resolve_company_user();
  if v_user.id is null then
    -- No company: surface any pending setup request so the UI can
    -- show the pending_company_review state.
    return jsonb_build_object('ok', false, 'error', 'no_company',
      'message', 'Your sign-in is not linked to a company account yet.',
      'setup_request', (
        select jsonb_build_object('id', r.id, 'status', r.status,
          'legal_name', r.legal_name, 'review_note', r.review_note,
          'created_at', r.created_at)
        from public.company_setup_requests r
        where r.user_id = v_uid
        order by r.created_at desc limit 1));
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
      'legal_name', v_company.legal_name, 'trading_name', v_company.trading_name,
      'billing_email', v_company.billing_email, 'status', v_company.status,
      'account_type', v_company.account_type,
      'contact_name', v_company.contact_name, 'billing_phone', v_company.billing_phone,
      'country', v_company.country, 'address', v_company.address,
      'tax_id', v_company.tax_id, 'preferred_currency', v_company.preferred_currency),
    'onboarding', jsonb_build_object(
      'status', v_company.onboarding_status,
      'completed_by_role', v_company.onboarded_by_role),
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
    'events', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', ce.id, 'event_id', ce.event_id,
        'title', e.title, 'slug', e.slug,
        'start_date', e.start_date, 'end_date', e.end_date,
        'parent_event_id', e.parent_event_id,
        'relationship_type', ce.relationship_type,
        'comped', ce.comped,
        'package', (select bp.name from public.billing_products bp
                     where bp.code = ce.package_product_code),
        'approved_at', ce.approved_at) order by e.start_date desc nulls last), '[]'::jsonb)
      from public.company_events ce
      join public.events e on e.id = ce.event_id
      where ce.company_account_id = v_company.id and ce.status = 'approved'),
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
            'receipt_path', pc.receipt_url, 'receipt_filename', pc.receipt_filename,
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
        'status', r.status, 'created_at', r.created_at,
        'related_event_id', r.related_event_id,
        'related_location_id', r.related_location_id) order by r.created_at desc), '[]'::jsonb)
      from public.company_requests r
      where r.company_account_id = v_company.id),
    'payment_instructions', jsonb_build_object(
      'USD', public.payment_instructions_for_currency('USD'),
      'JMD', public.payment_instructions_for_currency('JMD')),
    'invoice_footer_copy', coalesce(public._billing_setting('invoice_footer_copy'), '[]'::jsonb),
    'receipt_rules', jsonb_build_object(
      'max_mb', coalesce(public._billing_setting('receipt_max_mb'), to_jsonb(10)),
      'allowed_types', coalesce(public._billing_setting('receipt_allowed_types'),
                                '["pdf","jpg","jpeg","png"]'::jsonb))
  );
end;
$$;

-- ------------------------------------------------------------
-- admin_get_company: expanded with events + onboarding info
-- ------------------------------------------------------------
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
      'events', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', ce.id, 'event_id', ce.event_id, 'title', e.title, 'slug', e.slug,
          'start_date', e.start_date, 'parent_event_id', e.parent_event_id,
          'relationship_type', ce.relationship_type, 'status', ce.status,
          'comped', ce.comped, 'package_product_code', ce.package_product_code,
          'approved_at', ce.approved_at) order by e.start_date desc nulls last), '[]'::jsonb)
        from public.company_events ce
        join public.events e on e.id = ce.event_id
        where ce.company_account_id = ca.id and ce.status = 'approved'),
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
              'receipt_path', pc.receipt_url, 'receipt_filename', pc.receipt_filename,
              'notes', pc.notes, 'review_note', pc.review_note, 'created_at', pc.created_at)
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

-- ------------------------------------------------------------
-- admin_billing_overview: + notifications queue, setup requests,
-- renewals due, payment instructions, settings
-- ------------------------------------------------------------
create or replace function public.admin_billing_overview(p_admin_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_window integer := coalesce((public._billing_setting('renewal_reminder_days'))::text::integer, 30);
begin
  if not public._is_admin(p_admin_token) then return null; end if;

  return jsonb_build_object(
    'counts', jsonb_build_object(
      'pending_reviews', (select count(*) from public.payment_confirmations
                           where status in ('submitted', 'needs_clarification')),
      'open_requests',   (select count(*) from public.company_requests
                           where status in ('new', 'in_review', 'quoted', 'invoiced')),
      'draft_invoices',  (select count(*) from public.invoices where status = 'draft'),
      'overdue_invoices', (select count(*) from public.invoices
                            where public._invoice_effective_status(status, due_date) = 'overdue'),
      'pending_notifications', (select count(*) from public.billing_notifications
                                 where status = 'pending'),
      'setup_requests',  (select count(*) from public.company_setup_requests
                           where status = 'pending_review')),
    'companies', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', ca.id, 'name', ca.name, 'billing_email', ca.billing_email, 'status', ca.status,
        'account_type', ca.account_type, 'onboarding_status', ca.onboarding_status,
        'access', public.company_access_state(ca.id),
        'locations', (select count(*) from public.company_locations cl
                       where cl.company_account_id = ca.id and cl.status = 'approved'),
        'events', (select count(*) from public.company_events ce
                    where ce.company_account_id = ca.id and ce.status = 'approved'),
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
        'reference_number', pc.reference_number,
        'receipt_path', pc.receipt_url, 'receipt_filename', pc.receipt_filename,
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
    'setup_requests', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', r.id, 'email', r.email, 'legal_name', r.legal_name,
        'trading_name', r.trading_name, 'contact_name', r.contact_name,
        'country', r.country, 'business_type', r.business_type,
        'preferred_currency', r.preferred_currency, 'role_title', r.role_title,
        'message', r.message, 'status', r.status, 'created_at', r.created_at
      ) order by r.created_at), '[]'::jsonb)
      from public.company_setup_requests r where r.status = 'pending_review'),
    'requests', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', r.id, 'request_type', r.request_type, 'message', r.message,
        'status', r.status, 'admin_notes', r.admin_notes, 'created_at', r.created_at,
        'related_event_id', r.related_event_id, 'related_location_id', r.related_location_id,
        'company', (select jsonb_build_object('id', ca.id, 'name', ca.name)
                     from public.company_accounts ca where ca.id = r.company_account_id),
        'requested_by', (select cu.email from public.company_users cu where cu.id = r.requested_by)
      ) order by r.created_at desc), '[]'::jsonb)
      from public.company_requests r
      where r.status in ('new', 'in_review', 'quoted', 'invoiced')),
    'notifications', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', n.id, 'notification_type', n.notification_type,
        'recipient_email', n.recipient_email, 'subject', n.subject, 'body', n.body,
        'status', n.status, 'created_at', n.created_at,
        'company', (select ca.name from public.company_accounts ca
                     where ca.id = n.company_account_id)
      ) order by n.created_at desc), '[]'::jsonb)
      from (select * from public.billing_notifications
             where status = 'pending' order by created_at desc limit 100) n),
    'renewals_due', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'company_id', s.company_account_id, 'company_name', ca.name,
        'plan_key', s.plan_key, 'billing_cycle', s.billing_cycle,
        'paid_through', s.paid_through) order by s.paid_through), '[]'::jsonb)
      from public.subscriptions s
      join public.company_accounts ca on ca.id = s.company_account_id
      where s.status in ('active', 'past_due')
        and s.paid_through is not null
        and s.paid_through <= current_date + v_window
        and not exists (
          select 1 from public.invoices i
          join public.invoice_line_items li on li.invoice_id = i.id
          where i.company_account_id = s.company_account_id
            and i.status in ('draft', 'issued', 'payment_reported', 'overdue')
            and li.item_type = 'founding_partner_subscription'
            and coalesce(li.period_start, i.period_start) > s.paid_through - 7)),
    'payment_instructions', (
      select coalesce(jsonb_agg(to_jsonb(pi) order by pi.display_order), '[]'::jsonb)
      from public.payment_instructions pi),
    'settings', (
      select coalesce(jsonb_object_agg(bs.key, bs.value), '{}'::jsonb)
      from public.billing_settings bs),
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

-- ------------------------------------------------------------
-- Event dashboard billing (token-based, read-only)
-- ------------------------------------------------------------
create or replace function public._event_billing(p_event_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_ce      company_events%rowtype;
  v_company company_accounts%rowtype;
  v_access  jsonb;
  v_pkg     billing_products%rowtype;
  v_pkg_src text;
  v_paid    jsonb;
  v_ins     text;
  v_map     text;
begin
  -- Host/organizer company for this event (host wins).
  select ce.* into v_ce
    from public.company_events ce
   where ce.event_id = p_event_id
     and ce.status = 'approved'
     and ce.relationship_type in ('host', 'organizer')
   order by case ce.relationship_type when 'host' then 0 else 1 end, ce.approved_at
   limit 1;

  if v_ce.id is null then
    return jsonb_build_object('ok', false, 'error', 'no_company',
      'message', 'This event is not attached to a company account yet.');
  end if;

  select * into v_company from public.company_accounts where id = v_ce.company_account_id;
  v_access := public.company_access_state(v_company.id);

  -- PAID lines attributed to this event (line metadata.event_id).
  select coalesce(jsonb_agg(jsonb_build_object(
    'item_type', li.item_type, 'product_code', li.product_code,
    'description', li.description, 'amount', li.amount,
    'invoice_number', i.invoice_number, 'paid_at', i.paid_at)), '[]'::jsonb)
    into v_paid
  from public.invoice_line_items li
  join public.invoices i on i.id = li.invoice_id
  where i.company_account_id = v_company.id
    and i.status = 'paid'
    and li.metadata ->> 'event_id' = p_event_id::text;

  -- Package: explicit (admin-set / comped) beats derived-from-paid.
  if v_ce.package_product_code is not null then
    select * into v_pkg from public.billing_products where code = v_ce.package_product_code;
    v_pkg_src := case when v_ce.comped then 'comped' else 'assigned' end;
  else
    select bp.* into v_pkg
      from public.invoice_line_items li
      join public.invoices i on i.id = li.invoice_id
      left join public.billing_products bp on bp.code = li.product_code
     where i.company_account_id = v_company.id
       and i.status = 'paid'
       and li.metadata ->> 'event_id' = p_event_id::text
       and li.item_type in ('event_lite', 'event_pro', 'major_event_hub', 'flagship_event',
                            'carnival_hub', 'carnival_band_hub', 'carnival_event_listing',
                            'carnival_event_pro', 'event_series_hub')
     order by li.amount desc
     limit 1;
    v_pkg_src := case when v_pkg.code is null then null else 'paid' end;
  end if;

  -- Insights: ALWAYS unpaid on comped hubs unless separately
  -- purchased. Paid packages may include it via entitlements.
  if exists (
    select 1 from public.invoice_line_items li
    join public.invoices i on i.id = li.invoice_id
    where i.company_account_id = v_company.id and i.status = 'paid'
      and li.metadata ->> 'event_id' = p_event_id::text
      and li.item_type = 'event_insights') then
    v_ins := 'purchased';
  elsif v_pkg_src = 'paid' and v_pkg.entitlements ? 'event_insights' then
    v_ins := 'included';
  else
    v_ins := 'not_purchased';
  end if;

  if exists (
    select 1 from public.invoice_line_items li
    join public.invoices i on i.id = li.invoice_id
    where i.company_account_id = v_company.id and i.status = 'paid'
      and li.metadata ->> 'event_id' = p_event_id::text
      and li.item_type = 'premium_event_map') then
    v_map := 'purchased';
  elsif v_pkg_src = 'paid' and v_pkg.entitlements ? 'premium_event_map' then
    v_map := 'included';
  else
    v_map := 'not_included';
  end if;

  return jsonb_build_object(
    'ok', true,
    'company', jsonb_build_object('id', v_company.id, 'name', v_company.name,
      'relationship_type', v_ce.relationship_type),
    'company_billing_url', '/company/billing',
    'access', jsonb_build_object(
      'dashboard_state', case
        when v_ce.comped then 'comped'
        when v_access ->> 'access' = 'full' then 'active'
        when v_access ->> 'access' = 'read_only' then 'read_only'
        else 'inactive' end,
      'company_access', v_access),
    'package', case when v_pkg.code is null then null else jsonb_build_object(
      'code', v_pkg.code, 'name', v_pkg.name, 'source', v_pkg_src,
      'comped', v_ce.comped) end,
    'insights_status', v_ins,
    'premium_map_status', v_map,
    'sponsor_products', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'item_type', li.item_type, 'description', li.description,
        'amount', li.amount, 'invoice_number', i.invoice_number)), '[]'::jsonb)
      from public.invoice_line_items li
      join public.invoices i on i.id = li.invoice_id
      where i.company_account_id = v_company.id and i.status = 'paid'
        and li.metadata ->> 'event_id' = p_event_id::text
        and li.item_type in ('sponsor_activation', 'sponsor_report')),
    'push', jsonb_build_object(
      'cap', coalesce(v_pkg.metadata ->> 'push_cap', null),
      'used', public.event_push_cap_usage(p_event_id)),
    'paid_lines', v_paid,
    'open_invoice', (
      select jsonb_build_object('invoice_number', i.invoice_number,
        'status', public._invoice_effective_status(i.status, i.due_date),
        'total', i.total, 'currency', i.currency, 'due_date', i.due_date)
      from public.invoices i
      where i.company_account_id = v_company.id
        and i.status in ('issued', 'payment_reported', 'overdue')
      order by i.created_at desc limit 1));
end;
$$;

create or replace function public.get_event_billing_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
begin
  select id into v_event_id from public.events where partner_access_token = p_token;
  if v_event_id is null then return null; end if;
  return public._event_billing(v_event_id);
end;
$$;

-- ============================================================
-- GRANTS / REVOKES
-- ============================================================
revoke execute on function public._billing_setting(text) from public, anon, authenticated;
revoke execute on function public._billing_notify(text, uuid, text, text, uuid, uuid) from public, anon, authenticated;
revoke execute on function public._assert_request_transition(text, text) from public, anon, authenticated;
revoke execute on function public._submit_company_onboarding(uuid, jsonb) from public, anon, authenticated;
revoke execute on function public._submit_company_setup_request(uuid, text, jsonb) from public, anon, authenticated;
revoke execute on function public._submit_payment_confirmation(uuid, uuid, text, date, text, text, text, text, bigint, text) from public, anon, authenticated;
revoke execute on function public._event_billing(uuid) from public, anon;
revoke execute on function public._trg_invoice_notify() from public, anon, authenticated;
revoke execute on function public._trg_confirmation_notify() from public, anon, authenticated;
revoke execute on function public._trg_subscription_notify() from public, anon, authenticated;
revoke execute on function public._trg_request_notify() from public, anon, authenticated;
revoke execute on function public._trg_setup_request_notify() from public, anon, authenticated;

-- Company-facing (Supabase auth)
grant execute on function public.get_company_billing() to authenticated;
grant execute on function public.submit_company_onboarding(jsonb) to authenticated;
grant execute on function public.submit_company_setup_request(jsonb) to authenticated;
grant execute on function public.submit_billing_request(text, text, uuid, uuid) to authenticated;
grant execute on function public.submit_payment_confirmation(uuid, text, date, text, text, text, text, bigint, text) to authenticated;
grant execute on function public.payment_instructions_for_currency(text) to authenticated;

-- Event dashboard (partner token model)
grant execute on function public.get_event_billing_by_token(text) to anon, authenticated;

-- Admin (token-checked)
grant execute on function public.admin_upsert_company(text, uuid, text, text, text, text, text, text, text, text, uuid) to anon, authenticated;
grant execute on function public.admin_search_events(text, text) to anon, authenticated;
grant execute on function public.admin_search_partners(text, text) to anon, authenticated;
grant execute on function public.admin_attach_event(text, uuid, uuid, text, boolean) to anon, authenticated;
grant execute on function public.admin_detach_event(text, uuid) to anon, authenticated;
grant execute on function public.admin_set_event_package(text, uuid, text, boolean, text) to anon, authenticated;
grant execute on function public.admin_upsert_payment_instruction(text, uuid, jsonb) to anon, authenticated;
grant execute on function public.admin_set_billing_setting(text, text, jsonb) to anon, authenticated;
grant execute on function public.admin_review_company_setup(text, uuid, text, text) to anon, authenticated;
grant execute on function public.admin_set_notification_status(text, uuid, text) to anon, authenticated;
grant execute on function public.admin_generate_renewal_invoice(text, uuid) to anon, authenticated;
grant execute on function public.admin_run_billing_maintenance(text) to anon, authenticated;
grant execute on function public.admin_set_request_status(text, uuid, text, text) to anon, authenticated;
