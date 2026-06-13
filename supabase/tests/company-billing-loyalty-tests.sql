-- ============================================================
-- TRODDR Company Billing — Loyalty plan tests
-- ------------------------------------------------------------
-- Covers: loyalty plan family + specials allowance on the plan,
-- per-location specials usage (included vs used + billable
-- extras for the current cycle), and that get_company_billing
-- surfaces the specials block only for loyalty-family plans.
--
-- Requires company-billing.sql + seed + ops + billing-specials.sql
-- + company-billing-loyalty.sql. Transaction-wrapped; rolls back.
-- ============================================================

begin;

do $test$
declare
  v_token    text;
  v_company  uuid;
  v_user     uuid;
  v_auth_uid uuid := gen_random_uuid();
  v_place1   uuid;
  v_place2   uuid;
  v_res      jsonb;
  v_usage    jsonb;
  v_loc      jsonb;
  v_cycle    date := date_trunc('month', now())::date;
begin
  -- Plan model: loyalty tiers carry a 2/location allowance
  if (select specials_per_location from public.subscription_plans where key = 'fp_duo') <> 2
     or (select plan_family from public.subscription_plans where key = 'fp_duo') <> 'loyalty' then
    raise exception 'TEST FAIL: fp_duo should be loyalty family with 2 specials/location';
  end if;
  if not exists (select 1 from public.subscription_plans
                  where key = 'foundation_loyalty' and plan_family = 'loyalty'
                    and specials_per_location = 2) then
    raise exception 'TEST FAIL: foundation_loyalty plan missing';
  end if;
  raise notice 'PASS: loyalty plan model seeded (family + specials allowance)';

  -- Setup company on a loyalty plan with two locations
  insert into public.admin_tokens (label) values ('loyalty-test') returning token into v_token;
  v_res := public.admin_upsert_company(v_token, null, 'Soup King Group', 'loyalty-test@example.com',
    null, null, 'active', null, 'hospitality_group', 'manual', null);
  v_company := (v_res ->> 'id')::uuid;
  v_res := public.admin_upsert_company_user(v_token, v_company, 'owner@soupking.com', 'Owner', 'admin');
  v_user := (v_res ->> 'id')::uuid;

  insert into public.places (name, slug) values ('Soup King — Kingston',
    'sk-kingston-' || substr(md5(random()::text),1,6)) returning id into v_place1;
  insert into public.places (name, slug) values ('Soup King — Portmore',
    'sk-portmore-' || substr(md5(random()::text),1,6)) returning id into v_place2;
  perform public.admin_attach_location(v_token, v_company, v_place1, null);
  perform public.admin_attach_location(v_token, v_company, v_place2, null);

  -- Activate the loyalty plan (manual activation requires a note)
  perform public.admin_set_subscription(v_token, v_company, 'activate', 'fp_duo', 'annual',
    (current_date + 365), 'Loyalty partner onboarding');

  -- Seed specials in the CURRENT cycle:
  --   Kingston: 1 included
  --   Portmore: 2 included + 1 billable extra + 1 void (ignored)
  insert into public.specials (place_id, title, submission_status, billing_status, submitted_at)
  values
    (v_place1, 'K1', 'approved', 'included',         v_cycle + 1),
    (v_place2, 'P1', 'approved', 'included',         v_cycle + 1),
    (v_place2, 'P2', 'approved', 'included',         v_cycle + 2),
    (v_place2, 'P3', 'approved', 'billable',         v_cycle + 3),
    (v_place2, 'P4', 'rejected', 'void',             v_cycle + 4);

  v_usage := public.company_specials_usage(v_company);
  if (v_usage ->> 'included_per_location')::int <> 2 then
    raise exception 'TEST FAIL: allowance should be 2, got %', v_usage ->> 'included_per_location';
  end if;
  if (v_usage ->> 'billable_total')::int <> 1 then
    raise exception 'TEST FAIL: billable_total should be 1, got %', v_usage ->> 'billable_total';
  end if;

  -- Per-location counts
  select loc into v_loc
    from jsonb_array_elements(v_usage -> 'locations') loc
   where loc ->> 'place_id' = v_place1::text;
  if (v_loc ->> 'used')::int <> 1 then
    raise exception 'TEST FAIL: Kingston used should be 1, got %', v_loc ->> 'used';
  end if;

  select loc into v_loc
    from jsonb_array_elements(v_usage -> 'locations') loc
   where loc ->> 'place_id' = v_place2::text;
  if (v_loc ->> 'used')::int <> 3 then
    raise exception 'TEST FAIL: Portmore used should be 3 (void ignored), got %', v_loc ->> 'used';
  end if;
  if (v_loc ->> 'billable_extras')::int <> 1 then
    raise exception 'TEST FAIL: Portmore billable_extras should be 1, got %', v_loc ->> 'billable_extras';
  end if;
  raise notice 'PASS: per-location specials usage (included vs used + billable, void ignored)';

  -- get_company_billing surfaces specials for loyalty plans
  insert into auth.users (id, email) values (v_auth_uid, 'owner@soupking.com');
  update public.company_users set user_id = v_auth_uid, status = 'active' where id = v_user;
  perform set_config('request.jwt.claims',
    json_build_object('sub', v_auth_uid, 'email', 'owner@soupking.com', 'role', 'authenticated')::text, true);

  v_res := public.get_company_billing();
  if v_res -> 'plan' ->> 'plan_family' <> 'loyalty' then
    raise exception 'TEST FAIL: billing payload plan_family should be loyalty';
  end if;
  if v_res -> 'specials' is null or jsonb_typeof(v_res -> 'specials') <> 'object' then
    raise exception 'TEST FAIL: billing payload missing specials block for loyalty plan';
  end if;
  if jsonb_array_length(v_res -> 'specials' -> 'locations') <> 2 then
    raise exception 'TEST FAIL: specials block should list 2 locations';
  end if;
  raise notice 'PASS: get_company_billing exposes specials for loyalty plans';

  -- Non-loyalty plan: specials block should be null
  perform public.admin_set_subscription(v_token, v_company, 'activate', 'fp_single', 'annual',
    (current_date + 365), 'switch test');
  update public.subscription_plans set plan_family = 'standard' where key = 'fp_single';
  v_res := public.get_company_billing();
  if v_res -> 'specials' is not null and v_res -> 'specials' <> 'null'::jsonb then
    raise exception 'TEST FAIL: non-loyalty plan should not expose a specials block';
  end if;
  raise notice 'PASS: specials block omitted for non-loyalty plans';

  raise notice '=== ALL LOYALTY BILLING TESTS PASSED ===';
end;
$test$;

rollback;
