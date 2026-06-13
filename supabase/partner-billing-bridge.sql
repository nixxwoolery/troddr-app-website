-- ============================================================
-- Partner dashboard -> Company billing bridge (READ-ONLY)
-- ------------------------------------------------------------
-- Loyalty partners open their dashboard with a partner access
-- token (place or event token). This RPC resolves that token to
-- the owning COMPANY ACCOUNT (via company_locations /
-- company_events) and returns a read-only billing summary for
-- /partner/billing.
--
-- Deliberately read-only: payment confirmation, onboarding, and
-- requests still require authenticated sign-in at
-- /company/billing (submit_* RPCs are auth-only). A leaked
-- partner link can see billing state but can never act on it.
--
-- Run AFTER company-billing-ops.sql.
-- ============================================================

create or replace function public.get_partner_billing_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place_id  uuid;
  v_event_id  uuid;
  v_company   company_accounts%rowtype;
  v_plan      subscription_plans%rowtype;
  v_access    jsonb;
begin
  -- Resolve token: place first, then event (same order as the
  -- other partner RPCs).
  select id into v_place_id from public.places  where partner_access_token = p_token;
  if v_place_id is null then
    select id into v_event_id from public.events where partner_access_token = p_token;
  end if;
  if v_place_id is null and v_event_id is null then
    return null; -- invalid/revoked token
  end if;

  -- Token -> company account
  if v_place_id is not null then
    select ca.* into v_company
      from public.company_locations cl
      join public.company_accounts ca on ca.id = cl.company_account_id
     where cl.place_id = v_place_id and cl.status = 'approved'
     order by cl.approved_at
     limit 1;
  else
    select ca.* into v_company
      from public.company_events ce
      join public.company_accounts ca on ca.id = ce.company_account_id
     where ce.event_id = v_event_id and ce.status = 'approved'
       and ce.relationship_type in ('host', 'organizer')
     order by case ce.relationship_type when 'host' then 0 else 1 end, ce.approved_at
     limit 1;
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
    'ok', true,
    'read_only', true,
    'company_billing_url', '/company/billing',
    'company', jsonb_build_object(
      'name', v_company.name,
      'billing_email', v_company.billing_email,
      'preferred_currency', v_company.preferred_currency),
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
        'status', v_access ->> 'status',
        'current_period_start', s.current_period_start,
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
        'title', e.title, 'start_date', e.start_date,
        'parent_event_id', e.parent_event_id,
        'relationship_type', ce.relationship_type,
        'comped', ce.comped,
        'package', (select bp.name from public.billing_products bp
                     where bp.code = ce.package_product_code))
        order by e.start_date desc nulls last), '[]'::jsonb)
      from public.company_events ce
      join public.events e on e.id = ce.event_id
      where ce.company_account_id = v_company.id and ce.status = 'approved'),
    'entitlements', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'key', ce.entitlement_key, 'name', ed.name,
        'category', ed.category, 'source', ce.source,
        'expires_at', ce.expires_at)
        order by ed.category, ce.entitlement_key), '[]'::jsonb)
      from public.company_entitlements ce
      join public.entitlement_definitions ed on ed.key = ce.entitlement_key
      where ce.company_account_id = v_company.id
        and ce.is_active = true
        and ce.starts_at <= current_date
        and (ce.expires_at is null or ce.expires_at >= current_date)),
    'invoices', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'invoice_number', i.invoice_number,
        'status', public._invoice_effective_status(i.status, i.due_date),
        'currency', i.currency,
        'issue_date', i.issue_date, 'due_date', i.due_date,
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
          select jsonb_build_object('status', pc.status, 'paid_on', pc.paid_on,
            'review_note', pc.review_note)
          from public.payment_confirmations pc
          where pc.invoice_id = i.id
          order by pc.created_at desc limit 1)
      ) order by i.issue_date desc nulls last, i.created_at desc), '[]'::jsonb)
      from public.invoices i
      where i.company_account_id = v_company.id
        and i.status <> 'draft'),
    'payment_instructions', jsonb_build_object(
      'USD', public.payment_instructions_for_currency('USD'),
      'JMD', public.payment_instructions_for_currency('JMD')),
    'invoice_footer_copy', coalesce(public._billing_setting('invoice_footer_copy'), '[]'::jsonb)
  );
end;
$$;

grant execute on function public.get_partner_billing_by_token(text) to anon, authenticated;
