-- ============================================================
-- TRODDR Company Onboarding — tests
-- ------------------------------------------------------------
-- Covers: invite creation (pre-attaches businesses + registers
-- email), get_onboarding_invite resolution incl. revoked/expired,
-- accept_onboarding_invite linking, profile + billing completion,
-- and submit_onboarding_quote creating a DRAFT invoice priced from
-- the catalog (tampered client price ignored; ranged → min_amount)
-- without activating access. Re-asserts no self-attach.
--
-- Requires all prior billing migrations + company-onboarding.sql.
-- Transaction-wrapped; rolls back.
-- ============================================================

begin;

do $test$
declare
  v_token    text;
  v_company  uuid;
  v_place    uuid;
  v_event    uuid;
  v_auth_uid uuid := gen_random_uuid();
  v_email    text := 'prospect@example.com';
  v_invite   text;
  v_res      jsonb;
  v_inv      public.invoices%rowtype;
  v_access   jsonb;
  v_count    int;
  v_plan_amt numeric;
begin
  ---------------------------------------------------------------
  -- Setup: admin, company, a place + event to pre-attach
  ---------------------------------------------------------------
  insert into public.admin_tokens (label) values ('onboard-test') returning token into v_token;
  v_res := public.admin_upsert_company(v_token, null, 'Prospect Group', 'ops@prospect.com',
    null, null, 'active', null, 'hospitality_group', 'manual', null);
  v_company := (v_res ->> 'id')::uuid;

  insert into public.places (name, slug) values ('Prospect Bistro',
    'prospect-bistro-' || substr(md5(random()::text),1,6)) returning id into v_place;
  insert into public.events (title, slug) values ('Prospect Fest',
    'prospect-fest-' || substr(md5(random()::text),1,6)) returning id into v_event;

  ---------------------------------------------------------------
  -- Invite creation pre-attaches businesses + registers the email
  ---------------------------------------------------------------
  v_res := public.admin_create_onboarding_invite(v_token, v_company, v_email,
    array[v_place], array[v_event], 14);
  if not (v_res ->> 'ok')::boolean then
    raise exception 'invite creation failed: %', v_res ->> 'error';
  end if;
  v_invite := v_res ->> 'token';

  if not exists (select 1 from public.company_users
                  where company_account_id = v_company and email = v_email and role = 'admin') then
    raise exception 'TEST FAIL: invite did not register the owner email';
  end if;
  select count(*) into v_count from public.company_locations
   where company_account_id = v_company and place_id = v_place and status = 'approved';
  if v_count <> 1 then raise exception 'TEST FAIL: invite did not pre-attach the location'; end if;
  select count(*) into v_count from public.company_events
   where company_account_id = v_company and event_id = v_event and status = 'approved';
  if v_count <> 1 then raise exception 'TEST FAIL: invite did not pre-attach the event'; end if;
  raise notice 'PASS: invite pre-attaches businesses + registers owner';

  ---------------------------------------------------------------
  -- get_onboarding_invite resolves (anon-safe payload)
  ---------------------------------------------------------------
  v_res := public.get_onboarding_invite(v_invite);
  if not (v_res ->> 'ok')::boolean
     or v_res ->> 'company_name' <> 'Prospect Group'
     or v_res ->> 'email' <> v_email then
    raise exception 'TEST FAIL: invite lookup wrong: %', v_res;
  end if;
  if jsonb_array_length(v_res -> 'claimable' -> 'places') <> 1
     or jsonb_array_length(v_res -> 'claimable' -> 'events') <> 1 then
    raise exception 'TEST FAIL: claimable snapshot wrong';
  end if;
  raise notice 'PASS: get_onboarding_invite returns welcome payload';

  ---------------------------------------------------------------
  -- accept_onboarding_invite links the new auth user
  ---------------------------------------------------------------
  insert into auth.users (id, email) values (v_auth_uid, v_email);
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_auth_uid, 'email', v_email, 'role', 'authenticated')::text, true);

  v_res := public.accept_onboarding_invite(v_invite);
  if not (v_res ->> 'ok')::boolean then
    raise exception 'accept failed: %', v_res ->> 'error';
  end if;
  if (v_res ->> 'company_account_id')::uuid <> v_company then
    raise exception 'TEST FAIL: accepted to wrong company';
  end if;
  if (select status from public.company_onboarding_invites where token = v_invite) <> 'accepted' then
    raise exception 'TEST FAIL: invite not marked accepted';
  end if;
  if not exists (select 1 from public.company_users
                  where company_account_id = v_company and user_id = v_auth_uid and status = 'active') then
    raise exception 'TEST FAIL: auth user not linked active';
  end if;
  raise notice 'PASS: accept_onboarding_invite links the user';

  ---------------------------------------------------------------
  -- Wrong-email accept is rejected
  ---------------------------------------------------------------
  declare
    v_other uuid := gen_random_uuid();
    v_inv2  text;
  begin
    -- fresh pending invite for a different email
    v_res := public.admin_create_onboarding_invite(v_token, v_company, 'someone@else.com', '{}', '{}', 14);
    v_inv2 := v_res ->> 'token';
    insert into auth.users (id, email) values (v_other, 'mismatch@example.com');
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_other, 'email', 'mismatch@example.com', 'role', 'authenticated')::text, true);
    v_res := public.accept_onboarding_invite(v_inv2);
    if (v_res ->> 'ok')::boolean then
      raise exception 'TEST FAIL: accepted invite with mismatched email';
    end if;
    -- restore prospect identity
    perform set_config('request.jwt.claims',
      json_build_object('sub', v_auth_uid, 'email', v_email, 'role', 'authenticated')::text, true);
  end;
  raise notice 'PASS: invite rejects mismatched email';

  ---------------------------------------------------------------
  -- Profile + billing complete onboarding
  ---------------------------------------------------------------
  v_res := public.submit_onboarding_profile(jsonb_build_object(
    'business_type', 'hospitality_group', 'location_count', 2,
    'does_events', true, 'event_scale', 'major', 'wants_insights', 'company',
    'sponsor_interest', false, 'billing_cycle', 'annual'));
  if not (v_res ->> 'ok')::boolean then raise exception 'profile failed: %', v_res; end if;
  if (select onboarding_profile ->> 'event_scale' from public.company_accounts where id = v_company) <> 'major' then
    raise exception 'TEST FAIL: profile not stored';
  end if;

  v_res := public.submit_company_onboarding(jsonb_build_object(
    'legal_name', 'Prospect Group Ltd', 'billing_email', 'accounts@prospect.com',
    'preferred_currency', 'USD', 'business_type', 'hospitality_group'));
  if not (v_res ->> 'ok')::boolean then raise exception 'billing onboarding failed: %', v_res; end if;
  raise notice 'PASS: profile + billing info captured';

  ---------------------------------------------------------------
  -- submit_onboarding_quote: DRAFT invoice priced from catalog
  ---------------------------------------------------------------
  -- Tamper attempt: client sends a silly unit price — server must ignore
  -- it (the RPC only reads plan_key + product codes).
  v_res := public.submit_onboarding_quote(jsonb_build_object(
    'plan_key', 'fp_duo', 'billing_cycle', 'annual',
    'products', jsonb_build_array(
      jsonb_build_object('code', 'major_event_hub', 'quantity', 1, 'unit_amount', 1),
      jsonb_build_object('code', 'company_insights_annual', 'quantity', 1)),
    'notes', 'Two restaurants + a big festival'));
  if not (v_res ->> 'ok')::boolean then raise exception 'quote failed: %', v_res ->> 'error'; end if;

  select * into v_inv from public.invoices where id = (v_res ->> 'invoice_id')::uuid;
  if v_inv.status <> 'draft' then
    raise exception 'TEST FAIL: quote invoice should be DRAFT, got %', v_inv.status;
  end if;
  if v_inv.invoice_number is not null then
    raise exception 'TEST FAIL: draft should have no invoice number yet';
  end if;

  -- Plan line priced from catalog (fp_duo annual = 1056), not client.
  select sum(amount) into v_plan_amt from public.invoice_line_items
   where invoice_id = v_inv.id and item_type = 'founding_partner_subscription';
  if v_plan_amt <> 1056 then
    raise exception 'TEST FAIL: plan line should be 1056 from catalog, got %', v_plan_amt;
  end if;
  -- major_event_hub is 6500 (fixed) — client's 1 must be ignored.
  if (select unit_amount from public.invoice_line_items
       where invoice_id = v_inv.id and product_code = 'major_event_hub') <> 6500 then
    raise exception 'TEST FAIL: tampered product price was not overridden from catalog';
  end if;
  -- company_insights_annual = 750.
  if (select unit_amount from public.invoice_line_items
       where invoice_id = v_inv.id and product_code = 'company_insights_annual') <> 750 then
    raise exception 'TEST FAIL: insights product not priced from catalog';
  end if;

  -- A request landed in the admin queue + onboarding completed.
  if not exists (select 1 from public.company_requests
                  where company_account_id = v_company and request_type = 'billing_help') then
    raise exception 'TEST FAIL: quote did not create a request';
  end if;
  if (select onboarding_status from public.company_accounts where id = v_company) <> 'complete' then
    raise exception 'TEST FAIL: onboarding not marked complete';
  end if;

  -- INVARIANT: no activation — access stays read_only, no entitlements.
  v_access := public.company_access_state(v_company);
  if v_access ->> 'access' = 'full' then
    raise exception 'TEST FAIL: onboarding quote granted full access (invariant broken)';
  end if;
  if public.company_has_entitlement(v_company, 'major_event_hub') then
    raise exception 'TEST FAIL: entitlement active before any invoice paid';
  end if;
  raise notice 'PASS: quote creates catalog-priced DRAFT invoice + request, no activation';

  ---------------------------------------------------------------
  -- Ranged product estimates at min_amount
  ---------------------------------------------------------------
  v_res := public.submit_onboarding_quote(jsonb_build_object(
    'plan_key', 'foundation_loyalty', 'billing_cycle', 'annual',
    'products', jsonb_build_array(jsonb_build_object('code', 'flagship_event', 'quantity', 1))));
  select * into v_inv from public.invoices where id = (v_res ->> 'invoice_id')::uuid;
  -- flagship_event has min_amount 10000, unit_amount null → estimate at 10000.
  if (select unit_amount from public.invoice_line_items
       where invoice_id = v_inv.id and product_code = 'flagship_event') <> 10000 then
    raise exception 'TEST FAIL: ranged product not estimated at min_amount';
  end if;
  -- foundation_loyalty has no recurring fee → plan line at 0.
  if (select amount from public.invoice_line_items
       where invoice_id = v_inv.id and item_type = 'founding_partner_subscription') <> 0 then
    raise exception 'TEST FAIL: allowance-only plan line should be 0';
  end if;
  raise notice 'PASS: ranged products estimate at min_amount; allowance plan = 0';

  ---------------------------------------------------------------
  -- Revoked + expired invites rejected
  ---------------------------------------------------------------
  declare v_inv3 text; v_inv3_id uuid;
  begin
    v_res := public.admin_create_onboarding_invite(v_token, v_company, 'rev@example.com', '{}', '{}', 14);
    v_inv3 := v_res ->> 'token';
    select id into v_inv3_id from public.company_onboarding_invites where token = v_inv3;
    perform public.admin_revoke_onboarding_invite(v_token, v_inv3_id);
    v_res := public.get_onboarding_invite(v_inv3);
    if (v_res ->> 'ok')::boolean or v_res ->> 'error' <> 'revoked' then
      raise exception 'TEST FAIL: revoked invite still usable';
    end if;

    update public.company_onboarding_invites set expires_at = now() - interval '1 day'
     where token = v_invite;  -- already accepted, but force-expire a pending one instead
    v_res := public.admin_create_onboarding_invite(v_token, v_company, 'exp@example.com', '{}', '{}', 14);
    update public.company_onboarding_invites set expires_at = now() - interval '1 day'
     where token = v_res ->> 'token';
    v_res := public.get_onboarding_invite(v_res ->> 'token');
    if (v_res ->> 'ok')::boolean or v_res ->> 'error' <> 'expired' then
      raise exception 'TEST FAIL: expired invite still usable';
    end if;
  end;
  raise notice 'PASS: revoked + expired invites rejected';

  ---------------------------------------------------------------
  -- No self-attach (re-assert with onboarding tables present)
  ---------------------------------------------------------------
  begin
    set local role authenticated;
    begin
      insert into public.company_onboarding_invites (company_account_id, email)
      values (v_company, 'x@y.com');
      raise exception 'TEST FAIL: authenticated role inserted an invite';
    exception when insufficient_privilege then null; end;
    reset role;
  exception when others then reset role; raise;
  end;
  raise notice 'PASS: company users cannot forge invites';

  raise notice '=== ALL ONBOARDING TESTS PASSED ===';
end;
$test$;

rollback;
