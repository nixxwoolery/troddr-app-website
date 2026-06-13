-- ============================================================
-- TRODDR Company Onboarding — invite links + guided wizard + quote
-- ------------------------------------------------------------
-- Adds the interactive onboarding flow on top of the company
-- billing system:
--   1. company_onboarding_invites: admin-generated branded links
--      tied to a pre-created company + pre-attached businesses.
--   2. company_accounts.onboarding_profile / onboarding_quote.
--   3. RPCs: admin invite create/revoke, anon invite lookup,
--      authenticated accept / profile / catalog / quote.
--   4. submit_onboarding_quote() auto-creates a DRAFT invoice from
--      catalog-priced lines (admin reviews + issues — never
--      self-activates) and records a request.
--
-- Run AFTER company-billing-loyalty.sql.
-- ============================================================

-- ------------------------------------------------------------
-- 1. Schema
-- ------------------------------------------------------------
alter table public.company_accounts
  add column if not exists onboarding_profile jsonb not null default '{}'::jsonb,
  add column if not exists onboarding_quote   jsonb not null default '{}'::jsonb;

create table if not exists public.company_onboarding_invites (
  id                 uuid primary key default gen_random_uuid(),
  token              text not null unique default encode(gen_random_bytes(24), 'hex'),
  company_account_id uuid not null references public.company_accounts(id) on delete cascade,
  email              text not null,
  status             text not null default 'pending'
    check (status in ('pending', 'accepted', 'expired', 'revoked')),
  claimable          jsonb not null default '{}'::jsonb,  -- {places:[...], events:[...]}
  expires_at         timestamptz not null default (now() + interval '14 days'),
  created_by         text,
  accepted_at        timestamptz,
  accepted_user_id   uuid,
  created_at         timestamptz not null default now()
);

create index if not exists onboarding_invites_company_idx
  on public.company_onboarding_invites(company_account_id);
create index if not exists onboarding_invites_email_idx
  on public.company_onboarding_invites(lower(email));

alter table public.company_onboarding_invites enable row level security;
-- No policies: RPCs only.

-- ------------------------------------------------------------
-- 2. Internal: create a DRAFT invoice (shared insert path,
--    mirrors admin_save_invoice's create branch). Always draft.
-- ------------------------------------------------------------
create or replace function public._save_invoice(
  p_company_id  uuid,
  p_invoice     jsonb,
  p_actor_type  text,
  p_actor_label text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id       uuid;
  v_line     jsonb;
  v_subtotal numeric := 0;
  v_discount numeric := coalesce((p_invoice ->> 'discount_amount')::numeric, 0);
  v_i        integer := 0;
  v_qty      numeric;
  v_unit     numeric;
begin
  if jsonb_typeof(p_invoice -> 'line_items') is distinct from 'array'
     or jsonb_array_length(p_invoice -> 'line_items') = 0 then
    raise exception 'At least one line item is required';
  end if;

  for v_line in select * from jsonb_array_elements(p_invoice -> 'line_items')
  loop
    v_qty  := coalesce((v_line ->> 'quantity')::numeric, 1);
    v_unit := coalesce((v_line ->> 'unit_amount')::numeric, 0);
    v_subtotal := v_subtotal + round(v_qty * v_unit, 2);
  end loop;

  insert into public.invoices
    (company_account_id, currency, issue_date, due_date, period_start, period_end,
     subtotal, discount_amount, discount_note, total,
     notes, payment_instructions, internal_notes)
  values
    (p_company_id,
     coalesce(nullif(trim(coalesce(p_invoice ->> 'currency', '')), ''), 'USD'),
     (p_invoice ->> 'issue_date')::date,
     (p_invoice ->> 'due_date')::date,
     (p_invoice ->> 'period_start')::date,
     (p_invoice ->> 'period_end')::date,
     v_subtotal, v_discount, p_invoice ->> 'discount_note',
     round(v_subtotal - v_discount, 2),
     p_invoice ->> 'notes', p_invoice ->> 'payment_instructions',
     p_invoice ->> 'internal_notes')
  returning id into v_id;

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

  perform public._billing_audit(p_actor_type, p_actor_label, p_company_id,
    'invoice_draft_created',
    jsonb_build_object('invoice_id', v_id, 'total', round(v_subtotal - v_discount, 2)),
    v_id, null);

  return v_id;
end;
$$;

-- ------------------------------------------------------------
-- 3. Admin: invite create / revoke
-- ------------------------------------------------------------
create or replace function public.admin_create_onboarding_invite(
  p_admin_token text,
  p_company_id  uuid,
  p_email       text,
  p_place_ids   uuid[] default '{}',
  p_event_ids   uuid[] default '{}',
  p_expires_days integer default 14
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label     text;
  v_token     text;
  v_pid       uuid;
  v_eid       uuid;
  v_claimable jsonb;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  if p_email is null or position('@' in p_email) = 0 then
    return jsonb_build_object('ok', false, 'error', 'A valid email is required');
  end if;
  if not exists (select 1 from public.company_accounts where id = p_company_id) then
    return jsonb_build_object('ok', false, 'error', 'Company not found');
  end if;
  v_label := public._admin_label(p_admin_token);

  -- Register the invited owner as a company admin (links on first sign-in
  -- via _resolve_company_user) and pre-attach the businesses (admin
  -- attachment IS the approval per the locations/events rule).
  perform public.admin_upsert_company_user(p_admin_token, p_company_id, p_email, null, 'admin');

  foreach v_pid in array coalesce(p_place_ids, '{}')
  loop
    perform public.admin_attach_location(p_admin_token, p_company_id, v_pid, null);
  end loop;
  foreach v_eid in array coalesce(p_event_ids, '{}')
  loop
    perform public.admin_attach_event(p_admin_token, p_company_id, v_eid, 'host', false);
  end loop;

  v_claimable := jsonb_build_object(
    'places', (
      select coalesce(jsonb_agg(jsonb_build_object('place_id', p.id, 'name', p.name)), '[]'::jsonb)
      from public.places p where p.id = any(coalesce(p_place_ids, '{}'))),
    'events', (
      select coalesce(jsonb_agg(jsonb_build_object('event_id', e.id, 'title', e.title)), '[]'::jsonb)
      from public.events e where e.id = any(coalesce(p_event_ids, '{}'))));

  insert into public.company_onboarding_invites
    (company_account_id, email, claimable, expires_at, created_by)
  values
    (p_company_id, lower(trim(p_email)), v_claimable,
     now() + (coalesce(p_expires_days, 14) || ' days')::interval, v_label)
  returning token into v_token;

  perform public._billing_audit('admin', v_label, p_company_id, 'onboarding_invite_created',
    jsonb_build_object('email', lower(trim(p_email)),
                       'places', coalesce(array_length(p_place_ids, 1), 0),
                       'events', coalesce(array_length(p_event_ids, 1), 0)));

  return jsonb_build_object('ok', true, 'token', v_token,
    'url', '/onboarding?invite=' || v_token);
end;
$$;

create or replace function public.admin_revoke_onboarding_invite(
  p_admin_token text,
  p_invite_id   uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_label text;
  v_row   company_onboarding_invites%rowtype;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  v_label := public._admin_label(p_admin_token);

  update public.company_onboarding_invites
     set status = 'revoked'
   where id = p_invite_id and status = 'pending'
  returning * into v_row;
  if v_row.id is null then
    return jsonb_build_object('ok', false, 'error', 'Invite not found or already used');
  end if;

  perform public._billing_audit('admin', v_label, v_row.company_account_id,
    'onboarding_invite_revoked', jsonb_build_object('invite_id', p_invite_id));
  return jsonb_build_object('ok', true);
end;
$$;

-- ------------------------------------------------------------
-- 4. Anon: pre-signup welcome lookup
-- ------------------------------------------------------------
create or replace function public.get_onboarding_invite(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inv     company_onboarding_invites%rowtype;
  v_company company_accounts%rowtype;
begin
  select * into v_inv from public.company_onboarding_invites where token = p_token;
  if v_inv.id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid', 'message', 'This invite link is not valid.');
  end if;
  if v_inv.status = 'revoked' then
    return jsonb_build_object('ok', false, 'error', 'revoked', 'message', 'This invite has been revoked. Contact TRODDR for a new link.');
  end if;
  if v_inv.status = 'accepted' then
    return jsonb_build_object('ok', false, 'error', 'accepted', 'message', 'This invite has already been used. Sign in to your dashboard.');
  end if;
  if v_inv.expires_at < now() then
    return jsonb_build_object('ok', false, 'error', 'expired', 'message', 'This invite link has expired. Contact TRODDR for a new one.');
  end if;

  select * into v_company from public.company_accounts where id = v_inv.company_account_id;

  return jsonb_build_object(
    'ok', true,
    'company_name', v_company.name,
    'email', v_inv.email,
    'claimable', v_inv.claimable,
    'expires_at', v_inv.expires_at);
end;
$$;

-- ------------------------------------------------------------
-- 5. Authenticated: accept / profile / catalog / quote
-- ------------------------------------------------------------
create or replace function public.accept_onboarding_invite(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_inv   company_onboarding_invites%rowtype;
  v_email text := lower(coalesce(auth.jwt() ->> 'email', ''));
  v_uid   uuid := auth.uid();
  v_user  company_users%rowtype;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'error', 'Sign in first');
  end if;

  select * into v_inv from public.company_onboarding_invites where token = p_token;
  if v_inv.id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid invite');
  end if;
  if v_inv.status not in ('pending', 'accepted') then
    return jsonb_build_object('ok', false, 'error', 'This invite is no longer usable');
  end if;
  if lower(v_inv.email) <> v_email then
    return jsonb_build_object('ok', false, 'error',
      'Sign in with the email this invite was sent to (' || v_inv.email || ').');
  end if;

  -- Links the new auth user to the pre-created company by email.
  v_user := public._resolve_company_user();
  if v_user.id is null or v_user.company_account_id <> v_inv.company_account_id then
    return jsonb_build_object('ok', false, 'error', 'Could not link your account to the company');
  end if;

  update public.company_onboarding_invites
     set status = 'accepted', accepted_at = coalesce(accepted_at, now()),
         accepted_user_id = coalesce(accepted_user_id, v_uid)
   where id = v_inv.id;

  perform public._billing_audit('company_user', v_email, v_inv.company_account_id,
    'onboarding_invite_accepted', jsonb_build_object('invite_id', v_inv.id));

  return jsonb_build_object('ok', true, 'company_account_id', v_inv.company_account_id);
end;
$$;

create or replace function public.submit_onboarding_profile(p_profile jsonb)
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

  update public.company_accounts
     set onboarding_profile = coalesce(p_profile, '{}'::jsonb), updated_at = now()
   where id = v_user.company_account_id;

  perform public._billing_audit('company_user', v_user.email, v_user.company_account_id,
    'onboarding_profile_saved', coalesce(p_profile, '{}'::jsonb));

  return jsonb_build_object('ok', true);
end;
$$;

-- Unprivileged catalog read for the recommendation calculator.
create or replace function public.get_billing_catalog_for_quote()
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then return jsonb_build_object('ok', false, 'error', 'Sign in first'); end if;
  return jsonb_build_object(
    'ok', true,
    'plans', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'key', sp.key, 'name', sp.name, 'description', sp.description,
        'plan_family', sp.plan_family, 'specials_per_location', sp.specials_per_location,
        'included_locations', sp.included_locations, 'included_admins', sp.included_admins,
        'monthly_price', sp.monthly_price, 'annual_price', sp.annual_price,
        'currency', sp.currency, 'entitlements', sp.entitlements) order by sp.sort_order), '[]'::jsonb)
      from public.subscription_plans sp where sp.is_active),
    'products', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'code', bp.code, 'item_type', bp.item_type, 'name', bp.name,
        'description', bp.description, 'unit_amount', bp.unit_amount,
        'min_amount', bp.min_amount, 'max_amount', bp.max_amount,
        'currency', bp.currency, 'billing_unit', bp.billing_unit,
        'entitlements', bp.entitlements, 'metadata', bp.metadata) order by bp.sort_order, bp.name), '[]'::jsonb)
      from public.billing_products bp where bp.is_active));
end;
$$;

-- The paywall: record the accepted recommendation as a request AND
-- auto-create a DRAFT invoice with catalog-priced lines. Never issues,
-- never activates access (admin reviews + issues from the console).
--
-- p_selection shape:
-- { "plan_key": "fp_duo", "billing_cycle": "annual",
--   "products": [ {"code":"major_event_hub","quantity":1}, ... ],
--   "notes": "..." }
create or replace function public.submit_onboarding_quote(p_selection jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user     company_users%rowtype;
  v_company  company_accounts%rowtype;
  v_currency text;
  v_plan     subscription_plans%rowtype;
  v_cycle    text;
  v_lines    jsonb := '[]'::jsonb;
  v_prod     jsonb;
  v_bp       billing_products%rowtype;
  v_unit     numeric;
  v_qty      numeric;
  v_amount   numeric;
  v_start    date := current_date;
  v_end      date;
  v_inv_id   uuid;
  v_req_id   uuid;
  v_summary  text := '';
begin
  v_user := public._resolve_company_user();
  if v_user.id is null then
    return jsonb_build_object('ok', false, 'error', 'Not signed in to a company account');
  end if;
  select * into v_company from public.company_accounts where id = v_user.company_account_id;
  v_currency := coalesce(v_company.preferred_currency, 'USD');

  -- Plan line (priced from the catalog, not the client).
  if coalesce(p_selection ->> 'plan_key', '') <> '' then
    select * into v_plan from public.subscription_plans
     where key = p_selection ->> 'plan_key' and is_active;
    if v_plan.key is null then
      return jsonb_build_object('ok', false, 'error', 'Unknown plan');
    end if;
    v_cycle := case when (p_selection ->> 'billing_cycle') = 'monthly' then 'monthly' else 'annual' end;
    v_unit := case when v_cycle = 'monthly' then v_plan.monthly_price else v_plan.annual_price end;
    -- Allowance-only loyalty plans (e.g. foundation_loyalty) have no
    -- recurring fee — record a $0 plan line so the draft still reflects it.
    v_unit := coalesce(v_unit, 0);
    v_end := case when v_cycle = 'monthly'
                  then (v_start + interval '1 month - 1 day')::date
                  else (v_start + interval '1 year - 1 day')::date end;
    v_lines := v_lines || jsonb_build_object(
      'item_type', 'founding_partner_subscription',
      'description', v_plan.name || ' (' || v_cycle || ')',
      'quantity', 1, 'unit_amount', v_unit,
      'period_start', v_start::text, 'period_end', v_end::text,
      'metadata', jsonb_build_object('plan_key', v_plan.key, 'billing_cycle', v_cycle,
                                     'source', 'onboarding_quote'));
    v_summary := v_summary || format('Plan: %s (%s). ', v_plan.name, v_cycle);
  end if;

  -- Product lines (ranged products estimated at min_amount; "from").
  if jsonb_typeof(p_selection -> 'products') = 'array' then
    for v_prod in select * from jsonb_array_elements(p_selection -> 'products')
    loop
      select * into v_bp from public.billing_products
       where code = v_prod ->> 'code' and is_active;
      if v_bp.code is null then continue; end if;
      v_qty := greatest(coalesce((v_prod ->> 'quantity')::numeric, 1), 1);
      v_unit := coalesce(v_bp.unit_amount, v_bp.min_amount, 0);
      v_lines := v_lines || jsonb_build_object(
        'item_type', v_bp.item_type,
        'product_code', v_bp.code,
        'description', v_bp.name || case when v_bp.unit_amount is null and v_bp.min_amount is not null
                                         then ' (estimate — from)' else '' end,
        'quantity', v_qty, 'unit_amount', v_unit,
        'metadata', jsonb_build_object('source', 'onboarding_quote',
                                       'estimate', (v_bp.unit_amount is null)));
      v_summary := v_summary || format('%s x%s. ', v_bp.name, v_qty);
    end loop;
  end if;

  if jsonb_array_length(v_lines) = 0 then
    return jsonb_build_object('ok', false, 'error', 'Select at least a plan or a product');
  end if;

  -- Auto-draft invoice for admin review (NOT issued).
  v_inv_id := public._save_invoice(v_company.id, jsonb_build_object(
    'currency', v_currency,
    'period_start', v_start::text,
    'notes', 'Prepared from your onboarding selections. TRODDR will confirm and send your final invoice.',
    'internal_notes', 'Source: onboarding quote (auto-drafted). Review ranged estimates before issuing.',
    'line_items', v_lines
  ), 'company_user', v_user.email);

  -- Record the request so it lands in the admin Requests queue.
  insert into public.company_requests (company_account_id, requested_by, request_type, message)
  values (v_company.id, v_user.id, 'billing_help',
          'Onboarding quote accepted. ' || v_summary ||
          coalesce('Notes: ' || nullif(trim(coalesce(p_selection ->> 'notes', '')), ''), ''))
  returning id into v_req_id;

  update public.company_accounts
     set onboarding_quote = coalesce(p_selection, '{}'::jsonb),
         onboarding_status = 'complete',
         updated_at = now()
   where id = v_company.id;

  perform public._billing_notify('request_submitted', v_company.id,
    'Onboarding quote ready to invoice — ' || v_company.name,
    'A prospect finished onboarding and accepted a quote. A draft invoice was created; review and issue it.',
    v_inv_id, v_req_id);

  perform public._billing_audit('company_user', v_user.email, v_company.id,
    'onboarding_quote_submitted',
    jsonb_build_object('invoice_id', v_inv_id, 'request_id', v_req_id, 'selection', p_selection),
    v_inv_id, null);

  return jsonb_build_object('ok', true, 'invoice_id', v_inv_id,
    'message', 'All set! Your dashboard is ready and TRODDR will send your invoice shortly.');
end;
$$;

-- ------------------------------------------------------------
-- 6. Surface invites + profile in admin_get_company
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
      'onboarding', jsonb_build_object(
        'status', ca.onboarding_status,
        'profile', ca.onboarding_profile,
        'quote', ca.onboarding_quote),
      'invites', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id', inv.id, 'email', inv.email, 'status', inv.status,
          'url', '/onboarding?invite=' || inv.token,
          'expires_at', inv.expires_at, 'created_at', inv.created_at,
          'accepted_at', inv.accepted_at) order by inv.created_at desc), '[]'::jsonb)
        from public.company_onboarding_invites inv where inv.company_account_id = ca.id),
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
-- 7. Grants / revokes
-- ------------------------------------------------------------
revoke execute on function public._save_invoice(uuid, jsonb, text, text) from public, anon, authenticated;

grant execute on function public.get_onboarding_invite(text) to anon, authenticated;
grant execute on function public.accept_onboarding_invite(text) to authenticated;
grant execute on function public.submit_onboarding_profile(jsonb) to authenticated;
grant execute on function public.get_billing_catalog_for_quote() to authenticated;
grant execute on function public.submit_onboarding_quote(jsonb) to authenticated;

grant execute on function public.admin_create_onboarding_invite(text, uuid, text, uuid[], uuid[], integer) to anon, authenticated;
grant execute on function public.admin_revoke_onboarding_invite(text, uuid) to anon, authenticated;
