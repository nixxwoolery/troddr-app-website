-- ============================================================
-- TRODDR Company Billing OPS — tests
-- ------------------------------------------------------------
-- Covers: company event attachment (incl. series children),
-- company users CANNOT self-add locations/events, billing page
-- payload shows approved events+locations, event dashboard
-- billing reflects the host company, payment instructions by
-- currency, onboarding gating, company setup request flow,
-- renewal invoice + read-only maintenance, request workflow
-- transitions, and audit entries for reason-required overrides.
--
-- Requires: company-billing.sql, company-billing-seed.sql,
-- company-billing-ops.sql applied. Runs in one transaction and
-- ROLLS BACK. Failures raise (non-zero exit).
--   supabase db execute --file supabase/tests/company-billing-ops-tests.sql
-- ============================================================

begin;

do $test$
declare
  v_token    text;
  v_company  uuid;
  v_user     uuid;
  v_auth_uid uuid := gen_random_uuid();
  v_place    uuid;
  v_parent   uuid;
  v_child1   uuid;
  v_child2   uuid;
  v_ce_id    uuid;
  v_invoice  uuid;
  v_conf     uuid;
  v_req      uuid;
  v_setup    uuid;
  v_res      jsonb;
  v_eb       jsonb;
  v_count    int;
  v_sub      public.subscriptions%rowtype;
begin
  ---------------------------------------------------------------
  -- Setup: admin token, company, user, place, event series
  ---------------------------------------------------------------
  insert into public.admin_tokens (label) values ('ops-test') returning token into v_token;

  v_res := public.admin_upsert_company(v_token, null,
    'JFDF Productions', 'ops-test@example.com', 'Producer', null, 'active', null,
    'event_host', 'manual', null);
  if not (v_res ->> 'ok')::boolean then
    raise exception 'admin_upsert_company failed: %', v_res ->> 'error';
  end if;
  v_company := (v_res ->> 'id')::uuid;

  -- account_type persisted?
  if (select account_type from public.company_accounts where id = v_company) <> 'event_host' then
    raise exception 'TEST FAIL: account_type not persisted';
  end if;

  v_res := public.admin_upsert_company_user(v_token, v_company, 'producer@example.com', 'Producer', 'admin');
  v_user := (v_res ->> 'id')::uuid;

  insert into public.places (name, slug)
  values ('Ops Test Bistro', 'ops-test-bistro-' || substr(md5(random()::text), 1, 6))
  returning id into v_place;
  insert into public.events (title, slug)
  values ('JFDF 2026', 'jfdf-2026-' || substr(md5(random()::text), 1, 6))
  returning id into v_parent;
  insert into public.events (title, slug, parent_event_id)
  values ('JFDF Night 1', 'jfdf-n1-' || substr(md5(random()::text), 1, 6), v_parent)
  returning id into v_child1;
  insert into public.events (title, slug, parent_event_id)
  values ('JFDF Night 2', 'jfdf-n2-' || substr(md5(random()::text), 1, 6), v_parent)
  returning id into v_child2;

  ---------------------------------------------------------------
  -- Test: company event attachment + series children
  ---------------------------------------------------------------
  v_res := public.admin_attach_event(v_token, v_company, v_parent, 'host', true);
  if not (v_res ->> 'ok')::boolean or (v_res ->> 'attached')::int <> 3 then
    raise exception 'TEST FAIL: series attach expected 3 attachments, got %', v_res;
  end if;
  select count(*) into v_count from public.company_events
   where company_account_id = v_company and status = 'approved';
  if v_count <> 3 then
    raise exception 'TEST FAIL: expected 3 approved company events, got %', v_count;
  end if;
  perform public.admin_attach_location(v_token, v_company, v_place, null);
  raise notice 'PASS: event series + location attached by admin';

  ---------------------------------------------------------------
  -- Test: company users CANNOT self-add locations or events.
  -- There is no company-facing RPC, and direct table access is
  -- blocked by RLS + missing grants for the authenticated role.
  ---------------------------------------------------------------
  begin
    set local role authenticated;
    begin
      insert into public.company_locations (company_account_id, place_id)
      values (v_company, v_place);
      raise exception 'TEST FAIL: authenticated role inserted a company location';
    exception
      when insufficient_privilege then null;  -- expected
    end;
    begin
      insert into public.company_events (company_account_id, event_id)
      values (v_company, v_child1);
      raise exception 'TEST FAIL: authenticated role inserted a company event';
    exception
      when insufficient_privilege then null;  -- expected
    end;
    reset role;
  exception when others then
    reset role;
    raise;
  end;
  raise notice 'PASS: company users cannot self-add locations/events';

  ---------------------------------------------------------------
  -- Test: onboarding gating — new company starts at
  -- billing_info_required; completing onboarding flips it and
  -- never touches locations/events.
  ---------------------------------------------------------------
  if (select onboarding_status from public.company_accounts where id = v_company)
     <> 'billing_info_required' then
    raise exception 'TEST FAIL: new company should require billing info';
  end if;

  v_res := public._submit_company_onboarding(v_user, jsonb_build_object(
    'legal_name', 'JFDF Productions Limited',
    'trading_name', 'JFDF',
    'billing_contact_name', 'The Producer',
    'billing_email', 'accounts@jfdf.example.com',
    'billing_phone', '+1 876 555 0000',
    'country', 'Jamaica',
    'address', '1 Festival Way, Kingston',
    'preferred_currency', 'JMD',
    'business_type', 'event_host',
    'role_title', 'Managing Director'));
  if not (v_res ->> 'ok')::boolean then
    raise exception 'onboarding failed: %', v_res ->> 'error';
  end if;
  if (select onboarding_status from public.company_accounts where id = v_company) <> 'complete' then
    raise exception 'TEST FAIL: onboarding did not complete';
  end if;
  if (select preferred_currency from public.company_accounts where id = v_company) <> 'JMD' then
    raise exception 'TEST FAIL: preferred currency not saved';
  end if;
  select count(*) into v_count from public.company_events
   where company_account_id = v_company and status = 'approved';
  if v_count <> 3 then
    raise exception 'TEST FAIL: onboarding altered company events';
  end if;
  -- Audit recorded the billing info change
  if not exists (select 1 from public.billing_audit_log
                  where company_account_id = v_company
                    and action = 'company_billing_info_changed') then
    raise exception 'TEST FAIL: billing info change not audited';
  end if;
  raise notice 'PASS: onboarding completes billing info only, audited';

  ---------------------------------------------------------------
  -- Test: billing payload shows approved events and locations
  -- (via auth-simulated get_company_billing)
  ---------------------------------------------------------------
  insert into auth.users (id, email) values (v_auth_uid, 'producer@example.com');
  update public.company_users set user_id = v_auth_uid, status = 'active' where id = v_user;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_auth_uid, 'email', 'producer@example.com', 'role', 'authenticated')::text,
    true);

  v_res := public.get_company_billing();
  if not (v_res ->> 'ok')::boolean then
    raise exception 'get_company_billing failed: %', v_res;
  end if;
  if jsonb_array_length(v_res -> 'events') <> 3 then
    raise exception 'TEST FAIL: billing payload should list 3 events, got %',
      jsonb_array_length(v_res -> 'events');
  end if;
  if jsonb_array_length(v_res -> 'locations') <> 1 then
    raise exception 'TEST FAIL: billing payload should list 1 location';
  end if;
  if v_res -> 'onboarding' ->> 'status' <> 'complete' then
    raise exception 'TEST FAIL: billing payload missing onboarding status';
  end if;
  if jsonb_array_length(v_res -> 'invoice_footer_copy') < 4 then
    raise exception 'TEST FAIL: invoice footer copy missing';
  end if;
  raise notice 'PASS: billing payload shows approved events, locations, onboarding';

  ---------------------------------------------------------------
  -- Test: payment instructions render by currency
  ---------------------------------------------------------------
  v_res := public.payment_instructions_for_currency('USD');
  if jsonb_array_length(v_res) < 1
     or v_res -> 0 ->> 'account_type' <> 'Savings'
     or v_res -> 0 ->> 'bank_name' <> 'CIBC Caribbean' then
    raise exception 'TEST FAIL: USD instructions wrong: %', v_res;
  end if;
  v_res := public.payment_instructions_for_currency('JMD');
  if jsonb_array_length(v_res) < 1 or v_res -> 0 ->> 'account_type' <> 'Chequing' then
    raise exception 'TEST FAIL: JMD instructions wrong: %', v_res;
  end if;
  -- Seeded rows must never contain account numbers
  if exists (select 1 from public.payment_instructions where account_number is not null) then
    raise exception 'TEST FAIL: seeded payment instructions contain account numbers';
  end if;
  raise notice 'PASS: payment instructions resolve by currency, no seeded numbers';

  ---------------------------------------------------------------
  -- Test: company setup request flow (different fresh user)
  ---------------------------------------------------------------
  -- The requester must be a real auth user (approval links them).
  declare v_setup_uid uuid := gen_random_uuid();
  begin
    insert into auth.users (id, email) values (v_setup_uid, 'newbiz@example.com');
    v_res := public._submit_company_setup_request(v_setup_uid, 'newbiz@example.com',
    jsonb_build_object('legal_name', 'New Venue Limited', 'business_type', 'hospitality_group',
                       'preferred_currency', 'USD', 'message', 'Two restaurants in MoBay'));
  if not (v_res ->> 'ok')::boolean or v_res ->> 'status' <> 'pending_review' then
    raise exception 'setup request failed: %', v_res;
  end if;
  v_setup := (v_res ->> 'id')::uuid;

  v_res := public.admin_review_company_setup(v_token, v_setup, 'approve', 'Looks legit');
  if not (v_res ->> 'ok')::boolean then
    raise exception 'setup approval failed: %', v_res ->> 'error';
  end if;
  if not exists (select 1 from public.company_accounts
                  where id = (v_res ->> 'company_id')::uuid
                    and legal_name = 'New Venue Limited'
                    and onboarding_status = 'complete') then
    raise exception 'TEST FAIL: approved setup did not create company correctly';
  end if;
  if not exists (select 1 from public.company_users
                  where company_account_id = (v_res ->> 'company_id')::uuid
                    and email = 'newbiz@example.com' and role = 'admin') then
    raise exception 'TEST FAIL: setup approval did not register the requester';
  end if;
  -- Setup request notification was created
  if not exists (select 1 from public.billing_notifications
                  where notification_type = 'company_setup_request' and request_id = v_setup) then
    raise exception 'TEST FAIL: setup request notification missing';
  end if;
    raise notice 'PASS: company setup request -> admin approval -> company + user';
  end;

  ---------------------------------------------------------------
  -- Test: comped event package requires a note; insights stay
  -- unpaid on comped hubs in the event-billing payload
  ---------------------------------------------------------------
  select id into v_ce_id from public.company_events
   where company_account_id = v_company and event_id = v_parent;

  v_res := public.admin_set_event_package(v_token, v_ce_id, 'major_event_hub', true, null);
  if (v_res ->> 'ok')::boolean then
    raise exception 'TEST FAIL: comped package accepted without a note';
  end if;
  v_res := public.admin_set_event_package(v_token, v_ce_id, 'major_event_hub', true,
    'Founding event partner — comped 2026 hub');
  if not (v_res ->> 'ok')::boolean then
    raise exception 'comped package failed: %', v_res ->> 'error';
  end if;

  v_eb := public._event_billing(v_parent);
  if not (v_eb ->> 'ok')::boolean then
    raise exception 'event billing failed: %', v_eb;
  end if;
  if v_eb -> 'company' ->> 'name' <> 'JFDF Productions' then
    raise exception 'TEST FAIL: event billing wrong company';
  end if;
  if v_eb -> 'access' ->> 'dashboard_state' <> 'comped' then
    raise exception 'TEST FAIL: comped event should show comped, got %',
      v_eb -> 'access' ->> 'dashboard_state';
  end if;
  if v_eb -> 'package' ->> 'source' <> 'comped' then
    raise exception 'TEST FAIL: package source should be comped';
  end if;
  if v_eb ->> 'insights_status' <> 'not_purchased' then
    raise exception 'TEST FAIL: comped hub must NOT include insights (got %)',
      v_eb ->> 'insights_status';
  end if;
  raise notice 'PASS: comped event hub shows free access but unpaid insights';

  ---------------------------------------------------------------
  -- Test: paying for event insights flips the event billing view
  -- and event dashboard reflects host company invoice status
  ---------------------------------------------------------------
  v_res := public.admin_save_invoice(v_token, null, jsonb_build_object(
    'company_account_id', v_company,
    'currency', 'JMD',
    'line_items', jsonb_build_array(jsonb_build_object(
      'item_type', 'event_insights', 'product_code', 'major_event_insights',
      'description', 'Major Event Insights — JFDF 2026', 'quantity', 1, 'unit_amount', 2500,
      'metadata', jsonb_build_object('event_id', v_parent)))));
  v_invoice := (v_res ->> 'id')::uuid;
  perform public.admin_issue_invoice(v_token, v_invoice);

  v_eb := public._event_billing(v_parent);
  if v_eb -> 'open_invoice' ->> 'status' <> 'issued' then
    raise exception 'TEST FAIL: event billing should surface the open invoice';
  end if;

  v_res := public._submit_payment_confirmation(v_user, v_invoice,
    'bank_transfer', current_date, 'JN-778', null, null, null, null, null);
  v_conf := (v_res ->> 'confirmation_id')::uuid;
  perform public.admin_review_payment(v_token, v_conf, 'approve', null);

  v_eb := public._event_billing(v_parent);
  if v_eb ->> 'insights_status' <> 'purchased' then
    raise exception 'TEST FAIL: paid insights line should show purchased, got %',
      v_eb ->> 'insights_status';
  end if;
  raise notice 'PASS: event dashboard billing reflects host company purchases';

  ---------------------------------------------------------------
  -- Test: receipt rules (bad type / oversize rejected)
  ---------------------------------------------------------------
  v_res := public.admin_save_invoice(v_token, null, jsonb_build_object(
    'company_account_id', v_company,
    'line_items', jsonb_build_array(jsonb_build_object(
      'item_type', 'custom', 'description', 'Test fee', 'quantity', 1, 'unit_amount', 100))));
  v_invoice := (v_res ->> 'id')::uuid;
  perform public.admin_issue_invoice(v_token, v_invoice);

  v_res := public._submit_payment_confirmation(v_user, v_invoice,
    'bank_transfer', current_date, 'R-1', v_company || '/x/receipt.exe', null,
    'receipt.exe', 1000, 'application/octet-stream');
  if (v_res ->> 'ok')::boolean then
    raise exception 'TEST FAIL: .exe receipt accepted';
  end if;
  v_res := public._submit_payment_confirmation(v_user, v_invoice,
    'bank_transfer', current_date, 'R-2', v_company || '/x/receipt.pdf', null,
    'receipt.pdf', 999999999, 'application/pdf');
  if (v_res ->> 'ok')::boolean then
    raise exception 'TEST FAIL: oversize receipt accepted';
  end if;
  v_res := public._submit_payment_confirmation(v_user, v_invoice,
    'bank_transfer', current_date, 'R-3', v_company || '/x/receipt.pdf', 'slip attached',
    'receipt.pdf', 120000, 'application/pdf');
  if not (v_res ->> 'ok')::boolean then
    raise exception 'valid receipt rejected: %', v_res ->> 'error';
  end if;
  if not exists (select 1 from public.payment_confirmations
                  where id = (v_res ->> 'confirmation_id')::uuid
                    and receipt_filename = 'receipt.pdf' and receipt_mime = 'application/pdf') then
    raise exception 'TEST FAIL: receipt metadata not stored';
  end if;
  raise notice 'PASS: receipt type/size rules enforced, metadata stored';

  ---------------------------------------------------------------
  -- Test: request workflow transitions (+ related event linkage)
  ---------------------------------------------------------------
  insert into public.company_requests (company_account_id, requested_by, request_type, message, related_event_id)
  values (v_company, v_user, 'event_insights', 'Insights for Night 2 too', v_child2)
  returning id into v_req;

  v_res := public.admin_set_request_status(v_token, v_req, 'in_review', 'Scoping');
  if not (v_res ->> 'ok')::boolean then raise exception 'in_review failed: %', v_res; end if;
  v_res := public.admin_set_request_status(v_token, v_req, 'quoted', 'Quoted $2,500');
  if not (v_res ->> 'ok')::boolean then raise exception 'quoted failed: %', v_res; end if;
  v_res := public.admin_set_request_status(v_token, v_req, 'invoiced', null);
  if not (v_res ->> 'ok')::boolean then raise exception 'invoiced failed: %', v_res; end if;
  -- Backwards transition must fail
  v_res := public.admin_set_request_status(v_token, v_req, 'new', null);
  if (v_res ->> 'ok')::boolean then
    raise exception 'TEST FAIL: invoiced -> new transition accepted';
  end if;
  v_res := public.admin_set_request_status(v_token, v_req, 'completed', 'Paid + delivered');
  if not (v_res ->> 'ok')::boolean then raise exception 'completed failed: %', v_res; end if;
  v_res := public.admin_set_request_status(v_token, v_req, 'rejected', null);
  if (v_res ->> 'ok')::boolean then
    raise exception 'TEST FAIL: completed is terminal but transition accepted';
  end if;
  -- Request notification was created on insert
  if not exists (select 1 from public.billing_notifications
                  where notification_type = 'request_submitted' and request_id = v_req) then
    raise exception 'TEST FAIL: request notification missing';
  end if;
  raise notice 'PASS: request workflow transitions + notifications';

  ---------------------------------------------------------------
  -- Test: reason-required admin overrides + audit entries
  ---------------------------------------------------------------
  -- paid-through adjust without note -> refused
  perform public.admin_set_subscription(v_token, v_company, 'activate', 'fp_single', 'annual',
    (current_date + 30), 'Comped while migrating from legacy partner program');
  v_res := public.admin_set_subscription(v_token, v_company, 'adjust_paid_through',
    null, null, current_date + 60, null);
  if (v_res ->> 'ok')::boolean then
    raise exception 'TEST FAIL: paid-through adjusted without a note';
  end if;
  v_res := public.admin_set_subscription(v_token, v_company, 'adjust_paid_through',
    null, null, current_date + 60, 'Goodwill extension agreed by founders');
  if not (v_res ->> 'ok')::boolean then
    raise exception 'paid-through adjust failed: %', v_res ->> 'error';
  end if;

  -- entitlement override without note -> refused
  v_res := public.admin_set_entitlement(v_token, v_company, 'company_insights', true, null, null);
  if (v_res ->> 'ok')::boolean then
    raise exception 'TEST FAIL: entitlement override without a note';
  end if;
  v_res := public.admin_set_entitlement(v_token, v_company, 'company_insights', true, null, 'Pilot access');
  if not (v_res ->> 'ok')::boolean then raise exception 'entitlement grant failed'; end if;

  -- void without note -> refused
  v_res := public.admin_save_invoice(v_token, null, jsonb_build_object(
    'company_account_id', v_company,
    'line_items', jsonb_build_array(jsonb_build_object(
      'item_type', 'custom', 'description', 'Oops', 'quantity', 1, 'unit_amount', 10))));
  v_invoice := (v_res ->> 'id')::uuid;
  v_res := public.admin_set_invoice_status(v_token, v_invoice, 'void', null);
  if (v_res ->> 'ok')::boolean then
    raise exception 'TEST FAIL: invoice voided without a note';
  end if;
  v_res := public.admin_set_invoice_status(v_token, v_invoice, 'void', 'Duplicate draft');
  if not (v_res ->> 'ok')::boolean then raise exception 'void failed: %', v_res ->> 'error'; end if;

  -- payment rejection without note -> refused (fresh confirmation)
  v_res := public.admin_save_invoice(v_token, null, jsonb_build_object(
    'company_account_id', v_company,
    'line_items', jsonb_build_array(jsonb_build_object(
      'item_type', 'custom', 'description', 'Fee', 'quantity', 1, 'unit_amount', 10))));
  v_invoice := (v_res ->> 'id')::uuid;
  perform public.admin_issue_invoice(v_token, v_invoice);
  v_res := public._submit_payment_confirmation(v_user, v_invoice,
    'cash', current_date, 'C-1', null, null, null, null, null);
  v_conf := (v_res ->> 'confirmation_id')::uuid;
  v_res := public.admin_review_payment(v_token, v_conf, 'reject', null);
  if (v_res ->> 'ok')::boolean then
    raise exception 'TEST FAIL: payment rejected without a note';
  end if;
  v_res := public.admin_review_payment(v_token, v_conf, 'reject', 'No deposit found');
  if not (v_res ->> 'ok')::boolean then raise exception 'reject failed: %', v_res ->> 'error'; end if;

  -- Audit entries exist for each override
  select count(*) into v_count from public.billing_audit_log
   where company_account_id = v_company
     and action in ('subscription_adjust_paid_through', 'entitlement_granted',
                    'invoice_status_set', 'payment_rejected', 'event_package_set');
  if v_count < 5 then
    raise exception 'TEST FAIL: missing override audit entries (found %)', v_count;
  end if;
  raise notice 'PASS: reason-required overrides enforced and audited';

  ---------------------------------------------------------------
  -- Test: renewal operations — maintenance marks overdue +
  -- read-only, renewal draft continues from paid_through
  ---------------------------------------------------------------
  -- Lapse the subscription beyond grace and add an old open invoice
  update public.subscriptions
     set status = 'active', paid_through = current_date - 30
   where company_account_id = v_company;
  v_res := public.admin_save_invoice(v_token, null, jsonb_build_object(
    'company_account_id', v_company,
    'due_date', (current_date - 5)::text,
    'line_items', jsonb_build_array(jsonb_build_object(
      'item_type', 'custom', 'description', 'Old fee', 'quantity', 1, 'unit_amount', 10))));
  v_invoice := (v_res ->> 'id')::uuid;
  perform public.admin_issue_invoice(v_token, v_invoice);
  -- Re-stamp the due date (issue defaults it forward when null/past handling)
  update public.invoices set due_date = current_date - 5 where id = v_invoice;

  v_res := public.admin_run_billing_maintenance(v_token);
  if not (v_res ->> 'ok')::boolean then
    raise exception 'maintenance failed: %', v_res;
  end if;
  if (select status from public.invoices where id = v_invoice) <> 'overdue' then
    raise exception 'TEST FAIL: maintenance did not mark invoice overdue';
  end if;
  select * into v_sub from public.subscriptions where company_account_id = v_company;
  if v_sub.status <> 'read_only' then
    raise exception 'TEST FAIL: lapsed subscription not moved to read_only (got %)', v_sub.status;
  end if;
  -- read-only notification produced by trigger
  if not exists (select 1 from public.billing_notifications
                  where notification_type = 'subscription_read_only'
                    and company_account_id = v_company) then
    raise exception 'TEST FAIL: read-only notification missing';
  end if;

  -- Renewal draft: lapsed in the past -> period starts TODAY (no backfill)
  v_res := public.admin_generate_renewal_invoice(v_token, v_company);
  if not (v_res ->> 'ok')::boolean then
    raise exception 'renewal generation failed: %', v_res ->> 'error';
  end if;
  if (v_res ->> 'period_start')::date <> current_date then
    raise exception 'TEST FAIL: lapsed renewal should start today (no backfill), got %',
      v_res ->> 'period_start';
  end if;
  if not exists (select 1 from public.billing_notifications
                  where notification_type = 'renewal_invoice_generated'
                    and company_account_id = v_company) then
    raise exception 'TEST FAIL: renewal notification missing';
  end if;

  -- Future renewal: still-paid sub continues from paid_through + 1
  update public.subscriptions
     set status = 'active', paid_through = current_date + 10
   where company_account_id = v_company;
  v_res := public.admin_generate_renewal_invoice(v_token, v_company);
  if (v_res ->> 'period_start')::date <> current_date + 11 then
    raise exception 'TEST FAIL: renewal should continue from paid_through+1, got %',
      v_res ->> 'period_start';
  end if;
  raise notice 'PASS: renewal operations (overdue, read-only, draft periods)';

  ---------------------------------------------------------------
  -- Test: invoice lifecycle notifications exist
  ---------------------------------------------------------------
  select count(*) into v_count from public.billing_notifications
   where company_account_id = v_company
     and notification_type in ('invoice_issued', 'payment_reported',
                               'payment_approved', 'payment_rejected', 'invoice_overdue');
  if v_count < 5 then
    raise exception 'TEST FAIL: expected lifecycle notifications, found %', v_count;
  end if;
  raise notice 'PASS: lifecycle notifications recorded (% rows)', v_count;

  raise notice '=== ALL BILLING OPS TESTS PASSED ===';
end;
$test$;

rollback;
