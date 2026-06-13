-- ============================================================
-- TRODDR Company Billing — Loyalty plan model
-- ------------------------------------------------------------
-- Makes Foundation / Loyalty a first-class PLAN inside the
-- company-account system (the user's chosen model: "loyalty IS a
-- plan in the new system"). Loyalty partners are not billed like
-- the founding-partner subscription tiers — their plan centres on
-- an INCLUDED SPECIALS ALLOWANCE per location (2/location/cycle),
-- with extras rolling up as billable.
--
-- Adds:
--   - subscription_plans.plan_family + specials_per_location
--   - a Foundation Loyalty plan (and a specials allowance on the
--     existing Founding Partner / Loyalty tiers)
--   - company_specials_usage(): per-location included-vs-used +
--     billable extras for the current cycle, reading the existing
--     public.specials billing columns (see billing-specials.sql)
--   - specials block + plan_family/specials_per_location wired into
--     get_company_billing() and get_partner_billing_by_token()
--
-- Run AFTER company-billing-ops.sql (and billing-specials.sql,
-- which owns the specials.billing_status columns).
-- ============================================================

-- ------------------------------------------------------------
-- 1. Plan model: family + specials allowance
-- ------------------------------------------------------------
alter table public.subscription_plans
  add column if not exists plan_family text not null default 'standard'
    check (plan_family in ('standard', 'loyalty', 'event', 'sponsor')),
  add column if not exists specials_per_location integer not null default 0;

-- The Founding Partner / Loyalty tiers each include 2 standard
-- specials per location per cycle (per the pricing sheet).
update public.subscription_plans
   set plan_family = 'loyalty', specials_per_location = 2
 where key in ('fp_single', 'fp_duo', 'fp_trio', 'fp_group');

-- Standalone single-location Foundation Loyalty plan — the entry
-- loyalty plan for a one-restaurant partner (J$ pricing, matching
-- the legacy Foundation model: 2 included specials/location).
insert into public.subscription_plans
  (key, name, description, included_locations, included_admins,
   monthly_price, annual_price, currency, entitlements,
   plan_family, specials_per_location, sort_order)
values
  ('foundation_loyalty', 'Foundation Loyalty',
   '1 location · 2 included specials per location each billing cycle',
   1, 1, null, null, 'JMD',
   '["dashboard_access","loyalty_program","partner_bookings"]'::jsonb,
   'loyalty', 2, 0)
on conflict (key) do update
  set name = excluded.name, description = excluded.description,
      plan_family = 'loyalty', specials_per_location = 2,
      entitlements = excluded.entitlements, is_active = true;

-- ------------------------------------------------------------
-- 2. Per-location specials usage for the current billing cycle
-- ------------------------------------------------------------
-- Mirrors reserve_special_billing()'s counting rules:
--   included used = pending/approved, non-void specials this cycle
--   billable extras = billing_status in (pending_billable, billable)
-- The allowance comes from the company's plan (specials_per_location).
create or replace function public.company_specials_usage(p_company_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_limit       integer;
  v_cycle_start date := date_trunc('month', now())::date;
  v_cycle_end   date := (date_trunc('month', now()) + interval '1 month - 1 day')::date;
begin
  select coalesce(sp.specials_per_location, 0) into v_limit
    from public.subscriptions s
    join public.subscription_plans sp on sp.key = s.plan_key
   where s.company_account_id = p_company_id;
  v_limit := coalesce(v_limit, 0);

  return jsonb_build_object(
    'included_per_location', v_limit,
    'cycle_start', v_cycle_start,
    'cycle_end', v_cycle_end,
    'locations', (
      select coalesce(jsonb_agg(loc order by loc->>'name'), '[]'::jsonb)
      from (
        select jsonb_build_object(
          'place_id', cl.place_id,
          'name', coalesce(cl.label, p.name),
          'included_limit', v_limit,
          'used', (
            select count(*) from public.specials s
             where s.place_id = cl.place_id
               and coalesce(s.submission_status, 'approved') in ('pending', 'approved')
               and coalesce(s.billing_status, 'included') <> 'void'
               and s.submitted_at::date between v_cycle_start and v_cycle_end),
          'billable_extras', (
            select count(*) from public.specials s
             where s.place_id = cl.place_id
               and coalesce(s.billing_status, 'included') in ('pending_billable', 'billable')
               and s.submitted_at::date between v_cycle_start and v_cycle_end)
        ) as loc
        from public.company_locations cl
        left join public.places p on p.id = cl.place_id
        where cl.company_account_id = p_company_id and cl.status = 'approved'
      ) rows),
    'billable_total', (
      select count(*) from public.specials s
      join public.company_locations cl on cl.place_id = s.place_id
      where cl.company_account_id = p_company_id and cl.status = 'approved'
        and coalesce(s.billing_status, 'included') in ('pending_billable', 'billable')
        and s.submitted_at::date between v_cycle_start and v_cycle_end)
  );
end;
$$;

revoke execute on function public.company_specials_usage(uuid) from public, anon;
grant execute on function public.company_specials_usage(uuid) to authenticated;

-- ------------------------------------------------------------
-- 3. Wire plan_family + specials into the billing payloads
-- ------------------------------------------------------------
-- get_company_billing(): extend the plan block and add a specials
-- block for loyalty-family plans. (Full body re-declared so the
-- plan jsonb carries plan_family/specials_per_location.)
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
      'plan_family', v_plan.plan_family,
      'specials_per_location', v_plan.specials_per_location,
      'included_locations', v_plan.included_locations,
      'included_admins', v_plan.included_admins,
      'monthly_price', v_plan.monthly_price, 'annual_price', v_plan.annual_price,
      'currency', v_plan.currency) end,
    'specials', case when v_plan.plan_family = 'loyalty'
      then public.company_specials_usage(v_company.id) else null end,
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
        'key', ce.entitlement_key, 'name', ed.name, 'category', ed.category,
        'source', ce.source, 'starts_at', ce.starts_at, 'expires_at', ce.expires_at,
        'active_now', (ce.is_active and ce.starts_at <= current_date
                       and (ce.expires_at is null or ce.expires_at >= current_date))
      ) order by ed.category, ce.entitlement_key), '[]'::jsonb)
      from public.company_entitlements ce
      join public.entitlement_definitions ed on ed.key = ce.entitlement_key
      where ce.company_account_id = v_company.id and ce.is_active = true),
    'invoices', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', i.id, 'invoice_number', i.invoice_number,
        'status', public._invoice_effective_status(i.status, i.due_date),
        'currency', i.currency, 'issue_date', i.issue_date, 'due_date', i.due_date,
        'period_start', i.period_start, 'period_end', i.period_end,
        'subtotal', i.subtotal, 'discount_amount', i.discount_amount,
        'discount_note', i.discount_note, 'total', i.total,
        'notes', i.notes, 'payment_instructions', i.payment_instructions, 'paid_at', i.paid_at,
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
          where pc.invoice_id = i.id order by pc.created_at desc limit 1)
      ) order by i.issue_date desc nulls last, i.created_at desc), '[]'::jsonb)
      from public.invoices i
      where i.company_account_id = v_company.id and i.status <> 'draft'),
    'requests', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', r.id, 'request_type', r.request_type, 'message', r.message,
        'status', r.status, 'created_at', r.created_at,
        'related_event_id', r.related_event_id,
        'related_location_id', r.related_location_id) order by r.created_at desc), '[]'::jsonb)
      from public.company_requests r where r.company_account_id = v_company.id),
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

-- get_partner_billing_by_token(): add plan_family/specials_per_location
-- and the specials block (read-only loyalty view).
create or replace function public.get_partner_billing_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place_id uuid;
  v_event_id uuid;
  v_company  company_accounts%rowtype;
  v_plan     subscription_plans%rowtype;
  v_access   jsonb;
begin
  select id into v_place_id from public.places  where partner_access_token = p_token;
  if v_place_id is null then
    select id into v_event_id from public.events where partner_access_token = p_token;
  end if;
  if v_place_id is null and v_event_id is null then return null; end if;

  if v_place_id is not null then
    select ca.* into v_company
      from public.company_locations cl
      join public.company_accounts ca on ca.id = cl.company_account_id
     where cl.place_id = v_place_id and cl.status = 'approved'
     order by cl.approved_at limit 1;
  else
    select ca.* into v_company
      from public.company_events ce
      join public.company_accounts ca on ca.id = ce.company_account_id
     where ce.event_id = v_event_id and ce.status = 'approved'
       and ce.relationship_type in ('host', 'organizer')
     order by case ce.relationship_type when 'host' then 0 else 1 end, ce.approved_at limit 1;
  end if;

  if v_company.id is null then
    return jsonb_build_object('ok', false, 'error', 'no_company',
      'message', 'This listing is not attached to a TRODDR company billing account yet.');
  end if;

  v_access := public.company_access_state(v_company.id);
  select sp.* into v_plan
    from public.subscriptions s
    join public.subscription_plans sp on sp.key = s.plan_key
   where s.company_account_id = v_company.id;

  return jsonb_build_object(
    'ok', true, 'read_only', true, 'company_billing_url', '/company/billing',
    'company', jsonb_build_object('name', v_company.name,
      'billing_email', v_company.billing_email, 'preferred_currency', v_company.preferred_currency),
    'access', v_access,
    'plan', case when v_plan.key is null then null else jsonb_build_object(
      'key', v_plan.key, 'name', v_plan.name,
      'plan_family', v_plan.plan_family,
      'specials_per_location', v_plan.specials_per_location,
      'included_locations', v_plan.included_locations,
      'included_admins', v_plan.included_admins,
      'monthly_price', v_plan.monthly_price, 'annual_price', v_plan.annual_price,
      'currency', v_plan.currency) end,
    'specials', case when v_plan.plan_family = 'loyalty'
      then public.company_specials_usage(v_company.id) else null end,
    'subscription', (
      select jsonb_build_object('plan_key', s.plan_key, 'billing_cycle', s.billing_cycle,
        'status', v_access ->> 'status', 'current_period_start', s.current_period_start,
        'paid_through', s.paid_through)
      from public.subscriptions s where s.company_account_id = v_company.id),
    'locations', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'name', coalesce(cl.label, p.name), 'town', p.town, 'parish', p.parish)
        order by p.name), '[]'::jsonb)
      from public.company_locations cl
      left join public.places p on p.id = cl.place_id
      where cl.company_account_id = v_company.id and cl.status = 'approved'),
    'events', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'title', e.title, 'start_date', e.start_date, 'parent_event_id', e.parent_event_id,
        'relationship_type', ce.relationship_type, 'comped', ce.comped,
        'package', (select bp.name from public.billing_products bp where bp.code = ce.package_product_code))
        order by e.start_date desc nulls last), '[]'::jsonb)
      from public.company_events ce
      join public.events e on e.id = ce.event_id
      where ce.company_account_id = v_company.id and ce.status = 'approved'),
    'entitlements', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'key', ce.entitlement_key, 'name', ed.name, 'category', ed.category,
        'source', ce.source, 'expires_at', ce.expires_at)
        order by ed.category, ce.entitlement_key), '[]'::jsonb)
      from public.company_entitlements ce
      join public.entitlement_definitions ed on ed.key = ce.entitlement_key
      where ce.company_account_id = v_company.id and ce.is_active = true
        and ce.starts_at <= current_date
        and (ce.expires_at is null or ce.expires_at >= current_date)),
    'invoices', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'invoice_number', i.invoice_number,
        'status', public._invoice_effective_status(i.status, i.due_date),
        'currency', i.currency, 'issue_date', i.issue_date, 'due_date', i.due_date,
        'period_start', i.period_start, 'period_end', i.period_end,
        'subtotal', i.subtotal, 'discount_amount', i.discount_amount,
        'discount_note', i.discount_note, 'total', i.total,
        'notes', i.notes, 'payment_instructions', i.payment_instructions,
        'line_items', (
          select coalesce(jsonb_agg(jsonb_build_object(
            'description', li.description, 'quantity', li.quantity,
            'unit_amount', li.unit_amount, 'amount', li.amount,
            'period_start', li.period_start, 'period_end', li.period_end)
            order by li.sort_order, li.created_at), '[]'::jsonb)
          from public.invoice_line_items li where li.invoice_id = i.id),
        'payment_confirmation', (
          select jsonb_build_object('status', pc.status, 'paid_on', pc.paid_on, 'review_note', pc.review_note)
          from public.payment_confirmations pc where pc.invoice_id = i.id
          order by pc.created_at desc limit 1)
      ) order by i.issue_date desc nulls last, i.created_at desc), '[]'::jsonb)
      from public.invoices i
      where i.company_account_id = v_company.id and i.status <> 'draft'),
    'payment_instructions', jsonb_build_object(
      'USD', public.payment_instructions_for_currency('USD'),
      'JMD', public.payment_instructions_for_currency('JMD')),
    'invoice_footer_copy', coalesce(public._billing_setting('invoice_footer_copy'), '[]'::jsonb)
  );
end;
$$;
