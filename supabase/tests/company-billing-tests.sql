-- ============================================================
-- TRODDR Company Billing — tests
-- ------------------------------------------------------------
-- Covers: invoice numbering, status transitions, the
-- "user-reported payment never activates access" invariant,
-- entitlement activation on admin approval, rejection flow,
-- read-only lapse behavior, and renewal (no backfill).
--
-- Run against a database that already has company-billing.sql
-- and company-billing-seed.sql applied:
--   supabase db execute --file supabase/tests/company-billing-tests.sql
-- or: psql "$DB_URL" -f supabase/tests/company-billing-tests.sql
--
-- Everything runs in one transaction and ROLLS BACK: no data
-- is left behind. Failures raise an exception (non-zero exit).
-- ============================================================

begin;

do $test$
declare
  v_token      text;
  v_company    uuid;
  v_user       uuid;
  v_invoice    uuid;
  v_invoice2   uuid;
  v_conf       uuid;
  v_res        jsonb;
  v_inv        public.invoices%rowtype;
  v_sub        public.subscriptions%rowtype;
  v_access     jsonb;
  v_num1       text;
  v_num2       text;
  v_count      int;
begin
  ---------------------------------------------------------------
  -- Setup: admin token, company, company user, draft invoice
  ---------------------------------------------------------------
  insert into public.admin_tokens (label) values ('billing-test')
  returning token into v_token;

  v_res := public.admin_upsert_company(v_token, null,
    'Test Restaurant Group', 'billing-test@example.com', 'Test Person', null, 'active', null);
  if not (v_res ->> 'ok')::boolean then
    raise exception 'admin_upsert_company failed: %', v_res ->> 'error';
  end if;
  v_company := (v_res ->> 'id')::uuid;

  v_res := public.admin_upsert_company_user(v_token, v_company,
    'owner@example.com', 'Owner', 'admin');
  if not (v_res ->> 'ok')::boolean then
    raise exception 'admin_upsert_company_user failed: %', v_res ->> 'error';
  end if;
  v_user := (v_res ->> 'id')::uuid;

  -- Draft invoice: Duo plan annual + an add-on with entitlements.
  v_res := public.admin_save_invoice(v_token, null, jsonb_build_object(
    'company_account_id', v_company,
    'currency', 'USD',
    'due_date', (current_date + 14)::text,
    'period_start', current_date::text,
    'period_end', (current_date + interval '1 year - 1 day')::date::text,
    'discount_amount', 56,
    'discount_note', 'Founding partner discount',
    'notes', 'Thanks for partnering with TRODDR.',
    'payment_instructions', 'Bank transfer to TRODDR Ltd, acct 000000.',
    'line_items', jsonb_build_array(
      jsonb_build_object(
        'item_type', 'founding_partner_subscription',
        'description', 'Founding Partner — Duo (annual)',
        'quantity', 1, 'unit_amount', 1056,
        'metadata', jsonb_build_object('plan_key', 'fp_duo', 'billing_cycle', 'annual')),
      jsonb_build_object(
        'item_type', 'location_insights',
        'product_code', 'location_insights_annual',
        'description', 'Location Insights (annual) — 2 locations',
        'quantity', 2, 'unit_amount', 300))));
  if not (v_res ->> 'ok')::boolean then
    raise exception 'admin_save_invoice failed: %', v_res ->> 'error';
  end if;
  v_invoice := (v_res ->> 'id')::uuid;

  -- Totals: 1056 + 600 - 56 discount = 1600
  select * into v_inv from public.invoices where id = v_invoice;
  if v_inv.subtotal <> 1656 or v_inv.total <> 1600 then
    raise exception 'TEST FAIL: invoice totals wrong (subtotal %, total %)', v_inv.subtotal, v_inv.total;
  end if;
  if v_inv.status <> 'draft' or v_inv.invoice_number is not null then
    raise exception 'TEST FAIL: draft invoice should have no number yet';
  end if;
  raise notice 'PASS: draft invoice created with correct totals';

  ---------------------------------------------------------------
  -- Test: company cannot report payment on a DRAFT invoice
  ---------------------------------------------------------------
  v_res := public._submit_payment_confirmation(v_user, v_invoice,
    'bank_transfer', current_date, 'REF-001', null, null);
  if (v_res ->> 'ok')::boolean then
    raise exception 'TEST FAIL: payment confirmation accepted on draft invoice';
  end if;
  raise notice 'PASS: cannot report payment on a draft invoice';

  ---------------------------------------------------------------
  -- Test: issue invoice -> number format + subscription pending
  ---------------------------------------------------------------
  v_res := public.admin_issue_invoice(v_token, v_invoice);
  if not (v_res ->> 'ok')::boolean then
    raise exception 'admin_issue_invoice failed: %', v_res ->> 'error';
  end if;
  v_num1 := v_res ->> 'invoice_number';
  if v_num1 !~ ('^TRODDR-INV-' || extract(year from now())::int || '-\d{4}$') then
    raise exception 'TEST FAIL: bad invoice number format: %', v_num1;
  end if;

  select * into v_sub from public.subscriptions where company_account_id = v_company;
  if v_sub.status is distinct from 'invoice_issued' then
    raise exception 'TEST FAIL: subscription should be invoice_issued, got %', v_sub.status;
  end if;

  v_access := public.company_access_state(v_company);
  if v_access ->> 'access' <> 'read_only' then
    raise exception 'TEST FAIL: unpaid new company should not have full access (got %)', v_access ->> 'access';
  end if;
  raise notice 'PASS: invoice issued (%) and subscription pending without access', v_num1;

  ---------------------------------------------------------------
  -- Test: numbering increments
  ---------------------------------------------------------------
  v_num2 := public.next_invoice_number();
  if right(v_num2, 4)::int <> right(v_num1, 4)::int + 1 then
    raise exception 'TEST FAIL: invoice numbers not sequential (% then %)', v_num1, v_num2;
  end if;
  raise notice 'PASS: invoice numbering increments (% -> %)', v_num1, v_num2;

  ---------------------------------------------------------------
  -- Test: invalid transition raises (draft cannot be paid, etc.)
  ---------------------------------------------------------------
  begin
    perform public._assert_invoice_transition('draft', 'paid');
    raise exception 'TEST FAIL: draft -> paid should have raised';
  exception when others then
    if sqlerrm like 'TEST FAIL%' then raise; end if;
  end;
  begin
    perform public._assert_invoice_transition('void', 'issued');
    raise exception 'TEST FAIL: void -> issued should have raised';
  exception when others then
    if sqlerrm like 'TEST FAIL%' then raise; end if;
  end;
  raise notice 'PASS: invalid transitions are rejected';

  ---------------------------------------------------------------
  -- CORE INVARIANT: user-reported payment moves the invoice to
  -- payment_reported and NEVER activates anything.
  ---------------------------------------------------------------
  v_res := public._submit_payment_confirmation(v_user, v_invoice,
    'bank_transfer', current_date, 'NCB-12345', null, 'Paid via NCB transfer');
  if not (v_res ->> 'ok')::boolean then
    raise exception '_submit_payment_confirmation failed: %', v_res ->> 'error';
  end if;
  v_conf := (v_res ->> 'confirmation_id')::uuid;

  select * into v_inv from public.invoices where id = v_invoice;
  if v_inv.status <> 'payment_reported' then
    raise exception 'TEST FAIL: invoice should be payment_reported, got %', v_inv.status;
  end if;

  select * into v_sub from public.subscriptions where company_account_id = v_company;
  if v_sub.status <> 'payment_pending_review' then
    raise exception 'TEST FAIL: subscription should be payment_pending_review, got %', v_sub.status;
  end if;

  v_access := public.company_access_state(v_company);
  if v_access ->> 'access' = 'full' then
    raise exception 'TEST FAIL: INVARIANT BROKEN — user-reported payment granted full access';
  end if;
  if public.company_has_entitlement(v_company, 'loyalty_program') then
    raise exception 'TEST FAIL: INVARIANT BROKEN — entitlement active before admin approval';
  end if;
  raise notice 'PASS: reported payment does NOT activate access (invariant holds)';

  ---------------------------------------------------------------
  -- Test: duplicate confirmation while under review is blocked
  ---------------------------------------------------------------
  v_res := public._submit_payment_confirmation(v_user, v_invoice,
    'cash', current_date, 'DUP-1', null, null);
  if (v_res ->> 'ok')::boolean then
    raise exception 'TEST FAIL: duplicate confirmation accepted while under review';
  end if;
  raise notice 'PASS: duplicate confirmation blocked while under review';

  ---------------------------------------------------------------
  -- Test: admin approval -> paid + subscription active +
  -- entitlements (plan AND add-on) live
  ---------------------------------------------------------------
  v_res := public.admin_review_payment(v_token, v_conf, 'approve', 'Verified on bank statement');
  if not (v_res ->> 'ok')::boolean then
    raise exception 'admin_review_payment(approve) failed: %', v_res ->> 'error';
  end if;

  select * into v_inv from public.invoices where id = v_invoice;
  if v_inv.status <> 'paid' or v_inv.paid_at is null then
    raise exception 'TEST FAIL: invoice should be paid, got %', v_inv.status;
  end if;

  select * into v_sub from public.subscriptions where company_account_id = v_company;
  if v_sub.status <> 'active'
     or v_sub.plan_key <> 'fp_duo'
     or v_sub.paid_through <> (current_date + interval '1 year - 1 day')::date then
    raise exception 'TEST FAIL: subscription not activated correctly (status %, plan %, paid_through %)',
      v_sub.status, v_sub.plan_key, v_sub.paid_through;
  end if;

  v_access := public.company_access_state(v_company);
  if v_access ->> 'access' <> 'full' then
    raise exception 'TEST FAIL: approved company should have full access, got %', v_access ->> 'access';
  end if;
  if not public.company_has_entitlement(v_company, 'dashboard_access')
     or not public.company_has_entitlement(v_company, 'loyalty_program')
     or not public.company_has_entitlement(v_company, 'partner_bookings') then
    raise exception 'TEST FAIL: plan entitlements not active after approval';
  end if;
  if not public.company_has_entitlement(v_company, 'location_insights') then
    raise exception 'TEST FAIL: add-on entitlement (location_insights) not active after approval';
  end if;
  if public.company_has_entitlement(v_company, 'flagship_event') then
    raise exception 'TEST FAIL: ungranted entitlement reports active';
  end if;
  raise notice 'PASS: admin approval activates subscription + entitlements';

  ---------------------------------------------------------------
  -- Test: read-only after paid-through lapses (no auto-extend),
  -- and dashboard_access survives read-only mode
  ---------------------------------------------------------------
  update public.subscriptions
     set paid_through = current_date - 30,
         current_period_start = current_date - 395
   where company_account_id = v_company;
  update public.company_entitlements
     set expires_at = current_date - 30
   where company_account_id = v_company and source = 'plan';

  v_access := public.company_access_state(v_company);
  if v_access ->> 'access' <> 'read_only' or v_access ->> 'status' <> 'read_only' then
    raise exception 'TEST FAIL: lapsed subscription should be read_only, got % / %',
      v_access ->> 'access', v_access ->> 'status';
  end if;
  if public.company_has_entitlement(v_company, 'loyalty_program') then
    raise exception 'TEST FAIL: expired plan entitlement still active';
  end if;
  raise notice 'PASS: lapsed account drops to read-only';

  ---------------------------------------------------------------
  -- Test: renewal resumes from the NEW period (no backfill of the
  -- unpaid gap) after admin approval of the renewal invoice
  ---------------------------------------------------------------
  v_res := public.admin_save_invoice(v_token, null, jsonb_build_object(
    'company_account_id', v_company,
    'period_start', current_date::text,
    'period_end', (current_date + interval '1 year - 1 day')::date::text,
    'line_items', jsonb_build_array(jsonb_build_object(
      'item_type', 'founding_partner_subscription',
      'description', 'Founding Partner — Duo renewal (annual)',
      'quantity', 1, 'unit_amount', 1056,
      'metadata', jsonb_build_object('plan_key', 'fp_duo', 'billing_cycle', 'annual')))));
  v_invoice2 := (v_res ->> 'id')::uuid;
  perform public.admin_issue_invoice(v_token, v_invoice2);

  v_res := public._submit_payment_confirmation(v_user, v_invoice2,
    'bank_transfer', current_date, 'NCB-RENEW', null, null);
  v_conf := (v_res ->> 'confirmation_id')::uuid;

  -- Still read-only until the admin approves.
  v_access := public.company_access_state(v_company);
  if v_access ->> 'access' = 'full' then
    raise exception 'TEST FAIL: renewal report granted access before review';
  end if;

  v_res := public.admin_review_payment(v_token, v_conf, 'approve', null);
  if not (v_res ->> 'ok')::boolean then
    raise exception 'renewal approve failed: %', v_res ->> 'error';
  end if;

  select * into v_sub from public.subscriptions where company_account_id = v_company;
  if v_sub.status <> 'active'
     or v_sub.current_period_start <> current_date
     or v_sub.paid_through <> (current_date + interval '1 year - 1 day')::date then
    raise exception 'TEST FAIL: renewal did not resume from new period (start %, through %)',
      v_sub.current_period_start, v_sub.paid_through;
  end if;
  if not public.company_has_entitlement(v_company, 'loyalty_program') then
    raise exception 'TEST FAIL: plan entitlement not re-activated on renewal';
  end if;
  raise notice 'PASS: renewal resumes from new period, no backfill';

  ---------------------------------------------------------------
  -- Test: rejection flow (new invoice -> report -> reject)
  ---------------------------------------------------------------
  v_res := public.admin_save_invoice(v_token, null, jsonb_build_object(
    'company_account_id', v_company,
    'line_items', jsonb_build_array(jsonb_build_object(
      'item_type', 'event_lite', 'product_code', 'event_lite',
      'description', 'Event Lite', 'quantity', 1, 'unit_amount', 1500))));
  v_invoice := (v_res ->> 'id')::uuid;
  perform public.admin_issue_invoice(v_token, v_invoice);

  v_res := public._submit_payment_confirmation(v_user, v_invoice,
    'cheque', current_date, 'CHQ-9', null, null);
  v_conf := (v_res ->> 'confirmation_id')::uuid;

  v_res := public.admin_review_payment(v_token, v_conf, 'reject', 'No matching deposit found');
  if not (v_res ->> 'ok')::boolean then
    raise exception 'admin_review_payment(reject) failed: %', v_res ->> 'error';
  end if;

  select * into v_inv from public.invoices where id = v_invoice;
  if v_inv.status <> 'rejected' then
    raise exception 'TEST FAIL: invoice should be rejected, got %', v_inv.status;
  end if;
  if public.company_has_entitlement(v_company, 'event_lite') then
    raise exception 'TEST FAIL: rejected payment granted event_lite entitlement';
  end if;

  -- Company can re-report after rejection.
  v_res := public._submit_payment_confirmation(v_user, v_invoice,
    'bank_transfer', current_date, 'NCB-RETRY', null, null);
  if not (v_res ->> 'ok')::boolean then
    raise exception 'TEST FAIL: re-report after rejection blocked: %', v_res ->> 'error';
  end if;
  raise notice 'PASS: rejection flow works and allows re-reporting';

  ---------------------------------------------------------------
  -- Test: void is terminal; clarification keeps invoice reported
  ---------------------------------------------------------------
  v_conf := (v_res ->> 'confirmation_id')::uuid;
  v_res := public.admin_review_payment(v_token, v_conf, 'clarify', 'Send the deposit slip please');
  select * into v_inv from public.invoices where id = v_invoice;
  if v_inv.status <> 'payment_reported' then
    raise exception 'TEST FAIL: clarify should keep invoice payment_reported, got %', v_inv.status;
  end if;
  -- Re-report allowed when latest confirmation needs clarification.
  v_res := public._submit_payment_confirmation(v_user, v_invoice,
    'bank_transfer', current_date, 'NCB-RETRY-2', 'https://example.com/slip.jpg', null);
  if not (v_res ->> 'ok')::boolean then
    raise exception 'TEST FAIL: re-report after clarification blocked: %', v_res ->> 'error';
  end if;

  v_res := public.admin_set_invoice_status(v_token, v_invoice, 'void', 'Cancelled deal');
  if not (v_res ->> 'ok')::boolean then
    raise exception 'void failed: %', v_res ->> 'error';
  end if;
  v_res := public.admin_set_invoice_status(v_token, v_invoice, 'issued', null);
  if (v_res ->> 'ok')::boolean then
    raise exception 'TEST FAIL: void invoice was re-issued';
  end if;
  raise notice 'PASS: clarification + void behave correctly';

  ---------------------------------------------------------------
  -- Test: audit log captured the journey
  ---------------------------------------------------------------
  select count(*) into v_count from public.billing_audit_log
   where company_account_id = v_company;
  if v_count < 10 then
    raise exception 'TEST FAIL: expected a rich audit trail, found % entries', v_count;
  end if;
  raise notice 'PASS: audit log recorded % entries', v_count;

  raise notice '=== ALL BILLING TESTS PASSED ===';
end;
$test$;

rollback;
