

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;


CREATE EXTENSION IF NOT EXISTS "pg_cron" WITH SCHEMA "pg_catalog";






CREATE EXTENSION IF NOT EXISTS "pg_net" WITH SCHEMA "extensions";






COMMENT ON SCHEMA "public" IS 'standard public schema';



CREATE EXTENSION IF NOT EXISTS "citext" WITH SCHEMA "public";






CREATE EXTENSION IF NOT EXISTS "pg_stat_statements" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pg_trgm" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA "extensions";






CREATE EXTENSION IF NOT EXISTS "supabase_vault" WITH SCHEMA "vault";






CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA "extensions";






CREATE TYPE "public"."schedule_item_status" AS ENUM (
    'scheduled',
    'live',
    'delayed',
    'cancelled',
    'completed',
    'new'
);


ALTER TYPE "public"."schedule_item_status" OWNER TO "postgres";


CREATE TYPE "public"."schedule_track_type" AS ENUM (
    'stage',
    'venue',
    'ceremony',
    'workshop',
    'food',
    'vip',
    'other'
);


ALTER TYPE "public"."schedule_track_type" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_activate_paid_invoice"("p_invoice_id" "uuid", "p_actor_label" "text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."_activate_paid_invoice"("p_invoice_id" "uuid", "p_actor_label" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_admin_label"("p_token" "text") RETURNS "text"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(label, 'admin') from public.admin_tokens
   where token = p_token and is_active = true;
$$;


ALTER FUNCTION "public"."_admin_label"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_apply_change_request"("_request_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  r record;
begin
  select * into r from public.trip_change_requests where id = _request_id for update;
  if r.id is null then return; end if;
  if r.status <> 'pending' then return; end if;

  if r.change_type = 'delete_item' then
    if r.target_entity_type = 'place' then
      delete from public.itinerary_places where entry_id = r.target_entry_id;
    elsif r.target_entity_type = 'event' then
      delete from public.itinerary_events where entry_id = r.target_entry_id;
    end if;
  end if;

  update public.trip_change_requests
    set status = 'applied', resolved_at = now()
    where id = _request_id;
end $$;


ALTER FUNCTION "public"."_apply_change_request"("_request_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_assert_invoice_transition"("p_from" "text", "p_to" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
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


ALTER FUNCTION "public"."_assert_invoice_transition"("p_from" "text", "p_to" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_assert_request_transition"("p_from" "text", "p_to" "text") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
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


ALTER FUNCTION "public"."_assert_request_transition"("p_from" "text", "p_to" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_billing_audit"("p_actor_type" "text", "p_actor_label" "text", "p_company_id" "uuid", "p_action" "text", "p_details" "jsonb" DEFAULT '{}'::"jsonb", "p_invoice_id" "uuid" DEFAULT NULL::"uuid", "p_subscription" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  insert into public.billing_audit_log
    (actor_type, actor_label, company_account_id, invoice_id, subscription_id, action, details)
  values
    (p_actor_type, p_actor_label, p_company_id, p_invoice_id, p_subscription,
     p_action, coalesce(p_details, '{}'::jsonb));
$$;


ALTER FUNCTION "public"."_billing_audit"("p_actor_type" "text", "p_actor_label" "text", "p_company_id" "uuid", "p_action" "text", "p_details" "jsonb", "p_invoice_id" "uuid", "p_subscription" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_billing_notify"("p_type" "text", "p_company_id" "uuid", "p_subject" "text", "p_body" "text" DEFAULT NULL::"text", "p_invoice_id" "uuid" DEFAULT NULL::"uuid", "p_request_id" "uuid" DEFAULT NULL::"uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."_billing_notify"("p_type" "text", "p_company_id" "uuid", "p_subject" "text", "p_body" "text", "p_invoice_id" "uuid", "p_request_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_billing_setting"("p_key" "text") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select value from public.billing_settings where key = p_key;
$$;


ALTER FUNCTION "public"."_billing_setting"("p_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_event_billing"("p_event_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."_event_billing"("p_event_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_format_hours_text"("p_hours" "jsonb") RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$
declare
  v_days   text[] := array['mon','tue','wed','thu','fri','sat','sun'];
  v_labels text[] := array['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
  v_lines  text[] := '{}';
  v_day    text;
  v_entry  jsonb;
  v_open   text;
  v_close  text;
  v_i      int;
begin
  if p_hours is null or p_hours = '{}'::jsonb then
    return null;
  end if;
  for v_i in 1 .. array_length(v_days, 1) loop
    v_day   := v_days[v_i];
    v_entry := p_hours -> v_day;
    if v_entry is null then
      continue;
    end if;
    if (v_entry ->> 'closed')::boolean is true then
      v_lines := v_lines || (v_labels[v_i] || ' Closed');
    else
      v_open  := v_entry ->> 'open';
      v_close := v_entry ->> 'close';
      if v_open is not null and v_close is not null then
        v_lines := v_lines || (v_labels[v_i] || ' ' || v_open || '–' || v_close);
      end if;
    end if;
  end loop;
  if array_length(v_lines, 1) is null then return null; end if;
  return array_to_string(v_lines, '; ');
end;
$$;


ALTER FUNCTION "public"."_format_hours_text"("p_hours" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_grant_entitlement"("p_company_id" "uuid", "p_key" "text", "p_source" "text", "p_starts" "date", "p_expires" "date", "p_invoice_id" "uuid", "p_notes" "text" DEFAULT NULL::"text") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."_grant_entitlement"("p_company_id" "uuid", "p_key" "text", "p_source" "text", "p_starts" "date", "p_expires" "date", "p_invoice_id" "uuid", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_invoice_effective_status"("p_status" "text", "p_due" "date") RETURNS "text"
    LANGUAGE "sql" STABLE
    AS $$
  select case
    when p_status = 'issued' and p_due is not null and p_due < current_date then 'overdue'
    else p_status
  end;
$$;


ALTER FUNCTION "public"."_invoice_effective_status"("p_status" "text", "p_due" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_is_admin"("p_token" "text") RETURNS boolean
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists(
    select 1 from public.admin_tokens
     where token = p_token and is_active = true
  );
$$;


ALTER FUNCTION "public"."_is_admin"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_normalize_event_type"("p_raw" "text") RETURNS "text"
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case lower(regexp_replace(coalesce(trim(p_raw), ''), '[\s&-]+', ' ', 'g'))
    when ''                  then null
    when 'music'             then 'music'
    when 'concert'           then 'music'
    when 'live music'        then 'music'
    when 'food'              then 'food and drink'
    when 'food and drink'    then 'food and drink'
    when 'drink'             then 'food and drink'
    when 'drinks'            then 'food and drink'
    when 'culinary'          then 'food and drink'
    when 'art'               then 'art'
    when 'art and culture'   then 'art'
    when 'culture'           then 'art'
    when 'sports'            then 'sports'
    when 'sport'             then 'sports'
    when 'comedy'            then 'comedy'
    when 'festival'          then 'festival'
    when 'conference'        then 'conference'
    when 'networking'        then 'networking'
    when 'workshop'          then 'workshop'
    when 'party'             then 'party'
    when 'nightlife'         then 'nightlife'
    when 'family'            then 'family'
    when 'wellness'          then 'wellness'
    when 'community'         then 'community'
    when 'carnival'          then 'carnival'
    else null
  end;
$$;


ALTER FUNCTION "public"."_normalize_event_type"("p_raw" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_partner_event_id_from_token"("p_token" "text") RETURNS "uuid"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select id from public.events where partner_access_token = p_token limit 1;
$$;


ALTER FUNCTION "public"."_partner_event_id_from_token"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_partner_token_company_id"("p_token" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place_id   uuid;
  v_event_id   uuid;
  v_company_id uuid;
begin
  select id into v_place_id from public.places  where partner_access_token = p_token;
  if v_place_id is null then
    select id into v_event_id from public.events where partner_access_token = p_token;
  end if;
  if v_place_id is null and v_event_id is null then
    return null;
  end if;

  if v_place_id is not null then
    select ca.id into v_company_id
      from public.company_locations cl
      join public.company_accounts ca on ca.id = cl.company_account_id
     where cl.place_id = v_place_id and cl.status = 'approved'
     order by cl.approved_at
     limit 1;
  else
    select ca.id into v_company_id
      from public.company_events ce
      join public.company_accounts ca on ca.id = ce.company_account_id
     where ce.event_id = v_event_id and ce.status = 'approved'
       and ce.relationship_type in ('host', 'organizer')
     order by case ce.relationship_type when 'host' then 0 else 1 end, ce.approved_at
     limit 1;
  end if;

  return v_company_id;
end;
$$;


ALTER FUNCTION "public"."_partner_token_company_id"("p_token" "text") OWNER TO "postgres";

SET default_tablespace = '';

SET default_table_access_method = "heap";


CREATE TABLE IF NOT EXISTS "public"."company_users" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_account_id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "name" "text",
    "role" "text" DEFAULT 'admin'::"text" NOT NULL,
    "user_id" "uuid",
    "status" "text" DEFAULT 'invited'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "company_users_role_check" CHECK (("role" = ANY (ARRAY['admin'::"text", 'member'::"text"]))),
    CONSTRAINT "company_users_status_check" CHECK (("status" = ANY (ARRAY['invited'::"text", 'active'::"text", 'removed'::"text"])))
);


ALTER TABLE "public"."company_users" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_resolve_company_user"() RETURNS "public"."company_users"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."_resolve_company_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_save_invoice"("p_company_id" "uuid", "p_invoice" "jsonb", "p_actor_type" "text", "p_actor_label" "text") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."_save_invoice"("p_company_id" "uuid", "p_invoice" "jsonb", "p_actor_type" "text", "p_actor_label" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_send_email"("p_template" "text", "p_params" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_url   text;
  v_token text;
begin
  select value into v_url   from public.app_settings where key = 'send_email_url';
  select value into v_token from public.app_settings where key = 'service_role_jwt';
  if v_url is null or v_token is null then
    return;  -- not configured yet; silently skip
  end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || v_token
    ),
    body    := jsonb_build_object(
      'template', p_template,
      'params',   p_params
    )
  );
exception when others then
  -- Swallow errors so a missing/down email service never breaks the underlying write.
  null;
end;
$$;


ALTER FUNCTION "public"."_send_email"("p_template" "text", "p_params" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_submit_company_onboarding"("p_company_user_id" "uuid", "p_info" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."_submit_company_onboarding"("p_company_user_id" "uuid", "p_info" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_submit_company_setup_request"("p_user_id" "uuid", "p_email" "text", "p_info" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."_submit_company_setup_request"("p_user_id" "uuid", "p_email" "text", "p_info" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_submit_payment_confirmation"("p_company_user_id" "uuid", "p_invoice_id" "uuid", "p_payment_method" "text", "p_paid_on" "date", "p_reference" "text", "p_receipt_path" "text" DEFAULT NULL::"text", "p_notes" "text" DEFAULT NULL::"text", "p_receipt_filename" "text" DEFAULT NULL::"text", "p_receipt_size_bytes" bigint DEFAULT NULL::bigint, "p_receipt_mime" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
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
$_$;


ALTER FUNCTION "public"."_submit_payment_confirmation"("p_company_user_id" "uuid", "p_invoice_id" "uuid", "p_payment_method" "text", "p_paid_on" "date", "p_reference" "text", "p_receipt_path" "text", "p_notes" "text", "p_receipt_filename" "text", "p_receipt_size_bytes" bigint, "p_receipt_mime" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_taste_elo_expected"("p_self" integer, "p_opp" integer) RETURNS double precision
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select 1.0 / (1.0 + power(10.0, (p_opp - p_self) / 400.0));
$$;


ALTER FUNCTION "public"."_taste_elo_expected"("p_self" integer, "p_opp" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_taste_elo_k"("p_count" integer) RETURNS integer
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case when p_count < 10 then 40 when p_count > 30 then 16 else 32 end;
$$;


ALTER FUNCTION "public"."_taste_elo_k"("p_count" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_taste_note_apply"("p_log_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_user uuid; v_place uuid; v_item uuid; v_sent text;
  v_created timestamptz; v_visit date;
  v_score double precision; v_rank int;
  e_self int; c_self int; e_opp int; c_opp int;
  exp_self double precision; exp_opp double precision;
  res_self double precision; res_opp double precision;
  rank_opp int; id_lo uuid; id_hi uuid;
  r record;
begin
  select user_id, place_id, menu_item_id, sentiment, created_at, visit_date
    into v_user, v_place, v_item, v_sent, v_created, v_visit
  from public.user_item_logs where id = p_log_id;

  if v_sent is null then
    return; -- no rating signal, nothing to score
  end if;

  v_score := public._taste_sentiment_score(v_sent);
  v_rank  := public._taste_sentiment_rank(v_sent);

  -- Baseline: implicit match against a neutral 1000 opponent.
  select elo_rating, comparison_count into e_self, c_self
    from public.menu_items where id = v_item for update;
  exp_self := public._taste_elo_expected(e_self, 1000);
  update public.menu_items
    set elo_rating       = round(e_self + public._taste_elo_k(c_self) * (v_score - exp_self))::int,
        comparison_count = c_self + 1,
        total_reviews    = total_reviews + 1
    where id = v_item;

  -- Pairwise against earlier items from the same visit.
  for r in
    select menu_item_id, sentiment
    from public.user_item_logs
    where user_id = v_user
      and place_id = v_place
      and visit_date = v_visit
      and menu_item_id <> v_item
      and sentiment is not null
      and created_at < v_created
  loop
    rank_opp := public._taste_sentiment_rank(r.sentiment);
    if    v_rank > rank_opp then res_self := 1.0; res_opp := 0.0;
    elsif v_rank < rank_opp then res_self := 0.0; res_opp := 1.0;
    else  res_self := 0.5; res_opp := 0.5;
    end if;

    -- Lock both rows in a stable id order to avoid deadlocks.
    if v_item < r.menu_item_id then id_lo := v_item; id_hi := r.menu_item_id;
    else id_lo := r.menu_item_id; id_hi := v_item; end if;
    perform 1 from public.menu_items where id = id_lo for update;
    perform 1 from public.menu_items where id = id_hi for update;

    select elo_rating, comparison_count into e_self, c_self
      from public.menu_items where id = v_item;
    select elo_rating, comparison_count into e_opp, c_opp
      from public.menu_items where id = r.menu_item_id;

    exp_self := public._taste_elo_expected(e_self, e_opp);
    exp_opp  := 1.0 - exp_self;

    update public.menu_items
      set elo_rating = round(e_self + public._taste_elo_k(c_self) * (res_self - exp_self))::int,
          comparison_count = c_self + 1
      where id = v_item;
    update public.menu_items
      set elo_rating = round(e_opp + public._taste_elo_k(c_opp) * (res_opp - exp_opp))::int,
          comparison_count = c_opp + 1
      where id = r.menu_item_id;
  end loop;
end;
$$;


ALTER FUNCTION "public"."_taste_note_apply"("p_log_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_taste_note_elo_trigger"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform public._taste_note_apply(NEW.id);
  return NEW;
end;
$$;


ALTER FUNCTION "public"."_taste_note_elo_trigger"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_taste_sentiment_rank"("p_s" "text") RETURNS integer
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case p_s when 'loved' then 2 when 'ok' then 1 when 'not_for_me' then 0 end;
$$;


ALTER FUNCTION "public"."_taste_sentiment_rank"("p_s" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_taste_sentiment_score"("p_s" "text") RETURNS double precision
    LANGUAGE "sql" IMMUTABLE
    AS $$
  select case p_s when 'loved' then 1.0 when 'ok' then 0.5 when 'not_for_me' then 0.0 end;
$$;


ALTER FUNCTION "public"."_taste_sentiment_score"("p_s" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_trg_confirmation_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."_trg_confirmation_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_trg_invoice_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."_trg_invoice_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_trg_request_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform public._billing_notify('request_submitted', new.company_account_id,
    'New company request: ' || replace(new.request_type, '_', ' '),
    coalesce(new.message, ''), null, new.id);
  return new;
end;
$$;


ALTER FUNCTION "public"."_trg_request_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_trg_setup_request_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into public.billing_notifications
    (notification_type, recipient_email, subject, body, request_id)
  values ('company_setup_request', new.email,
          'New company setup request: ' || new.legal_name,
          coalesce(new.message, ''), new.id);
  return new;
end;
$$;


ALTER FUNCTION "public"."_trg_setup_request_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."_trg_subscription_notify"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."_trg_subscription_notify"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."accept_onboarding_invite"("p_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."accept_onboarding_invite"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."accept_trip_invite"("_token" "uuid") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_trip_id    uuid;
  v_status     text;
  v_invitee    uuid;
  v_expires_at timestamptz;
  v_owner      uuid;
begin
  if auth.uid() is null then
    raise exception 'auth.uid() is null — must be signed in';
  end if;

  select trip_id, status, invitee_id, invite_expires_at
    into v_trip_id, v_status, v_invitee, v_expires_at
    from public.trip_collaborators
    where invite_token = _token
    for update;

  if v_trip_id is null then
    raise exception 'Invite not found';
  end if;

  -- A user cannot accept an invite to their own trip.
  select user_id into v_owner from public.itineraries where id = v_trip_id;
  if v_owner = auth.uid() then
    raise exception 'You cannot accept an invite to your own trip';
  end if;

  -- Already accepted by this user? Idempotent — return success.
  if v_status = 'accepted' and v_invitee = auth.uid() then
    return v_trip_id;
  end if;

  -- Claimed by someone else already.
  if v_invitee is not null and v_invitee <> auth.uid() then
    raise exception 'Invite already claimed';
  end if;

  if v_status = 'declined' then
    raise exception 'Invite was declined';
  end if;

  if v_status = 'pending'
     and v_expires_at is not null
     and v_expires_at < now() then
    raise exception 'Invite has expired';
  end if;

  update public.trip_collaborators
    set invitee_id = auth.uid(),
        status     = 'accepted'
    where invite_token = _token;

  return v_trip_id;
end $$;


ALTER FUNCTION "public"."accept_trip_invite"("_token" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."add_user_points"("_user" "uuid", "_points" integer) RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if _user is distinct from auth.uid() then
    -- You can relax this if you call from service key.
    raise exception 'unauthorized';
  end if;

  insert into public.user_stats (user_id, total_points, level)
  values (_user, coalesce(_points,0), 1)
  on conflict (user_id)
  do update set
    total_points = public.user_stats.total_points + coalesce(_points,0),
    updated_at   = now();
end;
$$;


ALTER FUNCTION "public"."add_user_points"("_user" "uuid", "_points" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."add_visit"("_place_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into visit_log(user_id, place_id) values (auth.uid(), _place_id);
  insert into visited(user_id, place_id) values (auth.uid(), _place_id)
    on conflict (user_id, place_id) do nothing;
end;
$$;


ALTER FUNCTION "public"."add_visit"("_place_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_attach_event"("p_admin_token" "text", "p_company_id" "uuid", "p_event_id" "uuid", "p_relationship_type" "text" DEFAULT 'host'::"text", "p_include_children" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_attach_event"("p_admin_token" "text", "p_company_id" "uuid", "p_event_id" "uuid", "p_relationship_type" "text", "p_include_children" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_attach_location"("p_admin_token" "text", "p_company_id" "uuid", "p_place_id" "uuid", "p_label" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_attach_location"("p_admin_token" "text", "p_company_id" "uuid", "p_place_id" "uuid", "p_label" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_billing_overview"("p_admin_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_billing_overview"("p_admin_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_configure_place_booking"("p_admin_token" "text", "p_place_id" "uuid", "p_accepts_stay_bookings" boolean DEFAULT NULL::boolean, "p_booking_mode" "text" DEFAULT NULL::"text", "p_bookings_email" "text" DEFAULT NULL::"text", "p_booking_contact_name" "text" DEFAULT NULL::"text", "p_check_in_time" "text" DEFAULT NULL::"text", "p_check_out_time" "text" DEFAULT NULL::"text", "p_min_nights" integer DEFAULT NULL::integer, "p_max_guests" integer DEFAULT NULL::integer, "p_cancellation_policy" "text" DEFAULT NULL::"text", "p_deposit_instructions" "text" DEFAULT NULL::"text", "p_deposit_required" boolean DEFAULT NULL::boolean, "p_deposit_default_amount" numeric DEFAULT NULL::numeric, "p_deposit_currency" "text" DEFAULT NULL::"text", "p_commission_terms" "text" DEFAULT NULL::"text", "p_taxes_fees_notes" "text" DEFAULT NULL::"text", "p_hold_expiry_minutes" integer DEFAULT NULL::integer, "p_internal_booking_notes" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  update public.places set
    accepts_stay_bookings   = coalesce(p_accepts_stay_bookings,  accepts_stay_bookings),
    booking_mode            = coalesce(p_booking_mode,           booking_mode),
    bookings_email          = coalesce(p_bookings_email,         bookings_email),
    booking_contact_name    = coalesce(p_booking_contact_name,   booking_contact_name),
    check_in_time           = coalesce(p_check_in_time,          check_in_time),
    check_out_time          = coalesce(p_check_out_time,         check_out_time),
    min_nights              = coalesce(p_min_nights,             min_nights),
    max_guests              = coalesce(p_max_guests,             max_guests),
    cancellation_policy_text= coalesce(p_cancellation_policy,   cancellation_policy_text),
    deposit_instructions    = coalesce(p_deposit_instructions,   deposit_instructions),
    deposit_required        = coalesce(p_deposit_required,       deposit_required),
    deposit_default_amount  = coalesce(p_deposit_default_amount, deposit_default_amount),
    deposit_currency        = coalesce(p_deposit_currency,       deposit_currency),
    commission_terms        = coalesce(p_commission_terms,       commission_terms),
    taxes_fees_notes        = coalesce(p_taxes_fees_notes,       taxes_fees_notes),
    hold_expiry_minutes     = coalesce(p_hold_expiry_minutes,    hold_expiry_minutes),
    internal_booking_notes  = coalesce(p_internal_booking_notes, internal_booking_notes)
  where id = p_place_id;
  if not found then return jsonb_build_object('error', 'place_not_found'); end if;
  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "public"."admin_configure_place_booking"("p_admin_token" "text", "p_place_id" "uuid", "p_accepts_stay_bookings" boolean, "p_booking_mode" "text", "p_bookings_email" "text", "p_booking_contact_name" "text", "p_check_in_time" "text", "p_check_out_time" "text", "p_min_nights" integer, "p_max_guests" integer, "p_cancellation_policy" "text", "p_deposit_instructions" "text", "p_deposit_required" boolean, "p_deposit_default_amount" numeric, "p_deposit_currency" "text", "p_commission_terms" "text", "p_taxes_fees_notes" "text", "p_hold_expiry_minutes" integer, "p_internal_booking_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_create_onboarding_invite"("p_admin_token" "text", "p_company_id" "uuid", "p_email" "text", "p_place_ids" "uuid"[] DEFAULT '{}'::"uuid"[], "p_event_ids" "uuid"[] DEFAULT '{}'::"uuid"[], "p_expires_days" integer DEFAULT 14) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_create_onboarding_invite"("p_admin_token" "text", "p_company_id" "uuid", "p_email" "text", "p_place_ids" "uuid"[], "p_event_ids" "uuid"[], "p_expires_days" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_detach_event"("p_admin_token" "text", "p_company_event_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_detach_event"("p_admin_token" "text", "p_company_event_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_detach_location"("p_admin_token" "text", "p_company_id" "uuid", "p_place_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_detach_location"("p_admin_token" "text", "p_company_id" "uuid", "p_place_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_generate_renewal_invoice"("p_admin_token" "text", "p_company_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_generate_renewal_invoice"("p_admin_token" "text", "p_company_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_get_billing_catalog"("p_admin_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_get_billing_catalog"("p_admin_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_get_company"("p_admin_token" "text", "p_company_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_get_company"("p_admin_token" "text", "p_company_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_get_place_booking_config"("p_admin_token" "text", "p_place_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place places%rowtype;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  select * into v_place from public.places where id = p_place_id;
  if v_place.id is null then return jsonb_build_object('error', 'place_not_found'); end if;

  return jsonb_build_object(
    'place', jsonb_build_object(
      'id',                      v_place.id,
      'name',                    v_place.name,
      'slug',                    v_place.slug,
      'bookings_email',          v_place.bookings_email,
      'accepts_stay_bookings',   v_place.accepts_stay_bookings,
      'booking_mode',            v_place.booking_mode,
      'booking_contact_name',    v_place.booking_contact_name,
      'check_in_time',           v_place.check_in_time,
      'check_out_time',          v_place.check_out_time,
      'min_nights',              v_place.min_nights,
      'max_guests',              v_place.max_guests,
      'cancellation_policy_text',v_place.cancellation_policy_text,
      'deposit_instructions',    v_place.deposit_instructions,
      'deposit_required',        v_place.deposit_required,
      'deposit_default_amount',  v_place.deposit_default_amount,
      'deposit_currency',        v_place.deposit_currency,
      'commission_terms',        v_place.commission_terms,
      'taxes_fees_notes',        v_place.taxes_fees_notes,
      'hold_expiry_minutes',     v_place.hold_expiry_minutes,
      'internal_booking_notes',  v_place.internal_booking_notes,
      'partner_access_token',    v_place.partner_access_token
    ),
    'room_types', (
      select coalesce(jsonb_agg(row_to_json(rt.*) order by rt.display_order, rt.created_at), '[]'::jsonb)
      from public.hotel_room_types rt where rt.place_id = p_place_id
    ),
    'rate_plans', (
      select coalesce(jsonb_agg(row_to_json(rp.*) order by rp.created_at), '[]'::jsonb)
      from public.hotel_rate_plans rp where rp.place_id = p_place_id
    ),
    'cancellation_policies', (
      select coalesce(jsonb_agg(row_to_json(cp.*) order by cp.is_default desc, cp.created_at), '[]'::jsonb)
      from public.booking_cancellation_policies cp where cp.place_id = p_place_id
    ),
    'availability_60d', (
      select coalesce(jsonb_agg(row_to_json(av.*) order by av.room_type_id, av.stay_date), '[]'::jsonb)
      from public.hotel_availability av
      where av.place_id = p_place_id
        and av.stay_date between current_date and current_date + interval '60 days'
    ),
    'recent_bookings', (
      select coalesce(jsonb_agg(
        jsonb_build_object('id', b.id, 'status', b.status, 'guest_name', b.guest_name,
                           'visit_date', b.visit_date, 'created_at', b.created_at)
        order by b.created_at desc
      ), '[]'::jsonb)
      from public.bookings b
      where b.place_id = p_place_id and b.created_at >= now() - interval '30 days'
      limit 20
    )
  );
end;
$$;


ALTER FUNCTION "public"."admin_get_place_booking_config"("p_admin_token" "text", "p_place_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_issue_invoice"("p_admin_token" "text", "p_invoice_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_issue_invoice"("p_admin_token" "text", "p_invoice_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_remove_company_user"("p_admin_token" "text", "p_company_user_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_remove_company_user"("p_admin_token" "text", "p_company_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_review_company_setup"("p_admin_token" "text", "p_request_id" "uuid", "p_decision" "text", "p_note" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_review_company_setup"("p_admin_token" "text", "p_request_id" "uuid", "p_decision" "text", "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_review_payment"("p_admin_token" "text", "p_confirmation_id" "uuid", "p_decision" "text", "p_note" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_review_payment"("p_admin_token" "text", "p_confirmation_id" "uuid", "p_decision" "text", "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_revoke_onboarding_invite"("p_admin_token" "text", "p_invite_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_revoke_onboarding_invite"("p_admin_token" "text", "p_invite_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_run_billing_maintenance"("p_admin_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_run_billing_maintenance"("p_admin_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_save_invoice"("p_admin_token" "text", "p_invoice_id" "uuid", "p_invoice" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_save_invoice"("p_admin_token" "text", "p_invoice_id" "uuid", "p_invoice" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_search_events"("p_admin_token" "text", "p_query" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_search_events"("p_admin_token" "text", "p_query" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_search_partners"("p_admin_token" "text", "p_query" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_search_partners"("p_admin_token" "text", "p_query" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_search_places"("p_admin_token" "text", "p_query" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_search_places"("p_admin_token" "text", "p_query" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_search_places_for_booking"("p_admin_token" "text", "p_query" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  return jsonb_build_object(
    'places', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'id', p.id, 'name', p.name, 'slug', p.slug,
          'town', p.town, 'parish', p.parish, 'category', p.category,
          'bookings_email', p.bookings_email,
          'accepts_stay_bookings', p.accepts_stay_bookings,
          'booking_mode', p.booking_mode
        ) order by p.name
      ), '[]'::jsonb)
      from public.places p
      where p_query is null
         or lower(p.name) like lower('%' || p_query || '%')
         or lower(coalesce(p.town, '')) like lower('%' || p_query || '%')
    )
  );
end;
$$;


ALTER FUNCTION "public"."admin_search_places_for_booking"("p_admin_token" "text", "p_query" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_set_availability"("p_admin_token" "text", "p_room_type_id" "uuid", "p_place_id" "uuid", "p_dates" "date"[], "p_available_rooms" integer DEFAULT NULL::integer, "p_is_closed" boolean DEFAULT NULL::boolean, "p_is_blackout" boolean DEFAULT NULL::boolean, "p_min_nights" integer DEFAULT NULL::integer, "p_base_nightly_rate" numeric DEFAULT NULL::numeric, "p_currency" "text" DEFAULT 'USD'::"text", "p_notes" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_date  date;
  v_count integer := 0;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  foreach v_date in array p_dates loop
    insert into public.hotel_availability (
      place_id, room_type_id, stay_date,
      available_rooms, is_closed, is_blackout,
      min_nights, base_nightly_rate, currency, notes
    ) values (
      p_place_id, p_room_type_id, v_date,
      coalesce(p_available_rooms, 0),
      coalesce(p_is_closed, false),
      coalesce(p_is_blackout, false),
      coalesce(p_min_nights, 1),
      p_base_nightly_rate,
      coalesce(p_currency, 'USD'),
      p_notes
    )
    on conflict (room_type_id, stay_date) do update set
      available_rooms   = case when p_available_rooms   is not null then p_available_rooms   else hotel_availability.available_rooms end,
      is_closed         = case when p_is_closed         is not null then p_is_closed         else hotel_availability.is_closed end,
      is_blackout       = case when p_is_blackout       is not null then p_is_blackout       else hotel_availability.is_blackout end,
      min_nights        = case when p_min_nights        is not null then p_min_nights        else hotel_availability.min_nights end,
      base_nightly_rate = case when p_base_nightly_rate is not null then p_base_nightly_rate else hotel_availability.base_nightly_rate end,
      currency          = case when p_currency          is not null then p_currency          else hotel_availability.currency end,
      notes             = case when p_notes             is not null then p_notes             else hotel_availability.notes end,
      updated_at        = now();
    v_count := v_count + 1;
  end loop;
  return jsonb_build_object('ok', true, 'dates_updated', v_count);
end;
$$;


ALTER FUNCTION "public"."admin_set_availability"("p_admin_token" "text", "p_room_type_id" "uuid", "p_place_id" "uuid", "p_dates" "date"[], "p_available_rooms" integer, "p_is_closed" boolean, "p_is_blackout" boolean, "p_min_nights" integer, "p_base_nightly_rate" numeric, "p_currency" "text", "p_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_set_billing_setting"("p_admin_token" "text", "p_key" "text", "p_value" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_set_billing_setting"("p_admin_token" "text", "p_key" "text", "p_value" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_set_entitlement"("p_admin_token" "text", "p_company_id" "uuid", "p_key" "text", "p_active" boolean, "p_expires_at" "date" DEFAULT NULL::"date", "p_note" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_set_entitlement"("p_admin_token" "text", "p_company_id" "uuid", "p_key" "text", "p_active" boolean, "p_expires_at" "date", "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_set_event_package"("p_admin_token" "text", "p_company_event_id" "uuid", "p_package_code" "text", "p_comped" boolean DEFAULT false, "p_note" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_set_event_package"("p_admin_token" "text", "p_company_event_id" "uuid", "p_package_code" "text", "p_comped" boolean, "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_set_invoice_status"("p_admin_token" "text", "p_invoice_id" "uuid", "p_status" "text", "p_note" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_set_invoice_status"("p_admin_token" "text", "p_invoice_id" "uuid", "p_status" "text", "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_set_message_status"("p_admin_token" "text", "p_message_id" "uuid", "p_status" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  if p_status not in ('new','in_progress','resolved') then
    return jsonb_build_object('ok', false, 'error', 'Invalid status');
  end if;

  update public.partner_messages
     set status = p_status,
         resolved_at = case when p_status = 'resolved' then now() else resolved_at end
   where id = p_message_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Message not found');
  end if;

  return jsonb_build_object('ok', true, 'status', p_status);
end;
$$;


ALTER FUNCTION "public"."admin_set_message_status"("p_admin_token" "text", "p_message_id" "uuid", "p_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_set_notification_status"("p_admin_token" "text", "p_notification_id" "uuid", "p_status" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_set_notification_status"("p_admin_token" "text", "p_notification_id" "uuid", "p_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_set_request_status"("p_admin_token" "text", "p_request_id" "uuid", "p_status" "text", "p_admin_notes" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_set_request_status"("p_admin_token" "text", "p_request_id" "uuid", "p_status" "text", "p_admin_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_set_special_status"("p_admin_token" "text", "p_special_id" "uuid", "p_status" "text", "p_review_note" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_set_special_status"("p_admin_token" "text", "p_special_id" "uuid", "p_status" "text", "p_review_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_set_submission_status"("p_admin_token" "text", "p_submission_id" "uuid", "p_status" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_event_id   uuid;
  v_event_slug text;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  if p_status not in ('draft','submitted','reviewing','approved','archived') then
    return jsonb_build_object('ok', false, 'error', 'Invalid status');
  end if;

  update public.event_partner_submissions
     set status = p_status,
         updated_at = now()
   where id = p_submission_id
   returning event_id into v_event_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Submission not found');
  end if;

  if v_event_id is not null then
    select slug into v_event_slug from public.events where id = v_event_id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'status', p_status,
    'event_id', v_event_id,
    'event_slug', v_event_slug
  );
end;
$$;


ALTER FUNCTION "public"."admin_set_submission_status"("p_admin_token" "text", "p_submission_id" "uuid", "p_status" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_set_subscription"("p_admin_token" "text", "p_company_id" "uuid", "p_action" "text", "p_plan_key" "text" DEFAULT NULL::"text", "p_billing_cycle" "text" DEFAULT NULL::"text", "p_paid_through" "date" DEFAULT NULL::"date", "p_note" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_set_subscription"("p_admin_token" "text", "p_company_id" "uuid", "p_action" "text", "p_plan_key" "text", "p_billing_cycle" "text", "p_paid_through" "date", "p_note" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_upsert_cancellation_policy"("p_admin_token" "text", "p_id" "uuid" DEFAULT NULL::"uuid", "p_place_id" "uuid" DEFAULT NULL::"uuid", "p_rate_plan_id" "uuid" DEFAULT NULL::"uuid", "p_policy_name" "text" DEFAULT NULL::"text", "p_policy_text" "text" DEFAULT NULL::"text", "p_free_cancel_hours" integer DEFAULT NULL::integer, "p_is_non_refundable" boolean DEFAULT NULL::boolean, "p_deposit_forfeiture_notes" "text" DEFAULT NULL::"text", "p_is_default" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_id uuid;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  if p_id is not null then
    update public.booking_cancellation_policies set
      policy_name              = coalesce(p_policy_name,              policy_name),
      policy_text              = coalesce(p_policy_text,              policy_text),
      free_cancel_hours        = coalesce(p_free_cancel_hours,        free_cancel_hours),
      is_non_refundable        = coalesce(p_is_non_refundable,        is_non_refundable),
      deposit_forfeiture_notes = coalesce(p_deposit_forfeiture_notes, deposit_forfeiture_notes),
      is_default               = coalesce(p_is_default,               is_default),
      updated_at               = now()
    where id = p_id;
    v_id := p_id;
  else
    if p_policy_name is null or p_policy_text is null then
      return jsonb_build_object('error', 'policy_name and policy_text required');
    end if;
    insert into public.booking_cancellation_policies (
      place_id, rate_plan_id, policy_name, policy_text,
      free_cancel_hours, is_non_refundable, deposit_forfeiture_notes, is_default
    ) values (
      p_place_id, p_rate_plan_id, p_policy_name, p_policy_text,
      p_free_cancel_hours, coalesce(p_is_non_refundable, false),
      p_deposit_forfeiture_notes, coalesce(p_is_default, false)
    ) returning id into v_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;


ALTER FUNCTION "public"."admin_upsert_cancellation_policy"("p_admin_token" "text", "p_id" "uuid", "p_place_id" "uuid", "p_rate_plan_id" "uuid", "p_policy_name" "text", "p_policy_text" "text", "p_free_cancel_hours" integer, "p_is_non_refundable" boolean, "p_deposit_forfeiture_notes" "text", "p_is_default" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_upsert_company"("p_admin_token" "text", "p_company_id" "uuid", "p_name" "text", "p_billing_email" "text", "p_contact_name" "text" DEFAULT NULL::"text", "p_contact_phone" "text" DEFAULT NULL::"text", "p_status" "text" DEFAULT 'active'::"text", "p_notes" "text" DEFAULT NULL::"text", "p_account_type" "text" DEFAULT 'hospitality_group'::"text", "p_source_type" "text" DEFAULT 'manual'::"text", "p_source_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_upsert_company"("p_admin_token" "text", "p_company_id" "uuid", "p_name" "text", "p_billing_email" "text", "p_contact_name" "text", "p_contact_phone" "text", "p_status" "text", "p_notes" "text", "p_account_type" "text", "p_source_type" "text", "p_source_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_upsert_company_user"("p_admin_token" "text", "p_company_id" "uuid", "p_email" "text", "p_name" "text" DEFAULT NULL::"text", "p_role" "text" DEFAULT 'admin'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_upsert_company_user"("p_admin_token" "text", "p_company_id" "uuid", "p_email" "text", "p_name" "text", "p_role" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_upsert_payment_instruction"("p_admin_token" "text", "p_id" "uuid", "p_fields" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."admin_upsert_payment_instruction"("p_admin_token" "text", "p_id" "uuid", "p_fields" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_upsert_rate_plan"("p_admin_token" "text", "p_id" "uuid" DEFAULT NULL::"uuid", "p_room_type_id" "uuid" DEFAULT NULL::"uuid", "p_place_id" "uuid" DEFAULT NULL::"uuid", "p_name" "text" DEFAULT NULL::"text", "p_description" "text" DEFAULT NULL::"text", "p_cancellation_policy" "text" DEFAULT NULL::"text", "p_meal_plan" "text" DEFAULT NULL::"text", "p_inclusions" "text" DEFAULT NULL::"text", "p_is_refundable" boolean DEFAULT NULL::boolean, "p_is_active" boolean DEFAULT NULL::boolean) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_id uuid;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  if p_id is not null then
    update public.hotel_rate_plans set
      name                = coalesce(p_name,                name),
      description         = coalesce(p_description,         description),
      cancellation_policy = coalesce(p_cancellation_policy, cancellation_policy),
      meal_plan           = coalesce(p_meal_plan,           meal_plan),
      inclusions          = coalesce(p_inclusions,          inclusions),
      is_refundable       = coalesce(p_is_refundable,       is_refundable),
      is_active           = coalesce(p_is_active,           is_active),
      updated_at          = now()
    where id = p_id;
    v_id := p_id;
  else
    if p_room_type_id is null or p_place_id is null or p_name is null then
      return jsonb_build_object('error', 'room_type_id, place_id, and name required');
    end if;
    insert into public.hotel_rate_plans (
      room_type_id, place_id, name, description,
      cancellation_policy, meal_plan, inclusions, is_refundable, is_active
    ) values (
      p_room_type_id, p_place_id, p_name, p_description,
      p_cancellation_policy, p_meal_plan, p_inclusions,
      coalesce(p_is_refundable, true), coalesce(p_is_active, true)
    ) returning id into v_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;


ALTER FUNCTION "public"."admin_upsert_rate_plan"("p_admin_token" "text", "p_id" "uuid", "p_room_type_id" "uuid", "p_place_id" "uuid", "p_name" "text", "p_description" "text", "p_cancellation_policy" "text", "p_meal_plan" "text", "p_inclusions" "text", "p_is_refundable" boolean, "p_is_active" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."admin_upsert_room_type"("p_admin_token" "text", "p_id" "uuid" DEFAULT NULL::"uuid", "p_place_id" "uuid" DEFAULT NULL::"uuid", "p_name" "text" DEFAULT NULL::"text", "p_description" "text" DEFAULT NULL::"text", "p_max_guests" integer DEFAULT NULL::integer, "p_base_occupancy" integer DEFAULT NULL::integer, "p_room_count" integer DEFAULT NULL::integer, "p_amenities" "text"[] DEFAULT NULL::"text"[], "p_images" "text"[] DEFAULT NULL::"text"[], "p_is_active" boolean DEFAULT NULL::boolean, "p_display_order" integer DEFAULT NULL::integer) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_id uuid;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('error', 'unauthorized');
  end if;
  if p_id is not null then
    update public.hotel_room_types set
      name           = coalesce(p_name,           name),
      description    = coalesce(p_description,    description),
      max_guests     = coalesce(p_max_guests,      max_guests),
      base_occupancy = coalesce(p_base_occupancy,  base_occupancy),
      room_count     = coalesce(p_room_count,      room_count),
      amenities      = coalesce(p_amenities,       amenities),
      images         = coalesce(p_images,          images),
      is_active      = coalesce(p_is_active,       is_active),
      display_order  = coalesce(p_display_order,   display_order),
      updated_at     = now()
    where id = p_id;
    v_id := p_id;
  else
    if p_place_id is null or p_name is null then
      return jsonb_build_object('error', 'place_id and name required');
    end if;
    insert into public.hotel_room_types (
      place_id, name, description, max_guests, base_occupancy,
      room_count, amenities, images, is_active, display_order
    ) values (
      p_place_id, p_name, p_description,
      coalesce(p_max_guests, 2), coalesce(p_base_occupancy, 1),
      coalesce(p_room_count, 1), coalesce(p_amenities, '{}'),
      coalesce(p_images, '{}'), coalesce(p_is_active, true),
      coalesce(p_display_order, 0)
    ) returning id into v_id;
  end if;
  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;


ALTER FUNCTION "public"."admin_upsert_room_type"("p_admin_token" "text", "p_id" "uuid", "p_place_id" "uuid", "p_name" "text", "p_description" "text", "p_max_guests" integer, "p_base_occupancy" integer, "p_room_count" integer, "p_amenities" "text"[], "p_images" "text"[], "p_is_active" boolean, "p_display_order" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."after_xp_transaction_insert"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$

begin

  perform public.recalculate_user_xp(new.user_id);

  return new;

end;

$$;


ALTER FUNCTION "public"."after_xp_transaction_insert"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."approve_event_submission"("p_submission_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_event_id uuid;
  v_event_slug text;
begin
  update public.event_partner_submissions
     set status = 'approved',
         submitted_at = coalesce(submitted_at, now()),
         updated_at = now()
   where id = p_submission_id
   returning event_id into v_event_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Submission not found');
  end if;

  select slug into v_event_slug from public.events where id = v_event_id;

  return jsonb_build_object(
    'ok',        true,
    'event_id',  v_event_id,
    'event_slug', v_event_slug
  );
end;
$$;


ALTER FUNCTION "public"."approve_event_submission"("p_submission_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assign_partner_account"("p_partner_name" "text", "p_contact_email" "text" DEFAULT NULL::"text", "p_place_slugs" "text"[] DEFAULT '{}'::"text"[], "p_event_slugs" "text"[] DEFAULT '{}'::"text"[]) RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_partner_id uuid;
begin
  select id
    into v_partner_id
    from public.partners
   where lower(name) = lower(p_partner_name)
   limit 1;

  if v_partner_id is null then
    insert into public.partners (name, contact_email)
    values (p_partner_name, p_contact_email)
    returning id into v_partner_id;
  else
    update public.partners
       set contact_email = coalesce(p_contact_email, contact_email),
           updated_at = now()
     where id = v_partner_id;
  end if;

  update public.places
     set partner_id = v_partner_id
   where slug = any(p_place_slugs);

  update public.events
     set partner_id = v_partner_id
   where slug = any(p_event_slugs);

  return v_partner_id;
end;
$$;


ALTER FUNCTION "public"."assign_partner_account"("p_partner_name" "text", "p_contact_email" "text", "p_place_slugs" "text"[], "p_event_slugs" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."assign_special_waitlist_position"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
declare
  cap          int;
  active_count int;
begin
  if new.booking_type <> 'special' or new.special_id is null then
    return new;
  end if;

  select capacity into cap
  from public.specials
  where id = new.special_id;

  -- Uncapped specials never waitlist.
  if cap is null then
    new.waitlist_position := null;
    return new;
  end if;

  select count(*) into active_count
  from public.bookings
  where special_id = new.special_id
    and waitlist_position is null
    and status in ('pending', 'confirmed', 'counter_proposed', 'counter_accepted');

  if active_count < cap then
    new.waitlist_position := null;       -- within capacity → confirmed-eligible
  else
    -- Position N+1 where N is the current waitlist length.
    select coalesce(max(waitlist_position), 0) + 1 into new.waitlist_position
    from public.bookings
    where special_id = new.special_id
      and waitlist_position is not null
      and status in ('pending', 'confirmed', 'counter_proposed', 'counter_accepted');
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."assign_special_waitlist_position"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."award_achievement_bonus_xp"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_bonus_xp integer;
  v_achievement_title text;
begin

  select
    coalesce(bonus_xp, points, 0),
    title
  into
    v_bonus_xp,
    v_achievement_title
  from public.achievements
  where id = new.achievement_id;

  if v_bonus_xp > 0 then

    perform public.award_xp(
      new.user_id,
      'achievement',
      new.achievement_id,
      v_bonus_xp,
      jsonb_build_object(
        'achievement_id', new.achievement_id,
        'achievement_title', v_achievement_title,
        'awarded_from', 'achievement_completion'
      )
    );

  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."award_achievement_bonus_xp"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."award_xp"("p_user_id" "uuid", "p_source_type" "text", "p_source_id" "text", "p_xp_amount" integer, "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$

declare

  v_transaction_id uuid;

begin

  if p_user_id is null then

    raise exception 'user_id is required';

  end if;

  if p_xp_amount <= 0 then

    raise exception 'XP amount must be greater than 0';

  end if;

  insert into public.xp_transactions (

    user_id,

    transaction_type,

    source_type,

    source_id,

    xp_amount,

    metadata

  )

  values (

    p_user_id,

    'earn',

    p_source_type,

    p_source_id,

    p_xp_amount,

    coalesce(p_metadata, '{}'::jsonb)

  )

  on conflict do nothing

  returning id into v_transaction_id;

  return v_transaction_id;

end;

$$;


ALTER FUNCTION "public"."award_xp"("p_user_id" "uuid", "p_source_type" "text", "p_source_id" "text", "p_xp_amount" integer, "p_metadata" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."award_xp_by_rule"("p_user_id" "uuid", "p_rule_key" "text", "p_source_id" "text", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$

declare

  v_rule public.xp_rules%rowtype;

begin

  select *

  into v_rule

  from public.xp_rules

  where rule_key = p_rule_key

  and is_active = true;

  if not found then

    raise exception 'XP rule not found or inactive: %', p_rule_key;

  end if;

  return public.award_xp(

    p_user_id,

    v_rule.source_type,

    p_source_id,

    v_rule.xp_amount,

    p_metadata || jsonb_build_object('rule_key', p_rule_key)

  );

end;

$$;


ALTER FUNCTION "public"."award_xp_by_rule"("p_user_id" "uuid", "p_rule_key" "text", "p_source_id" "text", "p_metadata" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."build_guest_profile_snapshot"("p_user_id" "uuid", "p_place_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_total_xp     bigint      := 0;
  v_tier         text        := 'member';
  v_visits_total int         := 0;
  v_visits_here  int         := 0;
  v_checkins     int         := 0;
  v_saved_here   boolean     := false;
  v_saved_total  int         := 0;
  v_your_note    text;
  v_your_vote    int;
  v_last_visit   timestamptz;
  v_loyalty      jsonb       := null;
  v_pref_tags    jsonb       := '[]'::jsonb;
begin
  begin
    select coalesce(total_xp, 0) into v_total_xp
    from public.user_xp_totals where user_id = p_user_id;
  exception when others then v_total_xp := 0; end;

  v_tier := case
    when v_total_xp >= 1750 then 'inner_circle'
    when v_total_xp >= 700  then 'insider'
    when v_total_xp >= 250  then 'regular'
    else 'member'
  end;

  begin
    select count(*) into v_visits_total
    from public.visited where user_id = p_user_id;
  exception when others then null; end;

  begin
    select coalesce(visit_count, 1), notes, vote, created_at
      into v_visits_here, v_your_note, v_your_vote, v_last_visit
    from public.visited
    where user_id = p_user_id and place_id = p_place_id
    order by created_at desc
    limit 1;
  exception when others then null; end;

  begin
    select count(*) into v_checkins
    from public.user_checkins
    where user_id = p_user_id and place_id = p_place_id;
  exception when others then null; end;

  begin
    select count(*) into v_saved_total
    from public.favorites where user_id = p_user_id;
    select exists(
      select 1 from public.favorites
      where user_id = p_user_id and place_id = p_place_id
    ) into v_saved_here;
  exception when others then null; end;

  begin
    select jsonb_build_object(
      'current_stamps',   c.current_stamps,
      'required_stamps',  lp.required_stamps,
      'reward',           lp.reward,
      'completed_cycles', coalesce(c.completed_cycles, 0)
    )
    into v_loyalty
    from public.loyalty_programs lp
    join public.user_loyalty_cards c
      on c.program_id = lp.id and c.user_id = p_user_id
    where lp.place_id = p_place_id and lp.is_active = true
    limit 1;
  exception when others then v_loyalty := null; end;

  -- Review-derived signals: the guest's own quick_tags across their feedback.
  -- to_jsonb handles text[] or jsonb columns; jsonb_array_elements_text then
  -- flattens. Guarded because quick_tags shape isn't guaranteed everywhere.
  begin
    select coalesce(jsonb_agg(distinct tag), '[]'::jsonb) into v_pref_tags
    from (
      select jsonb_array_elements_text(to_jsonb(vf.quick_tags)) as tag
      from public.visited_feedback vf
      where vf.user_id = p_user_id
        and vf.quick_tags is not null
      limit 100
    ) s;
  exception when others then v_pref_tags := '[]'::jsonb; end;

  return jsonb_build_object(
    'version',      1,
    'generated_at', now(),
    'tier',         v_tier,
    'total_xp',     v_total_xp,
    'network', jsonb_build_object(
      'visits',       v_visits_total,
      'saved_places', v_saved_total
    ),
    'venue', jsonb_build_object(
      'checkins',    v_checkins,
      'visits_here', v_visits_here,
      'saved',       v_saved_here,
      'last_visit',  v_last_visit,
      'your_note',   v_your_note,
      'your_vote',   v_your_vote,
      'loyalty',     v_loyalty
    ),
    'preferences', jsonb_build_object('tags', v_pref_tags)
  );
end;
$$;


ALTER FUNCTION "public"."build_guest_profile_snapshot"("p_user_id" "uuid", "p_place_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bulk_import_schedule_items"("p_token" "text", "p_items" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_event_id uuid;
  v_item jsonb;
  v_day_id uuid;
  v_day_date date;
  v_inserted int := 0;
  v_skipped int := 0;
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  if jsonb_typeof(coalesce(p_items, '[]'::jsonb)) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'items_must_be_array');
  end if;

  for v_item in select value from jsonb_array_elements(p_items)
  loop
    if coalesce(btrim(v_item->>'title'), '') = '' then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    v_day_id := nullif(v_item->>'day_id', '')::uuid;
    if v_day_id is null and nullif(v_item->>'date', '') is not null then
      v_day_date := (v_item->>'date')::date;
      select id into v_day_id
        from public.event_schedule_days
       where event_id = v_event_id and date = v_day_date
       order by created_at
       limit 1;

      if v_day_id is null then
        insert into public.event_schedule_days (event_id, date, label)
        values (v_event_id, v_day_date, nullif(btrim(v_item->>'day_label'), ''))
        returning id into v_day_id;
      end if;
    end if;

    if v_day_id is null or not exists (
      select 1 from public.event_schedule_days where id = v_day_id and event_id = v_event_id
    ) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    insert into public.event_schedule_items (
      event_id, day_id, title, subtitle, start_time, end_time, venue_override,
      category, image_url, is_featured, is_must_see, is_published
    )
    values (
      v_event_id,
      v_day_id,
      btrim(v_item->>'title'),
      nullif(btrim(v_item->>'subtitle'), ''),
      nullif(v_item->>'start_time', '')::timestamptz,
      nullif(v_item->>'end_time', '')::timestamptz,
      nullif(btrim(coalesce(v_item->>'venue_override', v_item->>'stage')), ''),
      nullif(btrim(coalesce(v_item->>'category', 'artist')), ''),
      nullif(btrim(v_item->>'image_url'), ''),
      coalesce((v_item->>'is_featured')::boolean, false),
      coalesce((v_item->>'is_must_see')::boolean, false),
      coalesce((v_item->>'is_published')::boolean, true)
    );
    v_inserted := v_inserted + 1;
  end loop;

  return jsonb_build_object('ok', true, 'inserted', v_inserted, 'skipped', v_skipped);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM, 'inserted', v_inserted, 'skipped', v_skipped);
end;
$$;


ALTER FUNCTION "public"."bulk_import_schedule_items"("p_token" "text", "p_items" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bump_schedule_version"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF (
    OLD.start_time IS DISTINCT FROM NEW.start_time OR
    OLD.end_time IS DISTINCT FROM NEW.end_time OR
    OLD.status IS DISTINCT FROM NEW.status OR
    OLD.track_id IS DISTINCT FROM NEW.track_id OR
    OLD.title IS DISTINCT FROM NEW.title
  ) THEN
    NEW.version = OLD.version + 1;

    UPDATE event_schedule_meta
    SET current_version = current_version + 1,
        last_updated = NOW()
    WHERE event_id = NEW.event_id;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."bump_schedule_version"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."bump_share_view"("_token" "text") RETURNS "void"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  update itinerary_shares
  set view_count = coalesce(view_count, 0) + 1
  where token = _token
    and (expires_at is null or expires_at > now());
$$;


ALTER FUNCTION "public"."bump_share_view"("_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cancel_change_request"("_request_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  r record;
begin
  if auth.uid() is null then raise exception 'must be signed in'; end if;
  select * into r from public.trip_change_requests where id = _request_id;
  if r.id is null then raise exception 'request not found'; end if;
  if r.status <> 'pending' then return; end if;
  if r.proposed_by <> auth.uid() and not public.is_trip_owner(r.trip_id) then
    raise exception 'not allowed';
  end if;
  update public.trip_change_requests
    set status = 'cancelled', resolved_at = now()
    where id = _request_id;
end $$;


ALTER FUNCTION "public"."cancel_change_request"("_request_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."check_and_unlock"("_user" "uuid", "_event" "text", "_payload" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
DECLARE
  unlocked_achievements text[] := '{}';
  points_awarded integer := 0;
  user_leveled_up boolean := false;
  new_user_level integer := 1;
  achievement_to_check text;
BEGIN
  -- Map events to achievements
  CASE _event
    WHEN 'app_open' THEN
      achievement_to_check := 'comeback_kid';
    WHEN 'add_favorite' THEN
      achievement_to_check := 'first_favorite';
    WHEN 'visit_place' THEN
      achievement_to_check := 'first_visit';
    WHEN 'add_note' THEN
      achievement_to_check := 'note_bronze';
    ELSE
      achievement_to_check := NULL;
  END CASE;

  -- Only proceed if we have an achievement to check
  IF achievement_to_check IS NOT NULL THEN
    -- Check if achievement exists first
    IF EXISTS (SELECT 1 FROM achievements WHERE id = achievement_to_check) THEN
      -- Try to insert the achievement
      INSERT INTO user_achievements (
        user_id,
        achievement_id,
        unlocked_at,
        is_completed
      ) VALUES (
        _user,
        achievement_to_check,
        NOW(),
        true
      ) ON CONFLICT (user_id, achievement_id) DO NOTHING;
      
      -- Check if we actually inserted (GET DIAGNOSTICS is more reliable than FOUND for ON CONFLICT)
      IF FOUND THEN
        unlocked_achievements := array_append(unlocked_achievements, achievement_to_check);
        points_awarded := 10;
      END IF;
    ELSE
      RAISE WARNING 'Achievement % does not exist', achievement_to_check;
    END IF;
  END IF;

  RETURN jsonb_build_object(
    'unlocked', to_jsonb(unlocked_achievements),
    'pointsAwarded', points_awarded,
    'leveledUp', user_leveled_up,
    'newLevel', new_user_level
  );
END;
$$;


ALTER FUNCTION "public"."check_and_unlock"("_user" "uuid", "_event" "text", "_payload" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."checkin_in_app"("p_place_id" "uuid", "p_lat" double precision DEFAULT NULL::double precision, "p_lng" double precision DEFAULT NULL::double precision, "p_idempotency_key" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'extensions'
    AS $$
declare
  v_user_id     uuid := auth.uid();
  v_settings    public.place_checkin_settings;
  v_place_lat   double precision;
  v_place_lng   double precision;
  v_cooldown    int;
  v_distance_m  double precision;
  v_last        timestamptz;
  v_checkin_id  uuid;
  v_xp          int := 0;
begin
  if v_user_id is null then
    return jsonb_build_object('ok', false, 'error', 'auth', 'message', 'Sign in to check in.');
  end if;

  -- Settings gate.
  select * into v_settings
  from public.place_checkin_settings
  where place_id = p_place_id;

  if not found or v_settings.checkin_enabled is not true
     or v_settings.in_app_checkin_enabled is not true then
    return jsonb_build_object('ok', false, 'error', 'disabled',
      'message', 'Check-in isn''t available here.');
  end if;

  -- Idempotent replay: if this key already produced a check-in, return it.
  if p_idempotency_key is not null then
    select id into v_checkin_id
    from public.user_checkins
    where user_id = v_user_id and idempotency_key = p_idempotency_key
    limit 1;
    if v_checkin_id is not null then
      return jsonb_build_object('ok', true, 'checkin_id', v_checkin_id,
        'xp_earned', 0, 'replayed', true);
    end if;
  end if;

  -- Cooldown.
  v_cooldown := coalesce(v_settings.cooldown_minutes, 360);
  select max(created_at) into v_last
  from public.user_checkins
  where user_id = v_user_id and place_id = p_place_id;

  if v_last is not null and v_last > now() - make_interval(mins => v_cooldown) then
    return jsonb_build_object('ok', false, 'error', 'cooldown',
      'message', 'You already checked in here recently.');
  end if;

  -- Proximity ("if available"): only enforced when we have both the place's
  -- coords and the device's coords. Missing either → best-effort allow.
  if v_settings.requires_proximity is true and p_lat is not null and p_lng is not null then
    select latitude, longitude into v_place_lat, v_place_lng
    from public.places where id = p_place_id;

    if v_place_lat is not null and v_place_lng is not null then
      -- Haversine, metres.
      v_distance_m := 6371000 * 2 * asin(sqrt(
        power(sin(radians(v_place_lat - p_lat) / 2), 2) +
        cos(radians(p_lat)) * cos(radians(v_place_lat)) *
        power(sin(radians(v_place_lng - p_lng) / 2), 2)
      ));
      if v_distance_m > 250 then
        return jsonb_build_object('ok', false, 'error', 'too_far',
          'message', 'You need to be at the venue to check in.');
      end if;
    end if;
  end if;

  -- Record the check-in (source 'manual' — the table's CHECK only allows
  -- 'nfc'|'manual'; in-app is a manual-trust initiation).
  v_xp := case when v_settings.xp_enabled then 10 else 0 end;

  insert into public.user_checkins
    (user_id, place_id, checkin_type, source, idempotency_key, xp_earned)
  values
    (v_user_id, p_place_id, 'visit', 'manual', p_idempotency_key, v_xp)
  returning id into v_checkin_id;

  -- Mark visited (best-effort; ignore if the table/constraint differs).
  begin
    insert into public.visited (user_id, place_id)
    values (v_user_id, p_place_id)
    on conflict (user_id, place_id) do nothing;
  exception when others then null; end;

  -- Award XP to the ledger, deduped on the check-in id so retries are safe.
  if v_xp > 0 then
    begin
      insert into public.xp_transactions
        (user_id, action_key, xp_amount, source_type, source_id)
      values
        (v_user_id, 'place_visited', v_xp, 'checkin', v_checkin_id::text)
      on conflict do nothing;
    exception when others then null; end;
  end if;

  return jsonb_build_object('ok', true, 'checkin_id', v_checkin_id,
    'xp_earned', v_xp, 'loyalty', false);
end;
$$;


ALTER FUNCTION "public"."checkin_in_app"("p_place_id" "uuid", "p_lat" double precision, "p_lng" double precision, "p_idempotency_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."cleanup_expired_holds"() RETURNS integer
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_count integer;
begin
  update public.hotel_inventory_holds
     set released_at = now()
   where released_at is null
     and is_converted = false
     and expires_at < now();
  get diagnostics v_count = row_count;

  update public.bookings
     set status = 'expired'
   where status = 'held'
     and expires_at is not null
     and expires_at < now();

  return v_count;
end;
$$;


ALTER FUNCTION "public"."cleanup_expired_holds"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."company_access_state"("p_company_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."company_access_state"("p_company_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."company_has_entitlement"("p_company_id" "uuid", "p_key" "text") RETURNS boolean
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."company_has_entitlement"("p_company_id" "uuid", "p_key" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."company_specials_usage"("p_company_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."company_specials_usage"("p_company_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."copy_submission_to_event"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_event_id    uuid;
  v_start_date  date;
  v_end_date    date;
  v_lat         double precision;
  v_lng         double precision;
  v_capacity    integer;
  v_min_age     integer;
  v_gallery     text[];
  v_slug        text;
begin
  -- Only fire on transition INTO 'approved'.
  if new.status is distinct from 'approved' then
    return new;
  end if;
  if old.status is not null and old.status = 'approved' then
    return new;
  end if;

  -- Safe casts (catch bad text values from intake form)
  begin v_start_date := nullif(trim(coalesce(new.event_start_date, '')), '')::date;
  exception when others then v_start_date := null; end;
  begin v_end_date := nullif(trim(coalesce(new.event_end_date, '')), '')::date;
  exception when others then v_end_date := null; end;
  begin v_lat := nullif(trim(coalesce(new.venue_lat, '')), '')::double precision;
  exception when others then v_lat := null; end;
  begin v_lng := nullif(trim(coalesce(new.venue_lng, '')), '')::double precision;
  exception when others then v_lng := null; end;
  begin v_capacity := nullif(trim(coalesce(new.estimated_attendance, '')), '')::integer;
  exception when others then v_capacity := null; end;
  begin
    v_min_age := nullif(regexp_replace(coalesce(new.age_restriction, ''), '[^0-9]', '', 'g'), '')::integer;
  exception when others then v_min_age := null; end;

  -- Gallery URLs: jsonb array -> text[]
  begin
    v_gallery := array(select jsonb_array_elements_text(coalesce(new.gallery_urls, '[]'::jsonb)));
  exception when others then v_gallery := array[]::text[]; end;

  ------------------------------------------------------------
  -- (a) Update an existing linked event
  ------------------------------------------------------------
  if new.event_id is not null then
    update public.events set
      title              = coalesce(nullif(trim(new.event_name), ''), title),
      description        = coalesce(nullif(trim(new.event_description), ''), description),
      start_date         = coalesce(v_start_date, start_date),
      end_date           = coalesce(v_end_date,   end_date),
      venue_name         = coalesce(nullif(trim(new.venue_name), ''), venue_name),
      venue_address      = coalesce(nullif(trim(new.venue_address), ''), venue_address),
      venue_lat          = coalesce(v_lat, venue_lat),
      venue_lng          = coalesce(v_lng, venue_lng),
      website_url        = coalesce(nullif(trim(new.website), ''), website_url),
      instagram_url      = coalesce(nullif(trim(new.instagram), ''), instagram_url),
      ticket_url         = coalesce(nullif(trim(new.tickets_url), ''), ticket_url),
      organizer_name     = coalesce(nullif(trim(new.organizer_name), ''), organizer_name),
      contact_email      = coalesce(nullif(trim(new.contact_email), ''), contact_email),
      contact_phone      = coalesce(nullif(trim(new.contact_phone), ''), contact_phone),
      event_type         = coalesce(public._normalize_event_type(new.event_type), event_type),
      featured_image_url = coalesce(nullif(trim(new.hero_url), ''), featured_image_url),
      capacity           = coalesce(v_capacity, capacity),
      min_age            = coalesce(v_min_age, min_age),
      image_urls         = case
                              when array_length(v_gallery, 1) is not null and array_length(v_gallery, 1) > 0
                                then v_gallery
                              else image_urls
                           end,
      floor_plan_url     = coalesce(nullif(trim(new.floor_plan_url), ''), floor_plan_url),
      faq                = case
                              when new.faqs is not null and new.faqs <> '[]'::jsonb
                                then new.faqs
                              else faq
                           end,
      updated_at         = now()
    where id = new.event_id;

  ------------------------------------------------------------
  -- (b) Insert a fresh event row from the submission
  ------------------------------------------------------------
  else
    v_slug := public.generate_unique_event_slug(
      coalesce(nullif(trim(new.event_name), ''), 'event'));

    insert into public.events (
      slug, title, description, status,
      start_date, end_date,
      venue_name, venue_address, venue_lat, venue_lng,
      country, timezone,
      website_url, instagram_url, ticket_url,
      organizer_name, contact_email, contact_phone,
      event_type, featured_image_url, image_urls,
      capacity, min_age, faq, floor_plan_url
    ) values (
      v_slug,
      coalesce(nullif(trim(new.event_name), ''), 'Untitled event'),
      nullif(trim(new.event_description), ''),
      'published',
      coalesce(v_start_date, current_date),
      coalesce(v_end_date, v_start_date, current_date),
      nullif(trim(new.venue_name), ''),
      nullif(trim(new.venue_address), ''),
      v_lat, v_lng,
      'Jamaica', 'America/Jamaica',
      nullif(trim(new.website), ''),
      nullif(trim(new.instagram), ''),
      nullif(trim(new.tickets_url), ''),
      nullif(trim(new.organizer_name), ''),
      nullif(trim(new.contact_email), ''),
      nullif(trim(new.contact_phone), ''),
      public._normalize_event_type(new.event_type),
      nullif(trim(new.hero_url), ''),
      coalesce(v_gallery, array[]::text[]),
      v_capacity,
      v_min_age,
      new.faqs,
      nullif(trim(new.floor_plan_url), '')
    )
    returning id into v_event_id;

    -- Link the submission back to the freshly created event
    new.event_id := v_event_id;
  end if;

  return new;
end;
$$;


ALTER FUNCTION "public"."copy_submission_to_event"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."count_unique_visits"("p_place_id" "uuid") RETURNS integer
    LANGUAGE "sql" SECURITY DEFINER
    AS $$
  select count(distinct user_id)
  from visited
  where place_id = p_place_id;
$$;


ALTER FUNCTION "public"."count_unique_visits"("p_place_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."count_unique_votes"("p_place_id" "uuid", "p_vote" "text") RETURNS integer
    LANGUAGE "sql" SECURITY DEFINER
    AS $$
  select count(distinct user_id)
  from visited
  where place_id = p_place_id
  and vote = p_vote;
$$;


ALTER FUNCTION "public"."count_unique_votes"("p_place_id" "uuid", "p_vote" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_event_map_invite"("p_token" "text", "p_designer_name" "text" DEFAULT NULL::"text", "p_designer_email" "text" DEFAULT NULL::"text", "p_scopes" "text"[] DEFAULT '{markers}'::"text"[], "p_expires_in_days" integer DEFAULT 14) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_event_id uuid;
  v_token    text;
  v_expires  timestamptz;
begin
  select id into v_event_id
    from public.events
   where partner_access_token = p_token;

  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  v_expires := now() + (greatest(1, p_expires_in_days) || ' days')::interval;

  insert into public.event_map_invites (event_id, designer_name, designer_email, scopes, expires_at)
       values (v_event_id, p_designer_name, p_designer_email,
               coalesce(p_scopes, '{markers}'::text[]), v_expires)
    returning token into v_token;

  return jsonb_build_object(
    'ok', true,
    'token', v_token,
    'expires_at', v_expires,
    'scopes', coalesce(p_scopes, '{markers}'::text[])
  );
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;


ALTER FUNCTION "public"."create_event_map_invite"("p_token" "text", "p_designer_name" "text", "p_designer_email" "text", "p_scopes" "text"[], "p_expires_in_days" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_inventory_hold"("p_place_id" "uuid", "p_room_type_id" "uuid", "p_check_in" "date", "p_check_out" "date", "p_rooms" integer DEFAULT 1, "p_session_id" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place       places%rowtype;
  v_room_type   hotel_room_types%rowtype;
  v_expiry_mins integer;
  v_hold_id     uuid;
begin
  select * into v_place from public.places where id = p_place_id;
  select * into v_room_type from public.hotel_room_types
   where id = p_room_type_id and place_id = p_place_id;
  if v_room_type.id is null then
    return jsonb_build_object('error', 'room_type_not_found');
  end if;
  v_expiry_mins := coalesce(v_place.hold_expiry_minutes, 10);
  insert into public.hotel_inventory_holds (
    place_id, room_type_id, rooms_held,
    check_in_date, check_out_date, session_id, expires_at
  ) values (
    p_place_id, p_room_type_id, p_rooms,
    p_check_in, p_check_out, p_session_id,
    now() + (v_expiry_mins || ' minutes')::interval
  ) returning id into v_hold_id;
  return jsonb_build_object(
    'ok', true, 'hold_id', v_hold_id,
    'expires_at', now() + (v_expiry_mins || ' minutes')::interval,
    'expiry_minutes', v_expiry_mins
  );
end;
$$;


ALTER FUNCTION "public"."create_inventory_hold"("p_place_id" "uuid", "p_room_type_id" "uuid", "p_check_in" "date", "p_check_out" "date", "p_rooms" integer, "p_session_id" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_or_update_itinerary_share"("_itinerary_id" "uuid", "_expires_at" timestamp with time zone DEFAULT NULL::timestamp with time zone, "_regenerate" boolean DEFAULT false) RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_owner uuid;
  v_token text := replace(gen_random_uuid()::text, '-', ''); -- 32-char token
  v_existing text;
  v_final text;
begin
  -- Verify ownership first
  select user_id into v_owner
  from public.itineraries
  where id = _itinerary_id;

  if v_owner is null or v_owner <> auth.uid() then
    raise exception 'not owner';
  end if;

  -- If a share exists, fetch its token to reuse when not regenerating
  select token into v_existing
  from public.itinerary_shares
  where itinerary_id = _itinerary_id
  limit 1;

  v_final := case when _regenerate or v_existing is null then v_token else v_existing end;

  -- Single-statement upsert, scoped to this itinerary only
  insert into public.itinerary_shares (itinerary_id, token, expires_at, created_by)
  values (_itinerary_id, v_final, _expires_at, auth.uid())
  on conflict (itinerary_id) do update
    set token      = case when excluded.token <> public.itinerary_shares.token and _regenerate then excluded.token else public.itinerary_shares.token end,
        expires_at = excluded.expires_at,
        created_by = auth.uid(),
        created_at = now()
  where public.itinerary_shares.itinerary_id = _itinerary_id
    and (select user_id from public.itineraries where id = _itinerary_id) = auth.uid()
  returning token into v_final;

  return v_final;
end;
$$;


ALTER FUNCTION "public"."create_or_update_itinerary_share"("_itinerary_id" "uuid", "_expires_at" timestamp with time zone, "_regenerate" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."create_ranking_on_visit"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  INSERT INTO user_place_rankings (user_id, place_id, category)
  SELECT 
    NEW.user_id,
    NEW.place_id,
    p.category
  FROM places p
  WHERE p.id = NEW.place_id
    AND p.category IN ('eat', 'stay', 'play')
  ON CONFLICT (user_id, place_id) DO NOTHING;
  
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."create_ranking_on_visit"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."deactivate_expired_specials"() RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  update specials
  set active = false
  where end_date < now() and active = true;
end;
$$;


ALTER FUNCTION "public"."deactivate_expired_specials"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."decline_trip_invite"("_token" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  update public.trip_collaborators
    set status = 'declined',
        invitee_id = coalesce(invitee_id, auth.uid())
    where invite_token = _token
      and (invitee_id is null or invitee_id = auth.uid())
      and status <> 'accepted';
end $$;


ALTER FUNCTION "public"."decline_trip_invite"("_token" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."decrement_event_going"("event_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
  UPDATE events SET going_count = GREATEST(0, going_count - 1) WHERE id = event_id;
END;
$$;


ALTER FUNCTION "public"."decrement_event_going"("event_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."decrement_event_interested"("event_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
  UPDATE events SET interested_count = GREATEST(0, interested_count - 1) WHERE id = event_id;
END;
$$;


ALTER FUNCTION "public"."decrement_event_interested"("event_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."decrement_feedback_upvote"("fid" "uuid") RETURNS "void"
    LANGUAGE "sql"
    AS $$
  update public.feedback
  set upvotes = greatest(coalesce(upvotes, 0) - 1, 0)
  where id = fid;
$$;


ALTER FUNCTION "public"."decrement_feedback_upvote"("fid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_event_sponsor"("p_token" "text", "p_event_sponsor_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_event_id uuid;
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  delete from public.event_sponsors where id = p_event_sponsor_id and event_id = v_event_id;
  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "public"."delete_event_sponsor"("p_token" "text", "p_event_sponsor_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_partner_closure"("p_token" "text", "p_closure_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place places%rowtype;
begin
  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;

  delete from public.place_special_hours
   where id = p_closure_id and place_id = v_place.id;

  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "public"."delete_partner_closure"("p_token" "text", "p_closure_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_schedule_day"("p_token" "text", "p_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_event_id uuid;
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  delete from public.event_schedule_days where id = p_id and event_id = v_event_id;
  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "public"."delete_schedule_day"("p_token" "text", "p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_schedule_item"("p_token" "text", "p_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_event_id uuid;
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  delete from public.event_schedule_items where id = p_id and event_id = v_event_id;
  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "public"."delete_schedule_item"("p_token" "text", "p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_ticket_location"("p_token" "text", "p_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_event_id uuid;
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  delete from public.ticket_locations where id = p_id and event_id = v_event_id;
  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "public"."delete_ticket_location"("p_token" "text", "p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_transport_route"("p_token" "text", "p_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare v_event_id uuid;
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  delete from public.event_transport_routes where id = p_id and event_id = v_event_id;
  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "public"."delete_transport_route"("p_token" "text", "p_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."delete_user_and_data"("p_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public'
    AS $$
begin
  delete from itinerary_places 
  where itinerary_id in (
    select id from itineraries where user_id = p_user_id
  );

  delete from itineraries where user_id = p_user_id;

  delete from "user" where id = p_user_id;
end;
$$;


ALTER FUNCTION "public"."delete_user_and_data"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."ensure_schedule_meta"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  INSERT INTO event_schedule_meta (event_id)
  VALUES (NEW.event_id)
  ON CONFLICT (event_id) DO NOTHING;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."ensure_schedule_meta"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."event_push_cap_usage"("p_event_id" "uuid") RETURNS integer
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select count(*)::integer from public.event_push_notifications
   where event_id = p_event_id
     and sent_at is not null
     and category in ('reminder', 'promo');
$$;


ALTER FUNCTION "public"."event_push_cap_usage"("p_event_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."export_partner_bookings"("p_token" "text", "p_from_date" "date" DEFAULT NULL::"date", "p_to_date" "date" DEFAULT NULL::"date") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place places%rowtype;
begin
  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then
    return jsonb_build_object('error', 'invalid_token');
  end if;

  return jsonb_build_object(
    'place_name',  v_place.name,
    'exported_at', now(),
    'rows', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'booking_id',           b.id,
          'status',               b.status,
          'type',                 b.booking_type,
          'guest_name',           b.guest_name,
          'guest_email',          b.guest_email,
          'guest_phone',          b.guest_phone,
          'check_in',             b.visit_date,
          'check_out',            b.checkout_date,
          'nights',               b.total_nights,
          'adults',               b.adults,
          'children',             b.children,
          'rooms',                b.rooms_requested,
          'room_type',            rt.name,
          'rate_plan',            rp.name,
          'nightly_rate',         b.nightly_rate,
          'quoted_total',         b.total_quoted,
          'final_total',          b.final_total,
          'currency',             b.quoted_currency,
          'taxes',                b.taxes_amount,
          'fees',                 b.fees_amount,
          'deposit_required',     b.deposit_required,
          'deposit_amount',       b.deposit_amount,
          'payment_status',       b.manual_payment_status,
          'payment_reference',    b.payment_reference,
          'supplier_conf_number', b.supplier_confirmation_number,
          'partner_notes',        b.partner_message,
          'cancellation_reason',  b.cancellation_reason,
          'submitted_at',         b.created_at
        ) order by b.created_at desc
      ), '[]'::jsonb)
      from public.bookings b
      left join public.hotel_room_types rt on rt.id = b.room_type_id
      left join public.hotel_rate_plans  rp on rp.id = b.rate_plan_id
      where b.place_id = v_place.id
        and (p_from_date is null or b.visit_date >= p_from_date)
        and (p_to_date   is null or b.visit_date <= p_to_date)
    )
  );
end;
$$;


ALTER FUNCTION "public"."export_partner_bookings"("p_token" "text", "p_from_date" "date", "p_to_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_cleanup_expired_invites"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  delete from public.trip_collaborators
  where trip_id = NEW.trip_id
    and id <> NEW.id
    and status = 'pending'
    and invitee_id is null
    and invite_expires_at is not null
    and invite_expires_at < now();
  return NEW;
end;
$$;


ALTER FUNCTION "public"."fn_cleanup_expired_invites"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_notify_loyalty_stamp"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  perform net.http_post(
    url := 'https://rprpwudhplodaqmmwqkf.supabase.co/functions/v1/notify-loyalty-stamp',
    headers := jsonb_build_object(
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJwcnB3dWRocGxvZGFxbW13cWtmIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MDI4NzI4OSwiZXhwIjoyMDY1ODYzMjg5fQ.25otmTY0x8oeaPW8CjHyv1YQTZDwV5SzzSYGnqH1DvM',
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object('record', row_to_json(NEW))
  );
  return NEW;
end;
$$;


ALTER FUNCTION "public"."fn_notify_loyalty_stamp"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."fn_notify_trip_collaborator"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  -- Only fire on initial insert with status='pending'. Status changes
  -- (accept/decline) are handled in-app, not over push.
  if NEW.status <> 'pending' then
    return NEW;
  end if;

  perform net.http_post(
    url := 'https://rprpwudhplodaqmmwqkf.supabase.co/functions/v1/notify-trip-collaborator',
    headers := jsonb_build_object(
      'Authorization', 'Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJwcnB3dWRocGxvZGFxbW13cWtmIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MDI4NzI4OSwiZXhwIjoyMDY1ODYzMjg5fQ.25otmTY0x8oeaPW8CjHyv1YQTZDwV5SzzSYGnqH1DvM',
      'Content-Type', 'application/json'
    ),
    body := jsonb_build_object('record', row_to_json(NEW))
  );
  return NEW;
end;
$$;


ALTER FUNCTION "public"."fn_notify_trip_collaborator"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."force_apply_change_request"("_request_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  r record;
begin
  if auth.uid() is null then raise exception 'must be signed in'; end if;
  select * into r from public.trip_change_requests where id = _request_id;
  if r.id is null then raise exception 'request not found'; end if;
  if not public.is_trip_owner(r.trip_id) then
    raise exception 'only the trip owner can force-apply';
  end if;
  perform public._apply_change_request(_request_id);
end $$;


ALTER FUNCTION "public"."force_apply_change_request"("_request_id" "uuid") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."places" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "slug" "text" NOT NULL,
    "category" "text",
    "town" "text",
    "country" "text",
    "google_maps_link" "text",
    "latitude" double precision,
    "longitude" double precision,
    "cuisine" "text",
    "price_range" "text",
    "opening_hours" "text",
    "ambiance" "text",
    "description" "text",
    "recommended_dishes" "text",
    "menu_link" "text",
    "rating" real,
    "website" "text",
    "phone_number" "text",
    "is_featured" boolean DEFAULT false,
    "number_of_rooms" "text",
    "amenities" "text",
    "room_type" "text",
    "activities" "text",
    "duration" "text",
    "age_range" "text",
    "parish" "text",
    "address" "text",
    "perfect_for" "text",
    "curator_note" "text",
    "meal_type" "text",
    "image" "text"[],
    "type" "text",
    "kitchen_hours" "text",
    "instagram_url" "text",
    "is_hidden" boolean DEFAULT false,
    "menus" "jsonb" DEFAULT '[]'::"jsonb",
    "completed" boolean DEFAULT false,
    "booking_link" "text",
    "parent_place_id" "uuid",
    "place_role" "text",
    "brand_name" "text",
    "booking_contact_email" "text",
    "hospitality_group" "text",
    "day_pass_available" boolean DEFAULT false NOT NULL,
    "day_pass_price" "text",
    "day_pass_includes" "text",
    "day_pass_hours" "text",
    "day_pass_link" "text",
    "day_pass_notes" "text",
    "day_pass_child_price" "text",
    "day_pass_child_age" "text",
    "bookings_email" "text",
    "partner_access_token" "text" DEFAULT "encode"("extensions"."gen_random_bytes"(16), 'hex'::"text"),
    "partner_id" "uuid",
    "opening_hours_struct" "jsonb",
    "kitchen_hours_struct" "jsonb",
    "accepts_stay_bookings" boolean DEFAULT false NOT NULL,
    "booking_mode" "text" DEFAULT 'request_only'::"text" NOT NULL,
    "booking_contact_name" "text",
    "check_in_time" "text",
    "check_out_time" "text",
    "min_nights" integer DEFAULT 1 NOT NULL,
    "max_guests" integer,
    "cancellation_policy_text" "text",
    "deposit_instructions" "text",
    "deposit_required" boolean DEFAULT false NOT NULL,
    "deposit_default_amount" numeric(12,2),
    "deposit_currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "commission_terms" "text",
    "taxes_fees_notes" "text",
    "hold_expiry_minutes" integer DEFAULT 10 NOT NULL,
    "internal_booking_notes" "text",
    "stay_booking_mode" "text" DEFAULT 'request_only'::"text" NOT NULL,
    "stay_availability_source" "text",
    "stay_availability_url" "text",
    "stay_room_types" "text"[],
    "stay_min_nights" integer,
    "stay_max_guests" integer,
    "stay_commission_terms" "text",
    "insider_enabled" boolean DEFAULT false NOT NULL,
    "brand_color" "text",
    CONSTRAINT "places_stay_booking_mode_check" CHECK (("stay_booking_mode" = ANY (ARRAY['request_only'::"text", 'manual_availability'::"text", 'calendar_feed'::"text", 'booking_engine'::"text"]))),
    CONSTRAINT "places_stay_max_guests_check" CHECK ((("stay_max_guests" IS NULL) OR ("stay_max_guests" >= 1))),
    CONSTRAINT "places_stay_min_nights_check" CHECK ((("stay_min_nights" IS NULL) OR ("stay_min_nights" >= 1)))
);


ALTER TABLE "public"."places" OWNER TO "postgres";


COMMENT ON TABLE "public"."places" IS 'Stores detailed information about curated locations in Jamaica across three categories: Eat, Stay, and Play. Each record represents a destination such as a restaurant, boutique hotel, or activity venue, including metadata like coordinates, cuisine, pricing, and links for deeper discovery. Designed to power the TRODDR travel discovery experience.';



COMMENT ON COLUMN "public"."places"."booking_mode" IS 'request_only | manual_availability | instant_manual_inventory';



COMMENT ON COLUMN "public"."places"."stay_booking_mode" IS 'How a stay/place accepts bookings. Expected by mobile listing fetches.';



COMMENT ON COLUMN "public"."places"."stay_availability_source" IS 'Human-readable source label such as Cloudbeds, Beds24, hotel dashboard, iCal, or manual.';



COMMENT ON COLUMN "public"."places"."stay_availability_url" IS 'Optional private availability feed/API URL or booking-engine endpoint used by ops/integration code.';



COMMENT ON COLUMN "public"."places"."stay_room_types" IS 'Optional hotel-provided room labels to present as preferences in the booking request.';



COMMENT ON COLUMN "public"."places"."stay_commission_terms" IS 'Property-specific commission terms for TRODDR-attributed stay requests.';



COMMENT ON COLUMN "public"."places"."brand_color" IS 'Hex brand colour (e.g. ''#5A2A37'') used to theme the Insider Pass. Null = refined default. The pass darkens this for the gradient and auto-picks cream/charcoal text for contrast.';



CREATE OR REPLACE FUNCTION "public"."fuzzy_search_places"("q" "text") RETURNS SETOF "public"."places"
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select *
  from places
  where
    similarity(name, q) > 0.2
    or similarity(town, q) > 0.2
    or similarity(parish, q) > 0.2
    or similarity(category, q) > 0.2
    or similarity(cuisine, q) > 0.2
    or similarity(recommended_dishes, q) > 0.2
    or recommended_dishes ilike '%' || q || '%'
  order by
    greatest(
      similarity(name, q),
      similarity(town, q),
      similarity(parish, q),
      similarity(recommended_dishes, q),
      similarity(cuisine, q)
    ) desc
  limit 50;
$$;


ALTER FUNCTION "public"."fuzzy_search_places"("q" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."generate_unique_event_slug"("p_title" "text") RETURNS "text"
    LANGUAGE "plpgsql"
    AS $$
declare
  v_base text;
  v_slug text;
  v_n    int := 0;
begin
  v_base := lower(coalesce(trim(p_title), ''));
  v_base := regexp_replace(v_base, '[^a-z0-9\s-]', '', 'g');
  v_base := regexp_replace(v_base, '\s+', '-', 'g');
  v_base := regexp_replace(v_base, '-+', '-', 'g');
  v_base := trim(both '-' from v_base);
  v_base := substring(v_base, 1, 80);
  if v_base = '' then v_base := 'event'; end if;

  v_slug := v_base;
  while exists(select 1 from public.events where slug = v_slug) loop
    v_n := v_n + 1;
    v_slug := v_base || '-' || v_n;
  end loop;
  return v_slug;
end;
$$;


ALTER FUNCTION "public"."generate_unique_event_slug"("p_title" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_admin_review_queue"("p_admin_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if not public._is_admin(p_admin_token) then
    return null;
  end if;

  return jsonb_build_object(

    'counts', jsonb_build_object(
      'pending_submissions',
        (select count(*) from public.event_partner_submissions
          where status in ('submitted','reviewing')),
      'pending_specials',
        (select count(*) from public.specials
          where submission_status = 'pending'),
      'new_messages',
        (select count(*) from public.partner_messages
          where status = 'new'),
      'recent_event_updates_7d',
        (select count(*) from public.event_updates
          where created_at >= now() - interval '7 days')
    ),

    'pending_submissions', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',                s.id,
        'event_name',        s.event_name,
        'event_type',        s.event_type,
        'organizer_name',    s.organizer_name,
        'contact_email',     s.contact_email,
        'contact_phone',     s.contact_phone,
        'event_start_date',  s.event_start_date,
        'event_end_date',    s.event_end_date,
        'venue_name',        s.venue_name,
        'venue_address',     s.venue_address,
        'event_description', s.event_description,
        'website',           s.website,
        'instagram',         s.instagram,
        'hero_url',          s.hero_url,
        'logo_url',          s.logo_url,
        'gallery_urls',      s.gallery_urls,
        'tickets_url',       s.tickets_url,
        'status',            s.status,
        'event_id',          s.event_id,
        'created_at',        s.created_at,
        'updated_at',        s.updated_at
      ) order by s.created_at desc), '[]'::jsonb)
      from public.event_partner_submissions s
      where s.status in ('submitted','reviewing','draft')
    ),

    'pending_specials', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',                  sp.id,
        'title',               sp.title,
        'description',         sp.description,
        'special_type',        sp.special_type,
        'start_date',          sp.start_date,
        'end_date',            sp.end_date,
        'start_time',          sp.start_time,
        'end_time',            sp.end_time,
        'image_url',           (case when sp.image_urls is not null and array_length(sp.image_urls, 1) > 0
                                     then sp.image_urls[1] else null end),
        'discount_percentage', sp.discount_percentage,
        'discount_amount',     sp.discount_amount,
        'price_amount',        sp.price_amount,
        'currency',            sp.currency,
        'event_category',      sp.event_category,
        'event_tags',          sp.event_tags,
        'submitted_at',        sp.submitted_at,
        'submitted_via',       sp.submitted_via,
        'submission_status',   sp.submission_status,
        'review_note',         sp.review_note,
        'place', (
          select jsonb_build_object(
            'id',   p.id,
            'name', p.name,
            'slug', p.slug,
            'town', p.town,
            'parish', p.parish,
            'partner_email', p.bookings_email
          )
          from public.places p
          where p.id = sp.place_id
        )
      ) order by sp.submitted_at desc nulls last, sp.created_at desc), '[]'::jsonb)
      from public.specials sp
      where sp.submission_status in ('pending', 'draft')
    ),

    'new_messages', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',          m.id,
        'subject',     m.subject,
        'message',     m.message,
        'status',      m.status,
        'source_page', m.source_page,
        'created_at',  m.created_at,
        'partner', (
          select jsonb_build_object('id', p.id, 'name', p.name)
          from public.partners p where p.id = m.partner_id
        ),
        'place', (
          select jsonb_build_object('id', pl.id, 'name', pl.name, 'slug', pl.slug)
          from public.places pl where pl.id = m.place_id
        ),
        'event', (
          select jsonb_build_object('id', ev.id, 'title', ev.title, 'slug', ev.slug)
          from public.events ev where ev.id = m.event_id
        )
      ) order by
          case m.status when 'new' then 0 when 'in_progress' then 1 else 2 end,
          m.created_at desc), '[]'::jsonb)
      from public.partner_messages m
      where m.status in ('new', 'in_progress')
      limit 50
    ),

    'recent_event_updates', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',          u.id,
        'title',       u.title,
        'message',     u.message,
        'created_at',  u.created_at,
        'event', (
          select jsonb_build_object('id', e.id, 'title', e.title, 'slug', e.slug)
          from public.events e where e.id = u.event_id
        )
      ) order by u.created_at desc), '[]'::jsonb)
      from public.event_updates u
      where u.created_at >= now() - interval '30 days'
      limit 50
    )

  );
end;
$$;


ALTER FUNCTION "public"."get_admin_review_queue"("p_admin_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_billing_catalog_for_quote"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."get_billing_catalog_for_quote"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_booking_by_token"("p_token" "text") RETURNS TABLE("id" "uuid", "token" "text", "booking_type" "text", "place_id" "uuid", "place_name" "text", "place_slug" "text", "place_address" "text", "place_image" "text", "place_town" "text", "place_parish" "text", "bookings_email" "text", "day_pass_price" "text", "day_pass_child_price" "text", "day_pass_includes" "text", "day_pass_hours" "text", "day_pass_notes" "text", "stay_booking_mode" "text", "stay_availability_source" "text", "stay_room_types" "text"[], "stay_min_nights" integer, "stay_max_guests" integer, "stay_commission_terms" "text", "visit_date" "date", "visit_time" "text", "checkout_date" "date", "party_size" integer, "guest_name" "text", "guest_phone" "text", "guest_email" "text", "notes" "text", "agency_name" "text", "iata_tids_number" "text", "commission_terms" "text", "commission_status" "text", "commission_amount_expected" numeric, "commission_payment_reference" "text", "supplier_confirmation_number" "text", "booking_request_payload" "jsonb", "status" "text", "partner_message" "text", "proposed_visit_date" "date", "proposed_visit_time" "text", "responded_at" timestamp with time zone, "total_quoted" numeric, "created_at" timestamp with time zone)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    b.id, b.token, b.booking_type, b.place_id,
    p.name, p.slug, p.address, p.image, p.town, p.parish,
    p.bookings_email,
    p.day_pass_price, p.day_pass_child_price, p.day_pass_includes,
    p.day_pass_hours, p.day_pass_notes,
    p.stay_booking_mode, p.stay_availability_source, p.stay_room_types,
    p.stay_min_nights, p.stay_max_guests, p.stay_commission_terms,
    b.visit_date, b.visit_time, b.checkout_date, b.party_size,
    b.guest_name, b.guest_phone, b.guest_email, b.notes,
    b.agency_name, b.iata_tids_number, b.commission_terms,
    b.commission_status, b.commission_amount_expected,
    b.commission_payment_reference, b.supplier_confirmation_number,
    b.booking_request_payload,
    b.status, b.partner_message,
    b.proposed_visit_date, b.proposed_visit_time, b.responded_at,
    b.total_quoted,
    b.created_at
  from public.bookings b
  join public.places p on p.id = b.place_id
  where b.token = p_token
  limit 1;
$$;


ALTER FUNCTION "public"."get_booking_by_token"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_booking_detail_by_token"("p_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_booking bookings%rowtype;
  v_place   places%rowtype;
begin
  select * into v_booking from public.bookings where token = p_token;
  if v_booking.id is null then
    return jsonb_build_object('error', 'not_found');
  end if;
  select * into v_place from public.places where id = v_booking.place_id;

  return jsonb_build_object(
    'booking', row_to_json(v_booking.*),
    'place', jsonb_build_object(
      'id',                      v_place.id,
      'name',                    v_place.name,
      'address',                 v_place.address,
      'town',                    v_place.town,
      'parish',                  v_place.parish,
      'image',                   v_place.image,
      'check_in_time',           v_place.check_in_time,
      'check_out_time',          v_place.check_out_time,
      'cancellation_policy_text',v_place.cancellation_policy_text,
      'deposit_instructions',    v_place.deposit_instructions,
      'taxes_fees_notes',        v_place.taxes_fees_notes,
      'partner_access_token',    v_place.partner_access_token
    ),
    'room_type', (
      select row_to_json(rt.*)
      from public.hotel_room_types rt where rt.id = v_booking.room_type_id
    ),
    'rate_plan', (
      select row_to_json(rp.*)
      from public.hotel_rate_plans rp where rp.id = v_booking.rate_plan_id
    ),
    'timeline', (
      select coalesce(
        jsonb_agg(row_to_json(te.*) order by te.created_at asc),
        '[]'::jsonb
      )
      from public.booking_timeline_events te where te.booking_id = v_booking.id
    ),
    'cancellation_policy', (
      select row_to_json(cp.*)
      from public.booking_cancellation_policies cp
      where cp.place_id = v_place.id
        and (cp.rate_plan_id = v_booking.rate_plan_id or cp.rate_plan_id is null)
      order by cp.rate_plan_id desc nulls last, cp.is_default desc
      limit 1
    )
  );
end;
$$;


ALTER FUNCTION "public"."get_booking_detail_by_token"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_booking_guest_profile"("p_token" "text") RETURNS TABLE("shared" boolean, "user_id" "uuid", "snapshot" "jsonb")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    coalesce(b.share_profile, false) as shared,
    case when b.share_profile then b.user_id end as user_id,
    case when b.share_profile then b.guest_profile_snapshot end as snapshot
  from public.bookings b
  where b.token = p_token
  limit 1;
$$;


ALTER FUNCTION "public"."get_booking_guest_profile"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_bookings_by_partner_token"("p_token" "text") RETURNS TABLE("id" "uuid", "booking_type" "text", "status" "text", "visit_date" "date", "visit_time" "text", "checkout_date" "date", "party_size" integer, "guest_name" "text", "guest_email" "text", "guest_phone" "text", "notes" "text", "occasion" "text", "agency_name" "text", "iata_tids_number" "text", "commission_terms" "text", "commission_status" "text", "supplier_confirmation_number" "text", "booking_request_payload" "jsonb", "partner_message" "text", "proposed_visit_date" "date", "proposed_visit_time" "text", "total_quoted" numeric, "created_at" timestamp with time zone, "booking_token" "text")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    b.id,
    b.booking_type,
    b.status,
    b.visit_date,
    b.visit_time,
    b.checkout_date,
    b.party_size,
    b.guest_name,
    b.guest_email,
    b.guest_phone,
    b.notes,
    b.occasion,
    b.agency_name,
    b.iata_tids_number,
    b.commission_terms,
    b.commission_status,
    b.supplier_confirmation_number,
    b.booking_request_payload,
    b.partner_message,
    b.proposed_visit_date,
    b.proposed_visit_time,
    b.total_quoted,
    b.created_at,
    b.token
  from public.bookings b
  join public.places p on p.id = b.place_id
  where p.partner_access_token = p_token
  order by
    case b.status
      when 'pending'           then 1
      when 'counter_proposed'  then 2
      when 'confirmed'         then 3
      when 'counter_accepted'  then 4
      when 'declined'          then 5
      when 'counter_rejected'  then 6
      when 'cancelled'         then 7
      when 'expired'           then 8
      else 9
    end,
    b.visit_date asc nulls last,
    b.created_at desc;
$$;


ALTER FUNCTION "public"."get_bookings_by_partner_token"("p_token" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."place_checkin_settings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "place_id" "uuid" NOT NULL,
    "checkin_enabled" boolean DEFAULT false NOT NULL,
    "nfc_enabled" boolean DEFAULT false NOT NULL,
    "qr_enabled" boolean DEFAULT false NOT NULL,
    "manual_code_enabled" boolean DEFAULT false NOT NULL,
    "in_app_checkin_enabled" boolean DEFAULT false NOT NULL,
    "requires_proximity" boolean DEFAULT true NOT NULL,
    "xp_enabled" boolean DEFAULT true NOT NULL,
    "loyalty_enabled" boolean DEFAULT false NOT NULL,
    "cooldown_minutes" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "place_checkin_settings_cooldown_nonneg" CHECK ((("cooldown_minutes" IS NULL) OR ("cooldown_minutes" >= 0)))
);


ALTER TABLE "public"."place_checkin_settings" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_checkin_settings_by_partner_token"("p_token" "text") RETURNS "public"."place_checkin_settings"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select s.*
  from public.place_checkin_settings s
  join public.places p on p.id = s.place_id
  where p.partner_access_token = p_token
  limit 1;
$$;


ALTER FUNCTION "public"."get_checkin_settings_by_partner_token"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_company_billing"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."get_company_billing"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_event_billing_by_token"("p_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_event_id uuid;
begin
  select id into v_event_id from public.events where partner_access_token = p_token;
  if v_event_id is null then return null; end if;
  return public._event_billing(v_event_id);
end;
$$;


ALTER FUNCTION "public"."get_event_billing_by_token"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_event_floor_plan_public"("p_slug" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_evt public.events%rowtype;
begin
  select * into v_evt from public.events where slug = p_slug;
  if v_evt.id is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;

  return jsonb_build_object(
    'ok', true,
    'event', jsonb_build_object(
      'id',                 v_evt.id,
      'slug',               v_evt.slug,
      'title',              v_evt.title,
      'floor_plan_url',     v_evt.floor_plan_url,
      'floor_plan_markers', coalesce(v_evt.floor_plan_markers, '[]'::jsonb)
    ),
    'vendors', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'event_vendor_id', ev.id,
        'vendor_id',       v.id,
        'vendor_name',     coalesce(nullif(btrim(ev.display_name), ''), v.name)
      ) order by coalesce(nullif(btrim(ev.display_name), ''), v.name)), '[]'::jsonb)
      from public.event_vendors ev
      join public.vendors v on v.id = ev.vendor_id
      where ev.event_id = v_evt.id
    )
  );
end;
$$;


ALTER FUNCTION "public"."get_event_floor_plan_public"("p_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_event_sponsors_by_slug"("p_event_slug" "text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',                 s.id,
        'sponsor_id',         s.id,
        'event_sponsor_id',   es.id,
        'name',               s.name,
        'slug',               s.slug,
        'logo_url',           s.logo_url,
        'logo_variant',       s.logo_variant,
        'website',            s.website,
        'description',        coalesce(es.custom_tagline, s.description),
        'instagram',          s.instagram,
        'brand_color',        s.brand_color,
        'tier',               es.tier,
        'tier_label',         es.display_tier_label,
        'display_tier_label', es.display_tier_label,
        'is_featured',        es.is_featured
      )
      order by es.display_order nulls last, es.tier, s.name
    ),
    '[]'::jsonb
  )
  from public.events e
  join public.event_sponsors es on es.event_id = e.id
  join public.sponsors s on s.id = es.sponsor_id
  where e.slug = p_event_slug
    and coalesce(es.is_active, true) = true
    and coalesce(s.is_active, true) = true;
$$;


ALTER FUNCTION "public"."get_event_sponsors_by_slug"("p_event_slug" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."insider_status_settings" (
    "place_id" "uuid" NOT NULL,
    "guest_min" integer DEFAULT 1 NOT NULL,
    "familiar_face_min" integer DEFAULT 3 NOT NULL,
    "regular_min" integer DEFAULT 7 NOT NULL,
    "house_favourite_min" integer DEFAULT 15 NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "insider_status_settings_familiar_face_min_check" CHECK (("familiar_face_min" >= 0)),
    CONSTRAINT "insider_status_settings_guest_min_check" CHECK (("guest_min" >= 0)),
    CONSTRAINT "insider_status_settings_house_favourite_min_check" CHECK (("house_favourite_min" >= 0)),
    CONSTRAINT "insider_status_settings_regular_min_check" CHECK (("regular_min" >= 0))
);


ALTER TABLE "public"."insider_status_settings" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_insider_settings_by_partner_token"("p_token" "text") RETURNS "public"."insider_status_settings"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select s.*
  from public.places p
  left join public.insider_status_settings s on s.place_id = p.id
  where p.partner_access_token = p_token
  limit 1;
$$;


ALTER FUNCTION "public"."get_insider_settings_by_partner_token"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_itinerary_by_share_token"("_token" "text") RETURNS TABLE("id" "uuid", "title" "text", "user_id" "uuid", "destination" "text", "start_date" "date", "end_date" "date", "shared_by" "text")
    LANGUAGE "sql" STABLE
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
  select 
    i.id,
    i.title,
    i.user_id,
    i.destination,
    i.start_date,
    i.end_date,
    au.email as shared_by
  from itinerary_shares s
  join itineraries i on i.id = s.itinerary_id
  join auth.users au on au.id = s.created_by
  where s.token = _token
    and (s.expires_at is null or s.expires_at > now())
  limit 1;
$$;


ALTER FUNCTION "public"."get_itinerary_by_share_token"("_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_loyalty_analytics_by_token"("p_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place_id  uuid;
  v_program   loyalty_programs%rowtype;
  v_now       timestamptz := now();
begin
  -- Resolve token → place via the existing partner token column
  select id
    into v_place_id
    from public.places
   where partner_access_token = p_token;

  if v_place_id is null then
    return null;
  end if;

  -- Active loyalty program for this place
  select *
    into v_program
    from public.loyalty_programs
   where place_id = v_place_id
     and is_active = true
   order by created_at desc
   limit 1;

  if v_program.id is null then
    -- Place exists but has no active program yet
    return jsonb_build_object(
      'place', (select jsonb_build_object('id', id, 'name', name)
                  from public.places where id = v_place_id),
      'program', null,
      'stats',   null,
      'members', '[]'::jsonb
    );
  end if;

  return jsonb_build_object(
    'place', (
      select jsonb_build_object('id', id, 'name', name)
        from public.places where id = v_place_id
    ),
    'program', jsonb_build_object(
      'id',               v_program.id,
      'required_stamps',  v_program.required_stamps,
      'reward',           v_program.reward,
      'spend_per_stamp',  v_program.spend_per_stamp,
      'earning_type',     v_program.earning_type,
      'stamp_icon',       v_program.stamp_icon,
      'stamp_logo_url',   v_program.stamp_logo_url,
      'card_theme',       v_program.card_theme,
      'silver_after_redemptions',   v_program.silver_after_redemptions,
      'gold_after_redemptions',     v_program.gold_after_redemptions,
      'platinum_after_redemptions', v_program.platinum_after_redemptions,
      'card_design_notes',          v_program.card_design_notes,
      'primary_color',    v_program.primary_color,
      'accent_color',     v_program.accent_color,
      'text_color',       v_program.text_color,
      'secondary_color',  v_program.secondary_color,
      'watermark_icon',   v_program.watermark_icon,
      'fine_print',       v_program.fine_print
    ),
    'stats', (
      with cards as (
        select * from public.user_loyalty_cards where program_id = v_program.id
      ),
      visits as (
        select * from public.loyalty_visits where place_id = v_place_id
      ),
      per_member as (
        select user_id, count(*) as n
          from visits
         group by user_id
      )
      select jsonb_build_object(
        'total_members',
          (select count(*) from cards),

        'active_30d',
          (select count(distinct user_id)
             from visits
            where stamped_at >= v_now - interval '30 days'),

        'new_30d',
          (select count(*) from cards
            where created_at >= v_now - interval '30 days'),

        'total_visits',
          (select count(*) from visits),

        'rewards_earned',
          (select coalesce(sum(completed_cycles), 0) from cards),

        'close_to_reward',
          (select count(*) from cards
            where is_redeemed = false
              and current_stamps >= greatest(v_program.required_stamps - 2, 1)
              and current_stamps <  v_program.required_stamps),

        'dormant_60d',
          (select count(*) from cards
            where last_stamped_at is not null
              and last_stamped_at < v_now - interval '60 days'),

        'repeat_visit_rate',
          (select case
                    when count(*) = 0 then null
                    else count(*) filter (where n >= 2)::float / count(*)
                  end
             from per_member),

        'days_since_last_visit',
          (select case
                    when max(stamped_at) is null then null
                    else floor(extract(epoch from (v_now - max(stamped_at))) / 86400)::int
                  end
             from visits)
      )
    ),
    'members', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'card_id',           c.id,
            'user_id',           c.user_id,
            'current_stamps',    c.current_stamps,
            'completed_cycles',  c.completed_cycles,
            'is_redeemed',       c.is_redeemed,
            'last_stamped_at',   c.last_stamped_at,
            'created_at',        c.created_at
          )
          order by
            c.completed_cycles desc,
            c.current_stamps   desc,
            c.last_stamped_at  desc nulls last
        ),
        '[]'::jsonb
      )
      from public.user_loyalty_cards c
      where c.program_id = v_program.id
    ),
    'redemptions', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id',            r.id,
            'card_id',       r.card_id,
            'user_id',       r.user_id,
            'reward',        r.reward,
            'stamps_spent',  r.stamps_spent,
            'cycle_number',  r.cycle_number,
            'source',        r.source,
            'redeemed_by',   r.redeemed_by,
            'notes',         r.notes,
            'redeemed_at',   r.redeemed_at
          )
          order by r.redeemed_at desc
        ),
        '[]'::jsonb
      )
      from (
        select *
          from public.loyalty_redemptions
         where program_id = v_program.id
         order by redeemed_at desc
         limit 100
      ) r
    )
  );
end;
$$;


ALTER FUNCTION "public"."get_loyalty_analytics_by_token"("p_token" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."loyalty_programs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "place_id" "uuid" NOT NULL,
    "required_stamps" integer DEFAULT 8 NOT NULL,
    "reward" "text" NOT NULL,
    "accent_color" "text" DEFAULT '#D4603A'::"text" NOT NULL,
    "has_multiple_locations" boolean DEFAULT false NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "fine_print" "text",
    "primary_color" "text",
    "text_color" "text",
    "secondary_color" "text",
    "card_texture" "text",
    "watermark_icon" "text",
    "earning_type" "text" DEFAULT 'visit'::"text",
    "spend_per_stamp" numeric,
    "max_stamps_per_checkin" integer DEFAULT 1,
    "stamp_icon" "text",
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "stamp_logo_url" "text",
    "card_theme" "text" DEFAULT 'classic'::"text" NOT NULL,
    "silver_after_redemptions" integer DEFAULT 2 NOT NULL,
    "gold_after_redemptions" integer DEFAULT 5 NOT NULL,
    "platinum_after_redemptions" integer DEFAULT 10 NOT NULL,
    "card_design_notes" "text",
    "link_locations" boolean DEFAULT false NOT NULL,
    CONSTRAINT "loyalty_programs_earning_type_check" CHECK (("earning_type" = ANY (ARRAY['visit'::"text", 'spend'::"text", 'hybrid'::"text"])))
);


ALTER TABLE "public"."loyalty_programs" OWNER TO "postgres";


COMMENT ON COLUMN "public"."loyalty_programs"."stamp_icon" IS 'MaterialCommunityIcons glyph name (e.g. ''coffee'', ''bed'', ''pizza''). When null, LoyaltyCard.tsx falls back to its regex-based resolver keyed on the business name.';



COMMENT ON COLUMN "public"."loyalty_programs"."link_locations" IS 'When true, this program is shared across every place listed in loyalty_program_locations and stamps pool onto one card. When false (default) the program is single-location and behaves as before.';



CREATE OR REPLACE FUNCTION "public"."get_loyalty_program_for_place"("p_place_id" "uuid") RETURNS SETOF "public"."loyalty_programs"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select lp.*
    from public.loyalty_programs lp
   where lp.is_active = true
     and (
       lp.place_id = p_place_id
       or exists (
         select 1
           from public.loyalty_program_locations m
          where m.program_id = lp.id
            and m.place_id = p_place_id
       )
     )
   order by (lp.place_id = p_place_id) desc
   limit 1;
$$;


ALTER FUNCTION "public"."get_loyalty_program_for_place"("p_place_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_loyalty_redemption_report_by_token"("p_token" "text", "p_report_date" "date" DEFAULT CURRENT_DATE) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place_id uuid;
  v_program loyalty_programs%rowtype;
  v_start timestamptz;
  v_end timestamptz;
begin
  select id
    into v_place_id
    from public.places
   where partner_access_token = p_token;

  if v_place_id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid partner token');
  end if;

  select *
    into v_program
    from public.loyalty_programs
   where place_id = v_place_id
     and is_active = true
   order by created_at desc
   limit 1;

  if v_program.id is null then
    return jsonb_build_object('ok', false, 'error', 'No active loyalty program found');
  end if;

  v_start := coalesce(p_report_date, current_date)::timestamptz;
  v_end := v_start + interval '1 day';

  return jsonb_build_object(
    'ok', true,
    'generated_at', now(),
    'report_date', coalesce(p_report_date, current_date),
    'place', (
      select jsonb_build_object('id', id, 'name', name)
        from public.places
       where id = v_place_id
    ),
    'program', jsonb_build_object(
      'id',              v_program.id,
      'required_stamps', v_program.required_stamps,
      'reward',          v_program.reward,
      'spend_per_stamp', v_program.spend_per_stamp
    ),
    'redemptions', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id',           r.id,
            'card_id',      r.card_id,
            'user_id',      r.user_id,
            'reward',       r.reward,
            'stamps_spent', r.stamps_spent,
            'cycle_number', r.cycle_number,
            'source',       r.source,
            'redeemed_by',  r.redeemed_by,
            'notes',        r.notes,
            'redeemed_at',  r.redeemed_at
          )
          order by r.redeemed_at asc
        ),
        '[]'::jsonb
      )
      from public.loyalty_redemptions r
      where r.program_id = v_program.id
        and r.redeemed_at >= v_start
        and r.redeemed_at < v_end
    ),
    'open_cards', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'card_id',          c.id,
            'user_id',          c.user_id,
            'current_stamps',   c.current_stamps,
            'completed_cycles', c.completed_cycles,
            'is_redeemed',      c.is_redeemed,
            'last_stamped_at',  c.last_stamped_at,
            'created_at',       c.created_at
          )
          order by c.current_stamps desc, c.last_stamped_at desc nulls last, c.created_at asc
        ),
        '[]'::jsonb
      )
      from public.user_loyalty_cards c
      where c.program_id = v_program.id
        and coalesce(c.current_stamps, 0) > 0
        and coalesce(c.is_redeemed, false) = false
    )
  );
end;
$$;


ALTER FUNCTION "public"."get_loyalty_redemption_report_by_token"("p_token" "text", "p_report_date" "date") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_entitlements"() RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."get_my_entitlements"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_my_visit_history"() RETURNS TABLE("place_id" "uuid", "place_name" "text", "place_slug" "text", "place_image" "text", "parish" "text", "category" "text", "insider_enabled" boolean, "visit_count" bigint, "first_visit" timestamp with time zone, "last_visit" timestamp with time zone, "guest_min" integer, "familiar_face_min" integer, "regular_min" integer, "house_favourite_min" integer)
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    p.id,
    p.name,
    p.slug,
    p.image,
    p.parish,
    p.category,
    p.insider_enabled,
    count(uc.id)::bigint as visit_count,
    min(uc.created_at)   as first_visit,
    max(uc.created_at)   as last_visit,
    coalesce(s.guest_min, 1)            as guest_min,
    coalesce(s.familiar_face_min, 3)    as familiar_face_min,
    coalesce(s.regular_min, 7)          as regular_min,
    coalesce(s.house_favourite_min, 15) as house_favourite_min
  from public.user_checkins uc
  join public.places p
    on p.id = uc.place_id
  left join public.insider_status_settings s
    on s.place_id = p.id
  where uc.user_id = auth.uid()
    and uc.source  = 'nfc'
    and uc.place_id is not null
  group by p.id, p.name, p.slug, p.image, p.parish, p.category, p.insider_enabled,
           s.guest_min, s.familiar_face_min, s.regular_min, s.house_favourite_min
  order by max(uc.created_at) desc;
$$;


ALTER FUNCTION "public"."get_my_visit_history"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_onboarding_invite"("p_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."get_onboarding_invite"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_partner_billing_by_token"("p_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."get_partner_billing_by_token"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_partner_bookings_v2"("p_token" "text", "p_status" "text" DEFAULT NULL::"text", "p_type" "text" DEFAULT NULL::"text", "p_from_date" "date" DEFAULT NULL::"date", "p_to_date" "date" DEFAULT NULL::"date", "p_guest_name" "text" DEFAULT NULL::"text", "p_limit" integer DEFAULT 200, "p_offset" integer DEFAULT 0) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place places%rowtype;
begin
  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then
    return jsonb_build_object('error', 'invalid_token');
  end if;

  return jsonb_build_object(
    'place_id',     v_place.id,
    'place_name',   v_place.name,
    'booking_mode', coalesce(v_place.booking_mode, 'request_only'),
    'stats', jsonb_build_object(
      'total',           (select count(*) from public.bookings where place_id = v_place.id),
      'pending',         (select count(*) from public.bookings where place_id = v_place.id and status = 'pending'),
      'held',            (select count(*) from public.bookings where place_id = v_place.id and status = 'held'),
      'confirmed',       (select count(*) from public.bookings where place_id = v_place.id
                          and status in ('confirmed','counter_accepted','checked_in','checked_out')),
      'needs_attention', (select count(*) from public.bookings where place_id = v_place.id
                          and needs_troddr_attention = true),
      'this_month',      (select count(*) from public.bookings where place_id = v_place.id
                          and created_at >= date_trunc('month', now()))
    ),
    'bookings', (
      select coalesce(jsonb_agg(row_to_json(bv.*)), '[]'::jsonb)
      from (
        select
          b.id, b.token, b.status, b.booking_type,
          b.visit_date, b.checkout_date, b.visit_time,
          b.party_size, b.adults, b.children, b.rooms_requested,
          b.guest_name, b.guest_email, b.guest_phone,
          b.notes, b.room_preference,
          b.total_quoted, b.final_total, b.quoted_currency,
          b.nightly_rate, b.total_nights,
          b.taxes_amount, b.fees_amount,
          b.deposit_required, b.deposit_amount, b.deposit_currency,
          b.deposit_due_at, b.manual_payment_status, b.payment_reference,
          b.payment_instructions,
          b.supplier_confirmation_number,
          b.partner_message, b.partner_internal_notes,
          b.counter_date, b.counter_time,
          b.cancelled_by, b.cancellation_reason,
          b.needs_troddr_attention, b.attention_reason,
          b.expires_at, b.created_at, b.updated_at,
          rt.name  as room_type_name,
          rp.name  as rate_plan_name,
          (select count(*)::int from public.booking_timeline_events te
            where te.booking_id = b.id) as timeline_count
        from public.bookings b
        left join public.hotel_room_types rt on rt.id = b.room_type_id
        left join public.hotel_rate_plans  rp on rp.id = b.rate_plan_id
        where b.place_id = v_place.id
          and (p_status    is null or b.status       = p_status)
          and (p_type      is null or b.booking_type = p_type)
          and (p_from_date is null or b.visit_date  >= p_from_date)
          and (p_to_date   is null or b.visit_date  <= p_to_date)
          and (p_guest_name is null
               or lower(b.guest_name) like lower('%' || p_guest_name || '%'))
        order by
          case when b.status = 'pending' then 0
               when b.status = 'held'    then 1
               else 2 end,
          b.created_at desc
        limit p_limit offset p_offset
      ) bv
    )
  );
end;
$$;


ALTER FUNCTION "public"."get_partner_bookings_v2"("p_token" "text", "p_status" "text", "p_type" "text", "p_from_date" "date", "p_to_date" "date", "p_guest_name" "text", "p_limit" integer, "p_offset" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_partner_by_token"("p_token" "text") RETURNS TABLE("place_id" "uuid", "place_name" "text", "place_slug" "text", "place_town" "text", "place_parish" "text", "place_image" "text", "bookings_email" "text")
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    p.id,
    p.name,
    p.slug,
    p.town,
    p.parish,
    p.image,
    p.bookings_email
  from public.places p
  where p.partner_access_token = p_token
  limit 1;
$$;


ALTER FUNCTION "public"."get_partner_by_token"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_partner_capabilities_by_token"("p_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place        places%rowtype;
  v_event        events%rowtype;
  v_has_loyalty  boolean;
  v_has_vendors  boolean;
  v_partner_id   uuid;
  v_partner_name text;
  v_partner_jsonb jsonb;
  v_current_id   uuid;
  v_group_key    text;
  v_root_place_id uuid;
begin
  ------------------------------------------------------------
  -- 1. Resolve token to entity (place first, then event)
  ------------------------------------------------------------
  select * into v_place
    from public.places
   where partner_access_token = p_token;

  if v_place.id is null then
    select * into v_event
      from public.events
     where partner_access_token = p_token;
  end if;

  if v_place.id is null and v_event.id is null then
    return null;
  end if;

  v_partner_id := coalesce(v_place.partner_id, v_event.partner_id);
  v_current_id := coalesce(v_place.id, v_event.id);
  v_group_key := nullif(trim(coalesce(v_place.hospitality_group, '')), '');
  v_root_place_id := coalesce(v_place.parent_place_id, v_place.id);

  ------------------------------------------------------------
  -- 2. Build the partner block (sibling entity picker)
  ------------------------------------------------------------
  if v_partner_id is not null or v_group_key is not null or v_place.parent_place_id is not null then
    if v_partner_id is not null then
      select name into v_partner_name from public.partners where id = v_partner_id;
    end if;
    if v_partner_name is null and v_group_key is not null then
      v_partner_name := v_group_key;
    end if;
    if v_partner_name is null and v_root_place_id is not null then
      select name into v_partner_name from public.places where id = v_root_place_id;
    end if;

    v_partner_jsonb := jsonb_build_object(
      'id',         v_partner_id,
      'name',       v_partner_name,
      'current_id', v_current_id,
      'hospitality_group', v_group_key,
      'root_place_id', v_root_place_id,
      'entities', (
        with all_e as (
          select 'place'      as type,
                 id, name, slug,
                 partner_access_token as token,
                 coalesce(nullif(place_role, ''), category) as label
            from public.places
           where (
             (v_partner_id is not null and partner_id = v_partner_id)
             or (v_group_key is not null and hospitality_group = v_group_key)
             or (v_root_place_id is not null and (id = v_root_place_id or parent_place_id = v_root_place_id))
           )
          union all
          select 'event'      as type,
                 id, title as name, slug,
                 partner_access_token as token,
                 event_type as label
            from public.events
           where v_partner_id is not null and partner_id = v_partner_id
        )
        select coalesce(
          jsonb_agg(
            jsonb_build_object(
              'type',  type,
              'id',    id,
              'name',  name,
              'slug',  slug,
              'token', token,
              'label', label
            )
            order by type, name),
          '[]'::jsonb)
        from all_e
      )
    );
  else
    v_partner_jsonb := null;
  end if;

  ------------------------------------------------------------
  -- 3. Place response
  ------------------------------------------------------------
  if v_place.id is not null then
    v_has_loyalty := exists (
      select 1 from public.loyalty_programs
       where place_id = v_place.id and is_active = true
    );

    return jsonb_build_object(
      'type', 'place',
      'place', jsonb_build_object(
        'id',   v_place.id,
        'name', v_place.name,
        'slug', v_place.slug
      ),
      'capabilities', jsonb_build_object(
        'listing',  true,
        'bookings', (
          v_place.bookings_email is not null
          or v_place.booking_link is not null
          or v_place.day_pass_available = true
        ),
        'loyalty',  v_has_loyalty,
        'feedback', true,
        'specials', true,
        'billing',  true
      ),
      'program', (
        select jsonb_build_object(
          'primary_color',   primary_color,
          'accent_color',    accent_color,
          'text_color',      text_color,
          'secondary_color', secondary_color
        )
        from public.loyalty_programs
        where place_id = v_place.id and is_active = true
        order by created_at desc
        limit 1
      ),
      'partner', v_partner_jsonb
    );
  end if;

  ------------------------------------------------------------
  -- 4. Event response
  ------------------------------------------------------------
  -- Parse tabs defensively: column could be text, json, or jsonb.
  declare v_tabs_jsonb jsonb;
  begin
    begin
      v_tabs_jsonb := coalesce(
        nullif(v_event.tabs::text, '')::jsonb,
        '[]'::jsonb);
    exception when others then
      v_tabs_jsonb := '[]'::jsonb;
    end;

    v_has_vendors := coalesce(
      (select bool_or(t->>'key' = 'vendors')
         from jsonb_array_elements(v_tabs_jsonb) t),
      false);
  end;

  return jsonb_build_object(
    'type', 'event',
    'event', jsonb_build_object(
      'id',    v_event.id,
      'title', v_event.title,
      'slug',  v_event.slug
    ),
    'capabilities', jsonb_build_object(
      'event',   true,
      'vendors', v_has_vendors
    ),
    'partner', v_partner_jsonb
  );
end;
$$;


ALTER FUNCTION "public"."get_partner_capabilities_by_token"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_partner_event_by_token"("p_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_event   events%rowtype;
  v_now     timestamptz := now();
  v_starts  timestamptz;
  v_ends    timestamptz;
  v_days    int;
  v_is_past boolean;
  v_tabs    jsonb;
begin
  select * into v_event
    from public.events
   where partner_access_token = p_token;

  if v_event.id is null then
    return null;
  end if;

  -- Defensive timestamp composition
  begin
    v_starts := (v_event.start_date::timestamp
                 + coalesce(v_event.start_time, '00:00'::time))
                at time zone coalesce(nullif(v_event.timezone, ''), 'America/Jamaica');
    v_ends   := (coalesce(v_event.end_date, v_event.start_date)::timestamp
                 + coalesce(v_event.end_time, '23:59'::time))
                at time zone coalesce(nullif(v_event.timezone, ''), 'America/Jamaica');
  exception when others then
    v_starts := v_event.start_date::timestamptz;
    v_ends   := coalesce(v_event.end_date, v_event.start_date)::timestamptz;
  end;

  v_days    := floor(extract(epoch from (v_starts - v_now)) / 86400)::int;
  v_is_past := v_ends < v_now;

  -- Parse tabs defensively: column could be text, json, or jsonb.
  begin
    v_tabs := coalesce(nullif(v_event.tabs::text, '')::jsonb, '[]'::jsonb);
  exception when others then
    v_tabs := '[]'::jsonb;
  end;

  return jsonb_build_object(

    'event', (to_jsonb(v_event) - 'partner_access_token'),

    'stats', (
      with
        viewers as (
          select count(*) as n
            from public.user_event_interactions
           where event_id = v_event.id and interaction_type = 'viewed'
        ),
        saves as (
          select count(*) as n from public.saved_events where event_id = v_event.id
        ),
        saves_7d as (
          select count(*) as n from public.saved_events
           where event_id = v_event.id and created_at >= v_now - interval '7 days'
        ),
        interests as (
          select status, count(*) as n
            from public.event_interests
           where event_id = v_event.id
           group by status
        ),
        interests_7d as (
          select count(*) as n from public.event_interests
           where event_id = v_event.id and created_at >= v_now - interval '7 days'
        ),
        going_7d as (
          select count(*) as n from public.event_interests
           where event_id = v_event.id
             and status = 'going'
             and updated_at >= v_now - interval '7 days'
        ),
        checkins as (
          select count(*) as n
            from public.user_event_activity
           where event_id = v_event.id and activity_type = 'checked_in'
        ),
        shares as (
          select count(*) as n from public.user_event_activity
           where event_id = v_event.id and activity_type = 'shared'
        ),
        bookmarks as (
          select count(*) as n from public.user_event_activity
           where event_id = v_event.id and activity_type = 'bookmarked'
        )
      select jsonb_build_object(
        -- Hard event metadata
        'capacity',         v_event.capacity,
        'is_sold_out',      coalesce(v_event.is_sold_out, false),
        'days_until_event', v_days,
        'is_past',          v_is_past,
        'is_today',         (v_starts::date = v_now::date),
        'has_tickets',      coalesce(v_event.has_online_tickets, false),
        'price_min',        v_event.ticket_price_min,
        'price_max',        v_event.ticket_price_max,
        'currency',         coalesce(nullif(v_event.currency, ''), 'JMD'),

        -- Real engagement (from new tables)
        'view_count',       coalesce(v_event.view_count, 0),
        'unique_viewers',   (select n from viewers),
        'saved_count',      (select n from saves),
        'interested_count', coalesce((select n from interests where status = 'interested'), 0),
        'going_count',      coalesce((select n from interests where status = 'going'), 0),
        'went_count',       coalesce((select n from interests where status = 'went'), 0),
        'checkin_count',    (select n from checkins),
        'shares_count',     (select n from shares),
        'bookmarks_count',  (select n from bookmarks),
        'saves_7d',         (select n from saves_7d),
        'interests_7d',     (select n from interests_7d),
        'going_7d',         (select n from going_7d),

        'checkin_by_method', (
          select coalesce(jsonb_object_agg(coalesce(checkin_method, 'self'), n), '{}'::jsonb)
          from (
            select checkin_method, count(*) as n
              from public.user_event_activity
             where event_id = v_event.id and activity_type = 'checked_in'
             group by checkin_method
          ) m
        ),

        'capacity_fill_rate',
          (case
            when v_event.capacity is null or v_event.capacity = 0 then null
            else round(
              (coalesce((select n from interests where status = 'going'), 0)::numeric
                / v_event.capacity) * 100,
              1)
          end),

        'view_to_interest_rate',
          (case
            when (select n from viewers) = 0 then null
            else round(
              ((select coalesce(sum(n), 0) from interests where status in ('interested','going','went'))::numeric
                / (select n from viewers)) * 100,
              1)
          end),

        'interest_to_going_rate',
          (case
            when coalesce((select n from interests where status = 'interested'), 0) = 0 then null
            else round(
              (coalesce((select n from interests where status = 'going'), 0)::numeric
                / (select n from interests where status = 'interested')) * 100,
              1)
          end),

        'going_to_attended_rate',
          (case
            when coalesce((select n from interests where status = 'going'), 0) = 0 then null
            else round(
              ((select n from checkins)::numeric
                / (select n from interests where status = 'going')) * 100,
              1)
          end)
      )
    ),

    -- ── Audience location (from interactions.country) ─
    'top_countries', (
      select coalesce(
        jsonb_agg(jsonb_build_object('country', country, 'count', n) order by n desc),
        '[]'::jsonb)
      from (
        select country, count(*) as n
          from public.user_event_interactions
         where event_id = v_event.id
           and country is not null and country <> ''
         group by country
         order by count(*) desc
         limit 10
      ) c
    ),

    -- ── Activity trend (last 30 days, bucketed by day) ─
    'activity_trend', (
      select coalesce(
        jsonb_agg(jsonb_build_object('date', d, 'count', n) order by d),
        '[]'::jsonb)
      from (
        select to_char(created_at::date, 'YYYY-MM-DD') as d, count(*) as n
          from public.user_event_activity
         where event_id = v_event.id
           and created_at >= v_now - interval '30 days'
         group by created_at::date
      ) t
    ),

    -- ── Schedule overview ─
    'schedule', jsonb_build_object(
      'days_count', (
        select count(*) from public.event_schedule_days where event_id = v_event.id
      ),
      'items_count', (
        select count(*) from public.event_schedule_items where event_id = v_event.id
      ),
      'featured_count', (
        select count(*) from public.event_schedule_items
         where event_id = v_event.id and is_featured = true
      ),
      'must_see_count', (
        select count(*) from public.event_schedule_items
         where event_id = v_event.id and is_must_see = true
      ),
      'days', (
        select coalesce(
          jsonb_agg(jsonb_build_object(
            'id',            d.id,
            'date',          d.date,
            'label',         d.label,
            'date_display',  d.date_display,
            'gates_open',    d.gates_open,
            'gates_close',   d.gates_close,
            'is_cancelled',  d.is_cancelled,
            'day_number',    d.day_number,
            'items_count',   (select count(*) from public.event_schedule_items
                               where day_id = d.id and is_published = true),
            'must_see_count',(select count(*) from public.event_schedule_items
                               where day_id = d.id and is_must_see = true)
          ) order by d.date),
          '[]'::jsonb)
        from public.event_schedule_days d
        where d.event_id = v_event.id
      ),
      'next_item', (
        select jsonb_build_object(
          'id',          id,
          'title',       title,
          'subtitle',    subtitle,
          'start_time',  start_time,
          'end_time',    end_time,
          'venue_override', venue_override,
          'is_must_see', is_must_see
        )
        from public.event_schedule_items
        where event_id = v_event.id
          and is_published = true
          and start_time > v_now
        order by start_time
        limit 1
      ),

      'total_saved', (
        select count(*) from public.user_saved_schedule_items
         where event_id = v_event.id
      ),

      'unique_savers', (
        select count(distinct user_id) from public.user_saved_schedule_items
         where event_id = v_event.id
      ),

      'top_saved_items', (
        select coalesce(
          jsonb_agg(jsonb_build_object(
            'id',             sc.schedule_item_id,
            'count',          sc.n,
            'title',          si.title,
            'subtitle',       si.subtitle,
            'start_time',     si.start_time,
            'venue_override', si.venue_override,
            'is_must_see',    si.is_must_see,
            'is_featured',    si.is_featured,
            'image_url',      si.image_url,
            'category',       si.category
          ) order by sc.n desc),
          '[]'::jsonb)
        from (
          select schedule_item_id, count(*) as n
            from public.user_saved_schedule_items
           where event_id = v_event.id
           group by schedule_item_id
           order by count(*) desc
           limit 10
        ) sc
        join public.event_schedule_items si on si.id = sc.schedule_item_id
        where si.is_published = true
      )
    ),

    -- ── Updates (organizer-pushed messages) ─
    'updates', (
      select coalesce(
        jsonb_agg(jsonb_build_object(
          'id',         id,
          'title',      title,
          'message',    message,
          'created_at', created_at
        ) order by created_at desc),
        '[]'::jsonb)
      from (
        select * from public.event_updates
        where event_id = v_event.id
        order by created_at desc
        limit 20
      ) u
    ),

    'tabs', v_tabs,

    'capabilities', jsonb_build_object(
      'event',   true,
      'vendors', coalesce(
        (select bool_or(t->>'key' = 'vendors')
           from jsonb_array_elements(v_tabs) t),
        false)
    ),

    -- ── Vendors lineup with per-vendor menu + per-item ratings ─
    'vendors', (
      with vendor_base as (
        select distinct on (vendor_id)
          vendor_id,
          coalesce((select nullif(btrim(ev.display_name), '')
                      from public.event_vendors ev
                     where ev.id = evm_base.event_vendor_id), vendor_name) as vendor_name,
          vendor_description, vendor_type,
          coalesce((select ev.filter_tags
                      from public.event_vendors ev
                     where ev.id = evm_base.event_vendor_id), '{}'::text[]) as filter_tags,
          logo_url, cover_image_url, instagram, website,
          place_id, place_slug, place_name, place_image, place_category,
          event_vendor_id, booth_number, vendor_is_featured
        from public.event_vendors_with_menu evm_base
        where event_id = v_event.id
      )
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'vendor_id',       vb.vendor_id,
            'name',            vb.vendor_name,
            'description',     vb.vendor_description,
            'vendor_type',     vb.vendor_type,
            'filter_tags',     vb.filter_tags,
            'filters',         vb.filter_tags,
            'logo_url',        vb.logo_url,
            'cover_image_url', vb.cover_image_url,
            'instagram',       vb.instagram,
            'website',         vb.website,
            'place_id',        vb.place_id,
            'place_slug',      vb.place_slug,
            'place_name',      vb.place_name,
            'place_image',     vb.place_image,
            'place_category',  vb.place_category,
            'event_vendor_id', vb.event_vendor_id,
            'booth_number',    vb.booth_number,
            'zone', (
              select ev.zone from public.event_vendors ev
               where ev.id = vb.event_vendor_id
            ),
            'is_featured',     vb.vendor_is_featured,

            -- Per-vendor activity. The app has used both vendor ids and
            -- event_vendor ids for entity_id, so count either shape.
            -- NOTE: activity_type 'visited' is deliberately NOT counted as a
            -- view — in the app that name belongs to the My Plan "Visited"
            -- check-off (written as 'going', see visited_count below).
            'view_count', (
              select count(*) from public.user_event_activity a
               where a.event_id = v_event.id
                 and a.entity_type in ('vendor', 'event_vendor')
                 and a.entity_id in (vb.vendor_id, vb.event_vendor_id)
                 and a.action = 'viewed'
            ),
            'save_count', (
              select count(*) from public.user_event_activity a
               where a.event_id = v_event.id
                 and a.entity_type in ('vendor', 'event_vendor')
                 and a.entity_id in (vb.vendor_id, vb.event_vendor_id)
                 and (a.activity_type = 'bookmarked' or a.action = 'saved')
            ),
            'menu_clicks', (
              select count(*) from public.user_event_activity a
               where a.event_id = v_event.id
                 and a.entity_type in ('vendor', 'event_vendor', 'vendor_menu')
                 and a.entity_id in (vb.vendor_id, vb.event_vendor_id)
                 and a.action in ('menu_click', 'menu_clicked', 'menu_viewed')
            ),

            -- "My Plan" signals from the mobile app. The app's UI labels do
            -- NOT match the stored activity_type names — this is the
            -- confirmed mapping (do not "fix" it to match intuition):
            --   app "Interested"  → activity_type 'bookmarked'
            --   app "Visited"     → activity_type 'going'
            --   app "Favourites"  → activity_type 'interested'
            --   app "Want to try" → rows in user_saved_menu_items (per vendor)
            -- All activity rows are written with action = null. Some app
            -- builds omit event_id, so also accept a null event_id when the
            -- row points at this event's event_vendor id (those ids are
            -- event-scoped, so the match stays unambiguous).
            'interested_count', (
              select count(*) from public.user_event_activity a
               where a.entity_type in ('vendor', 'event_vendor')
                 and a.entity_id in (vb.vendor_id, vb.event_vendor_id)
                 and a.activity_type = 'bookmarked'
                 and (a.event_id = v_event.id
                      or (a.event_id is null and a.entity_id = vb.event_vendor_id))
            ),
            'visited_count', (
              select count(*) from public.user_event_activity a
               where a.entity_type in ('vendor', 'event_vendor')
                 and a.entity_id in (vb.vendor_id, vb.event_vendor_id)
                 and a.activity_type = 'going'
                 and (a.event_id = v_event.id
                      or (a.event_id is null and a.entity_id = vb.event_vendor_id))
            ),
            'favourite_count', (
              select count(*) from public.user_event_activity a
               where a.entity_type in ('vendor', 'event_vendor')
                 and a.entity_id in (vb.vendor_id, vb.event_vendor_id)
                 and a.activity_type = 'interested'
                 and (a.event_id = v_event.id
                      or (a.event_id is null and a.entity_id = vb.event_vendor_id))
            ),
            'want_to_try_count', (
              select count(*) from public.user_saved_menu_items s
               where s.vendor_id in (vb.vendor_id, vb.event_vendor_id)
                 and (s.event_id = v_event.id
                      or (s.event_id is null and s.vendor_id = vb.event_vendor_id))
            ),

            -- Total ratings across all this vendor's items
            'total_ratings', (
              select count(*) from public.user_vendor_item_ratings r
               where r.event_id = v_event.id
                 and r.vendor_id = vb.vendor_id::text
            ),

            -- Menu items with per-item ratings
            'menu_items', (
              select coalesce(jsonb_agg(item_obj order by sort_key, name nulls last), '[]'::jsonb)
              from (
                select distinct on (menu_item_id)
                  menu_item_id,
                  menu_item_name as name,
                  menu_item_description as description,
                  price, currency, menu_category as category,
                  tags, is_special, is_sold_out,
                  menu_image_url as image_url,
                  sort_order as sort_key,
                  jsonb_build_object(
                    'menu_item_id', menu_item_id,
                    'name',         menu_item_name,
                    'description',  menu_item_description,
                    'price',        price,
                    'currency',     currency,
                    'category',     menu_category,
                    'tags',         tags,
                    'is_special',   is_special,
                    'is_sold_out',  is_sold_out,
                    'image_url',    menu_image_url,
                    'rating_count', (
                      select count(*) from public.user_vendor_item_ratings r
                       where r.event_id = v_event.id
                         and r.vendor_id = vb.vendor_id::text
                         and r.item_name = evm.menu_item_name
                    ),
                    'rating_breakdown', (
                      select coalesce(jsonb_object_agg(rating, n), '{}'::jsonb)
                      from (
                        select rating, count(*) as n
                          from public.user_vendor_item_ratings r
                         where r.event_id = v_event.id
                           and r.vendor_id = vb.vendor_id::text
                           and r.item_name = evm.menu_item_name
                         group by rating
                      ) rb
                    )
                  ) as item_obj
                from public.event_vendors_with_menu evm
                where evm.event_id = v_event.id
                  and evm.vendor_id = vb.vendor_id
                  and evm.menu_item_id is not null
              ) items
            )
          )
          order by vb.vendor_is_featured desc nulls last, vb.vendor_name
        ),
        '[]'::jsonb)
      from vendor_base vb
    ),

    'vendor_stats', (
      with rows as (
        select distinct on (vendor_id)
          vendor_id, vendor_is_featured, place_id, logo_url, cover_image_url
        from public.event_vendors_with_menu
        where event_id = v_event.id
      )
      select jsonb_build_object(
        'total',         (select count(*) from rows),
        'featured',      (select count(*) from rows where vendor_is_featured = true),
        'with_place',    (select count(*) from rows where place_id is not null),
        'with_imagery',  (select count(*) from rows where coalesce(logo_url, cover_image_url) is not null)
      )
    ),

    'menu_stats', (
      with rows as (
        select menu_item_id, vendor_id
        from public.event_vendors_with_menu
        where event_id = v_event.id and menu_item_id is not null
      )
      select jsonb_build_object(
        'items_total',     (select count(distinct menu_item_id) from rows),
        'vendors_with_menu', (select count(distinct vendor_id) from rows)
      )
    ),

    -- ── Top-rated menu items (real interaction signal) ─
    'top_rated_items', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'vendor_id', vendor_id,
            'item_name', item_name,
            'count',     n,
            'breakdown', breakdown
          )
          order by n desc),
        '[]'::jsonb)
      from (
        select
          vendor_id,
          item_name,
          count(*) as n,
          jsonb_object_agg(rating, rating_count) as breakdown
        from (
          select vendor_id, item_name, rating, count(*) as rating_count
            from public.user_vendor_item_ratings
           where event_id = v_event.id
           group by vendor_id, item_name, rating
        ) per_rating
        group by vendor_id, item_name
        order by sum(rating_count) desc
        limit 15
      ) t
    ),

    'rating_summary', (
      select jsonb_build_object(
        'total_ratings',
          (select count(*) from public.user_vendor_item_ratings where event_id = v_event.id),
        'unique_raters',
          (select count(distinct user_id) from public.user_vendor_item_ratings where event_id = v_event.id),
        'by_rating',
          (select coalesce(jsonb_object_agg(rating, n), '{}'::jsonb)
             from (
               select rating, count(*) as n
                 from public.user_vendor_item_ratings
                where event_id = v_event.id
                group by rating
             ) r)
      )
    ),

    -- ── Sponsors (with activations + real engagement) ─
    'sponsors', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id',                 s.id,
            'sponsor_id',         s.id,
            'event_sponsor_id',   es.id,
            'name',               s.name,
            'sponsor_name',       s.name,
            'logo_url',           s.logo_url,
            'website',            s.website,
            'instagram',          s.instagram,
            'brand_color',        s.brand_color,
            'tier',               es.tier,
            'tier_label',         es.display_tier_label,
            'display_tier_label', es.display_tier_label,
            'is_featured',        es.is_featured,
            'tagline',            es.custom_tagline,
            'custom_tagline',     es.custom_tagline,
            'description',        s.description,
            'activations', (
              select coalesce(
                jsonb_agg(jsonb_build_object(
                  'id',             a.id,
                  'name',           a.name,
                  'description',    a.description,
                  'zone',           a.zone,
                  'days_active',    a.days_active,
                  'start_time',     a.start_time,
                  'end_time',       a.end_time,
                  'troddr_offer',   a.troddr_offer,
                  'checkin_method', a.checkin_method,
                  'has_qr',         (a.qr_code_token is not null),
                  'has_nfc',        (a.nfc_token is not null),
                  'redemptions', (
                    select count(*) from public.user_event_activity
                     where event_id = v_event.id
                       and entity_type = 'sponsor_activation'
                       and entity_id = a.id
                  )
                ) order by a.display_order),
                '[]'::jsonb)
              from public.event_sponsor_activations a
              where a.event_sponsor_id = es.id
                and coalesce(a.is_active, true) = true
            )
          )
          order by es.display_order, es.tier),
        '[]'::jsonb)
      from public.event_sponsors es
      join public.sponsors s on s.id = es.sponsor_id
      where es.event_id = v_event.id
        and coalesce(es.is_active, true) = true
        and coalesce(s.is_active, true) = true
    )
  );
end;
$$;


ALTER FUNCTION "public"."get_partner_event_by_token"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_partner_event_extras_by_token"("p_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_event_id   uuid;
  v_event_type text;
begin
  select id, event_type
    into v_event_id, v_event_type
    from public.events
   where partner_access_token = p_token;

  if v_event_id is null then
    return null;
  end if;

  return jsonb_build_object(
    'ticket_locations', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',            tl.id,
          'name',          tl.name,
          'address',       tl.address,
          'parish',        tl.parish,
          'town',          tl.town,
          'contact_phone', tl.contact_phone,
          'opening_hours', tl.opening_hours,
          'is_online',     tl.is_online,
          'provider_type', tl.provider_type,
          'ticket_url',    tl.ticket_url,
          'logo_url',      tl.logo_url,
          'latitude',      tl.latitude,
          'longitude',     tl.longitude,
          'place_slug',    tl.place_slug,
          'place_name',    (select name from public.places where slug = tl.place_slug)
        )
        order by tl.display_order, tl.created_at
      )
      from public.ticket_locations tl
      where tl.event_id = v_event_id and coalesce(tl.is_active, true)
    ), '[]'::jsonb),

    'transport_routes', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',          r.id,
          'name',        r.name,
          'color',       r.color,
          'direction',   r.direction,
          'frequency',   r.frequency,
          'stops_count', (select count(*) from public.event_transport_stops s where s.route_id = r.id)
        )
        order by r.display_order, r.created_at
      )
      from public.event_transport_routes r
      where r.event_id = v_event_id
    ), '[]'::jsonb),

    'schedule_days', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',             d.id,
          'date',           d.date,
          'date_display',   d.date_display,
          'label',          d.label,
          'description',    d.description,
          'gates_open',     d.gates_open,
          'gates_close',    d.gates_close,
          'is_cancelled',   d.is_cancelled,
          'day_number',     d.day_number,
          'items_count',    (select count(*) from public.event_schedule_items i where i.day_id = d.id),
          'must_see_count', (select count(*) from public.event_schedule_items i where i.day_id = d.id and i.is_must_see = true)
        )
        order by d.date
      )
      from public.event_schedule_days d
      where d.event_id = v_event_id
    ), '[]'::jsonb),

    'schedule_items', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'id',             i.id,
          'day_id',         i.day_id,
          'title',          i.title,
          'subtitle',       i.subtitle,
          'start_time',     i.start_time,
          'end_time',       i.end_time,
          'venue_override', i.venue_override,
          'category',       i.category,
          'image_url',      i.image_url,
          'is_featured',    i.is_featured,
          'is_must_see',    i.is_must_see,
          'is_published',   i.is_published
        )
        order by i.start_time nulls last, i.title
      )
      from public.event_schedule_items i
      where i.event_id = v_event_id
    ), '[]'::jsonb),

    'bands', case
      when lower(coalesce(v_event_type, '')) = 'carnival' then
        coalesce((
          select jsonb_agg(
            jsonb_build_object(
              'id',                     mb.id,
              'name',                   mb.name,
              'slug',                   mb.slug,
              'tagline',                mb.tagline,
              'logo_url',               mb.logo_url,
              'cover_url',              mb.cover_url,
              'website_url',            mb.website_url,
              'registration_deadline',  mb.registration_deadline,
              'registration_url',       mb.registration_url
            )
            order by mb.sort_order, mb.name
          )
          from public.mas_bands mb
          where mb.season_id = v_event_id
        ), '[]'::jsonb)
      else null
    end
  );
end;
$$;


ALTER FUNCTION "public"."get_partner_event_extras_by_token"("p_token" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_partner_event_extras_by_token"("p_token" "text") IS 'Supplementary data for the partner-event dashboard: ticket_locations, transport_routes, and (for carnivals) mas_bands. Kept separate from get_partner_event_by_token so the main RPC stays untouched.';



CREATE OR REPLACE FUNCTION "public"."get_partner_feedback_by_token"("p_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place_id  uuid;
  v_now       timestamptz := now();
begin
  select id
    into v_place_id
    from public.places
   where partner_access_token = p_token;

  if v_place_id is null then
    return null;
  end if;

  return jsonb_build_object(

    'place', (
      select jsonb_build_object('id', id, 'name', name, 'slug', slug)
        from public.places where id = v_place_id
    ),

    'program', (
      select jsonb_build_object(
        'primary_color',   primary_color,
        'accent_color',    accent_color,
        'text_color',      text_color,
        'secondary_color', secondary_color
      )
      from public.loyalty_programs
      where place_id = v_place_id and is_active = true
      order by created_at desc
      limit 1
    ),

    'stats', (
      with fb as (
        select * from public.visited_feedback where place_id = v_place_id
      )
      select jsonb_build_object(

        'total',     (select count(*) from fb),
        'count_30d', (select count(*) from fb where created_at >= v_now - interval '30 days'),
        'count_7d',  (select count(*) from fb where created_at >= v_now - interval '7 days'),

        'would_return_yes',
          (select count(*) from fb where would_return = true),

        'would_return_no',
          (select count(*) from fb where would_return = false),

        'would_return_rate',
          (select case
                    when count(*) filter (where would_return is not null) = 0 then null
                    else count(*) filter (where would_return = true)::float
                       / count(*) filter (where would_return is not null)
                  end
             from fb),

        'overall_rating',
          (select round(avg(r)::numeric, 2)
             from fb, lateral (values
               (rating_service), (rating_vibe), (rating_value),
               (rating_wait_time), (rating_cleanliness),
               (rating_taste), (rating_ambiance), (rating_speed)
             ) v(r) where r is not null),

        'contexts',
          (select coalesce(jsonb_object_agg(context, n), '{}'::jsonb)
             from (select context, count(*) as n from fb group by context) c)
      )
    ),

    'avg_ratings', (
      select jsonb_build_object(
        'service',     round(avg(rating_service)::numeric,     2),
        'vibe',        round(avg(rating_vibe)::numeric,        2),
        'value',       round(avg(rating_value)::numeric,       2),
        'wait_time',   round(avg(rating_wait_time)::numeric,   2),
        'cleanliness', round(avg(rating_cleanliness)::numeric, 2),
        'taste',       round(avg(rating_taste)::numeric,       2),
        'ambiance',    round(avg(rating_ambiance)::numeric,    2),
        'speed',       round(avg(rating_speed)::numeric,       2)
      )
      from public.visited_feedback where place_id = v_place_id
    ),

    -- Per-dimension 1..5 distribution
    'distributions', (
      with fb as (select * from public.visited_feedback where place_id = v_place_id)
      select jsonb_build_object(
        'service',     (select jsonb_build_object('1', count(*) filter (where rating_service     = 1), '2', count(*) filter (where rating_service     = 2), '3', count(*) filter (where rating_service     = 3), '4', count(*) filter (where rating_service     = 4), '5', count(*) filter (where rating_service     = 5)) from fb),
        'vibe',        (select jsonb_build_object('1', count(*) filter (where rating_vibe        = 1), '2', count(*) filter (where rating_vibe        = 2), '3', count(*) filter (where rating_vibe        = 3), '4', count(*) filter (where rating_vibe        = 4), '5', count(*) filter (where rating_vibe        = 5)) from fb),
        'value',       (select jsonb_build_object('1', count(*) filter (where rating_value       = 1), '2', count(*) filter (where rating_value       = 2), '3', count(*) filter (where rating_value       = 3), '4', count(*) filter (where rating_value       = 4), '5', count(*) filter (where rating_value       = 5)) from fb),
        'wait_time',   (select jsonb_build_object('1', count(*) filter (where rating_wait_time   = 1), '2', count(*) filter (where rating_wait_time   = 2), '3', count(*) filter (where rating_wait_time   = 3), '4', count(*) filter (where rating_wait_time   = 4), '5', count(*) filter (where rating_wait_time   = 5)) from fb),
        'cleanliness', (select jsonb_build_object('1', count(*) filter (where rating_cleanliness = 1), '2', count(*) filter (where rating_cleanliness = 2), '3', count(*) filter (where rating_cleanliness = 3), '4', count(*) filter (where rating_cleanliness = 4), '5', count(*) filter (where rating_cleanliness = 5)) from fb),
        'taste',       (select jsonb_build_object('1', count(*) filter (where rating_taste       = 1), '2', count(*) filter (where rating_taste       = 2), '3', count(*) filter (where rating_taste       = 3), '4', count(*) filter (where rating_taste       = 4), '5', count(*) filter (where rating_taste       = 5)) from fb),
        'ambiance',    (select jsonb_build_object('1', count(*) filter (where rating_ambiance    = 1), '2', count(*) filter (where rating_ambiance    = 2), '3', count(*) filter (where rating_ambiance    = 3), '4', count(*) filter (where rating_ambiance    = 4), '5', count(*) filter (where rating_ambiance    = 5)) from fb),
        'speed',       (select jsonb_build_object('1', count(*) filter (where rating_speed       = 1), '2', count(*) filter (where rating_speed       = 2), '3', count(*) filter (where rating_speed       = 3), '4', count(*) filter (where rating_speed       = 4), '5', count(*) filter (where rating_speed       = 5)) from fb)
      )
    ),

    'trend', (
      select coalesce(
        jsonb_agg(jsonb_build_object('week', week, 'count', n) order by week),
        '[]'::jsonb)
      from (
        select to_char(date_trunc('week', created_at)::date, 'YYYY-MM-DD') as week,
               count(*) as n
          from public.visited_feedback
         where place_id = v_place_id
           and created_at >= v_now - interval '12 weeks'
         group by date_trunc('week', created_at)
      ) t
    ),

    'top_tags', (
      with tags as (
        select unnest(quick_tags) as tag
          from public.visited_feedback
         where place_id = v_place_id
      )
      select coalesce(
        jsonb_agg(jsonb_build_object('tag', tag, 'count', n) order by n desc),
        '[]'::jsonb)
      from (
        select tag, count(*) as n
          from tags
         where tag is not null and tag <> ''
         group by tag
         order by count(*) desc
         limit 30
      ) t
    ),

    'feedback', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id',           id,
            'user_id',      user_id,
            'created_at',   created_at,
            'updated_at',   updated_at,
            'context',      context,
            'would_return', would_return,
            'quick_tags',   quick_tags,
            'ratings', jsonb_build_object(
              'service',     rating_service,
              'vibe',        rating_vibe,
              'value',       rating_value,
              'wait_time',   rating_wait_time,
              'cleanliness', rating_cleanliness,
              'taste',       rating_taste,
              'ambiance',    rating_ambiance,
              'speed',       rating_speed
            )
          )
          order by created_at desc
        ),
        '[]'::jsonb
      )
      from (
        select * from public.visited_feedback
        where place_id = v_place_id
        order by created_at desc
        limit 200
      ) recent
    )
  );
end;
$$;


ALTER FUNCTION "public"."get_partner_feedback_by_token"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_partner_group_insights_by_token"("p_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place         places%rowtype;
  v_partner_id    uuid;
  v_group_key     text;
  v_root_place_id uuid;
  v_now           timestamptz := now();
  v_place_ids     uuid[];
begin
  select * into v_place from public.places where partner_access_token = p_token;

  if v_place.id is null then
    -- Group insights are place-based. An event-only token is still a
    -- valid partner, so return an empty (but ok) payload rather than null.
    if exists (select 1 from public.events where partner_access_token = p_token) then
      return jsonb_build_object('ok', true,
        'totals', jsonb_build_object('locations', 0, 'total', 0, 'count_30d', 0,
                  'count_7d', 0, 'would_return_rate', null, 'overall_rating', null),
        'locations', '[]'::jsonb, 'trend', '[]'::jsonb, 'top_tags', '[]'::jsonb);
    end if;
    return null; -- invalid / revoked token
  end if;

  v_partner_id    := v_place.partner_id;
  v_group_key     := nullif(trim(coalesce(v_place.hospitality_group, '')), '');
  v_root_place_id := coalesce(v_place.parent_place_id, v_place.id);

  select array_agg(id) into v_place_ids
    from public.places
   where (v_partner_id is not null and partner_id = v_partner_id)
      or (v_group_key is not null and hospitality_group = v_group_key)
      or (id = v_root_place_id or parent_place_id = v_root_place_id);

  if v_place_ids is null then
    v_place_ids := array[v_place.id];
  end if;

  return jsonb_build_object(
    'ok', true,

    'totals', (
      with fb as (select * from public.visited_feedback where place_id = any(v_place_ids))
      select jsonb_build_object(
        'locations',  array_length(v_place_ids, 1),
        'total',      (select count(*) from fb),
        'count_30d',  (select count(*) from fb where created_at >= v_now - interval '30 days'),
        'count_7d',   (select count(*) from fb where created_at >= v_now - interval '7 days'),
        'would_return_rate',
          (select case when count(*) filter (where would_return is not null) = 0 then null
                       else count(*) filter (where would_return = true)::float
                          / count(*) filter (where would_return is not null) end
             from fb),
        'overall_rating',
          (select round(avg(r)::numeric, 2)
             from fb, lateral (values
               (rating_service), (rating_vibe), (rating_value), (rating_wait_time),
               (rating_cleanliness), (rating_taste), (rating_ambiance), (rating_speed)
             ) v(r) where r is not null)
      )
    ),

    -- Per-location leaderboard (highest review count first).
    'locations', (
      select coalesce(jsonb_agg(loc order by (loc->>'total')::int desc, loc->>'name'), '[]'::jsonb)
      from (
        select jsonb_build_object(
          'id',     p.id,
          'name',   p.name,
          'slug',   p.slug,
          'town',   p.town,
          'parish', p.parish,
          'total',     (select count(*) from public.visited_feedback f where f.place_id = p.id),
          'count_30d', (select count(*) from public.visited_feedback f
                          where f.place_id = p.id and f.created_at >= v_now - interval '30 days'),
          'would_return_rate',
            (select case when count(*) filter (where would_return is not null) = 0 then null
                         else count(*) filter (where would_return = true)::float
                            / count(*) filter (where would_return is not null) end
               from public.visited_feedback f where f.place_id = p.id),
          'overall_rating',
            (select round(avg(r)::numeric, 2)
               from public.visited_feedback f, lateral (values
                 (f.rating_service), (f.rating_vibe), (f.rating_value), (f.rating_wait_time),
                 (f.rating_cleanliness), (f.rating_taste), (f.rating_ambiance), (f.rating_speed)
               ) v(r) where f.place_id = p.id and r is not null)
        ) as loc
        from public.places p
        where p.id = any(v_place_ids)
      ) sub
    ),

    -- Group-wide weekly review volume, last 12 weeks.
    'trend', (
      select coalesce(jsonb_agg(jsonb_build_object('week', week, 'count', n) order by week), '[]'::jsonb)
      from (
        select to_char(date_trunc('week', created_at)::date, 'YYYY-MM-DD') as week, count(*) as n
          from public.visited_feedback
         where place_id = any(v_place_ids)
           and created_at >= v_now - interval '12 weeks'
         group by date_trunc('week', created_at)
      ) t
    ),

    -- Most common quick-tags across the group.
    'top_tags', (
      with tags as (
        select unnest(quick_tags) as tag
          from public.visited_feedback where place_id = any(v_place_ids)
      )
      select coalesce(jsonb_agg(jsonb_build_object('tag', tag, 'count', n) order by n desc), '[]'::jsonb)
      from (
        select tag, count(*) as n from tags
         where tag is not null and tag <> ''
         group by tag order by count(*) desc limit 20
      ) t
    )
  );
end;
$$;


ALTER FUNCTION "public"."get_partner_group_insights_by_token"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_partner_group_item_insights_by_token"("p_token" "text", "p_min_reviews" integer DEFAULT 5) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place         places%rowtype;
  v_partner_id    uuid;
  v_group_key     text;
  v_root_place_id uuid;
  v_place_ids     uuid[];
begin
  select * into v_place from public.places where partner_access_token = p_token;

  if v_place.id is null then
    if exists (select 1 from public.events where partner_access_token = p_token) then
      return jsonb_build_object('ok', true, 'min_reviews', p_min_reviews,
        'most_loved', '[]'::jsonb, 'lowest_rated', '[]'::jsonb, 'hidden_gems', '[]'::jsonb,
        'house_favourites', '[]'::jsonb, 'comments', '[]'::jsonb,
        'unavailable', jsonb_build_object(
          'trending', 'no elo history/snapshot stored yet',
          'most_saved', 'user_favorite_items dormant; user_saved_menu_items is event-scoped'));
    end if;
    return null;
  end if;

  -- Same place-id resolution as group-insights.sql.
  v_partner_id    := v_place.partner_id;
  v_group_key     := nullif(trim(coalesce(v_place.hospitality_group, '')), '');
  v_root_place_id := coalesce(v_place.parent_place_id, v_place.id);

  select array_agg(id) into v_place_ids
    from public.places
   where (v_partner_id is not null and partner_id = v_partner_id)
      or (v_group_key is not null and hospitality_group = v_group_key)
      or (id = v_root_place_id or parent_place_id = v_root_place_id);

  if v_place_ids is null then
    v_place_ids := array[v_place.id];
  end if;

  return jsonb_build_object(
    'ok', true,
    'min_reviews', p_min_reviews,

    'most_loved', (
      select coalesce(jsonb_agg(x order by (x->>'elo_rating')::int desc), '[]'::jsonb)
      from (
        select jsonb_build_object(
          'menu_item_id', mi.id, 'name', mi.canonical_name, 'category', mi.category,
          'elo_rating', mi.elo_rating, 'total_reviews', mi.total_reviews,
          'place_name', p.name, 'place_slug', p.slug) as x
        from public.menu_items mi join public.places p on p.id = mi.place_id
        where mi.place_id = any(v_place_ids) and mi.total_reviews >= p_min_reviews
        order by mi.elo_rating desc limit 15
      ) sub
    ),

    'lowest_rated', (
      select coalesce(jsonb_agg(x order by (x->>'elo_rating')::int asc), '[]'::jsonb)
      from (
        select jsonb_build_object(
          'menu_item_id', mi.id, 'name', mi.canonical_name, 'category', mi.category,
          'elo_rating', mi.elo_rating, 'total_reviews', mi.total_reviews,
          'place_name', p.name, 'place_slug', p.slug) as x
        from public.menu_items mi join public.places p on p.id = mi.place_id
        where mi.place_id = any(v_place_ids) and mi.total_reviews >= p_min_reviews
        order by mi.elo_rating asc limit 15
      ) sub
    ),

    'hidden_gems', (
      select coalesce(jsonb_agg(x order by (x->>'elo_rating')::int desc), '[]'::jsonb)
      from (
        select jsonb_build_object(
          'menu_item_id', mi.id, 'name', mi.canonical_name, 'category', mi.category,
          'elo_rating', mi.elo_rating, 'total_reviews', mi.total_reviews,
          'place_name', p.name, 'place_slug', p.slug) as x
        from public.menu_items mi join public.places p on p.id = mi.place_id
        where mi.place_id = any(v_place_ids)
          and mi.elo_rating >= 1100
          and mi.total_reviews between 2 and greatest(p_min_reviews - 1, 2)
        order by mi.elo_rating desc limit 15
      ) sub
    ),

    'house_favourites', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'menu_item_id', mi.id, 'name', mi.canonical_name, 'category', mi.category,
        'reviews', s.n, 'reorder_rate', round(s.rate::numeric, 2),
        'place_name', p.name, 'place_slug', p.slug) order by s.rate desc), '[]'::jsonb)
      from (
        select menu_item_id, count(*) as n, avg((would_order_again)::int) as rate
          from public.user_item_logs
         where place_id = any(v_place_ids) and is_public = true
         group by menu_item_id
        having count(*) >= p_min_reviews
         order by avg((would_order_again)::int) desc nulls last
         limit 15
      ) s
      join public.menu_items mi on mi.id = s.menu_item_id
      join public.places p on p.id = mi.place_id
    ),

    'comments', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'name', mi.canonical_name, 'notes', l.notes, 'sentiment', l.sentiment,
        'would_order_again', l.would_order_again, 'visit_date', l.visit_date,
        'place_name', p.name) order by l.created_at desc), '[]'::jsonb)
      from (
        select menu_item_id, place_id, notes, sentiment, would_order_again, visit_date, created_at
          from public.user_item_logs
         where place_id = any(v_place_ids) and is_public = true
           and notes is not null and trim(notes) <> ''
         order by created_at desc limit 40
      ) l
      join public.menu_items mi on mi.id = l.menu_item_id
      join public.places p on p.id = l.place_id
    ),

    'unavailable', jsonb_build_object(
      'trending', 'no elo history/snapshot stored yet',
      'most_saved', 'user_favorite_items dormant; user_saved_menu_items is event-scoped'
    )
  );
end;
$$;


ALTER FUNCTION "public"."get_partner_group_item_insights_by_token"("p_token" "text", "p_min_reviews" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_partner_item_insights_by_token"("p_token" "text", "p_min_reviews" integer DEFAULT 5) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place places%rowtype;
begin
  select * into v_place from public.places where partner_access_token = p_token;

  if v_place.id is null then
    -- Event-only token is still a valid partner: empty-but-ok payload.
    if exists (select 1 from public.events where partner_access_token = p_token) then
      return jsonb_build_object('ok', true, 'place', null, 'min_reviews', p_min_reviews,
        'most_loved', '[]'::jsonb, 'lowest_rated', '[]'::jsonb, 'hidden_gems', '[]'::jsonb,
        'house_favourites', '[]'::jsonb, 'comments', '[]'::jsonb,
        'unavailable', jsonb_build_object(
          'trending', 'no elo history/snapshot stored yet',
          'most_saved', 'user_favorite_items dormant; user_saved_menu_items is event-scoped'));
    end if;
    return null; -- invalid / revoked token
  end if;

  return jsonb_build_object(
    'ok', true,
    'place', jsonb_build_object('id', v_place.id, 'name', v_place.name, 'slug', v_place.slug),
    'min_reviews', p_min_reviews,

    -- Highest Elo (min reviews) — anonymous aggregate, safe to rank.
    'most_loved', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'menu_item_id', id, 'name', canonical_name, 'category', category,
        'elo_rating', elo_rating, 'total_reviews', total_reviews) order by elo_rating desc), '[]'::jsonb)
      from (
        select id, canonical_name, category, elo_rating, total_reviews
          from public.menu_items
         where place_id = v_place.id and total_reviews >= p_min_reviews
         order by elo_rating desc limit 10
      ) t
    ),

    -- Lowest Elo (min reviews) — for attention.
    'lowest_rated', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'menu_item_id', id, 'name', canonical_name, 'category', category,
        'elo_rating', elo_rating, 'total_reviews', total_reviews) order by elo_rating asc), '[]'::jsonb)
      from (
        select id, canonical_name, category, elo_rating, total_reviews
          from public.menu_items
         where place_id = v_place.id and total_reviews >= p_min_reviews
         order by elo_rating asc limit 10
      ) t
    ),

    -- High Elo, low exposure.
    'hidden_gems', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'menu_item_id', id, 'name', canonical_name, 'category', category,
        'elo_rating', elo_rating, 'total_reviews', total_reviews) order by elo_rating desc), '[]'::jsonb)
      from (
        select id, canonical_name, category, elo_rating, total_reviews
          from public.menu_items
         where place_id = v_place.id
           and elo_rating >= 1100
           and total_reviews between 2 and greatest(p_min_reviews - 1, 2)
         order by elo_rating desc limit 10
      ) t
    ),

    -- Highest reorder rate — public logs + min-count threshold.
    'house_favourites', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'menu_item_id', mi.id, 'name', mi.canonical_name, 'category', mi.category,
        'reviews', s.n, 'reorder_rate', round(s.rate::numeric, 2)) order by s.rate desc), '[]'::jsonb)
      from (
        select menu_item_id, count(*) as n, avg((would_order_again)::int) as rate
          from public.user_item_logs
         where place_id = v_place.id and is_public = true
         group by menu_item_id
        having count(*) >= p_min_reviews
         order by avg((would_order_again)::int) desc nulls last
         limit 10
      ) s
      join public.menu_items mi on mi.id = s.menu_item_id
    ),

    -- Recent public comments — anonymous (no user_id).
    'comments', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'name', mi.canonical_name, 'notes', l.notes, 'sentiment', l.sentiment,
        'would_order_again', l.would_order_again, 'visit_date', l.visit_date) order by l.created_at desc), '[]'::jsonb)
      from (
        select menu_item_id, notes, sentiment, would_order_again, visit_date, created_at
          from public.user_item_logs
         where place_id = v_place.id and is_public = true
           and notes is not null and trim(notes) <> ''
         order by created_at desc limit 30
      ) l
      join public.menu_items mi on mi.id = l.menu_item_id
    ),

    -- Flagged, never fabricated.
    'unavailable', jsonb_build_object(
      'trending', 'no elo history/snapshot stored yet',
      'most_saved', 'user_favorite_items dormant; user_saved_menu_items is event-scoped'
    )
  );
end;
$$;


ALTER FUNCTION "public"."get_partner_item_insights_by_token"("p_token" "text", "p_min_reviews" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_partner_listing_by_token"("p_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place_id  uuid;
  v_now       timestamptz := now();
begin
  select id
    into v_place_id
    from public.places
   where partner_access_token = p_token;

  if v_place_id is null then
    return null;
  end if;

  return jsonb_build_object(

    'place', (
      select to_jsonb(p) - 'partner_access_token'
        from public.places p
       where p.id = v_place_id
    ),

    -- Loyalty program (for brand colors, if one exists)
    'program', (
      select jsonb_build_object(
        'primary_color',   primary_color,
        'accent_color',    accent_color,
        'text_color',      text_color,
        'secondary_color', secondary_color
      )
      from public.loyalty_programs
      where place_id = v_place_id and is_active = true
      order by created_at desc
      limit 1
    ),

    'stats', (
      with fb as (
        select * from public.visited_feedback where place_id = v_place_id
      ),
      pve as (
        select * from public.place_visit_events where place_id = v_place_id
      )
      select jsonb_build_object(

        'marked_visits',
          (select count(*) from pve),

        'marked_visits_30d',
          (select count(*) from pve where visited_at >= v_now - interval '30 days'),

        'unique_visitors',
          (select count(distinct user_id) from pve),

        'feedback_count',
          (select count(*) from fb),

        'feedback_30d',
          (select count(*) from fb where created_at >= v_now - interval '30 days'),

        'would_return_rate',
          (select case
                    when count(*) filter (where would_return is not null) = 0 then null
                    else count(*) filter (where would_return = true)::float
                       / count(*) filter (where would_return is not null)
                  end
             from fb),

        'avg_ratings', jsonb_build_object(
          'service',     (select round(avg(rating_service)::numeric,    2) from fb),
          'vibe',        (select round(avg(rating_vibe)::numeric,       2) from fb),
          'value',       (select round(avg(rating_value)::numeric,      2) from fb),
          'wait_time',   (select round(avg(rating_wait_time)::numeric,  2) from fb),
          'cleanliness', (select round(avg(rating_cleanliness)::numeric,2) from fb),
          'taste',       (select round(avg(rating_taste)::numeric,      2) from fb),
          'ambiance',    (select round(avg(rating_ambiance)::numeric,   2) from fb),
          'speed',       (select round(avg(rating_speed)::numeric,      2) from fb)
        ),

        'overall_rating',
          (select round(avg(r)::numeric, 2)
             from fb, lateral (values
               (rating_service), (rating_vibe), (rating_value),
               (rating_wait_time), (rating_cleanliness),
               (rating_taste), (rating_ambiance), (rating_speed)
             ) v(r)
            where r is not null)
      )
    ),

    'top_tags', (
      with tags as (
        select unnest(quick_tags) as tag
          from public.visited_feedback
         where place_id = v_place_id
      )
      select coalesce(
        jsonb_agg(jsonb_build_object('tag', tag, 'count', n)
                  order by n desc),
        '[]'::jsonb)
      from (
        select tag, count(*) as n
          from tags
         where tag is not null and tag <> ''
         group by tag
         order by count(*) desc
         limit 12
      ) t
    ),

    'recent_feedback', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id',          id,
            'created_at',  created_at,
            'context',     context,
            'would_return', would_return,
            'quick_tags',  quick_tags,
            'ratings', jsonb_build_object(
              'service',     rating_service,
              'vibe',        rating_vibe,
              'value',       rating_value,
              'wait_time',   rating_wait_time,
              'cleanliness', rating_cleanliness,
              'taste',       rating_taste,
              'ambiance',    rating_ambiance,
              'speed',       rating_speed
            )
          )
          order by created_at desc
        ),
        '[]'::jsonb
      )
      from (
        select * from public.visited_feedback
        where place_id = v_place_id
        order by created_at desc
        limit 20
      ) recent
    )
  );
end;
$$;


ALTER FUNCTION "public"."get_partner_listing_by_token"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_partner_specials_by_token"("p_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place places%rowtype;
  v_now   timestamptz := now();
begin
  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then return null; end if;

  return jsonb_build_object(
    'place', jsonb_build_object('id', v_place.id, 'name', v_place.name, 'slug', v_place.slug),

    'program', (
      select jsonb_build_object(
        'primary_color',   primary_color,
        'accent_color',    accent_color,
        'text_color',      text_color,
        'secondary_color', secondary_color
      )
      from public.loyalty_programs
      where place_id = v_place.id and is_active = true
      order by created_at desc limit 1
    ),

    'summary', (
      select jsonb_build_object(
        'total',     count(*),
        'active',    count(*) filter (
          where coalesce(submission_status, 'approved') = 'approved'
            and coalesce(active, true) = true
            and v_now between start_date and end_date),
        'upcoming',  count(*) filter (
          where coalesce(submission_status, 'approved') = 'approved'
            and coalesce(active, true) = true
            and v_now < start_date),
        'ended',     count(*) filter (where v_now > end_date),
        'inactive',  count(*) filter (
          where coalesce(submission_status, 'approved') = 'approved'
            and coalesce(active, true) = false),
        'pending',   count(*) filter (where submission_status = 'pending'),
        'rejected',  count(*) filter (where submission_status = 'rejected'),
        'draft',     count(*) filter (where submission_status = 'draft'),
        'total_visits',
          (select count(*) from public.special_visits
            where special_id in (select id from public.specials where place_id = v_place.id)),
        'total_interactions',
          (select count(*) from public.special_interactions
            where special_id in (select id from public.specials where place_id = v_place.id)),
        'total_ratings',
          (select count(*) from public.special_interactions
            where special_id in (select id from public.specials where place_id = v_place.id)
              and rating is not null)
      )
      from public.specials
      where place_id = v_place.id
    ),

    'specials', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',                  s.id,
        'title',               s.title,
        'description',         s.description,
        'special_type',        s.special_type,
        'special_slug',        s.special_slug,
        'start_date',          s.start_date,
        'end_date',            s.end_date,
        'start_time',          s.start_time,
        'end_time',            s.end_time,
        'recurring_days',      s.recurring_days,
        'is_active',           coalesce(s.active, true),
        'submission_status',   coalesce(s.submission_status, 'approved'),
        'submitted_at',        s.submitted_at,
        'review_note',         s.review_note,
        'image_url',
          (case when s.image_urls is not null and array_length(s.image_urls, 1) > 0
                then s.image_urls[1] else null end),
        'image_urls',          s.image_urls,
        'discount_percentage', s.discount_percentage,
        'discount_amount',     s.discount_amount,
        'price_amount',        s.price_amount,
        'price_type',          s.price_type,
        'currency',            coalesce(nullif(s.currency, ''), 'JMD'),
        'event_category',      s.event_category,
        'event_tags',          s.event_tags,
        'priority',            coalesce(s.priority, 0),
        'age_restriction',     s.age_restriction,
        'host_name',           s.host_name,
        'event_slug',          s.event_slug,
        'ticket_link',         s.ticket_link,
        'rsvp_link',           s.rsvp_link,
        'capacity',            s.capacity,
        'claimed_count',
          (select count(*) from public.special_interactions
            where special_id = s.id and status = 'going'),
        'remaining',
          (case
            when s.capacity is null then null
            else greatest(0,
              s.capacity - coalesce(
                (select count(*) from public.special_interactions
                  where special_id = s.id and status = 'going'),
                0))
          end),
        'lifecycle', (
          case
            when coalesce(s.submission_status, 'approved') = 'pending'  then 'pending'
            when coalesce(s.submission_status, 'approved') = 'rejected' then 'rejected'
            when coalesce(s.submission_status, 'approved') = 'draft'    then 'draft'
            when not coalesce(s.active, true) then 'inactive'
            when v_now < s.start_date then 'upcoming'
            when v_now > s.end_date then 'ended'
            else 'active'
          end
        ),
        'visits_count',
          (select count(*) from public.special_visits where special_id = s.id),
        'unique_visitors',
          (select count(distinct user_id) from public.special_visits where special_id = s.id),
        'interested_count',
          (select count(*) from public.special_interactions where special_id = s.id and status = 'interested'),
        'going_count',
          (select count(*) from public.special_interactions where special_id = s.id and status = 'going'),
        'attended_count',
          (select count(*) from public.special_interactions where special_id = s.id and status = 'attended'),
        'upvotes',
          (select count(*) from public.special_interactions where special_id = s.id and vote = 'up'),
        'downvotes',
          (select count(*) from public.special_interactions where special_id = s.id and vote = 'down'),
        'rating_avg',
          (select round(avg(rating)::numeric, 2) from public.special_interactions
            where special_id = s.id and rating is not null),
        'rating_count',
          (select count(*) from public.special_interactions
            where special_id = s.id and rating is not null),
        'avg_ratings', (
          select jsonb_build_object(
            'value',         round(avg(rating_value)::numeric,         2),
            'vibe',          round(avg(rating_vibe)::numeric,          2),
            'experience',    round(avg(rating_experience)::numeric,    2),
            'organisation',  round(avg(rating_organisation)::numeric,  2),
            'taste',         round(avg(rating_taste)::numeric,         2),
            'portions',      round(avg(rating_portions)::numeric,      2),
            'presentation',  round(avg(rating_presentation)::numeric,  2),
            'drinks',        round(avg(rating_drinks)::numeric,        2)
          )
          from public.special_interactions where special_id = s.id
        ),
        'top_tags', (
          select coalesce(
            jsonb_agg(jsonb_build_object('tag', tag, 'count', n) order by n desc),
            '[]'::jsonb)
          from (
            select tag, count(*) as n
            from (
              select unnest(quick_tags) as tag
              from public.special_interactions
              where special_id = s.id
            ) tags
            where tag is not null and tag <> ''
            group by tag
            order by count(*) desc
            limit 6
          ) t
        )
      ) order by
          (case when coalesce(s.submission_status, 'approved') = 'pending' then -1
                when coalesce(s.active, true) = true and v_now between s.start_date and s.end_date then 0
                when coalesce(s.active, true) = true and v_now < s.start_date then 1
                else 2 end),
          s.priority desc nulls last,
          s.start_date desc
      ), '[]'::jsonb)
      from public.specials s
      where s.place_id = v_place.id
    )
  );
end;
$$;


ALTER FUNCTION "public"."get_partner_specials_by_token"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_partner_vendor_directory"("p_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_event_id uuid;
begin
  select id into v_event_id
    from public.events
   where partner_access_token = p_token;

  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  return jsonb_build_object(
    'ok', true,
    'vendors', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'vendor_id',   v.id,
        'name',        v.name,
        'vendor_type', v.vendor_type,
        'description', v.description,
        -- Already linked to this event? The dropdown disables these.
        'on_event', exists (
          select 1 from public.event_vendors ev
           where ev.event_id = v_event_id and ev.vendor_id = v.id
        )
      ) order by v.name), '[]'::jsonb)
      from public.vendors v
    )
  );
end;
$$;


ALTER FUNCTION "public"."get_partner_vendor_directory"("p_token" "text") OWNER TO "postgres";


COMMENT ON FUNCTION "public"."get_partner_vendor_directory"("p_token" "text") IS 'Returns the vendor directory for the Add Vendor dropdown on the partner event dashboard, flagging vendors already linked to the event. Token-gated.';



CREATE TABLE IF NOT EXISTS "public"."partner_perks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "place_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "required_tier" "text" DEFAULT 'member'::"text" NOT NULL,
    "perk_type" "text" DEFAULT 'other'::"text" NOT NULL,
    "redemption_limit" integer,
    "active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "partner_perks_redemption_limit_check" CHECK ((("redemption_limit" IS NULL) OR ("redemption_limit" >= 0))),
    CONSTRAINT "partner_perks_required_tier_check" CHECK (("required_tier" = ANY (ARRAY['member'::"text", 'regular'::"text", 'insider'::"text", 'inner_circle'::"text"])))
);


ALTER TABLE "public"."partner_perks" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_perks_by_partner_token"("p_token" "text") RETURNS SETOF "public"."partner_perks"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select pk.*
  from public.partner_perks pk
  join public.places p on p.id = pk.place_id
  where p.partner_access_token = p_token
  order by pk.active desc, pk.created_at desc;
$$;


ALTER FUNCTION "public"."get_perks_by_partner_token"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_place_public"("_slug" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare r jsonb;
begin
  select to_jsonb(p) into r
  from places p
  where p.slug = _slug
  limit 1;

  return r;
end; $$;


ALTER FUNCTION "public"."get_place_public"("_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_place_rating"("p_user_id" "uuid", "p_place_id" "uuid") RETURNS numeric
    LANGUAGE "plpgsql"
    AS $$
DECLARE
  result numeric;
BEGIN
  SELECT 
    ROUND(
      (
        COALESCE(rating_vibe, 3) * 1.3 +
        COALESCE(rating_value, 3) * 1.2 +
        COALESCE(rating_service, 3) * 1.0 +
        COALESCE(rating_cleanliness, 3) * 0.8 +
        COALESCE(rating_wait_time, 3) * 0.7
      ) / 5.0,
      1
    )
  INTO result
  FROM visited_feedback
  WHERE user_id = p_user_id AND place_id = p_place_id;
  
  RETURN COALESCE(result, NULL);
END;
$$;


ALTER FUNCTION "public"."get_place_rating"("p_user_id" "uuid", "p_place_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_shared_itinerary"("_token" "text") RETURNS json
    LANGUAGE "plpgsql" SECURITY DEFINER
    AS $$
DECLARE
  result json;
BEGIN
  SELECT json_build_object(
    'itinerary', json_build_object(
      'id', i.id,
      'title', i.title,
      'destination', i.destination,
      'start_date', i.start_date,
      'end_date', i.end_date,
      'shared_by', i.user_id,
      'shared_by_name', u.username
    ),
    'places', (
      SELECT json_agg(
        json_build_object(
          'id', p.id, 'name', p.name, 'slug', p.slug,
          'description', p.description, 'category', p.category,
          'image', p.image, 'rating', p.rating, 'price_range', p.price_range,
          'town', p.town, 'parish', p.parish,
          'latitude', p.latitude, 'longitude', p.longitude,
          'visited', ip.visited, 'planned_day', ip.planned_day,
          'planned_time', ip.planned_time, 'time_slot', ip.time_slot,
          'order', ip.order, 'entry_id', ip.entry_id
        )
      )
      FROM itinerary_places ip
      JOIN places p ON p.id = ip.place_id
      WHERE ip.itinerary_id = i.id
    ),
    'events', (
      SELECT json_agg(
        json_build_object(
          'id', e.id,
          'name', e.title,
          'slug', e.slug,
          'image', e.featured_image_url,
          'image_urls', e.image_urls,
          'venue_name', e.venue_name,
          'planned_day', ie.planned_day,
          'time_slot', ie.time_slot,
          'order', ie."order",
          'entry_id', ie.entry_id,
          'is_event', true
        ) ORDER BY ie."order"
      )
      FROM itinerary_events ie
      JOIN events e ON e.id = ie.event_id
      WHERE ie.itinerary_id = i.id
    )
  )
  INTO result
  FROM itineraries i
  JOIN itinerary_shares s ON s.itinerary_id = i.id
  LEFT JOIN public."user" u ON u.id = i.user_id
  WHERE s.token = _token
  LIMIT 1;

  RETURN result;
END;
$$;


ALTER FUNCTION "public"."get_shared_itinerary"("_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_shared_itinerary_by_id"("_itinerary_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_it record;
  v_items jsonb;
begin
  select
    i.id, i.title, i.destination, i.start_date, i.end_date, i.slugs,
    (select p.full_name from profiles p where p.id = i.user_id limit 1) as owner_name
  into v_it
  from itineraries i
  where i.id = _itinerary_id
  limit 1;

  if not found then
    return null;
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',           p.id,
        'slug',         p.slug,
        'name',         coalesce(p.name, p.slug),
        'description',  p.description,
        'image', case when jsonb_typeof(to_jsonb(p.image)) = 'array'
                      then (to_jsonb(p.image)->>0)
                      else p.image::text end,
        'category',     p.category,
        'town',         p.town,
        'parish',       p.parish,
        'rating',       p.rating,
        'price_range',  p.price_range,
        'planned_day',  ip.planned_day,
        'planned_time', ip.planned_time,
        'visited',      coalesce(ip.visited, false),
        'order',        ip."order",
        'latitude',     p.latitude,
        'longitude',    p.longitude
      )
      order by
        case when ip.planned_day is null then 1 else 0 end,
        ip.planned_day   nulls last,
        ip.planned_time  nulls last,
        ip."order"       nulls last
    ),
    '[]'::jsonb
  )
  into v_items
  from itinerary_places ip
  join places           p  on p.id = ip.place_id
  where ip.itinerary_id = v_it.id;

  if v_items = '[]'::jsonb then
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'id',           p.id,
          'slug',         p.slug,
          'name',         coalesce(p.name, p.slug),
          'description',  p.description,
          'image', case when jsonb_typeof(to_jsonb(p.image)) = 'array'
                        then (to_jsonb(p.image)->>0)
                        else p.image::text end,
          'category',     p.category,
          'town',         p.town,
          'parish',       p.parish,
          'rating',       p.rating,
          'price_range',  p.price_range,
          'latitude',     p.latitude,
          'longitude',    p.longitude
        )
      ),
      '[]'::jsonb
    )
    into v_items
    from places p
    where p.slug = any (
      case
        when jsonb_typeof(v_it.slugs::jsonb) = 'array'
          then array(select jsonb_array_elements_text(v_it.slugs::jsonb))
        else string_to_array(coalesce(v_it.slugs::text,''), ',')
      end::text[]
    );
  end if;

  return jsonb_build_object(
    'itinerary_id', v_it.id,
    'title',        v_it.title,
    'destination',  v_it.destination,
    'start_date',   v_it.start_date,
    'end_date',     v_it.end_date,
    'owner_name',   v_it.owner_name,
    'items',        v_items
  );
end;
$$;


ALTER FUNCTION "public"."get_shared_itinerary_by_id"("_itinerary_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_trip_invite_preview"("_token" "uuid") RETURNS TABLE("trip_id" "uuid", "trip_title" "text", "trip_destination" "text", "trip_start_date" "date", "trip_end_date" "date", "invited_by" "uuid", "inviter_name" "text", "status" "text", "role" "text", "already_member" boolean, "expired" boolean, "is_owner" boolean)
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select
    i.id              as trip_id,
    i.title           as trip_title,
    i.destination     as trip_destination,
    i.start_date      as trip_start_date,
    i.end_date        as trip_end_date,
    tc.invited_by,
    coalesce(u.username, '')::text as inviter_name,
    tc.status,
    tc.role,
    (tc.invitee_id is not null and tc.invitee_id = auth.uid()) as already_member,
    (
      tc.status = 'pending'
      and tc.invite_expires_at is not null
      and tc.invite_expires_at < now()
    ) as expired,
    (i.user_id = auth.uid()) as is_owner
  from public.trip_collaborators tc
  join public.itineraries i on i.id = tc.trip_id
  left join public.user u on u.id = tc.invited_by
  where tc.invite_token = _token
  limit 1;
$$;


ALTER FUNCTION "public"."get_trip_invite_preview"("_token" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_achievements"("_user" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if _user is distinct from auth.uid() then
    return null;
  end if;

  return (
    with v as (
      select v.user_id, v.vote, v.created_at, v.notes, p.parish, p.cuisine
      from visited v
      left join places p on p.id = v.place_id
      where v.user_id = auth.uid()
    ),
    m as (
      select
        count(*) as month_count,
        (select cuisine from (
          select nullif(trim(cuisine),'') as cuisine, count(*) c
          from v
          where date_trunc('month', created_at) = date_trunc('month', now())
          group by 1
          having nullif(trim(cuisine),'') is not null
          order by c desc
          limit 1
        ) t) as top_cuisine
      from v
      where date_trunc('month', created_at) = date_trunc('month', now())
    ),
    agg as (
      select
        count(*)                                            as total_visited,
        count(*) filter (where vote = 'up')                 as liked,
        count(*) filter (where coalesce(trim(notes),'')<>'') as note_count
      from v
    ),
    parish_ct as (select count(distinct nullif(trim(parish),''))  as n from v),
    cuisine_ct as (select count(distinct nullif(trim(cuisine),'')) as n from v),
    fav as (select count(*) as n from favorites where user_id = auth.uid())
    select jsonb_build_object(
      'totalVisited', coalesce((select total_visited from agg),0),
      'liked',        coalesce((select liked         from agg),0),
      'noteCount',    coalesce((select note_count    from agg),0),
      'parishes',     coalesce((select n from parish_ct),0),
      'cuisines',     coalesce((select n from cuisine_ct),0),
      'favCount',     coalesce((select n from fav),0),
      'monthCount',   coalesce((select month_count from m),0),
      'monthCuisine', (select top_cuisine from m)
    )
  );
end;
$$;


ALTER FUNCTION "public"."get_user_achievements"("_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_ratings_batch"("p_user_id" "uuid") RETURNS TABLE("place_id" "uuid", "rating" numeric)
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  RETURN QUERY
  SELECT 
    vf.place_id,
    ROUND(
      (
        COALESCE(vf.rating_vibe, 3) * 1.3 +
        COALESCE(vf.rating_value, 3) * 1.2 +
        COALESCE(vf.rating_service, 3) * 1.0 +
        COALESCE(vf.rating_cleanliness, 3) * 0.8 +
        COALESCE(vf.rating_wait_time, 3) * 0.7
      ) / 5.0,
      1
    ) as rating
  FROM visited_feedback vf
  WHERE vf.user_id = p_user_id;
END;
$$;


ALTER FUNCTION "public"."get_user_ratings_batch"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_user_tier"("p_lifetime_xp" integer) RETURNS "text"
    LANGUAGE "plpgsql" IMMUTABLE
    AS $$

begin

  return case

    when p_lifetime_xp >= 10000 then 'Passport Elite'

    when p_lifetime_xp >= 5000 then 'Gold'

    when p_lifetime_xp >= 2500 then 'TasteMaker'

    when p_lifetime_xp >= 1000 then 'Insider'

    else 'Explorer'

  end;

end;

$$;


ALTER FUNCTION "public"."get_user_tier"("p_lifetime_xp" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."get_visit_summary"("_place" "uuid", "_user" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select jsonb_build_object(
    'visit_count',      coalesce(count(*), 0),
    'first_visited_at', min(visited_at),
    'last_visited_at',  max(visited_at)
  )
  from place_visit_events
  where user_id = coalesce(_user, auth.uid())
    and place_id = _place;
$$;


ALTER FUNCTION "public"."get_visit_summary"("_place" "uuid", "_user" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."handle_new_auth_user"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
begin
  insert into public."user" (id, email, created_at)
  values (new.id, new.email, now())
  on conflict (id) do nothing;
  return new;
end;
$$;


ALTER FUNCTION "public"."handle_new_auth_user"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."has_trip_access"("_trip_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select public.is_trip_owner(_trip_id) or public.is_trip_collaborator(_trip_id);
$$;


ALTER FUNCTION "public"."has_trip_access"("_trip_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."increment_event_going"("event_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
  UPDATE events SET going_count = going_count + 1 WHERE id = event_id;
END;
$$;


ALTER FUNCTION "public"."increment_event_going"("event_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."increment_event_interested"("event_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
  UPDATE events SET interested_count = interested_count + 1 WHERE id = event_id;
END;
$$;


ALTER FUNCTION "public"."increment_event_interested"("event_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."increment_feedback_upvote"("fid" "uuid") RETURNS "void"
    LANGUAGE "sql"
    AS $$
  update public.feedback
  set upvotes = coalesce(upvotes, 0) + 1
  where id = fid;
$$;


ALTER FUNCTION "public"."increment_feedback_upvote"("fid" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."invoke_notify_partner_booking"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_project_url text;
  v_service_key text;
begin
  -- Notifications are best-effort: this trigger must NEVER roll back the
  -- booking insert. If the vault secrets aren't configured (e.g. this is being
  -- applied to an environment that never set them), or pg_net errors, we skip
  -- the call and let the booking succeed.
  select decrypted_secret into v_project_url
  from vault.decrypted_secrets where name = 'project_url';
  select decrypted_secret into v_service_key
  from vault.decrypted_secrets where name = 'service_role_key';

  if v_project_url is null or v_service_key is null then
    return new;
  end if;

  begin
    perform net.http_post(
      url := v_project_url || '/functions/v1/notify-partner-booking',
      headers := jsonb_build_object(
        'Content-Type', 'application/json',
        'Authorization', 'Bearer ' || v_service_key
      ),
      body := jsonb_build_object('record', to_jsonb(new))
    );
  exception when others then
    -- swallow: a notification failure can't break the booking
    null;
  end;

  return new;
end;
$$;


ALTER FUNCTION "public"."invoke_notify_partner_booking"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_trip_collaborator"("_trip_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1
    from public.trip_collaborators
    where trip_id = _trip_id
      and invitee_id = auth.uid()
      and status = 'accepted'
  );
$$;


ALTER FUNCTION "public"."is_trip_collaborator"("_trip_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."is_trip_owner"("_trip_id" "uuid") RETURNS boolean
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select exists (
    select 1
    from public.itineraries
    where id = _trip_id
      and user_id = auth.uid()
  );
$$;


ALTER FUNCTION "public"."is_trip_owner"("_trip_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_event_map_invites"("p_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_event_id uuid;
begin
  select id into v_event_id
    from public.events
   where partner_access_token = p_token;
  if v_event_id is null then return null; end if;

  return (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'token',          token,
        'designer_name',  designer_name,
        'designer_email', designer_email,
        'scopes',         to_jsonb(scopes),
        'expires_at',     expires_at,
        'used_at',        used_at,
        'created_at',     created_at
      )
      order by created_at desc
    ), '[]'::jsonb)
    from public.event_map_invites
    where event_id = v_event_id
      and revoked_at is null
      and expires_at > now()
  );
end;
$$;


ALTER FUNCTION "public"."list_event_map_invites"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."list_partner_closures"("p_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place places%rowtype;
begin
  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;

  return jsonb_build_object(
    'ok', true,
    'closures', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',            id,
        'date',          date,
        'is_closed',     is_closed,
        'open_time',     open_time,
        'close_time',    close_time,
        'kitchen_open',  kitchen_open,
        'kitchen_close', kitchen_close,
        'reason',        reason
      ) order by date), '[]'::jsonb)
      from public.place_special_hours
      where place_id = v_place.id
        and date >= current_date - interval '7 days'
    )
  );
end;
$$;


ALTER FUNCTION "public"."list_partner_closures"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."next_invoice_number"() RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."next_invoice_number"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."normalize_quick_tags"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF NEW.quick_tags IS NOT NULL THEN
    NEW.quick_tags = (
      SELECT ARRAY_AGG(
        LOWER(
          TRIM(REGEXP_REPLACE(tag, '[^a-zA-Z0-9 ]', '', 'g'))
        )
      )
      FROM unnest(NEW.quick_tags) tag
    );
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."normalize_quick_tags"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."partner_get_billing_profile"("p_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_company_id uuid;
  v_c          company_accounts%rowtype;
begin
  if p_token is null or length(trim(p_token)) = 0 then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  v_company_id := public._partner_token_company_id(p_token);
  if v_company_id is null then
    -- Either the token is bad, or the listing has no company billing
    -- account yet. The caller (page) treats no_company as "set up needed".
    return jsonb_build_object('ok', false, 'error', 'no_company',
      'message', 'This listing is not attached to a TRODDR company billing account yet.');
  end if;

  select * into v_c from public.company_accounts where id = v_company_id;

  return jsonb_build_object(
    'ok', true,
    'profile', jsonb_build_object(
      'business_name',  coalesce(nullif(v_c.legal_name, ''), v_c.name),
      'trading_name',   v_c.trading_name,
      'contact_name',   v_c.contact_name,
      'billing_email',  v_c.billing_email,
      'billing_phone',  coalesce(nullif(v_c.billing_phone, ''), v_c.contact_phone),
      'address',        v_c.address,
      'country',        v_c.country,
      'tax_id',         v_c.tax_id,
      'preferred_currency', coalesce(v_c.preferred_currency, 'USD')
    )
  );
end;
$$;


ALTER FUNCTION "public"."partner_get_billing_profile"("p_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."partner_update_billing_profile"("p_token" "text", "p_info" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_company_id uuid;
  v_business   text;
  v_email      text;
  v_currency   text;
begin
  if p_token is null or length(trim(p_token)) = 0 then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;

  v_company_id := public._partner_token_company_id(p_token);
  if v_company_id is null then
    return jsonb_build_object('ok', false, 'error',
      'This listing is not attached to a TRODDR company billing account yet. Email billing@troddr.com to get set up.');
  end if;

  -- Validation (mirrors the authenticated onboarding flow).
  v_business := nullif(trim(coalesce(p_info ->> 'business_name', '')), '');
  if v_business is null then
    return jsonb_build_object('ok', false, 'error', 'Registered business name is required.');
  end if;

  v_email := lower(nullif(trim(coalesce(p_info ->> 'billing_email', '')), ''));
  if v_email is null or position('@' in v_email) = 0 then
    return jsonb_build_object('ok', false, 'error', 'A valid billing email is required.');
  end if;

  v_currency := upper(coalesce(nullif(trim(coalesce(p_info ->> 'preferred_currency', '')), ''), 'USD'));
  if v_currency not in ('USD', 'JMD') then
    return jsonb_build_object('ok', false, 'error', 'Preferred currency must be USD or JMD.');
  end if;

  update public.company_accounts
     set name               = v_business,   -- display/account name shown on invoices
         legal_name         = v_business,
         trading_name       = nullif(trim(coalesce(p_info ->> 'trading_name', '')), ''),
         contact_name       = nullif(trim(coalesce(p_info ->> 'contact_name', '')), ''),
         billing_email      = v_email,
         billing_phone      = nullif(trim(coalesce(p_info ->> 'billing_phone', '')), ''),
         address            = nullif(trim(coalesce(p_info ->> 'address', '')), ''),
         country            = nullif(trim(coalesce(p_info ->> 'country', '')), ''),
         tax_id             = nullif(trim(coalesce(p_info ->> 'tax_id', '')), ''),
         preferred_currency = v_currency,
         updated_at         = now()
   where id = v_company_id;

  perform public._billing_audit('system', 'partner dashboard', v_company_id,
    'partner_billing_info_changed',
    jsonb_build_object(
      'channel', 'partner_link',
      'business_name', v_business,
      'billing_email', v_email,
      'preferred_currency', v_currency));

  return jsonb_build_object('ok', true, 'message', 'Billing details saved.');
end;
$$;


ALTER FUNCTION "public"."partner_update_billing_profile"("p_token" "text", "p_info" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."partner_update_booking"("p_partner_token" "text", "p_booking_id" "uuid", "p_action" "text" DEFAULT NULL::"text", "p_data" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place      places%rowtype;
  v_booking    bookings%rowtype;
  v_new_status text;
begin
  select * into v_place from public.places where partner_access_token = p_partner_token;
  if v_place.id is null then
    return jsonb_build_object('error', 'invalid_token');
  end if;

  select * into v_booking from public.bookings
   where id = p_booking_id and place_id = v_place.id;
  if v_booking.id is null then
    return jsonb_build_object('error', 'booking_not_found');
  end if;

  v_new_status := case p_action
    when 'confirm'          then 'confirmed'
    when 'decline'          then 'declined'
    when 'counter'          then 'counter_proposed'
    when 'cancel'           then 'cancelled_by_partner'
    when 'mark_no_show'     then 'no_show'
    when 'mark_completed'   then 'completed'
    when 'mark_checked_in'  then 'checked_in'
    when 'mark_checked_out' then 'checked_out'
    else null
  end;

  update public.bookings set
    status                       = coalesce(v_new_status,                              status),
    partner_message              = coalesce(p_data->>'message',                        partner_message),
    counter_date                 = coalesce((p_data->>'counter_date')::date,           counter_date),
    counter_time                 = coalesce(p_data->>'counter_time',                   counter_time),
    supplier_confirmation_number = coalesce(p_data->>'supplier_confirmation_number',   supplier_confirmation_number),
    partner_internal_notes       = coalesce(p_data->>'partner_internal_notes',         partner_internal_notes),
    total_quoted                 = coalesce((p_data->>'total_quoted')::numeric,        total_quoted),
    final_total                  = coalesce((p_data->>'final_total')::numeric,         final_total),
    nightly_rate                 = coalesce((p_data->>'nightly_rate')::numeric,        nightly_rate),
    total_nights                 = coalesce((p_data->>'total_nights')::integer,        total_nights),
    taxes_amount                 = coalesce((p_data->>'taxes_amount')::numeric,        taxes_amount),
    fees_amount                  = coalesce((p_data->>'fees_amount')::numeric,         fees_amount),
    quoted_currency              = coalesce(p_data->>'quoted_currency',                quoted_currency),
    deposit_required             = coalesce((p_data->>'deposit_required')::boolean,    deposit_required),
    deposit_amount               = coalesce((p_data->>'deposit_amount')::numeric,      deposit_amount),
    deposit_currency             = coalesce(p_data->>'deposit_currency',               deposit_currency),
    deposit_due_at               = coalesce((p_data->>'deposit_due_at')::timestamptz,  deposit_due_at),
    payment_instructions         = coalesce(p_data->>'payment_instructions',           payment_instructions),
    manual_payment_status        = coalesce(p_data->>'manual_payment_status',          manual_payment_status),
    payment_reference            = coalesce(p_data->>'payment_reference',              payment_reference),
    room_type_id                 = coalesce((p_data->>'room_type_id')::uuid,           room_type_id),
    rate_plan_id                 = coalesce((p_data->>'rate_plan_id')::uuid,           rate_plan_id),
    rooms_requested              = coalesce((p_data->>'rooms_requested')::integer,     rooms_requested),
    cancelled_by                 = case when p_action = 'cancel' then 'partner' else cancelled_by end,
    cancellation_reason          = coalesce(p_data->>'cancellation_reason',            cancellation_reason),
    needs_troddr_attention       = coalesce((p_data->>'needs_troddr_attention')::boolean, needs_troddr_attention),
    updated_at                   = now()
  where id = p_booking_id;

  -- Stamp actor info on the timeline row the trigger already inserted
  if v_new_status is not null then
    update public.booking_timeline_events
       set actor_type  = 'partner',
           actor_email = p_data->>'responder_email',
           message     = p_data->>'message'
     where booking_id = p_booking_id
       and new_status  = v_new_status
       and actor_type  = 'system'
       and created_at  = (
         select max(created_at) from public.booking_timeline_events
          where booking_id = p_booking_id and new_status = v_new_status
       );
  else
    -- Non-status update — log as a partner note
    insert into public.booking_timeline_events (
      booking_id, old_status, new_status, actor_type, actor_email, message
    ) values (
      p_booking_id,
      v_booking.status, v_booking.status,
      'partner',
      p_data->>'responder_email',
      coalesce(p_data->>'message', 'Booking details updated')
    );
  end if;

  return jsonb_build_object(
    'ok',         true,
    'booking_id', p_booking_id,
    'new_status', coalesce(v_new_status, v_booking.status)
  );
end;
$$;


ALTER FUNCTION "public"."partner_update_booking"("p_partner_token" "text", "p_booking_id" "uuid", "p_action" "text", "p_data" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."payment_instructions_for_currency"("p_currency" "text") RETURNS "jsonb"
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."payment_instructions_for_currency"("p_currency" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."populate_booking_guest_snapshot"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if new.share_profile is true and new.guest_profile_snapshot is null then
    begin
      new.guest_profile_snapshot :=
        public.build_guest_profile_snapshot(new.user_id, new.place_id);
    exception when others then
      new.guest_profile_snapshot := null;  -- never block the booking
    end;
  end if;
  return new;
end;
$$;


ALTER FUNCTION "public"."populate_booking_guest_snapshot"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_duplicate_visits"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM visited
    WHERE user_id = NEW.user_id
      AND place_id = NEW.place_id
      AND created_at >= NOW() - INTERVAL '1 hour'
  ) THEN
    RAISE EXCEPTION 'Visit already logged within the last hour';
  END IF;

  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."prevent_duplicate_visits"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."prevent_xp_transaction_mutation"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$

begin

  raise exception 'xp_transactions is an immutable append-only ledger. Use reversal or adjustment transactions instead.';

end;

$$;


ALTER FUNCTION "public"."prevent_xp_transaction_mutation"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."propose_delete_item"("_trip_id" "uuid", "_target_entity_type" "text", "_target_entry_id" "uuid", "_payload" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "uuid"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_proposer uuid := auth.uid();
  v_is_owner boolean;
  v_other_count integer;
  v_request_id uuid;
begin
  if v_proposer is null then
    raise exception 'must be signed in';
  end if;

  if not public.has_trip_access(_trip_id) then
    raise exception 'no access to this trip';
  end if;

  if _target_entity_type not in ('place', 'event') then
    raise exception 'invalid target_entity_type';
  end if;

  v_is_owner := public.is_trip_owner(_trip_id);
  v_other_count := public.trip_other_voter_count(_trip_id, v_proposer);

  -- Solo trips and owner-initiated deletes skip the request flow entirely.
  -- We still record the request row for audit, marking it 'applied'.
  if v_is_owner or v_other_count = 0 then
    if _target_entity_type = 'place' then
      delete from public.itinerary_places where entry_id = _target_entry_id;
    else
      delete from public.itinerary_events where entry_id = _target_entry_id;
    end if;

    insert into public.trip_change_requests (
      trip_id, proposed_by, change_type, target_entity_type, target_entry_id, payload, status, resolved_at
    ) values (
      _trip_id, v_proposer, 'delete_item', _target_entity_type, _target_entry_id, _payload, 'applied', now()
    )
    returning id into v_request_id;

    return v_request_id;
  end if;

  -- Otherwise create a pending request and wait for votes.
  insert into public.trip_change_requests (
    trip_id, proposed_by, change_type, target_entity_type, target_entry_id, payload, status
  ) values (
    _trip_id, v_proposer, 'delete_item', _target_entity_type, _target_entry_id, _payload, 'pending'
  )
  returning id into v_request_id;

  return v_request_id;
end $$;


ALTER FUNCTION "public"."propose_delete_item"("_trip_id" "uuid", "_target_entity_type" "text", "_target_entry_id" "uuid", "_payload" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."recalculate_user_xp"("p_user_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$

declare

  v_lifetime_xp integer;

  v_tier text;

begin

  select coalesce(sum(xp_amount), 0)

  into v_lifetime_xp

  from public.xp_transactions

  where user_id = p_user_id;

  v_tier := public.get_user_tier(v_lifetime_xp);

  insert into public.user_stats (

    user_id,

    lifetime_xp,

    tier_points,

    tier,

    updated_at

  )

  values (

    p_user_id,

    v_lifetime_xp,

    v_lifetime_xp,

    v_tier,

    now()

  )

  on conflict (user_id)

  do update set

    lifetime_xp = excluded.lifetime_xp,

    tier_points = excluded.tier_points,

    tier = excluded.tier,

    updated_at = now();

end;

$$;


ALTER FUNCTION "public"."recalculate_user_xp"("p_user_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."record_loyalty_redemption_by_token"("p_token" "text", "p_card_id" "uuid", "p_redeemed_by" "text" DEFAULT NULL::"text", "p_notes" "text" DEFAULT NULL::"text", "p_source" "text" DEFAULT 'partner_dashboard'::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place_id uuid;
  v_program loyalty_programs%rowtype;
  v_card user_loyalty_cards%rowtype;
  v_redemption loyalty_redemptions%rowtype;
begin
  select id
    into v_place_id
    from public.places
   where partner_access_token = p_token;

  if v_place_id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid partner token');
  end if;

  select *
    into v_program
    from public.loyalty_programs
   where place_id = v_place_id
     and is_active = true
   order by created_at desc
   limit 1;

  if v_program.id is null then
    return jsonb_build_object('ok', false, 'error', 'No active loyalty program found');
  end if;

  select *
    into v_card
    from public.user_loyalty_cards
   where id = p_card_id
     and program_id = v_program.id
   for update;

  if v_card.id is null then
    return jsonb_build_object('ok', false, 'error', 'Card not found for this program');
  end if;

  if v_card.current_stamps < v_program.required_stamps then
    return jsonb_build_object('ok', false, 'error', 'This card does not have enough stamps to redeem');
  end if;

  if p_source not in ('app', 'partner_dashboard', 'staff', 'migration', 'other') then
    p_source := 'other';
  end if;

  insert into public.loyalty_redemptions (
    program_id, card_id, place_id, user_id, reward, stamps_spent,
    cycle_number, source, redeemed_by, notes
  )
  values (
    v_program.id,
    v_card.id,
    v_place_id,
    v_card.user_id,
    coalesce(v_program.reward, 'Reward'),
    v_program.required_stamps,
    coalesce(v_card.completed_cycles, 0) + 1,
    p_source,
    nullif(trim(p_redeemed_by), ''),
    nullif(trim(p_notes), '')
  )
  returning * into v_redemption;

  update public.user_loyalty_cards
     set current_stamps   = greatest(current_stamps - v_program.required_stamps, 0),
         completed_cycles = coalesce(completed_cycles, 0) + 1,
         is_redeemed      = false
   where id = v_card.id
   returning * into v_card;

  return jsonb_build_object(
    'ok', true,
    'redemption', jsonb_build_object(
      'id',           v_redemption.id,
      'card_id',      v_redemption.card_id,
      'user_id',      v_redemption.user_id,
      'reward',       v_redemption.reward,
      'stamps_spent', v_redemption.stamps_spent,
      'cycle_number', v_redemption.cycle_number,
      'source',       v_redemption.source,
      'redeemed_by',  v_redemption.redeemed_by,
      'notes',        v_redemption.notes,
      'redeemed_at',  v_redemption.redeemed_at
    ),
    'card', jsonb_build_object(
      'card_id',          v_card.id,
      'user_id',          v_card.user_id,
      'current_stamps',   v_card.current_stamps,
      'completed_cycles', v_card.completed_cycles,
      'is_redeemed',      v_card.is_redeemed,
      'last_stamped_at',  v_card.last_stamped_at,
      'created_at',       v_card.created_at
    )
  );
end;
$$;


ALTER FUNCTION "public"."record_loyalty_redemption_by_token"("p_token" "text", "p_card_id" "uuid", "p_redeemed_by" "text", "p_notes" "text", "p_source" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."perk_redemptions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "perk_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "place_id" "uuid",
    "booking_id" "uuid",
    "checkin_id" "uuid",
    "redeemed_by_partner_user_id" "text",
    "redeemed_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."perk_redemptions" OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."redeem_perk_by_partner_token"("p_token" "text", "p_perk_id" "uuid", "p_user_id" "uuid", "p_booking_id" "uuid" DEFAULT NULL::"uuid", "p_checkin_id" "uuid" DEFAULT NULL::"uuid", "p_redeemed_by" "text" DEFAULT NULL::"text") RETURNS "public"."perk_redemptions"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place_id uuid;
  v_limit    integer;
  v_count    integer;
  result     public.perk_redemptions;
begin
  -- Token must own the place the perk belongs to.
  select pk.place_id, pk.redemption_limit
    into v_place_id, v_limit
  from public.partner_perks pk
  join public.places p on p.id = pk.place_id
  where pk.id = p_perk_id
    and p.partner_access_token = p_token
  limit 1;

  if v_place_id is null then
    raise exception 'Perk not found for this partner';
  end if;

  if v_limit is not null then
    select count(*) into v_count
    from public.perk_redemptions
    where perk_id = p_perk_id;

    if v_count >= v_limit then
      raise exception 'Perk redemption limit reached';
    end if;
  end if;

  insert into public.perk_redemptions
    (perk_id, user_id, place_id, booking_id, checkin_id,
     redeemed_by_partner_user_id)
  values
    (p_perk_id, p_user_id, v_place_id, p_booking_id, p_checkin_id, p_redeemed_by)
  returning * into result;

  return result;
end;
$$;


ALTER FUNCTION "public"."redeem_perk_by_partner_token"("p_token" "text", "p_perk_id" "uuid", "p_user_id" "uuid", "p_booking_id" "uuid", "p_checkin_id" "uuid", "p_redeemed_by" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."release_inventory_hold"("p_hold_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  update public.hotel_inventory_holds
     set released_at = now()
   where id = p_hold_id and released_at is null;
  return jsonb_build_object('ok', found);
end;
$$;


ALTER FUNCTION "public"."release_inventory_hold"("p_hold_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."reserve_special_billing"("p_place_id" "uuid", "p_special_id" "uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."reserve_special_billing"("p_place_id" "uuid", "p_special_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."resolve_event_map_invite"("p_invite_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_inv  public.event_map_invites%rowtype;
  v_evt  public.events%rowtype;
begin
  select * into v_inv from public.event_map_invites where token = p_invite_token;
  if v_inv.token is null then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  if v_inv.revoked_at is not null then
    return jsonb_build_object('ok', false, 'error', 'revoked');
  end if;
  if v_inv.expires_at <= now() then
    return jsonb_build_object('ok', false, 'error', 'expired');
  end if;

  select * into v_evt from public.events where id = v_inv.event_id;

  -- Mark first-use only
  if v_inv.used_at is null then
    update public.event_map_invites set used_at = now() where token = p_invite_token;
  end if;

  return jsonb_build_object(
    'ok', true,
    'event', jsonb_build_object(
      'id',                  v_evt.id,
      'slug',                v_evt.slug,
      'title',               v_evt.title,
      'floor_plan_url',      v_evt.floor_plan_url,
      'floor_plan_markers',  coalesce(v_evt.floor_plan_markers, '[]'::jsonb)
    ),
    'scopes', to_jsonb(v_inv.scopes),
    'expires_at', v_inv.expires_at,
    'vendors', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'event_vendor_id', ev.id,
        'vendor_id',       v.id,
        'vendor_name',     coalesce(nullif(btrim(ev.display_name), ''), v.name)
      ) order by coalesce(nullif(btrim(ev.display_name), ''), v.name)), '[]'::jsonb)
      from public.event_vendors ev
      join public.vendors v on v.id = ev.vendor_id
      where ev.event_id = v_evt.id
    )
  );
end;
$$;


ALTER FUNCTION "public"."resolve_event_map_invite"("p_invite_token" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bookings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "token" "text" DEFAULT "encode"("extensions"."gen_random_bytes"(16), 'hex'::"text") NOT NULL,
    "booking_type" "text" NOT NULL,
    "place_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "visit_date" "date" NOT NULL,
    "visit_time" "text",
    "checkout_date" "date",
    "party_size" integer DEFAULT 1 NOT NULL,
    "guest_name" "text" NOT NULL,
    "guest_phone" "text",
    "guest_email" "text" NOT NULL,
    "notes" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "partner_message" "text",
    "proposed_visit_date" "date",
    "proposed_visit_time" "text",
    "responded_at" timestamp with time zone,
    "responded_by" "text",
    "total_quoted" numeric,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "feedback_requested_at" timestamp with time zone,
    "room_type_id" "uuid",
    "rate_plan_id" "uuid",
    "rooms_requested" integer DEFAULT 1 NOT NULL,
    "adults" integer,
    "children" integer DEFAULT 0 NOT NULL,
    "hold_id" "uuid",
    "nightly_rate" numeric(12,2),
    "total_nights" integer,
    "quoted_currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "taxes_amount" numeric(12,2),
    "fees_amount" numeric(12,2),
    "discount_amount" numeric(12,2),
    "final_total" numeric(12,2),
    "deposit_required" boolean DEFAULT false NOT NULL,
    "deposit_amount" numeric(12,2),
    "deposit_currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "deposit_due_at" timestamp with time zone,
    "payment_instructions" "text",
    "manual_payment_status" "text" DEFAULT 'not_required'::"text" NOT NULL,
    "payment_reference" "text",
    "partner_internal_notes" "text",
    "internal_notes" "text",
    "cancelled_by" "text",
    "cancellation_reason" "text",
    "expires_at" timestamp with time zone,
    "needs_troddr_attention" boolean DEFAULT false NOT NULL,
    "attention_reason" "text",
    "counter_date" "date",
    "counter_time" "text",
    "supplier_confirmation_number" "text",
    "share_profile" boolean DEFAULT false NOT NULL,
    "guest_profile_snapshot" "jsonb",
    "occasion" "text",
    "special_id" "uuid",
    "waitlist_position" integer,
    "agency_name" "text",
    "iata_tids_number" "text",
    "commission_terms" "text",
    "commission_status" "text" DEFAULT 'not_applicable'::"text" NOT NULL,
    "commission_amount_expected" numeric,
    "commission_payment_reference" "text",
    "booking_request_payload" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "bookings_booking_type_check" CHECK (("booking_type" = ANY (ARRAY['day_pass'::"text", 'restaurant'::"text", 'stay'::"text", 'activity'::"text", 'special'::"text"]))),
    CONSTRAINT "bookings_checkout_after_visit" CHECK ((("checkout_date" IS NULL) OR ("checkout_date" >= "visit_date"))),
    CONSTRAINT "bookings_commission_status_check" CHECK (("commission_status" = ANY (ARRAY['not_applicable'::"text", 'pending_attribution'::"text", 'attributed'::"text", 'payable'::"text", 'paid'::"text", 'disputed'::"text"]))),
    CONSTRAINT "bookings_manual_payment_status_check" CHECK (("manual_payment_status" = ANY (ARRAY['not_required'::"text", 'requested'::"text", 'received'::"text", 'refunded'::"text", 'disputed'::"text"]))),
    CONSTRAINT "bookings_party_size_check" CHECK (("party_size" >= 1)),
    CONSTRAINT "bookings_special_requires_special_id" CHECK (((("booking_type" = 'special'::"text") AND ("special_id" IS NOT NULL)) OR (("booking_type" <> 'special'::"text") AND ("special_id" IS NULL)))),
    CONSTRAINT "bookings_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'held'::"text", 'confirmed'::"text", 'declined'::"text", 'counter_proposed'::"text", 'counter_accepted'::"text", 'counter_rejected'::"text", 'cancelled'::"text", 'cancelled_by_guest'::"text", 'cancelled_by_partner'::"text", 'expired'::"text", 'no_show'::"text", 'checked_in'::"text", 'checked_out'::"text", 'completed'::"text"]))),
    CONSTRAINT "bookings_stay_requires_checkout" CHECK ((("booking_type" <> 'stay'::"text") OR ("checkout_date" IS NOT NULL)))
);


ALTER TABLE "public"."bookings" OWNER TO "postgres";


COMMENT ON COLUMN "public"."bookings"."supplier_confirmation_number" IS 'Hotel or booking-engine confirmation number once the property confirms.';



COMMENT ON COLUMN "public"."bookings"."special_id" IS 'Set when booking_type = ''special''. Points to the specials row the reservation is for. Cascades on special delete (rare — usually deactivated instead).';



COMMENT ON COLUMN "public"."bookings"."waitlist_position" IS 'NULL for confirmed-or-pending reservations within capacity. Positive integer = position on the waitlist (1 = next in line). Assigned at insert time based on capacity vs. existing active bookings.';



COMMENT ON COLUMN "public"."bookings"."agency_name" IS 'Travel seller name sent to the hotel for commission attribution.';



COMMENT ON COLUMN "public"."bookings"."iata_tids_number" IS 'TRODDR IATA/TIDS identifier sent to the hotel for commission attribution.';



COMMENT ON COLUMN "public"."bookings"."commission_terms" IS 'Commission terms expected for this specific request, copied from the property/default at booking time.';



COMMENT ON COLUMN "public"."bookings"."commission_status" IS 'Reconciliation state for commission on this booking.';



COMMENT ON COLUMN "public"."bookings"."booking_request_payload" IS 'Structured request details that do not deserve first-class columns yet, such as room count, room preference, children, arrival time, and availability source.';



CREATE OR REPLACE FUNCTION "public"."respond_to_booking"("p_token" "text", "p_status" "text", "p_message" "text" DEFAULT NULL::"text", "p_proposed_date" "date" DEFAULT NULL::"date", "p_proposed_time" "text" DEFAULT NULL::"text", "p_responder_email" "text" DEFAULT NULL::"text") RETURNS "public"."bookings"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  result public.bookings;
begin
  if p_status not in ('confirmed', 'declined', 'counter_proposed') then
    raise exception 'Invalid partner status: %', p_status;
  end if;

  if p_status = 'counter_proposed' and p_proposed_date is null then
    raise exception 'counter_proposed requires a proposed_date';
  end if;

  update public.bookings
     set status              = p_status,
         partner_message     = coalesce(p_message, partner_message),
         proposed_visit_date = case when p_status = 'counter_proposed'
                                    then p_proposed_date
                                    else proposed_visit_date end,
         proposed_visit_time = case when p_status = 'counter_proposed'
                                    then p_proposed_time
                                    else proposed_visit_time end,
         responded_at        = now(),
         responded_by        = p_responder_email,
         updated_at          = now()
   where token = p_token
     and status in ('pending', 'counter_proposed')
  returning * into result;

  if result.id is null then
    raise exception 'Booking not found, or already finalized';
  end if;

  return result;
end;
$$;


ALTER FUNCTION "public"."respond_to_booking"("p_token" "text", "p_status" "text", "p_message" "text", "p_proposed_date" "date", "p_proposed_time" "text", "p_responder_email" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."revoke_event_map_invite"("p_token" "text", "p_invite_token" "text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_event_id uuid;
begin
  select id into v_event_id
    from public.events
   where partner_access_token = p_token;
  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  update public.event_map_invites
     set revoked_at = now()
   where token = p_invite_token
     and event_id = v_event_id;

  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "public"."revoke_event_map_invite"("p_token" "text", "p_invite_token" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."revoke_itinerary_share"("_itinerary_id" "uuid") RETURNS "void"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_owner uuid;
begin
  select user_id into v_owner
  from public.itineraries
  where id = _itinerary_id;

  if v_owner is null or v_owner <> auth.uid() then
    raise exception 'not owner';
  end if;

  -- Soft revoke by expiring now; keeps audit/history
  update public.itinerary_shares
  set expires_at = now()
  where itinerary_id = _itinerary_id
    and created_by   = auth.uid();
end;
$$;


ALTER FUNCTION "public"."revoke_itinerary_share"("_itinerary_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."search_stay_availability"("p_place_id" "uuid", "p_check_in" "date", "p_check_out" "date", "p_adults" integer DEFAULT 2, "p_children" integer DEFAULT 0, "p_rooms" integer DEFAULT 1) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place   places%rowtype;
  v_nights  integer;
begin
  select * into v_place from public.places where id = p_place_id;
  if v_place.id is null then
    return jsonb_build_object('error', 'place_not_found');
  end if;

  v_nights := p_check_out - p_check_in;
  if v_nights <= 0 then
    return jsonb_build_object('error', 'invalid_dates');
  end if;
  if v_nights < coalesce(v_place.min_nights, 1) then
    return jsonb_build_object(
      'error',            'min_nights_not_met',
      'min_nights',       v_place.min_nights,
      'nights_requested', v_nights
    );
  end if;

  return jsonb_build_object(
    'place', jsonb_build_object(
      'id',                      v_place.id,
      'name',                    v_place.name,
      'booking_mode',            coalesce(v_place.booking_mode, 'request_only'),
      'min_nights',              coalesce(v_place.min_nights, 1),
      'check_in_time',           v_place.check_in_time,
      'check_out_time',          v_place.check_out_time,
      'cancellation_policy_text',v_place.cancellation_policy_text,
      'deposit_instructions',    v_place.deposit_instructions,
      'taxes_fees_notes',        v_place.taxes_fees_notes
    ),
    'search', jsonb_build_object(
      'check_in', p_check_in, 'check_out', p_check_out,
      'nights', v_nights, 'adults', p_adults,
      'children', p_children, 'rooms', p_rooms
    ),
    'room_types', (
      select coalesce(jsonb_agg(
        jsonb_build_object(
          'room_type',               row_to_json(rt.*),
          'fits_guests',             rt.max_guests >= (p_adults + p_children),
          'available_all_nights',   (
            select count(*) from public.hotel_availability av
             where av.room_type_id = rt.id
               and av.stay_date >= p_check_in and av.stay_date < p_check_out
               and av.is_closed = false and av.is_blackout = false
               and av.available_rooms >= p_rooms
               and (av.min_nights is null or v_nights >= av.min_nights)
          ) = v_nights,
          'nights_with_availability',(
            select count(*)::int from public.hotel_availability av
             where av.room_type_id = rt.id
               and av.stay_date >= p_check_in and av.stay_date < p_check_out
               and av.is_closed = false and av.is_blackout = false
               and av.available_rooms >= p_rooms
          ),
          'avg_nightly_rate', (
            select round(avg(av.base_nightly_rate)::numeric, 2)
              from public.hotel_availability av
             where av.room_type_id = rt.id
               and av.stay_date >= p_check_in and av.stay_date < p_check_out
               and av.base_nightly_rate is not null
          ),
          'estimated_total', (
            select round(sum(av.base_nightly_rate)::numeric, 2)
              from public.hotel_availability av
             where av.room_type_id = rt.id
               and av.stay_date >= p_check_in and av.stay_date < p_check_out
               and av.base_nightly_rate is not null
          ),
          'rate_plans', (
            select coalesce(jsonb_agg(row_to_json(rp.*) order by rp.created_at), '[]'::jsonb)
            from public.hotel_rate_plans rp
            where rp.room_type_id = rt.id and rp.is_active = true
          )
        ) order by rt.display_order, rt.name
      ), '[]'::jsonb)
      from public.hotel_room_types rt
      where rt.place_id = p_place_id and rt.is_active = true
        and rt.max_guests >= p_adults
    )
  );
end;
$$;


ALTER FUNCTION "public"."search_stay_availability"("p_place_id" "uuid", "p_check_in" "date", "p_check_out" "date", "p_adults" integer, "p_children" integer, "p_rooms" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."send_partner_message"("p_token" "text", "p_subject" "text", "p_message" "text", "p_source_page" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place      places%rowtype;
  v_event      events%rowtype;
  v_partner_id uuid;
  v_msg_id     uuid;
begin
  if p_message is null or length(trim(p_message)) = 0 then
    return jsonb_build_object('ok', false, 'error', 'Message is required');
  end if;
  if length(p_message) > 5000 then
    return jsonb_build_object('ok', false, 'error', 'Message is too long (5000 char max)');
  end if;

  -- Resolve token to a place or event
  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then
    select * into v_event from public.events where partner_access_token = p_token;
  end if;

  if v_place.id is null and v_event.id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;

  v_partner_id := coalesce(v_place.partner_id, v_event.partner_id);

  insert into public.partner_messages (
    partner_id, place_id, event_id,
    source_page, subject, message
  )
  values (
    v_partner_id,
    v_place.id,
    v_event.id,
    nullif(trim(coalesce(p_source_page, '')), ''),
    nullif(trim(coalesce(p_subject, '')), ''),
    trim(p_message)
  )
  returning id into v_msg_id;

  return jsonb_build_object('ok', true, 'id', v_msg_id);
end;
$$;


ALTER FUNCTION "public"."send_partner_message"("p_token" "text", "p_subject" "text", "p_message" "text", "p_source_page" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_bookings_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


ALTER FUNCTION "public"."set_bookings_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_partner_perks_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


ALTER FUNCTION "public"."set_partner_perks_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_place_checkin_settings_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


ALTER FUNCTION "public"."set_place_checkin_settings_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."set_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  new.updated_at = now();
  return new;
end;
$$;


ALTER FUNCTION "public"."set_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_billing_request"("p_request_type" "text", "p_message" "text" DEFAULT NULL::"text", "p_related_location_id" "uuid" DEFAULT NULL::"uuid", "p_related_event_id" "uuid" DEFAULT NULL::"uuid") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."submit_billing_request"("p_request_type" "text", "p_message" "text", "p_related_location_id" "uuid", "p_related_event_id" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_company_onboarding"("p_info" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."submit_company_onboarding"("p_info" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_company_setup_request"("p_info" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."submit_company_setup_request"("p_info" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_onboarding_profile"("p_profile" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."submit_onboarding_profile"("p_profile" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_onboarding_quote"("p_selection" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $_$
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
$_$;


ALTER FUNCTION "public"."submit_onboarding_quote"("p_selection" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_partner_special"("p_token" "text", "p_title" "text", "p_description" "text", "p_special_type" "text", "p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_start_time" time without time zone DEFAULT NULL::time without time zone, "p_end_time" time without time zone DEFAULT NULL::time without time zone, "p_image_url" "text" DEFAULT NULL::"text", "p_discount_percentage" numeric DEFAULT NULL::numeric, "p_discount_amount" numeric DEFAULT NULL::numeric, "p_price_amount" numeric DEFAULT NULL::numeric, "p_currency" "text" DEFAULT NULL::"text", "p_event_category" "text" DEFAULT NULL::"text", "p_tags" "text"[] DEFAULT NULL::"text"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place places%rowtype;
  v_special_id uuid;
  v_image_urls text[];
begin
  -- Validate
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

  -- Resolve token
  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;

  v_image_urls := case
    when p_image_url is null or length(trim(p_image_url)) = 0 then array[]::text[]
    else array[trim(p_image_url)]
  end;

  insert into public.specials (
    place_id, title, description, special_type,
    start_date, end_date, start_time, end_time,
    image_urls,
    discount_percentage, discount_amount,
    price_amount, currency,
    event_category, event_tags,
    active, submission_status,
    submitted_at, submitted_via, country, town, parish
  )
  values (
    v_place.id,
    trim(p_title),
    nullif(trim(coalesce(p_description, '')), ''),
    p_special_type,
    p_start_date, p_end_date,
    p_start_time, p_end_time,
    v_image_urls,
    p_discount_percentage,
    p_discount_amount,
    p_price_amount,
    coalesce(nullif(trim(coalesce(p_currency,'')), ''), 'JMD'),
    nullif(trim(coalesce(p_event_category, '')), ''),
    coalesce(p_tags, '{}'::text[]),
    false,                          -- not active until approved
    'pending',
    now(),
    'partner_dashboard',
    v_place.country, v_place.town, v_place.parish
  )
  returning id into v_special_id;

  return jsonb_build_object(
    'ok', true,
    'id', v_special_id,
    'status', 'pending',
    'message', 'Submitted for approval. We''ll review within 1 business day.'
  );
end;
$$;


ALTER FUNCTION "public"."submit_partner_special"("p_token" "text", "p_title" "text", "p_description" "text", "p_special_type" "text", "p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_start_time" time without time zone, "p_end_time" time without time zone, "p_image_url" "text", "p_discount_percentage" numeric, "p_discount_amount" numeric, "p_price_amount" numeric, "p_currency" "text", "p_event_category" "text", "p_tags" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_partner_special"("p_token" "text", "p_title" "text", "p_description" "text", "p_special_type" "text", "p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_start_time" time without time zone DEFAULT NULL::time without time zone, "p_end_time" time without time zone DEFAULT NULL::time without time zone, "p_image_url" "text" DEFAULT NULL::"text", "p_discount_percentage" numeric DEFAULT NULL::numeric, "p_discount_amount" numeric DEFAULT NULL::numeric, "p_price_amount" numeric DEFAULT NULL::numeric, "p_currency" "text" DEFAULT NULL::"text", "p_event_category" "text" DEFAULT NULL::"text", "p_tags" "text"[] DEFAULT NULL::"text"[], "p_capacity" integer DEFAULT NULL::integer, "p_recurring_days" "text"[] DEFAULT NULL::"text"[], "p_age_restriction" "text" DEFAULT NULL::"text", "p_host_name" "text" DEFAULT NULL::"text", "p_event_slug" "text" DEFAULT NULL::"text", "p_ticket_link" "text" DEFAULT NULL::"text", "p_rsvp_link" "text" DEFAULT NULL::"text", "p_image_urls" "text"[] DEFAULT NULL::"text"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."submit_partner_special"("p_token" "text", "p_title" "text", "p_description" "text", "p_special_type" "text", "p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_start_time" time without time zone, "p_end_time" time without time zone, "p_image_url" "text", "p_discount_percentage" numeric, "p_discount_amount" numeric, "p_price_amount" numeric, "p_currency" "text", "p_event_category" "text", "p_tags" "text"[], "p_capacity" integer, "p_recurring_days" "text"[], "p_age_restriction" "text", "p_host_name" "text", "p_event_slug" "text", "p_ticket_link" "text", "p_rsvp_link" "text", "p_image_urls" "text"[]) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."submit_payment_confirmation"("p_invoice_id" "uuid", "p_payment_method" "text", "p_paid_on" "date", "p_reference" "text", "p_receipt_path" "text" DEFAULT NULL::"text", "p_notes" "text" DEFAULT NULL::"text", "p_receipt_filename" "text" DEFAULT NULL::"text", "p_receipt_size_bytes" bigint DEFAULT NULL::bigint, "p_receipt_mime" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
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


ALTER FUNCTION "public"."submit_payment_confirmation"("p_invoice_id" "uuid", "p_payment_method" "text", "p_paid_on" "date", "p_reference" "text", "p_receipt_path" "text", "p_notes" "text", "p_receipt_filename" "text", "p_receipt_size_bytes" bigint, "p_receipt_mime" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."sync_vendor_place_slug"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
begin
  select slug into new.place_slug from places where id = new.place_id;
  return new;
end;
$$;


ALTER FUNCTION "public"."sync_vendor_place_slug"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_booking_timeline"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  if tg_op = 'INSERT' then
    insert into public.booking_timeline_events (
      booking_id, old_status, new_status, actor_type, message
    ) values (
      NEW.id, null, NEW.status, 'system', 'Booking created'
    );
  elsif tg_op = 'UPDATE' and NEW.status is distinct from OLD.status then
    insert into public.booking_timeline_events (
      booking_id, old_status, new_status, actor_type, message
    ) values (
      NEW.id, OLD.status, NEW.status, 'system', null
    );
  end if;
  return NEW;
end;
$$;


ALTER FUNCTION "public"."tg_booking_timeline"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_partner_message_email"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_context text;
begin
  -- Build a human-readable "from" line from partner / place / event
  select coalesce(
    (select p.name from public.partners p where p.id = NEW.partner_id),
    (select pl.name from public.places   pl where pl.id = NEW.place_id),
    (select ev.title from public.events  ev where ev.id = NEW.event_id),
    'Unknown partner'
  ) into v_context;

  perform public._send_email('partner_message', jsonb_build_object(
    'subject',     NEW.subject,
    'message',     NEW.message,
    'source_page', NEW.source_page,
    'context',     v_context
  ));
  return NEW;
end;
$$;


ALTER FUNCTION "public"."tg_partner_message_email"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_special_email"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_dashboard_base text;
  v_partner_email  text;
  v_place_name     text;
  v_place_token    text;
begin
  if NEW.submission_status is distinct from OLD.submission_status then
    select bookings_email, name, partner_access_token
      into v_partner_email, v_place_name, v_place_token
      from public.places where id = NEW.place_id;
    if v_partner_email is null or v_partner_email = '' then
      return NEW;  -- no email on file
    end if;

    select value into v_dashboard_base from public.app_settings where key = 'dashboard_base_url';

    if NEW.submission_status = 'approved' then
      perform public._send_email('special_approved', jsonb_build_object(
        'partner_email', v_partner_email,
        'title',         NEW.title,
        'place_name',    v_place_name,
        'dashboard_url', case when v_place_token is not null
                              then coalesce(v_dashboard_base, '') || '/partner/specials?token=' || v_place_token
                              else null end
      ));
    elsif NEW.submission_status = 'rejected' then
      perform public._send_email('special_rejected', jsonb_build_object(
        'partner_email', v_partner_email,
        'title',         NEW.title,
        'place_name',    v_place_name,
        'review_note',   NEW.review_note
      ));
    end if;
  end if;
  return NEW;
end;
$$;


ALTER FUNCTION "public"."tg_special_email"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."tg_submission_email"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_dashboard_base text;
  v_event_slug     text;
  v_event_token    text;
begin
  if NEW.status is distinct from OLD.status then
    if NEW.contact_email is null or NEW.contact_email = '' then
      return NEW;
    end if;

    select value into v_dashboard_base from public.app_settings where key = 'dashboard_base_url';
    if NEW.event_id is not null then
      select slug, partner_access_token into v_event_slug, v_event_token
        from public.events where id = NEW.event_id;
    end if;

    if NEW.status = 'approved' then
      perform public._send_email('submission_approved', jsonb_build_object(
        'partner_email', NEW.contact_email,
        'event_name',    NEW.event_name,
        'event_url',     case when v_event_slug is not null
                              then coalesce(v_dashboard_base, '') || '/events/' || v_event_slug
                              else null end,
        'dashboard_url', case when v_event_token is not null
                              then coalesce(v_dashboard_base, '') || '/partner/event?token=' || v_event_token
                              else null end
      ));
    elsif NEW.status = 'archived' then
      perform public._send_email('submission_rejected', jsonb_build_object(
        'partner_email', NEW.contact_email,
        'event_name',    NEW.event_name,
        'review_note',   null
      ));
    end if;
  end if;
  return NEW;
end;
$$;


ALTER FUNCTION "public"."tg_submission_email"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."track_event_metric"("p_event_id" "uuid", "p_event_name" "text", "p_anon_device_id" "text" DEFAULT NULL::"text", "p_session_id" "text" DEFAULT NULL::"text", "p_tab_key" "text" DEFAULT NULL::"text", "p_vendor_id" "uuid" DEFAULT NULL::"uuid", "p_sponsor_id" "uuid" DEFAULT NULL::"uuid", "p_activation_id" "uuid" DEFAULT NULL::"uuid", "p_band_id" "uuid" DEFAULT NULL::"uuid", "p_notification_id" "uuid" DEFAULT NULL::"uuid", "p_notification_category" "text" DEFAULT NULL::"text", "p_target_url" "text" DEFAULT NULL::"text", "p_metadata" "jsonb" DEFAULT '{}'::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
begin
  insert into public.event_analytics_events
    (event_id, event_name, user_id, anon_device_id, session_id,
     tab_key, vendor_id, sponsor_id, activation_id, band_id,
     notification_id, notification_category, target_url, metadata)
  values
    (p_event_id, p_event_name, auth.uid(), nullif(trim(coalesce(p_anon_device_id, '')), ''),
     nullif(trim(coalesce(p_session_id, '')), ''),
     p_tab_key, p_vendor_id, p_sponsor_id, p_activation_id, p_band_id,
     p_notification_id, p_notification_category, p_target_url,
     coalesce(p_metadata, '{}'::jsonb));
  return jsonb_build_object('ok', true);
exception when others then
  -- Never break the consumer app over analytics.
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end;
$$;


ALTER FUNCTION "public"."track_event_metric"("p_event_id" "uuid", "p_event_name" "text", "p_anon_device_id" "text", "p_session_id" "text", "p_tab_key" "text", "p_vendor_id" "uuid", "p_sponsor_id" "uuid", "p_activation_id" "uuid", "p_band_id" "uuid", "p_notification_id" "uuid", "p_notification_category" "text", "p_target_url" "text", "p_metadata" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."trip_other_voter_count"("_trip_id" "uuid", "_proposer" "uuid") RETURNS integer
    LANGUAGE "sql" STABLE SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select count(distinct uid)::int from (
    select user_id as uid
      from public.itineraries
      where id = _trip_id
    union
    select invitee_id as uid
      from public.trip_collaborators
      where trip_id = _trip_id
        and invitee_id is not null
        and status = 'accepted'
  ) t
  where uid is not null and uid <> _proposer;
$$;


ALTER FUNCTION "public"."trip_other_voter_count"("_trip_id" "uuid", "_proposer" "uuid") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_event_floor_plan"("p_token" "text", "p_floor_plan_url" "text", "p_floor_plan_markers" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_event_id uuid;
begin
  select id into v_event_id
    from public.events
   where partner_access_token = p_token;

  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  update public.events
     set floor_plan_url     = p_floor_plan_url,
         floor_plan_markers = coalesce(p_floor_plan_markers, '[]'::jsonb),
         updated_at         = now()
   where id = v_event_id;

  return jsonb_build_object('ok', true, 'event_id', v_event_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;


ALTER FUNCTION "public"."update_event_floor_plan"("p_token" "text", "p_floor_plan_url" "text", "p_floor_plan_markers" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_event_floor_plan_via_invite"("p_invite_token" "text", "p_floor_plan_markers" "jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_inv  public.event_map_invites%rowtype;
begin
  select * into v_inv from public.event_map_invites where token = p_invite_token;
  if v_inv.token is null then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if v_inv.revoked_at is not null then return jsonb_build_object('ok', false, 'error', 'revoked'); end if;
  if v_inv.expires_at <= now() then return jsonb_build_object('ok', false, 'error', 'expired'); end if;
  if not ('markers' = any(v_inv.scopes)) then
    return jsonb_build_object('ok', false, 'error', 'scope_denied');
  end if;

  update public.events
     set floor_plan_markers = coalesce(p_floor_plan_markers, '[]'::jsonb),
         updated_at         = now()
   where id = v_inv.event_id;

  return jsonb_build_object('ok', true);
end;
$$;


ALTER FUNCTION "public"."update_event_floor_plan_via_invite"("p_invite_token" "text", "p_floor_plan_markers" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_event_popularity"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
  IF (NEW.going_count + NEW.interested_count) >= 100 THEN
    NEW.is_featured = true;
  END IF;
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_event_popularity"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_event_vendor"("p_token" "text", "p_event_vendor_id" "uuid", "p_vendor_name" "text" DEFAULT NULL::"text", "p_booth_number" "text" DEFAULT NULL::"text", "p_vendor_type" "text" DEFAULT NULL::"text", "p_vendor_description" "text" DEFAULT NULL::"text", "p_is_featured" boolean DEFAULT NULL::boolean, "p_filter_tags" "text"[] DEFAULT NULL::"text"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_event_id  uuid;
  v_vendor_id uuid;
begin
  select id into v_event_id
    from public.events
   where partner_access_token = p_token;

  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  select vendor_id into v_vendor_id
    from public.event_vendors
   where id = p_event_vendor_id and event_id = v_event_id;

  if v_vendor_id is null then
    return jsonb_build_object('ok', false, 'error', 'vendor_not_found_for_event');
  end if;

  update public.event_vendors
     set booth_number = coalesce(p_booth_number, booth_number),
         is_featured  = coalesce(p_is_featured,  is_featured),
         filter_tags  = coalesce(p_filter_tags,  filter_tags),
         updated_at   = now()
   where id = p_event_vendor_id;

  if p_vendor_name is not null or p_vendor_type is not null or p_vendor_description is not null then
    update public.vendors
       set name        = coalesce(p_vendor_name,        name),
           vendor_type = coalesce(p_vendor_type,        vendor_type),
           description = coalesce(p_vendor_description, description),
           updated_at  = now()
     where id = v_vendor_id;
  end if;

  return jsonb_build_object('ok', true, 'event_vendor_id', p_event_vendor_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;


ALTER FUNCTION "public"."update_event_vendor"("p_token" "text", "p_event_vendor_id" "uuid", "p_vendor_name" "text", "p_booth_number" "text", "p_vendor_type" "text", "p_vendor_description" "text", "p_is_featured" boolean, "p_filter_tags" "text"[]) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."update_event_vendor"("p_token" "text", "p_event_vendor_id" "uuid", "p_vendor_name" "text", "p_booth_number" "text", "p_vendor_type" "text", "p_vendor_description" "text", "p_is_featured" boolean, "p_filter_tags" "text"[]) IS 'Lets a partner update one vendor row on their event via the partner-event dashboard edit modal. Updates event_vendors.booth_number/is_featured and (optionally) the vendor''s own name/vendor_type/description. Token-gated to the owning event.';



CREATE OR REPLACE FUNCTION "public"."update_loyalty_program_by_token"("p_token" "text", "p_required_stamps" integer DEFAULT NULL::integer, "p_reward" "text" DEFAULT NULL::"text", "p_spend_per_stamp" numeric DEFAULT NULL::numeric, "p_fine_print" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place_id uuid;
  v_program loyalty_programs%rowtype;
begin
  select id
    into v_place_id
    from public.places
   where partner_access_token = p_token;

  if v_place_id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid partner token');
  end if;

  select *
    into v_program
    from public.loyalty_programs
   where place_id = v_place_id
     and is_active = true
   order by created_at desc
   limit 1;

  if v_program.id is null then
    return jsonb_build_object('ok', false, 'error', 'No active loyalty program found');
  end if;

  if p_required_stamps is not null and (p_required_stamps < 1 or p_required_stamps > 100) then
    return jsonb_build_object('ok', false, 'error', 'Required stamps must be between 1 and 100');
  end if;

  if p_spend_per_stamp is not null and p_spend_per_stamp < 0 then
    return jsonb_build_object('ok', false, 'error', 'Spend per stamp cannot be negative');
  end if;

  update public.loyalty_programs
     set required_stamps = coalesce(p_required_stamps, required_stamps),
         reward          = coalesce(nullif(trim(p_reward), ''), reward),
         spend_per_stamp = p_spend_per_stamp,
         fine_print      = p_fine_print,
         updated_at      = now()
   where id = v_program.id
   returning * into v_program;

  return jsonb_build_object(
    'ok', true,
    'program', jsonb_build_object(
      'id',               v_program.id,
      'required_stamps',  v_program.required_stamps,
      'reward',           v_program.reward,
      'spend_per_stamp',  v_program.spend_per_stamp,
      'earning_type',     v_program.earning_type,
      'primary_color',    v_program.primary_color,
      'accent_color',     v_program.accent_color,
      'text_color',       v_program.text_color,
      'secondary_color',  v_program.secondary_color,
      'watermark_icon',   v_program.watermark_icon,
      'fine_print',       v_program.fine_print
    )
  );
end;
$$;


ALTER FUNCTION "public"."update_loyalty_program_by_token"("p_token" "text", "p_required_stamps" integer, "p_reward" "text", "p_spend_per_stamp" numeric, "p_fine_print" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_loyalty_program_by_token"("p_token" "text", "p_required_stamps" integer DEFAULT NULL::integer, "p_reward" "text" DEFAULT NULL::"text", "p_spend_per_stamp" numeric DEFAULT NULL::numeric, "p_fine_print" "text" DEFAULT NULL::"text", "p_stamp_icon" "text" DEFAULT NULL::"text", "p_stamp_logo_url" "text" DEFAULT NULL::"text", "p_card_theme" "text" DEFAULT NULL::"text", "p_silver_after_redemptions" integer DEFAULT NULL::integer, "p_gold_after_redemptions" integer DEFAULT NULL::integer, "p_platinum_after_redemptions" integer DEFAULT NULL::integer, "p_card_design_notes" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place_id uuid;
  v_program loyalty_programs%rowtype;
begin
  select id
    into v_place_id
    from public.places
   where partner_access_token = p_token;

  if v_place_id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid partner token');
  end if;

  select *
    into v_program
    from public.loyalty_programs
   where place_id = v_place_id
     and is_active = true
   order by created_at desc
   limit 1;

  if v_program.id is null then
    return jsonb_build_object('ok', false, 'error', 'No active loyalty program found');
  end if;

  if p_required_stamps is not null and (p_required_stamps < 1 or p_required_stamps > 100) then
    return jsonb_build_object('ok', false, 'error', 'Required stamps must be between 1 and 100');
  end if;

  if p_spend_per_stamp is not null and p_spend_per_stamp < 0 then
    return jsonb_build_object('ok', false, 'error', 'Spend per stamp cannot be negative');
  end if;

  if p_stamp_icon is not null and p_stamp_icon not in ('bowl','star','coffee','cocktail','leaf','music','logo') then
    return jsonb_build_object('ok', false, 'error', 'Choose a valid stamp icon');
  end if;

  if p_card_theme is not null and p_card_theme not in ('classic','silver','gold','platinum','brand') then
    return jsonb_build_object('ok', false, 'error', 'Choose a valid card design');
  end if;

  if p_silver_after_redemptions is not null and p_silver_after_redemptions < 1 then
    return jsonb_build_object('ok', false, 'error', 'Silver threshold must be at least 1');
  end if;

  if p_gold_after_redemptions is not null and p_gold_after_redemptions < 1 then
    return jsonb_build_object('ok', false, 'error', 'Gold threshold must be at least 1');
  end if;

  if p_platinum_after_redemptions is not null and p_platinum_after_redemptions < 1 then
    return jsonb_build_object('ok', false, 'error', 'Platinum threshold must be at least 1');
  end if;

  if coalesce(p_silver_after_redemptions, v_program.silver_after_redemptions) >=
     coalesce(p_gold_after_redemptions, v_program.gold_after_redemptions) then
    return jsonb_build_object('ok', false, 'error', 'Gold must unlock after Silver');
  end if;

  if coalesce(p_gold_after_redemptions, v_program.gold_after_redemptions) >=
     coalesce(p_platinum_after_redemptions, v_program.platinum_after_redemptions) then
    return jsonb_build_object('ok', false, 'error', 'Platinum must unlock after Gold');
  end if;

  update public.loyalty_programs
     set required_stamps = coalesce(p_required_stamps, required_stamps),
         reward          = coalesce(nullif(trim(p_reward), ''), reward),
         spend_per_stamp = p_spend_per_stamp,
         fine_print      = p_fine_print,
         stamp_icon      = coalesce(p_stamp_icon, stamp_icon),
         stamp_logo_url  = nullif(trim(p_stamp_logo_url), ''),
         card_theme      = coalesce(p_card_theme, card_theme),
         silver_after_redemptions   = coalesce(p_silver_after_redemptions, silver_after_redemptions),
         gold_after_redemptions     = coalesce(p_gold_after_redemptions, gold_after_redemptions),
         platinum_after_redemptions = coalesce(p_platinum_after_redemptions, platinum_after_redemptions),
         card_design_notes          = p_card_design_notes,
         updated_at      = now()
   where id = v_program.id
   returning * into v_program;

  return jsonb_build_object(
    'ok', true,
    'program', jsonb_build_object(
      'id',               v_program.id,
      'required_stamps',  v_program.required_stamps,
      'reward',           v_program.reward,
      'spend_per_stamp',  v_program.spend_per_stamp,
      'earning_type',     v_program.earning_type,
      'stamp_icon',       v_program.stamp_icon,
      'stamp_logo_url',   v_program.stamp_logo_url,
      'card_theme',       v_program.card_theme,
      'silver_after_redemptions',   v_program.silver_after_redemptions,
      'gold_after_redemptions',     v_program.gold_after_redemptions,
      'platinum_after_redemptions', v_program.platinum_after_redemptions,
      'card_design_notes',          v_program.card_design_notes,
      'primary_color',    v_program.primary_color,
      'accent_color',     v_program.accent_color,
      'text_color',       v_program.text_color,
      'secondary_color',  v_program.secondary_color,
      'watermark_icon',   v_program.watermark_icon,
      'fine_print',       v_program.fine_print
    )
  );
end;
$$;


ALTER FUNCTION "public"."update_loyalty_program_by_token"("p_token" "text", "p_required_stamps" integer, "p_reward" "text", "p_spend_per_stamp" numeric, "p_fine_print" "text", "p_stamp_icon" "text", "p_stamp_logo_url" "text", "p_card_theme" "text", "p_silver_after_redemptions" integer, "p_gold_after_redemptions" integer, "p_platinum_after_redemptions" integer, "p_card_design_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_partner_event"("p_token" "text", "p_title" "text" DEFAULT NULL::"text", "p_description" "text" DEFAULT NULL::"text", "p_short_description" "text" DEFAULT NULL::"text", "p_start_date" "date" DEFAULT NULL::"date", "p_end_date" "date" DEFAULT NULL::"date", "p_start_time" time without time zone DEFAULT NULL::time without time zone, "p_end_time" time without time zone DEFAULT NULL::time without time zone, "p_is_all_day" boolean DEFAULT NULL::boolean, "p_timezone" "text" DEFAULT NULL::"text", "p_venue_name" "text" DEFAULT NULL::"text", "p_venue_address" "text" DEFAULT NULL::"text", "p_parish" "text" DEFAULT NULL::"text", "p_town" "text" DEFAULT NULL::"text", "p_country" "text" DEFAULT NULL::"text", "p_is_free" boolean DEFAULT NULL::boolean, "p_ticket_price_min" numeric DEFAULT NULL::numeric, "p_ticket_price_max" numeric DEFAULT NULL::numeric, "p_currency" "text" DEFAULT NULL::"text", "p_has_online_tickets" boolean DEFAULT NULL::boolean, "p_is_sold_out" boolean DEFAULT NULL::boolean, "p_ticket_url" "text" DEFAULT NULL::"text", "p_capacity" integer DEFAULT NULL::integer, "p_min_age" integer DEFAULT NULL::integer, "p_dress_code" "text" DEFAULT NULL::"text", "p_food_available" boolean DEFAULT NULL::boolean, "p_alcohol_served" boolean DEFAULT NULL::boolean, "p_organizer_name" "text" DEFAULT NULL::"text", "p_contact_email" "text" DEFAULT NULL::"text", "p_contact_phone" "text" DEFAULT NULL::"text", "p_support_email" "text" DEFAULT NULL::"text", "p_support_phone" "text" DEFAULT NULL::"text", "p_support_url" "text" DEFAULT NULL::"text", "p_website_url" "text" DEFAULT NULL::"text", "p_instagram_url" "text" DEFAULT NULL::"text", "p_featured_image_url" "text" DEFAULT NULL::"text", "p_event_type" "text" DEFAULT NULL::"text", "p_info_sections" "jsonb" DEFAULT NULL::"jsonb", "p_faq" "jsonb" DEFAULT NULL::"jsonb", "p_parking_image_url" "text" DEFAULT NULL::"text", "p_parking_image_urls" "jsonb" DEFAULT NULL::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_event events%rowtype;
  v_updated_count int;
  v_start_date date;
  v_end_date date;
  v_start_time time;
  v_end_time time;
begin
  select * into v_event from public.events where partner_access_token = p_token;
  if v_event.id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;

  v_start_date := coalesce(p_start_date, v_event.start_date);
  v_end_date := coalesce(p_end_date, v_event.end_date);
  v_start_time := coalesce(p_start_time, v_event.start_time);
  v_end_time := coalesce(p_end_time, v_event.end_time);

  if v_start_date is not null and v_end_date is not null and v_end_date < v_start_date then
    return jsonb_build_object('ok', false, 'error', 'End date must be on or after start date');
  end if;

  if v_start_date is not null
     and v_end_date is not null
     and v_end_date = v_start_date
     and v_start_time is not null
     and v_end_time is not null
     and v_end_time < v_start_time then
    return jsonb_build_object('ok', false, 'error', 'For overnight events, set the end date to the following day');
  end if;

  update public.events set
    title              = coalesce(nullif(trim(p_title), ''), title),
    description        = case when p_description is not null then nullif(trim(p_description), '') else description end,
    short_description  = case when p_short_description is not null then nullif(trim(p_short_description), '') else short_description end,
    start_date         = v_start_date,
    end_date           = v_end_date,
    start_time         = v_start_time,
    end_time           = v_end_time,
    is_all_day         = coalesce(p_is_all_day, is_all_day),
    timezone           = coalesce(nullif(trim(p_timezone), ''), timezone),
    venue_name         = case when p_venue_name is not null then nullif(trim(p_venue_name), '') else venue_name end,
    venue_address      = case when p_venue_address is not null then nullif(trim(p_venue_address), '') else venue_address end,
    parish             = case when p_parish is not null then nullif(trim(p_parish), '') else parish end,
    town               = case when p_town is not null then nullif(trim(p_town), '') else town end,
    country            = case when p_country is not null then nullif(trim(p_country), '') else country end,
    is_free            = coalesce(p_is_free, is_free),
    ticket_price_min   = case when p_ticket_price_min is not null then p_ticket_price_min else ticket_price_min end,
    ticket_price_max   = case when p_ticket_price_max is not null then p_ticket_price_max else ticket_price_max end,
    currency           = case when p_currency is not null then nullif(trim(p_currency), '') else currency end,
    has_online_tickets = coalesce(p_has_online_tickets, has_online_tickets),
    is_sold_out        = coalesce(p_is_sold_out, is_sold_out),
    ticket_url         = case when p_ticket_url is not null then nullif(trim(p_ticket_url), '') else ticket_url end,
    capacity           = case when p_capacity is not null then p_capacity else capacity end,
    min_age            = case when p_min_age is not null then p_min_age else min_age end,
    dress_code         = case when p_dress_code is not null then nullif(trim(p_dress_code), '') else dress_code end,
    food_available     = coalesce(p_food_available, food_available),
    alcohol_served     = coalesce(p_alcohol_served, alcohol_served),
    organizer_name     = case when p_organizer_name is not null then nullif(trim(p_organizer_name), '') else organizer_name end,
    contact_email      = case when p_contact_email is not null then nullif(trim(p_contact_email), '') else contact_email end,
    contact_phone      = case when p_contact_phone is not null then nullif(trim(p_contact_phone), '') else contact_phone end,
    support_email      = case when p_support_email is not null then nullif(trim(p_support_email), '') else support_email end,
    support_phone      = case when p_support_phone is not null then nullif(trim(p_support_phone), '') else support_phone end,
    support_url        = case when p_support_url is not null then nullif(trim(p_support_url), '') else support_url end,
    website_url        = case when p_website_url is not null then nullif(trim(p_website_url), '') else website_url end,
    instagram_url      = case when p_instagram_url is not null then nullif(trim(p_instagram_url), '') else instagram_url end,
    featured_image_url = case when p_featured_image_url is not null then nullif(trim(p_featured_image_url), '') else featured_image_url end,
    event_type         = case when p_event_type is not null then coalesce(public._normalize_event_type(p_event_type), event_type) else event_type end,
    info_sections      = case when p_info_sections is not null then p_info_sections else info_sections end,
    faq                = case when p_faq is not null then p_faq else faq end,
    parking_image_url  = case when p_parking_image_url is not null then nullif(trim(p_parking_image_url), '') else parking_image_url end,
    parking_image_urls = case when p_parking_image_urls is not null then p_parking_image_urls else parking_image_urls end,
    updated_at         = now()
  where id = v_event.id;

  get diagnostics v_updated_count = row_count;

  return jsonb_build_object(
    'ok', true,
    'updated_count', v_updated_count,
    'message', 'Event updated successfully.'
  );
end;
$$;


ALTER FUNCTION "public"."update_partner_event"("p_token" "text", "p_title" "text", "p_description" "text", "p_short_description" "text", "p_start_date" "date", "p_end_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_is_all_day" boolean, "p_timezone" "text", "p_venue_name" "text", "p_venue_address" "text", "p_parish" "text", "p_town" "text", "p_country" "text", "p_is_free" boolean, "p_ticket_price_min" numeric, "p_ticket_price_max" numeric, "p_currency" "text", "p_has_online_tickets" boolean, "p_is_sold_out" boolean, "p_ticket_url" "text", "p_capacity" integer, "p_min_age" integer, "p_dress_code" "text", "p_food_available" boolean, "p_alcohol_served" boolean, "p_organizer_name" "text", "p_contact_email" "text", "p_contact_phone" "text", "p_support_email" "text", "p_support_phone" "text", "p_support_url" "text", "p_website_url" "text", "p_instagram_url" "text", "p_featured_image_url" "text", "p_event_type" "text", "p_info_sections" "jsonb", "p_faq" "jsonb", "p_parking_image_url" "text", "p_parking_image_urls" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_partner_hours"("p_token" "text", "p_opening_hours_struct" "jsonb" DEFAULT NULL::"jsonb", "p_kitchen_hours_struct" "jsonb" DEFAULT NULL::"jsonb") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place places%rowtype;
begin
  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;

  update public.places set
    opening_hours_struct = coalesce(p_opening_hours_struct, opening_hours_struct),
    kitchen_hours_struct = coalesce(p_kitchen_hours_struct, kitchen_hours_struct),
    opening_hours        = case
                              when p_opening_hours_struct is not null
                                then public._format_hours_text(p_opening_hours_struct)
                              else opening_hours
                           end,
    kitchen_hours        = case
                              when p_kitchen_hours_struct is not null
                                then public._format_hours_text(p_kitchen_hours_struct)
                              else kitchen_hours
                           end
  where id = v_place.id;

  return jsonb_build_object('ok', true, 'message', 'Hours updated.');
end;
$$;


ALTER FUNCTION "public"."update_partner_hours"("p_token" "text", "p_opening_hours_struct" "jsonb", "p_kitchen_hours_struct" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_partner_place_contact"("p_token" "text", "p_phone_number" "text" DEFAULT NULL::"text", "p_website" "text" DEFAULT NULL::"text", "p_instagram_url" "text" DEFAULT NULL::"text", "p_menu_link" "text" DEFAULT NULL::"text", "p_booking_link" "text" DEFAULT NULL::"text", "p_booking_contact_email" "text" DEFAULT NULL::"text", "p_bookings_email" "text" DEFAULT NULL::"text", "p_day_pass_link" "text" DEFAULT NULL::"text", "p_day_pass_notes" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place places%rowtype;
begin
  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;

  update public.places set
    phone_number          = case when p_phone_number          is not null then nullif(trim(p_phone_number), '')          else phone_number end,
    website               = case when p_website               is not null then nullif(trim(p_website), '')               else website end,
    instagram_url         = case when p_instagram_url         is not null then nullif(trim(p_instagram_url), '')         else instagram_url end,
    menu_link             = case when p_menu_link             is not null then nullif(trim(p_menu_link), '')             else menu_link end,
    booking_link          = case when p_booking_link          is not null then nullif(trim(p_booking_link), '')          else booking_link end,
    booking_contact_email = case when p_booking_contact_email is not null then nullif(trim(p_booking_contact_email), '') else booking_contact_email end,
    bookings_email        = case when p_bookings_email        is not null then nullif(trim(p_bookings_email), '')        else bookings_email end,
    day_pass_link         = case when p_day_pass_link         is not null then nullif(trim(p_day_pass_link), '')         else day_pass_link end,
    day_pass_notes        = case when p_day_pass_notes        is not null then nullif(trim(p_day_pass_notes), '')        else day_pass_notes end
  where id = v_place.id;

  return jsonb_build_object('ok', true, 'message', 'Contact info updated.');
end;
$$;


ALTER FUNCTION "public"."update_partner_place_contact"("p_token" "text", "p_phone_number" "text", "p_website" "text", "p_instagram_url" "text", "p_menu_link" "text", "p_booking_link" "text", "p_booking_contact_email" "text", "p_bookings_email" "text", "p_day_pass_link" "text", "p_day_pass_notes" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_partner_special"("p_token" "text", "p_special_id" "uuid", "p_title" "text" DEFAULT NULL::"text", "p_description" "text" DEFAULT NULL::"text", "p_special_type" "text" DEFAULT NULL::"text", "p_start_date" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_end_date" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_start_time" time without time zone DEFAULT NULL::time without time zone, "p_end_time" time without time zone DEFAULT NULL::time without time zone, "p_image_url" "text" DEFAULT NULL::"text", "p_discount_percentage" numeric DEFAULT NULL::numeric, "p_discount_amount" numeric DEFAULT NULL::numeric, "p_price_amount" numeric DEFAULT NULL::numeric, "p_currency" "text" DEFAULT NULL::"text", "p_event_category" "text" DEFAULT NULL::"text", "p_tags" "text"[] DEFAULT NULL::"text"[], "p_capacity" integer DEFAULT NULL::integer, "p_recurring_days" "text"[] DEFAULT NULL::"text"[], "p_age_restriction" "text" DEFAULT NULL::"text", "p_host_name" "text" DEFAULT NULL::"text", "p_event_slug" "text" DEFAULT NULL::"text", "p_ticket_link" "text" DEFAULT NULL::"text", "p_rsvp_link" "text" DEFAULT NULL::"text", "p_clear_capacity" boolean DEFAULT false, "p_clear_image" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place    places%rowtype;
  v_special  specials%rowtype;
  v_image_urls text[];
begin
  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;

  select * into v_special from public.specials where id = p_special_id;
  if v_special.id is null then
    return jsonb_build_object('ok', false, 'error', 'Special not found');
  end if;
  if v_special.place_id is distinct from v_place.id then
    return jsonb_build_object('ok', false, 'error', 'You do not own this special');
  end if;

  if p_special_type is not null and p_special_type not in
     ('partnership','local_discount','seasonal','general','event','travel_special') then
    return jsonb_build_object('ok', false, 'error', 'Pick a valid special type');
  end if;
  if p_end_date is not null and p_start_date is not null and p_end_date < p_start_date then
    return jsonb_build_object('ok', false, 'error', 'End date must be on or after start date');
  end if;

  -- Image handling: explicit clear, OR new url (becomes first image), OR no change
  v_image_urls := v_special.image_urls;
  if p_clear_image then
    v_image_urls := array[]::text[];
  elsif p_image_url is not null and length(trim(p_image_url)) > 0 then
    v_image_urls := array[trim(p_image_url)] || coalesce(
      (select array_agg(x) from unnest(v_special.image_urls) x offset 1),
      array[]::text[]
    );
  end if;

  update public.specials set
    title               = coalesce(nullif(trim(p_title), ''), title),
    description         = case when p_description is not null then nullif(trim(p_description), '') else description end,
    special_type        = coalesce(p_special_type, special_type),
    start_date          = coalesce(p_start_date, start_date),
    end_date            = coalesce(p_end_date, end_date),
    start_time          = case when p_start_time is not null then p_start_time else start_time end,
    end_time            = case when p_end_time   is not null then p_end_time   else end_time end,
    image_urls          = v_image_urls,
    discount_percentage = case when p_discount_percentage is not null then p_discount_percentage else discount_percentage end,
    discount_amount     = case when p_discount_amount     is not null then p_discount_amount     else discount_amount end,
    price_amount        = case when p_price_amount        is not null then p_price_amount        else price_amount end,
    currency            = coalesce(nullif(trim(p_currency), ''), currency),
    event_category      = case when p_event_category is not null then nullif(trim(p_event_category), '') else event_category end,
    event_tags          = coalesce(p_tags, event_tags),
    capacity            = case when p_clear_capacity then null
                               when p_capacity is not null then p_capacity
                               else capacity end,
    recurring_days      = coalesce(p_recurring_days, recurring_days),
    age_restriction     = case when p_age_restriction is not null then nullif(trim(p_age_restriction), '') else age_restriction end,
    host_name           = case when p_host_name       is not null then nullif(trim(p_host_name), '')       else host_name end,
    event_slug          = case when p_event_slug      is not null then nullif(trim(p_event_slug), '')      else event_slug end,
    ticket_link         = case when p_ticket_link     is not null then nullif(trim(p_ticket_link), '')     else ticket_link end,
    rsvp_link           = case when p_rsvp_link       is not null then nullif(trim(p_rsvp_link), '')       else rsvp_link end
  where id = p_special_id;

  return jsonb_build_object('ok', true, 'id', p_special_id, 'message', 'Special updated.');
end;
$$;


ALTER FUNCTION "public"."update_partner_special"("p_token" "text", "p_special_id" "uuid", "p_title" "text", "p_description" "text", "p_special_type" "text", "p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_start_time" time without time zone, "p_end_time" time without time zone, "p_image_url" "text", "p_discount_percentage" numeric, "p_discount_amount" numeric, "p_price_amount" numeric, "p_currency" "text", "p_event_category" "text", "p_tags" "text"[], "p_capacity" integer, "p_recurring_days" "text"[], "p_age_restriction" "text", "p_host_name" "text", "p_event_slug" "text", "p_ticket_link" "text", "p_rsvp_link" "text", "p_clear_capacity" boolean, "p_clear_image" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_place_ranks"("payload" "jsonb") RETURNS "void"
    LANGUAGE "plpgsql"
    AS $$
begin
  update user_place_rankings upr
  set manual_rank = p.manual_rank,
      updated_at = now()
  from jsonb_to_recordset(payload) as p(id uuid, manual_rank int)
  where upr.id = p.id;
end;
$$;


ALTER FUNCTION "public"."update_place_ranks"("payload" "jsonb") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_updated_at"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_updated_at_column"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    AS $$
BEGIN
  NEW.updated_at = now();
  RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_updated_at_column"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_user_stats_from_all"() RETURNS "trigger"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
declare
  uid uuid;
begin
  -- Figure out which user
  uid := coalesce(new.user_id, old.user_id);

  -- Ensure row exists
  insert into public.user_stats (user_id)
  values (uid)
  on conflict (user_id) do nothing;

  -- Recalculate total_points
  update public.user_stats us
  set total_points = coalesce((
    select sum(a.points)
    from public.user_achievements ua
    join public.achievements a on a.id = ua.achievement_id
    where ua.user_id = us.user_id
      and ua.is_completed = true
  ), 0),
  updated_at = now()
  where us.user_id = uid;

  return null;
end;
$$;


ALTER FUNCTION "public"."update_user_stats_from_all"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."update_visited_feedback_timestamp"() RETURNS "trigger"
    LANGUAGE "plpgsql"
    SET "search_path" TO 'public', 'pg_temp'
    AS $$
BEGIN
    NEW.updated_at = now();
    RETURN NEW;
END;
$$;


ALTER FUNCTION "public"."update_visited_feedback_timestamp"() OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_checkin_settings_by_partner_token"("p_token" "text", "p_checkin_enabled" boolean, "p_nfc_enabled" boolean, "p_qr_enabled" boolean, "p_manual_code_enabled" boolean, "p_in_app_checkin_enabled" boolean, "p_requires_proximity" boolean, "p_xp_enabled" boolean, "p_loyalty_enabled" boolean, "p_cooldown_minutes" integer DEFAULT NULL::integer) RETURNS "public"."place_checkin_settings"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place_id uuid;
  result     public.place_checkin_settings;
begin
  select id into v_place_id
  from public.places
  where partner_access_token = p_token
  limit 1;

  if v_place_id is null then
    raise exception 'Invalid partner token';
  end if;

  insert into public.place_checkin_settings as s (
    place_id, checkin_enabled, nfc_enabled, qr_enabled, manual_code_enabled,
    in_app_checkin_enabled, requires_proximity, xp_enabled, loyalty_enabled,
    cooldown_minutes
  ) values (
    v_place_id, p_checkin_enabled, p_nfc_enabled, p_qr_enabled,
    p_manual_code_enabled, p_in_app_checkin_enabled, p_requires_proximity,
    p_xp_enabled, p_loyalty_enabled, p_cooldown_minutes
  )
  on conflict (place_id) do update set
    checkin_enabled        = excluded.checkin_enabled,
    nfc_enabled            = excluded.nfc_enabled,
    qr_enabled             = excluded.qr_enabled,
    manual_code_enabled    = excluded.manual_code_enabled,
    in_app_checkin_enabled = excluded.in_app_checkin_enabled,
    requires_proximity     = excluded.requires_proximity,
    xp_enabled             = excluded.xp_enabled,
    loyalty_enabled        = excluded.loyalty_enabled,
    cooldown_minutes       = excluded.cooldown_minutes
  returning * into result;

  return result;
end;
$$;


ALTER FUNCTION "public"."upsert_checkin_settings_by_partner_token"("p_token" "text", "p_checkin_enabled" boolean, "p_nfc_enabled" boolean, "p_qr_enabled" boolean, "p_manual_code_enabled" boolean, "p_in_app_checkin_enabled" boolean, "p_requires_proximity" boolean, "p_xp_enabled" boolean, "p_loyalty_enabled" boolean, "p_cooldown_minutes" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_event_sponsor"("p_token" "text", "p_event_sponsor_id" "uuid" DEFAULT NULL::"uuid", "p_sponsor_name" "text" DEFAULT NULL::"text", "p_tier" "text" DEFAULT NULL::"text", "p_display_tier_label" "text" DEFAULT NULL::"text", "p_custom_tagline" "text" DEFAULT NULL::"text", "p_logo_url" "text" DEFAULT NULL::"text", "p_website" "text" DEFAULT NULL::"text", "p_instagram" "text" DEFAULT NULL::"text", "p_is_featured" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_event_id   uuid;
  v_sponsor_id uuid;
  v_es_id      uuid;
  v_slug       text;
  v_tier       text;
  v_tier_label text;
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;
  if p_sponsor_name is null or btrim(p_sponsor_name) = '' then
    return jsonb_build_object('ok', false, 'error', 'sponsor_name_required');
  end if;
  v_tier := case lower(coalesce(nullif(btrim(p_tier), ''), 'partner'))
    when 'title' then 'presenting'
    when 'platinum' then 'presenting'
    when 'gold' then 'major'
    when 'silver' then 'supporting'
    when 'bronze' then 'supporting'
    when 'presenting' then 'presenting'
    when 'major' then 'major'
    when 'supporting' then 'supporting'
    when 'community' then 'community'
    else 'partner'
  end;
  v_tier_label := coalesce(
    nullif(btrim(p_display_tier_label), ''),
    case lower(coalesce(nullif(btrim(p_tier), ''), 'partner'))
      when 'title' then 'Title Sponsor'
      when 'platinum' then 'Platinum Sponsor'
      when 'gold' then 'Gold Sponsor'
      when 'silver' then 'Silver Sponsor'
      when 'bronze' then 'Bronze Sponsor'
      else null
    end
  );

  if p_event_sponsor_id is null then
    -- Create a sponsor row + event_sponsor link
    v_slug := regexp_replace(lower(btrim(p_sponsor_name)) || '-' || substr(encode(extensions.gen_random_bytes(3), 'hex'), 1, 6), '[^a-z0-9-]+', '-', 'g');
    insert into public.sponsors (name, slug, logo_url, website, description, instagram, is_active)
         values (
           btrim(p_sponsor_name),
           v_slug,
           nullif(btrim(p_logo_url), ''),
           nullif(btrim(p_website), ''),
           nullif(btrim(p_custom_tagline), ''),
           nullif(btrim(p_instagram), ''),
           true
         )
      returning id into v_sponsor_id;

    insert into public.event_sponsors (event_id, sponsor_id, tier, display_tier_label, custom_tagline, is_featured, is_active)
         values (
           v_event_id,
           v_sponsor_id,
           v_tier,
           v_tier_label,
           nullif(btrim(p_custom_tagline), ''),
           coalesce(p_is_featured, false),
           true
         )
      returning id into v_es_id;
  else
    -- Update : confirm ownership, then update both tables
    select id, sponsor_id into v_es_id, v_sponsor_id
      from public.event_sponsors
     where id = p_event_sponsor_id and event_id = v_event_id;
    if v_es_id is null then
      return jsonb_build_object('ok', false, 'error', 'sponsor_not_on_event');
    end if;

    update public.event_sponsors
       set tier               = v_tier,
           display_tier_label = v_tier_label,
           custom_tagline     = nullif(btrim(p_custom_tagline), ''),
           is_featured        = coalesce(p_is_featured,        is_featured),
           is_active          = true,
           updated_at         = now()
     where id = v_es_id;

    update public.sponsors
       set name        = btrim(p_sponsor_name),
           logo_url    = nullif(btrim(p_logo_url), ''),
           website     = nullif(btrim(p_website), ''),
           instagram   = nullif(btrim(p_instagram), ''),
           description = nullif(btrim(p_custom_tagline), ''),
           is_active   = true,
           updated_at  = now()
     where id = v_sponsor_id;
  end if;

  return jsonb_build_object('ok', true, 'event_sponsor_id', v_es_id, 'sponsor_id', v_sponsor_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;


ALTER FUNCTION "public"."upsert_event_sponsor"("p_token" "text", "p_event_sponsor_id" "uuid", "p_sponsor_name" "text", "p_tier" "text", "p_display_tier_label" "text", "p_custom_tagline" "text", "p_logo_url" "text", "p_website" "text", "p_instagram" "text", "p_is_featured" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_event_vendor"("p_token" "text", "p_event_vendor_id" "uuid" DEFAULT NULL::"uuid", "p_vendor_id" "uuid" DEFAULT NULL::"uuid", "p_vendor_name" "text" DEFAULT NULL::"text", "p_booth_number" "text" DEFAULT NULL::"text", "p_vendor_type" "text" DEFAULT NULL::"text", "p_vendor_description" "text" DEFAULT NULL::"text", "p_is_featured" boolean DEFAULT NULL::boolean, "p_zone" "text" DEFAULT NULL::"text", "p_filter_tags" "text"[] DEFAULT NULL::"text"[]) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_event_id        uuid;
  v_vendor_id       uuid;
  v_event_vendor_id uuid;
begin
  select id into v_event_id
    from public.events
   where partner_access_token = p_token;

  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  if p_event_vendor_id is not null then
    select vendor_id into v_vendor_id
      from public.event_vendors
     where id = p_event_vendor_id and event_id = v_event_id;

    if v_vendor_id is null then
      return jsonb_build_object('ok', false, 'error', 'vendor_not_found_for_event');
    end if;

    update public.event_vendors
       set booth_number = coalesce(p_booth_number, booth_number),
           is_featured  = coalesce(p_is_featured,  is_featured),
           zone         = coalesce(p_zone,         zone),
           filter_tags  = coalesce(p_filter_tags,  filter_tags),
           updated_at   = now()
     where id = p_event_vendor_id;

    if p_vendor_name is not null or p_vendor_type is not null or p_vendor_description is not null then
      update public.vendors
         set name        = coalesce(p_vendor_name,        name),
             vendor_type = coalesce(p_vendor_type,        vendor_type),
             description = coalesce(p_vendor_description, description),
             updated_at  = now()
       where id = v_vendor_id;
    end if;

    return jsonb_build_object('ok', true, 'event_vendor_id', p_event_vendor_id);
  end if;

  v_vendor_id := p_vendor_id;

  if v_vendor_id is null then
    if coalesce(trim(p_vendor_name), '') = '' then
      return jsonb_build_object('ok', false, 'error', 'vendor_name_required');
    end if;

    select id into v_vendor_id
      from public.vendors
     where lower(btrim(name)) = lower(btrim(p_vendor_name))
     limit 1;

    if v_vendor_id is null then
      insert into public.vendors (name, vendor_type, description)
      values (trim(p_vendor_name), p_vendor_type, p_vendor_description)
      returning id into v_vendor_id;
    end if;
  else
    if not exists (select 1 from public.vendors where id = v_vendor_id) then
      return jsonb_build_object('ok', false, 'error', 'vendor_not_found');
    end if;
  end if;

  select id into v_event_vendor_id
    from public.event_vendors
   where event_id = v_event_id and vendor_id = v_vendor_id;

  if v_event_vendor_id is not null then
    update public.event_vendors
       set booth_number = coalesce(p_booth_number, booth_number),
           is_featured  = coalesce(p_is_featured,  is_featured),
           zone         = coalesce(p_zone,         zone),
           filter_tags  = coalesce(p_filter_tags,  filter_tags),
           updated_at   = now()
     where id = v_event_vendor_id;
    return jsonb_build_object('ok', true, 'event_vendor_id', v_event_vendor_id, 'already_linked', true);
  end if;

  insert into public.event_vendors (event_id, vendor_id, booth_number, is_featured, zone, filter_tags)
  values (v_event_id, v_vendor_id, p_booth_number, coalesce(p_is_featured, false), p_zone, coalesce(p_filter_tags, '{}'))
  returning id into v_event_vendor_id;

  return jsonb_build_object('ok', true, 'event_vendor_id', v_event_vendor_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;


ALTER FUNCTION "public"."upsert_event_vendor"("p_token" "text", "p_event_vendor_id" "uuid", "p_vendor_id" "uuid", "p_vendor_name" "text", "p_booth_number" "text", "p_vendor_type" "text", "p_vendor_description" "text", "p_is_featured" boolean, "p_zone" "text", "p_filter_tags" "text"[]) OWNER TO "postgres";


COMMENT ON FUNCTION "public"."upsert_event_vendor"("p_token" "text", "p_event_vendor_id" "uuid", "p_vendor_id" "uuid", "p_vendor_name" "text", "p_booth_number" "text", "p_vendor_type" "text", "p_vendor_description" "text", "p_is_featured" boolean, "p_zone" "text", "p_filter_tags" "text"[]) IS 'Adds a vendor to an event from the partner dashboard: links an existing directory vendor (p_vendor_id) or creates a new vendor row, then inserts into event_vendors. With p_event_vendor_id set it behaves like update_event_vendor. Token-gated.';



CREATE OR REPLACE FUNCTION "public"."upsert_insider_settings_by_partner_token"("p_token" "text", "p_guest_min" integer, "p_familiar_face_min" integer, "p_regular_min" integer, "p_house_favourite_min" integer) RETURNS "public"."insider_status_settings"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place_id uuid;
  result     public.insider_status_settings;
begin
  select id into v_place_id
  from public.places
  where partner_access_token = p_token
  limit 1;

  if v_place_id is null then
    raise exception 'Invalid partner token';
  end if;

  insert into public.insider_status_settings
    (place_id, guest_min, familiar_face_min, regular_min, house_favourite_min, updated_at)
  values
    (v_place_id,
     coalesce(p_guest_min, 1),
     coalesce(p_familiar_face_min, 3),
     coalesce(p_regular_min, 7),
     coalesce(p_house_favourite_min, 15),
     now())
  on conflict (place_id) do update
    set guest_min           = excluded.guest_min,
        familiar_face_min   = excluded.familiar_face_min,
        regular_min         = excluded.regular_min,
        house_favourite_min = excluded.house_favourite_min,
        updated_at          = now()
  returning * into result;

  return result;
end;
$$;


ALTER FUNCTION "public"."upsert_insider_settings_by_partner_token"("p_token" "text", "p_guest_min" integer, "p_familiar_face_min" integer, "p_regular_min" integer, "p_house_favourite_min" integer) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_partner_closure"("p_token" "text", "p_date" "date", "p_is_closed" boolean DEFAULT true, "p_open_time" time without time zone DEFAULT NULL::time without time zone, "p_close_time" time without time zone DEFAULT NULL::time without time zone, "p_kitchen_open" time without time zone DEFAULT NULL::time without time zone, "p_kitchen_close" time without time zone DEFAULT NULL::time without time zone, "p_reason" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place places%rowtype;
  v_id    uuid;
begin
  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;
  if p_date is null then
    return jsonb_build_object('ok', false, 'error', 'Pick a date for this closure');
  end if;
  if p_is_closed = false and (p_open_time is null or p_close_time is null) then
    return jsonb_build_object('ok', false, 'error',
      'For a non-closed day, please give open and close times');
  end if;

  insert into public.place_special_hours (
    place_id, date, is_closed, open_time, close_time,
    kitchen_open, kitchen_close, reason
  ) values (
    v_place.id, p_date, p_is_closed, p_open_time, p_close_time,
    p_kitchen_open, p_kitchen_close, nullif(trim(coalesce(p_reason, '')), '')
  )
  on conflict (place_id, date) do update set
    is_closed     = excluded.is_closed,
    open_time     = excluded.open_time,
    close_time    = excluded.close_time,
    kitchen_open  = excluded.kitchen_open,
    kitchen_close = excluded.kitchen_close,
    reason        = excluded.reason,
    updated_at    = now()
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;


ALTER FUNCTION "public"."upsert_partner_closure"("p_token" "text", "p_date" "date", "p_is_closed" boolean, "p_open_time" time without time zone, "p_close_time" time without time zone, "p_kitchen_open" time without time zone, "p_kitchen_close" time without time zone, "p_reason" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_perk_by_partner_token"("p_token" "text", "p_perk_id" "uuid", "p_title" "text", "p_description" "text", "p_required_tier" "text", "p_perk_type" "text", "p_redemption_limit" integer, "p_active" boolean) RETURNS "public"."partner_perks"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_place_id uuid;
  result     public.partner_perks;
begin
  select id into v_place_id
  from public.places
  where partner_access_token = p_token
  limit 1;

  if v_place_id is null then
    raise exception 'Invalid partner token';
  end if;

  if p_perk_id is null then
    insert into public.partner_perks
      (place_id, title, description, required_tier, perk_type,
       redemption_limit, active)
    values
      (v_place_id, p_title, p_description, coalesce(p_required_tier, 'member'),
       coalesce(p_perk_type, 'other'), p_redemption_limit, coalesce(p_active, true))
    returning * into result;
  else
    update public.partner_perks
       set title            = p_title,
           description      = p_description,
           required_tier    = coalesce(p_required_tier, required_tier),
           perk_type        = coalesce(p_perk_type, perk_type),
           redemption_limit = p_redemption_limit,
           active           = coalesce(p_active, active)
     where id = p_perk_id
       and place_id = v_place_id
    returning * into result;

    if result.id is null then
      raise exception 'Perk not found for this partner';
    end if;
  end if;

  return result;
end;
$$;


ALTER FUNCTION "public"."upsert_perk_by_partner_token"("p_token" "text", "p_perk_id" "uuid", "p_title" "text", "p_description" "text", "p_required_tier" "text", "p_perk_type" "text", "p_redemption_limit" integer, "p_active" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_schedule_day"("p_token" "text", "p_id" "uuid" DEFAULT NULL::"uuid", "p_date" "date" DEFAULT NULL::"date", "p_label" "text" DEFAULT NULL::"text", "p_description" "text" DEFAULT NULL::"text", "p_gates_open" time without time zone DEFAULT NULL::time without time zone, "p_gates_close" time without time zone DEFAULT NULL::time without time zone, "p_is_cancelled" boolean DEFAULT false) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_event_id uuid; v_id uuid;
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  if p_date is null then return jsonb_build_object('ok', false, 'error', 'date_required'); end if;

  if p_id is null then
    insert into public.event_schedule_days (event_id, date, label, description, gates_open, gates_close, is_cancelled)
         values (v_event_id, p_date, p_label, p_description, p_gates_open, p_gates_close, coalesce(p_is_cancelled, false))
      returning id into v_id;
  else
    update public.event_schedule_days
       set date         = coalesce(p_date,         date),
           label        = coalesce(p_label,        label),
           description  = coalesce(p_description,  description),
           gates_open   = coalesce(p_gates_open,   gates_open),
           gates_close  = coalesce(p_gates_close,  gates_close),
           is_cancelled = coalesce(p_is_cancelled, is_cancelled),
           updated_at   = now()
     where id = p_id and event_id = v_event_id
     returning id into v_id;
    if v_id is null then return jsonb_build_object('ok', false, 'error', 'not_on_event'); end if;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;


ALTER FUNCTION "public"."upsert_schedule_day"("p_token" "text", "p_id" "uuid", "p_date" "date", "p_label" "text", "p_description" "text", "p_gates_open" time without time zone, "p_gates_close" time without time zone, "p_is_cancelled" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_schedule_item"("p_token" "text", "p_id" "uuid" DEFAULT NULL::"uuid", "p_day_id" "uuid" DEFAULT NULL::"uuid", "p_title" "text" DEFAULT NULL::"text", "p_subtitle" "text" DEFAULT NULL::"text", "p_start_time" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_end_time" timestamp with time zone DEFAULT NULL::timestamp with time zone, "p_venue_override" "text" DEFAULT NULL::"text", "p_category" "text" DEFAULT NULL::"text", "p_image_url" "text" DEFAULT NULL::"text", "p_is_featured" boolean DEFAULT false, "p_is_must_see" boolean DEFAULT false, "p_is_published" boolean DEFAULT true) RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_event_id uuid;
  v_id uuid;
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  if coalesce(btrim(p_title), '') = '' then return jsonb_build_object('ok', false, 'error', 'title_required'); end if;
  if p_day_id is null then return jsonb_build_object('ok', false, 'error', 'day_required'); end if;
  if not exists (select 1 from public.event_schedule_days where id = p_day_id and event_id = v_event_id) then
    return jsonb_build_object('ok', false, 'error', 'day_not_on_event');
  end if;

  if p_id is null then
    insert into public.event_schedule_items (
      event_id, day_id, title, subtitle, start_time, end_time, venue_override,
      category, image_url, is_featured, is_must_see, is_published
    )
    values (
      v_event_id, p_day_id, btrim(p_title), nullif(btrim(p_subtitle), ''),
      p_start_time, p_end_time, nullif(btrim(p_venue_override), ''),
      nullif(btrim(p_category), ''), nullif(btrim(p_image_url), ''),
      coalesce(p_is_featured, false), coalesce(p_is_must_see, false),
      coalesce(p_is_published, true)
    )
    returning id into v_id;
  else
    update public.event_schedule_items
       set day_id         = coalesce(p_day_id, day_id),
           title          = coalesce(nullif(btrim(p_title), ''), title),
           subtitle       = case when p_subtitle is not null then nullif(btrim(p_subtitle), '') else subtitle end,
           start_time     = case when p_start_time is not null then p_start_time else start_time end,
           end_time       = case when p_end_time is not null then p_end_time else end_time end,
           venue_override = case when p_venue_override is not null then nullif(btrim(p_venue_override), '') else venue_override end,
           category       = case when p_category is not null then nullif(btrim(p_category), '') else category end,
           image_url      = case when p_image_url is not null then nullif(btrim(p_image_url), '') else image_url end,
           is_featured    = coalesce(p_is_featured, is_featured),
           is_must_see    = coalesce(p_is_must_see, is_must_see),
           is_published   = coalesce(p_is_published, is_published)
     where id = p_id and event_id = v_event_id
     returning id into v_id;
    if v_id is null then return jsonb_build_object('ok', false, 'error', 'item_not_on_event'); end if;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;


ALTER FUNCTION "public"."upsert_schedule_item"("p_token" "text", "p_id" "uuid", "p_day_id" "uuid", "p_title" "text", "p_subtitle" "text", "p_start_time" timestamp with time zone, "p_end_time" timestamp with time zone, "p_venue_override" "text", "p_category" "text", "p_image_url" "text", "p_is_featured" boolean, "p_is_must_see" boolean, "p_is_published" boolean) OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_ticket_location"("p_token" "text", "p_id" "uuid" DEFAULT NULL::"uuid", "p_name" "text" DEFAULT NULL::"text", "p_is_online" boolean DEFAULT false, "p_ticket_url" "text" DEFAULT NULL::"text", "p_provider_type" "text" DEFAULT NULL::"text", "p_address" "text" DEFAULT NULL::"text", "p_town" "text" DEFAULT NULL::"text", "p_parish" "text" DEFAULT NULL::"text", "p_contact_phone" "text" DEFAULT NULL::"text", "p_opening_hours" "text" DEFAULT NULL::"text", "p_latitude" double precision DEFAULT NULL::double precision, "p_longitude" double precision DEFAULT NULL::double precision, "p_place_slug" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_event_id uuid;
  v_id       uuid;
  v_slug     text := nullif(btrim(p_place_slug), '');
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  if p_name is null or btrim(p_name) = '' then
    return jsonb_build_object('ok', false, 'error', 'name_required');
  end if;

  -- When a slug is supplied it must point at a real listing.
  if v_slug is not null and not exists (select 1 from public.places where slug = v_slug) then
    return jsonb_build_object('ok', false, 'error', 'unknown_place_slug');
  end if;

  if p_id is null then
    insert into public.ticket_locations (
      event_id, name, address, parish, town, contact_phone, opening_hours,
      is_online, ticket_url, provider_type, latitude, longitude, place_slug, is_active
    ) values (
      v_event_id, p_name, p_address, p_parish, p_town, p_contact_phone, p_opening_hours,
      coalesce(p_is_online, false), p_ticket_url, p_provider_type, p_latitude, p_longitude, v_slug, true
    ) returning id into v_id;
  else
    update public.ticket_locations
       set name           = coalesce(p_name,          name),
           address        = coalesce(p_address,       address),
           parish         = coalesce(p_parish,        parish),
           town           = coalesce(p_town,          town),
           contact_phone  = coalesce(p_contact_phone, contact_phone),
           opening_hours  = coalesce(p_opening_hours, opening_hours),
           is_online      = coalesce(p_is_online,     is_online),
           ticket_url     = coalesce(p_ticket_url,    ticket_url),
           provider_type  = coalesce(p_provider_type, provider_type),
           latitude       = coalesce(p_latitude,      latitude),
           longitude      = coalesce(p_longitude,     longitude),
           -- null param leaves it; empty string clears the link.
           place_slug     = case when p_place_slug is null then place_slug else v_slug end,
           updated_at     = now()
     where id = p_id and event_id = v_event_id
     returning id into v_id;
    if v_id is null then return jsonb_build_object('ok', false, 'error', 'not_on_event'); end if;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;


ALTER FUNCTION "public"."upsert_ticket_location"("p_token" "text", "p_id" "uuid", "p_name" "text", "p_is_online" boolean, "p_ticket_url" "text", "p_provider_type" "text", "p_address" "text", "p_town" "text", "p_parish" "text", "p_contact_phone" "text", "p_opening_hours" "text", "p_latitude" double precision, "p_longitude" double precision, "p_place_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."upsert_transport_route"("p_token" "text", "p_id" "uuid" DEFAULT NULL::"uuid", "p_name" "text" DEFAULT NULL::"text", "p_color" "text" DEFAULT '#0a7aff'::"text", "p_direction" "text" DEFAULT 'both'::"text", "p_frequency" "text" DEFAULT NULL::"text") RETURNS "jsonb"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_event_id uuid; v_id uuid;
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  if p_name is null or btrim(p_name) = '' then
    return jsonb_build_object('ok', false, 'error', 'name_required');
  end if;
  if p_direction not in ('both', 'to_event', 'return') then
    return jsonb_build_object('ok', false, 'error', 'invalid_direction');
  end if;

  if p_id is null then
    insert into public.event_transport_routes (event_id, name, color, direction, frequency)
         values (v_event_id, p_name, coalesce(p_color, '#0a7aff'), p_direction, p_frequency)
      returning id into v_id;
  else
    update public.event_transport_routes
       set name      = coalesce(p_name,      name),
           color     = coalesce(p_color,     color),
           direction = coalesce(p_direction, direction),
           frequency = coalesce(p_frequency, frequency)
     where id = p_id and event_id = v_event_id
     returning id into v_id;
    if v_id is null then return jsonb_build_object('ok', false, 'error', 'not_on_event'); end if;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;


ALTER FUNCTION "public"."upsert_transport_route"("p_token" "text", "p_id" "uuid", "p_name" "text", "p_color" "text", "p_direction" "text", "p_frequency" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."validate_place_slug"("p_slug" "text") RETURNS "jsonb"
    LANGUAGE "sql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
  select coalesce(
    (select jsonb_build_object('exists', true, 'slug', slug, 'name', name)
       from public.places where slug = nullif(btrim(p_slug), '') limit 1),
    jsonb_build_object('exists', false, 'slug', nullif(btrim(p_slug), ''), 'name', null)
  );
$$;


ALTER FUNCTION "public"."validate_place_slug"("p_slug" "text") OWNER TO "postgres";


CREATE OR REPLACE FUNCTION "public"."vote_change_request"("_request_id" "uuid", "_vote" "text") RETURNS "text"
    LANGUAGE "plpgsql" SECURITY DEFINER
    SET "search_path" TO 'public'
    AS $$
declare
  v_user uuid := auth.uid();
  r record;
  v_other_count integer;
  v_approvals integer;
  v_rejections integer;
  v_threshold integer;
begin
  if v_user is null then raise exception 'must be signed in'; end if;
  if _vote not in ('approve', 'reject') then raise exception 'invalid vote'; end if;

  select * into r from public.trip_change_requests where id = _request_id for update;
  if r.id is null then raise exception 'request not found'; end if;
  if r.status <> 'pending' then raise exception 'request already %', r.status; end if;
  if not public.has_trip_access(r.trip_id) then raise exception 'no access'; end if;
  if r.proposed_by = v_user then raise exception 'cannot vote on your own request'; end if;

  insert into public.trip_change_votes (request_id, user_id, vote)
  values (_request_id, v_user, _vote)
  on conflict (request_id, user_id) do update set vote = excluded.vote, created_at = now();

  v_other_count := public.trip_other_voter_count(r.trip_id, r.proposed_by);
  -- Strict majority: approvals * 2 > total eligible voters.
  v_threshold := v_other_count;

  select count(*) into v_approvals
    from public.trip_change_votes where request_id = _request_id and vote = 'approve';
  select count(*) into v_rejections
    from public.trip_change_votes where request_id = _request_id and vote = 'reject';

  if v_approvals * 2 > v_threshold then
    perform public._apply_change_request(_request_id);
    return 'applied';
  end if;

  if v_rejections * 2 > v_threshold then
    update public.trip_change_requests
      set status = 'rejected', resolved_at = now()
      where id = _request_id;
    return 'rejected';
  end if;

  return 'pending';
end $$;


ALTER FUNCTION "public"."vote_change_request"("_request_id" "uuid", "_vote" "text") OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."achievements" (
    "id" "text" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text" NOT NULL,
    "category" "text" NOT NULL,
    "icon" "text" NOT NULL,
    "badge_color" "text" DEFAULT '#0077cc'::"text",
    "points" integer DEFAULT 10,
    "max_progress" integer DEFAULT 1,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "rarity" "text" DEFAULT 'common'::"text",
    "is_hidden" boolean DEFAULT false NOT NULL,
    "bonus_xp" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "achievements_rarity_check" CHECK (("rarity" = ANY (ARRAY['common'::"text", 'rare'::"text", 'epic'::"text", 'legendary'::"text"])))
);


ALTER TABLE "public"."achievements" OWNER TO "postgres";


COMMENT ON COLUMN "public"."achievements"."points" IS 'Deprecated. Use bonus_xp + xp_transactions instead.';



CREATE TABLE IF NOT EXISTS "public"."event_sponsor_activations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid",
    "sponsor_id" "uuid",
    "event_sponsor_id" "uuid",
    "name" "text" NOT NULL,
    "description" "text",
    "zone" "text",
    "days_active" "text"[],
    "start_time" time without time zone,
    "end_time" time without time zone,
    "troddr_offer" "text",
    "qr_code_token" "text" DEFAULT ("gen_random_uuid"())::"text",
    "nfc_token" "text",
    "checkin_method" "text" DEFAULT 'self'::"text",
    "display_order" integer DEFAULT 0,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."event_sponsor_activations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."sponsors" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "slug" "text",
    "logo_url" "text",
    "logo_variant" "text",
    "website" "text",
    "description" "text",
    "instagram" "text",
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "brand_color" "text",
    CONSTRAINT "sponsors_logo_variant_check" CHECK (("logo_variant" = ANY (ARRAY['light'::"text", 'dark'::"text", 'transparent'::"text"])))
);


ALTER TABLE "public"."sponsors" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_event_activity" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "event_id" "uuid" NOT NULL,
    "activity_type" "text" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "country" "text",
    "entity_type" "text",
    "entity_id" "uuid",
    "action" "text",
    "checkin_method" "text" DEFAULT 'self'::"text",
    "idempotency_key" "text",
    CONSTRAINT "user_event_activity_activity_type_check" CHECK (("activity_type" = ANY (ARRAY['bookmarked'::"text", 'interested'::"text", 'going'::"text", 'shared'::"text", 'visited'::"text", 'checked_in'::"text"]))),
    CONSTRAINT "user_event_activity_checkin_method_check" CHECK (("checkin_method" = ANY (ARRAY['qr'::"text", 'nfc'::"text", 'self'::"text"])))
);


ALTER TABLE "public"."user_event_activity" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."activation_funnel" AS
 SELECT "esa"."event_id",
    "esa"."id" AS "activation_id",
    "esa"."name" AS "activation_name",
    "s"."name" AS "sponsor_name",
    "count"(*) FILTER (WHERE ("uea"."activity_type" = 'visited'::"text")) AS "checkins",
    "count"(*) FILTER (WHERE ("uea"."activity_type" = 'redeemed'::"text")) AS "redemptions",
    "round"(((("count"(*) FILTER (WHERE ("uea"."activity_type" = 'redeemed'::"text")))::numeric / (NULLIF("count"(*) FILTER (WHERE ("uea"."activity_type" = 'visited'::"text")), 0))::numeric) * (100)::numeric), 1) AS "redemption_rate_pct"
   FROM (("public"."event_sponsor_activations" "esa"
     JOIN "public"."sponsors" "s" ON (("s"."id" = "esa"."sponsor_id")))
     LEFT JOIN "public"."user_event_activity" "uea" ON ((("uea"."entity_id" = "esa"."id") AND ("uea"."entity_type" = 'sponsor_activation'::"text"))))
  GROUP BY "esa"."event_id", "esa"."id", "esa"."name", "s"."name";


ALTER VIEW "public"."activation_funnel" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."admin_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "token" "text" DEFAULT "encode"("extensions"."gen_random_bytes"(24), 'hex'::"text") NOT NULL,
    "label" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."admin_tokens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."alerts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "place_id" "uuid",
    "applies_to" "text" DEFAULT 'place'::"text",
    "country" "text",
    "parish" "text",
    "location" "jsonb",
    "title" "text" NOT NULL,
    "description" "text",
    "alert_type" "text",
    "severity" "text" DEFAULT 'info'::"text",
    "start_date" timestamp with time zone NOT NULL,
    "end_date" timestamp with time zone,
    "is_recurring" boolean DEFAULT false,
    "recurrence_rule" "text",
    "icon" "text",
    "priority" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "alerts_alert_type_check" CHECK (("alert_type" = ANY (ARRAY['holiday'::"text", 'weather'::"text", 'seasonal'::"text", 'event'::"text", 'maintenance'::"text", 'other'::"text"]))),
    CONSTRAINT "alerts_applies_to_check" CHECK (("applies_to" = ANY (ARRAY['place'::"text", 'region'::"text", 'global'::"text"]))),
    CONSTRAINT "alerts_severity_check" CHECK (("severity" = ANY (ARRAY['info'::"text", 'warning'::"text", 'critical'::"text"])))
);


ALTER TABLE "public"."alerts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."analytics_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "user_id" "uuid",
    "session_id" "text" NOT NULL,
    "event_name" "text" NOT NULL,
    "entity_type" "text",
    "entity_id" "text",
    "source_screen" "text",
    "source_component" "text",
    "source_context" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "device_platform" "text",
    "app_version" "text"
);


ALTER TABLE "public"."analytics_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."app_config" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "latest_version" "text" NOT NULL,
    "update_message" "text",
    "force_update" boolean DEFAULT false,
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."app_config" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."app_settings" (
    "key" "text" NOT NULL,
    "value" "text" NOT NULL
);


ALTER TABLE "public"."app_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."bands" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "slug" "text" NOT NULL,
    "description" "text",
    "logo_url" "text",
    "cover_image_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."bands" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."billing_accounts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "partner_id" "uuid" NOT NULL,
    "plan_key" "text" DEFAULT 'foundation_loyalty'::"text" NOT NULL,
    "included_specials_per_location" integer DEFAULT 2 NOT NULL,
    "extra_special_price_amount" numeric,
    "currency" "text" DEFAULT 'JMD'::"text" NOT NULL,
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "payment_provider" "text",
    "payment_customer_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "billing_accounts_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'past_due'::"text", 'paused'::"text", 'cancelled'::"text"])))
);


ALTER TABLE "public"."billing_accounts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."billing_audit_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "actor_type" "text" NOT NULL,
    "actor_label" "text",
    "company_account_id" "uuid",
    "invoice_id" "uuid",
    "subscription_id" "uuid",
    "action" "text" NOT NULL,
    "details" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "billing_audit_log_actor_type_check" CHECK (("actor_type" = ANY (ARRAY['admin'::"text", 'company_user'::"text", 'system'::"text"])))
);


ALTER TABLE "public"."billing_audit_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."billing_notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "notification_type" "text" NOT NULL,
    "company_account_id" "uuid",
    "invoice_id" "uuid",
    "request_id" "uuid",
    "recipient_email" "text",
    "subject" "text" NOT NULL,
    "body" "text",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sent_at" timestamp with time zone,
    CONSTRAINT "billing_notifications_notification_type_check" CHECK (("notification_type" = ANY (ARRAY['invoice_issued'::"text", 'invoice_overdue'::"text", 'payment_reported'::"text", 'payment_approved'::"text", 'payment_rejected'::"text", 'clarification_requested'::"text", 'subscription_activated'::"text", 'subscription_read_only'::"text", 'renewal_invoice_generated'::"text", 'request_submitted'::"text", 'company_setup_request'::"text"]))),
    CONSTRAINT "billing_notifications_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'sent'::"text", 'failed'::"text", 'dismissed'::"text"])))
);


ALTER TABLE "public"."billing_notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."billing_products" (
    "code" "text" NOT NULL,
    "item_type" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "unit_amount" numeric,
    "min_amount" numeric,
    "max_amount" numeric,
    "currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "billing_unit" "text" DEFAULT 'one_time'::"text" NOT NULL,
    "entitlements" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "billing_products_billing_unit_check" CHECK (("billing_unit" = ANY (ARRAY['one_time'::"text", 'month'::"text", 'year'::"text", 'per_location_month'::"text", 'per_location_year'::"text", 'per_day'::"text"]))),
    CONSTRAINT "billing_products_item_type_check" CHECK (("item_type" = ANY (ARRAY['founding_partner_subscription'::"text", 'otr_basic'::"text", 'otr_premium'::"text", 'location_insights'::"text", 'company_insights'::"text", 'event_lite'::"text", 'event_pro'::"text", 'major_event_hub'::"text", 'flagship_event'::"text", 'carnival_hub'::"text", 'carnival_band_hub'::"text", 'carnival_event_listing'::"text", 'carnival_event_pro'::"text", 'event_series_hub'::"text", 'event_insights'::"text", 'premium_event_map'::"text", 'sponsor_activation'::"text", 'sponsor_report'::"text", 'custom'::"text"])))
);


ALTER TABLE "public"."billing_products" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."billing_settings" (
    "key" "text" NOT NULL,
    "value" "jsonb" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."billing_settings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."billing_usage" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "billing_account_id" "uuid" NOT NULL,
    "partner_id" "uuid" NOT NULL,
    "place_id" "uuid",
    "event_id" "uuid",
    "source_type" "text" NOT NULL,
    "source_id" "uuid" NOT NULL,
    "usage_type" "text" NOT NULL,
    "status" "text" DEFAULT 'pending_approval'::"text" NOT NULL,
    "amount" numeric,
    "currency" "text" DEFAULT 'JMD'::"text" NOT NULL,
    "cycle_start" "date" NOT NULL,
    "cycle_end" "date" NOT NULL,
    "description" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "billing_usage_status_check" CHECK (("status" = ANY (ARRAY['pending_approval'::"text", 'ready_to_invoice'::"text", 'invoiced'::"text", 'paid'::"text", 'void'::"text"])))
);


ALTER TABLE "public"."billing_usage" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."booking_cancellation_policies" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "place_id" "uuid",
    "rate_plan_id" "uuid",
    "policy_name" "text" NOT NULL,
    "policy_text" "text" NOT NULL,
    "free_cancel_hours" integer,
    "is_non_refundable" boolean DEFAULT false NOT NULL,
    "deposit_forfeiture_notes" "text",
    "partner_override_notes" "text",
    "is_default" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."booking_cancellation_policies" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."booking_notification_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "booking_id" "uuid",
    "template" "text" NOT NULL,
    "recipient_email" "text" NOT NULL,
    "status" "text" DEFAULT 'sent'::"text" NOT NULL,
    "error_message" "text",
    "retry_count" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."booking_notification_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."booking_room_allocations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "booking_id" "uuid" NOT NULL,
    "room_type_id" "uuid" NOT NULL,
    "rate_plan_id" "uuid",
    "rooms_allocated" integer DEFAULT 1 NOT NULL,
    "check_in_date" "date" NOT NULL,
    "check_out_date" "date" NOT NULL,
    "nightly_rate" numeric(12,2),
    "currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."booking_room_allocations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."booking_timeline_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "booking_id" "uuid" NOT NULL,
    "old_status" "text",
    "new_status" "text",
    "actor_type" "text" DEFAULT 'system'::"text" NOT NULL,
    "actor_id" "uuid",
    "actor_email" "text",
    "message" "text",
    "metadata" "jsonb",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."booking_timeline_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."businesses" (
    "id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "email" "text" NOT NULL,
    "listing_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "is_admin" boolean DEFAULT false
);


ALTER TABLE "public"."businesses" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."company_accounts" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "billing_email" "text" NOT NULL,
    "contact_name" "text",
    "contact_phone" "text",
    "status" "text" DEFAULT 'active'::"text" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "account_type" "text" DEFAULT 'hospitality_group'::"text" NOT NULL,
    "source_type" "text" DEFAULT 'manual'::"text" NOT NULL,
    "source_id" "uuid",
    "legal_name" "text",
    "trading_name" "text",
    "billing_phone" "text",
    "country" "text",
    "address" "text",
    "tax_id" "text",
    "preferred_currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "onboarding_status" "text" DEFAULT 'billing_info_required'::"text" NOT NULL,
    "onboarded_by_role" "text",
    "onboarding_profile" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "onboarding_quote" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    CONSTRAINT "company_accounts_account_type_check" CHECK (("account_type" = ANY (ARRAY['hospitality_group'::"text", 'event_host'::"text", 'sponsor'::"text", 'mixed'::"text"]))),
    CONSTRAINT "company_accounts_onboarding_status_check" CHECK (("onboarding_status" = ANY (ARRAY['not_started'::"text", 'pending_company_review'::"text", 'billing_info_required'::"text", 'complete'::"text"]))),
    CONSTRAINT "company_accounts_preferred_currency_check" CHECK (("preferred_currency" = ANY (ARRAY['USD'::"text", 'JMD'::"text"]))),
    CONSTRAINT "company_accounts_source_type_check" CHECK (("source_type" = ANY (ARRAY['place_group'::"text", 'event_organizer'::"text", 'sponsor'::"text", 'manual'::"text"]))),
    CONSTRAINT "company_accounts_status_check" CHECK (("status" = ANY (ARRAY['active'::"text", 'suspended'::"text", 'archived'::"text"])))
);


ALTER TABLE "public"."company_accounts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."company_entitlements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_account_id" "uuid" NOT NULL,
    "entitlement_key" "text" NOT NULL,
    "source" "text" DEFAULT 'manual'::"text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "starts_at" "date" DEFAULT CURRENT_DATE NOT NULL,
    "expires_at" "date",
    "source_invoice_id" "uuid",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "company_entitlements_source_check" CHECK (("source" = ANY (ARRAY['plan'::"text", 'addon'::"text", 'manual'::"text"])))
);


ALTER TABLE "public"."company_entitlements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."company_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_account_id" "uuid" NOT NULL,
    "event_id" "uuid" NOT NULL,
    "relationship_type" "text" DEFAULT 'host'::"text" NOT NULL,
    "status" "text" DEFAULT 'approved'::"text" NOT NULL,
    "comped" boolean DEFAULT false NOT NULL,
    "package_product_code" "text",
    "approved_by" "text",
    "approved_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "company_events_relationship_type_check" CHECK (("relationship_type" = ANY (ARRAY['host'::"text", 'organizer'::"text", 'sponsor'::"text", 'vendor'::"text", 'production_partner'::"text"]))),
    CONSTRAINT "company_events_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'approved'::"text", 'inactive'::"text", 'removed'::"text"])))
);


ALTER TABLE "public"."company_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."company_locations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_account_id" "uuid" NOT NULL,
    "place_id" "uuid" NOT NULL,
    "label" "text",
    "status" "text" DEFAULT 'approved'::"text" NOT NULL,
    "approved_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "approved_by" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "company_locations_status_check" CHECK (("status" = ANY (ARRAY['approved'::"text", 'removed'::"text"])))
);


ALTER TABLE "public"."company_locations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."company_onboarding_invites" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "token" "text" DEFAULT "encode"("extensions"."gen_random_bytes"(24), 'hex'::"text") NOT NULL,
    "company_account_id" "uuid" NOT NULL,
    "email" "text" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "claimable" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "expires_at" timestamp with time zone DEFAULT ("now"() + '14 days'::interval) NOT NULL,
    "created_by" "text",
    "accepted_at" timestamp with time zone,
    "accepted_user_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "company_onboarding_invites_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'accepted'::"text", 'expired'::"text", 'revoked'::"text"])))
);


ALTER TABLE "public"."company_onboarding_invites" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."company_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_account_id" "uuid" NOT NULL,
    "requested_by" "uuid",
    "request_type" "text" NOT NULL,
    "message" "text",
    "status" "text" DEFAULT 'new'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "resolved_at" timestamp with time zone,
    "related_location_id" "uuid",
    "related_event_id" "uuid",
    "admin_notes" "text",
    CONSTRAINT "company_requests_request_type_check" CHECK (("request_type" = ANY (ARRAY['extra_admins'::"text", 'insights'::"text", 'location_insights'::"text", 'company_insights'::"text", 'event_coverage'::"text", 'event_insights'::"text", 'sponsor_activation'::"text", 'sponsor_report'::"text", 'billing_help'::"text", 'other'::"text"]))),
    CONSTRAINT "company_requests_status_check" CHECK (("status" = ANY (ARRAY['new'::"text", 'in_review'::"text", 'quoted'::"text", 'invoiced'::"text", 'completed'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."company_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."company_setup_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "email" "text" NOT NULL,
    "legal_name" "text" NOT NULL,
    "trading_name" "text",
    "contact_name" "text",
    "billing_phone" "text",
    "country" "text",
    "address" "text",
    "tax_id" "text",
    "preferred_currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "business_type" "text" DEFAULT 'hospitality_group'::"text" NOT NULL,
    "role_title" "text",
    "message" "text",
    "status" "text" DEFAULT 'pending_review'::"text" NOT NULL,
    "review_note" "text",
    "reviewed_by" "text",
    "reviewed_at" timestamp with time zone,
    "created_company_id" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "company_setup_requests_business_type_check" CHECK (("business_type" = ANY (ARRAY['hospitality_group'::"text", 'event_host'::"text", 'sponsor'::"text", 'mixed'::"text"]))),
    CONSTRAINT "company_setup_requests_preferred_currency_check" CHECK (("preferred_currency" = ANY (ARRAY['USD'::"text", 'JMD'::"text"]))),
    CONSTRAINT "company_setup_requests_status_check" CHECK (("status" = ANY (ARRAY['pending_review'::"text", 'approved'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."company_setup_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."dish_likes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "dish_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "place_id" "uuid" NOT NULL,
    "liked" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "country" "text"
);


ALTER TABLE "public"."dish_likes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."entitlement_definitions" (
    "key" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "category" "text" DEFAULT 'core'::"text" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    CONSTRAINT "entitlement_definitions_category_check" CHECK (("category" = ANY (ARRAY['core'::"text", 'listing'::"text", 'insights'::"text", 'event'::"text", 'sponsor'::"text"])))
);


ALTER TABLE "public"."entitlement_definitions" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."event_activation_summary" AS
SELECT
    NULL::"uuid" AS "id",
    NULL::"uuid" AS "event_id",
    NULL::"uuid" AS "sponsor_id",
    NULL::"text" AS "name",
    NULL::"text" AS "zone",
    NULL::"text"[] AS "days_active",
    NULL::time without time zone AS "start_time",
    NULL::time without time zone AS "end_time",
    NULL::"text" AS "troddr_offer",
    NULL::"text" AS "qr_code_token",
    NULL::integer AS "display_order",
    NULL::"text" AS "sponsor_name",
    NULL::"text" AS "sponsor_brand_color",
    NULL::"text" AS "sponsor_logo_url",
    NULL::bigint AS "checkin_count";


ALTER VIEW "public"."event_activation_summary" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."event_analytics" AS
 SELECT "entity_id" AS "event_id",
    "count"(*) FILTER (WHERE ("event_name" = 'event_viewed'::"text")) AS "total_views",
    "count"(DISTINCT "session_id") FILTER (WHERE ("event_name" = 'event_viewed'::"text")) AS "unique_viewers",
    "count"(*) FILTER (WHERE ("event_name" = 'ticket_clicked'::"text")) AS "ticket_clicks",
    "count"(*) FILTER (WHERE ("event_name" = 'vendor_clicked'::"text")) AS "vendor_clicks",
    "count"(*) FILTER (WHERE ("event_name" = 'event_saved'::"text")) AS "saves",
    "count"(*) FILTER (WHERE ("event_name" = 'event_attended'::"text")) AS "attendance",
    "count"(*) FILTER (WHERE ("event_name" = 'share_clicked'::"text")) AS "shares",
    "max"("created_at") FILTER (WHERE ("event_name" = 'event_viewed'::"text")) AS "last_viewed"
   FROM "public"."analytics_events" "e"
  WHERE ("entity_type" = 'event'::"text")
  GROUP BY "entity_id";


ALTER VIEW "public"."event_analytics" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_analytics_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "event_name" "text" NOT NULL,
    "user_id" "uuid",
    "anon_device_id" "text",
    "session_id" "text",
    "tab_key" "text",
    "vendor_id" "uuid",
    "sponsor_id" "uuid",
    "activation_id" "uuid",
    "band_id" "uuid",
    "notification_id" "uuid",
    "notification_category" "text",
    "target_url" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "event_analytics_events_event_name_check" CHECK (("event_name" = ANY (ARRAY['event_open'::"text", 'tab_view'::"text", 'interest_interested'::"text", 'interest_going'::"text", 'interest_went'::"text", 'ticket_click'::"text", 'schedule_save'::"text", 'schedule_remove'::"text", 'map_view'::"text", 'map_marker_click'::"text", 'map_vendor_click'::"text", 'vendor_tab_view'::"text", 'vendor_card_click'::"text", 'vendor_view'::"text", 'vendor_social_click'::"text", 'vendor_listing_click'::"text", 'sponsor_view'::"text", 'sponsor_link_click'::"text", 'activation_checkin'::"text", 'activation_redemption'::"text", 'band_view'::"text", 'band_link_click'::"text", 'band_subtab_select'::"text", 'event_pass_view'::"text", 'event_pass_qr_open'::"text", 'outbound_link_click'::"text", 'push_sent'::"text", 'push_opened'::"text"]))),
    CONSTRAINT "event_analytics_events_notification_category_check" CHECK ((("notification_category" IS NULL) OR ("notification_category" = ANY (ARRAY['reminder'::"text", 'promo'::"text", 'logistics'::"text", 'emergency'::"text"]))))
);


ALTER TABLE "public"."event_analytics_events" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."event_analytics_rollup" AS
 SELECT "event_id",
    "event_name",
    "count"(*) AS "total",
    "count"(DISTINCT COALESCE(("user_id")::"text", "anon_device_id")) AS "unique_attendees"
   FROM "public"."event_analytics_events" "e"
  GROUP BY "event_id", "event_name";


ALTER VIEW "public"."event_analytics_rollup" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_bands" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "band_id" "uuid" NOT NULL
);


ALTER TABLE "public"."event_bands" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_interests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "event_id" "uuid" NOT NULL,
    "status" "text" NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "event_interests_status_check" CHECK (("status" = ANY (ARRAY['interested'::"text", 'going'::"text", 'went'::"text"])))
);


ALTER TABLE "public"."event_interests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_map_invites" (
    "token" "text" DEFAULT "encode"("extensions"."gen_random_bytes"(16), 'hex'::"text") NOT NULL,
    "event_id" "uuid" NOT NULL,
    "designer_name" "text",
    "designer_email" "text",
    "scopes" "text"[] DEFAULT '{markers}'::"text"[] NOT NULL,
    "expires_at" timestamp with time zone NOT NULL,
    "used_at" timestamp with time zone,
    "revoked_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."event_map_invites" OWNER TO "postgres";


COMMENT ON TABLE "public"."event_map_invites" IS 'Scoped tokens that let a designer (no full partner access) edit only the floor-plan markers for one event.';



CREATE TABLE IF NOT EXISTS "public"."event_map_points" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "event_vendor_id" "uuid",
    "name" "text",
    "type" "text" NOT NULL,
    "x" numeric NOT NULL,
    "y" numeric NOT NULL,
    "icon" "text",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."event_map_points" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_notification_deliveries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "notification_type" "text" NOT NULL,
    "sent_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "event_notification_deliveries_notification_type_check" CHECK (("notification_type" = ANY (ARRAY['t_minus_2'::"text", 'day_of'::"text"])))
);


ALTER TABLE "public"."event_notification_deliveries" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_partner_submission_assets" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "submission_id" "uuid",
    "token" "text" NOT NULL,
    "asset_key" "text" NOT NULL,
    "file_name" "text",
    "file_url" "text" NOT NULL,
    "content_type" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."event_partner_submission_assets" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_partner_submissions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "token" "text" NOT NULL,
    "status" "text" DEFAULT 'draft'::"text",
    "contact_name" "text",
    "contact_email" "text",
    "contact_phone" "text",
    "event_name" "text",
    "event_description" "text",
    "event_start_date" "text",
    "event_end_date" "text",
    "gates_open" "text",
    "estimated_attendance" "text",
    "venue_name" "text",
    "venue_address" "text",
    "venue_lat" "text",
    "venue_lng" "text",
    "website" "text",
    "instagram" "text",
    "facebook" "text",
    "twitter" "text",
    "logo_url" "text",
    "hero_url" "text",
    "gallery_urls" "jsonb" DEFAULT '[]'::"jsonb",
    "performers" "jsonb" DEFAULT '[]'::"jsonb",
    "vendors" "jsonb" DEFAULT '[]'::"jsonb",
    "floor_plan_url" "text",
    "floor_plan_annotated_url" "text",
    "placement_notes" "text",
    "stage_count" "text",
    "stage_names" "text",
    "sponsors" "jsonb" DEFAULT '[]'::"jsonb",
    "tickets" "jsonb" DEFAULT '[]'::"jsonb",
    "ticketing_platform" "text",
    "tickets_url" "text",
    "parking_info" "text",
    "parking_map_url" "text",
    "accessibility_info" "text",
    "reentry_policy" "text",
    "prohibited_items" "text",
    "age_restriction" "text",
    "faqs" "jsonb" DEFAULT '[]'::"jsonb",
    "promos" "jsonb" DEFAULT '[]'::"jsonb",
    "additional_notes" "text",
    "submitted_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "event_type" "text",
    "organizer_name" "text",
    "event_id" "uuid",
    CONSTRAINT "event_partner_submissions_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'submitted'::"text", 'reviewing'::"text", 'approved'::"text", 'archived'::"text"])))
);


ALTER TABLE "public"."event_partner_submissions" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."event_partner_submission_summary" AS
 SELECT "id",
    "token",
    "status",
    "contact_name",
    "contact_email",
    "event_name",
    "event_start_date",
    "event_end_date",
    "venue_name",
    "submitted_at",
    "created_at",
    "updated_at",
    "jsonb_array_length"(COALESCE("performers", '[]'::"jsonb")) AS "performer_count",
    "jsonb_array_length"(COALESCE("vendors", '[]'::"jsonb")) AS "vendor_count",
    "jsonb_array_length"(COALESCE("sponsors", '[]'::"jsonb")) AS "sponsor_count",
    "jsonb_array_length"(COALESCE("tickets", '[]'::"jsonb")) AS "ticket_count",
    "jsonb_array_length"(COALESCE("promos", '[]'::"jsonb")) AS "promo_count"
   FROM "public"."event_partner_submissions";


ALTER VIEW "public"."event_partner_submission_summary" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_push_notifications" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "body" "text",
    "category" "text" NOT NULL,
    "approved" boolean DEFAULT false NOT NULL,
    "scheduled_at" timestamp with time zone,
    "sent_at" timestamp with time zone,
    "sent_count" integer DEFAULT 0 NOT NULL,
    "opened_count" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "event_push_notifications_category_check" CHECK (("category" = ANY (ARRAY['reminder'::"text", 'promo'::"text", 'logistics'::"text", 'emergency'::"text"])))
);


ALTER TABLE "public"."event_push_notifications" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "slug" "text" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text",
    "start_date" "date" NOT NULL,
    "end_date" "date" NOT NULL,
    "start_time" time without time zone,
    "end_time" time without time zone,
    "is_all_day" boolean DEFAULT false,
    "timezone" "text" DEFAULT 'America/Jamaica'::"text",
    "place_id" "uuid",
    "venue_name" "text",
    "venue_address" "text",
    "parish" "text",
    "town" "text",
    "event_type" "text" DEFAULT 'general'::"text" NOT NULL,
    "image_urls" "text"[] DEFAULT '{}'::"text"[],
    "featured_image_url" "text",
    "is_free" boolean DEFAULT false,
    "ticket_price_min" numeric(10,2),
    "ticket_price_max" numeric(10,2),
    "currency" "text" DEFAULT 'JMD'::"text",
    "status" "text" DEFAULT 'published'::"text",
    "is_featured" boolean DEFAULT false,
    "priority" integer DEFAULT 0,
    "going_count" integer DEFAULT 0,
    "interested_count" integer DEFAULT 0,
    "view_count" integer DEFAULT 0,
    "is_recurring" boolean DEFAULT false,
    "recurring_pattern" "text",
    "recurring_days" "text"[],
    "recurring_end_date" "date",
    "organizer_name" "text",
    "organizer_id" "uuid",
    "contact_email" "text",
    "contact_phone" "text",
    "website_url" "text",
    "ticket_url" "text",
    "has_online_tickets" boolean DEFAULT false,
    "is_sold_out" boolean DEFAULT false,
    "capacity" integer,
    "discount_percentage" integer,
    "discount_amount" numeric(10,2),
    "discount_code" "text",
    "promo_text" "text",
    "vibe_tags" "text"[],
    "short_description" "text",
    "dress_code" "text",
    "min_age" integer,
    "weather_dependent" boolean DEFAULT false,
    "food_available" boolean DEFAULT false,
    "alcohol_served" boolean DEFAULT false,
    "is_partnership" boolean DEFAULT false,
    "partner_name" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "created_by" "uuid",
    "deleted_at" timestamp with time zone,
    "country" "text",
    "venue_lat" double precision,
    "venue_lng" double precision,
    "parent_event_id" "uuid",
    "floor_plan_url" "text",
    "floor_plan_markers" "jsonb",
    "parking_image_url" "text",
    "parking_image_urls" "jsonb",
    "faq" "jsonb",
    "info_sections" "jsonb",
    "support_email" "text",
    "support_phone" "text",
    "support_url" "text",
    "tabs" "jsonb",
    "band_id" "uuid",
    "map_calibration" "jsonb",
    "map_features" "jsonb" DEFAULT '{}'::"jsonb",
    "has_offline_map" boolean DEFAULT false,
    "visibility" "text" DEFAULT 'public'::"text",
    "allowed_user_ids" "uuid"[],
    "partner_access_token" "text" DEFAULT "encode"("extensions"."gen_random_bytes"(16), 'hex'::"text"),
    "partner_id" "uuid",
    "instagram_url" "text",
    CONSTRAINT "events_no_self_parent" CHECK ((("parent_event_id" IS NULL) OR ("parent_event_id" <> "id"))),
    CONSTRAINT "events_valid_event_chronology" CHECK ((("start_date" IS NULL) OR ("end_date" IS NULL) OR ("end_date" > "start_date") OR (("end_date" = "start_date") AND (("start_time" IS NULL) OR ("end_time" IS NULL) OR ("end_time" >= "start_time"))))),
    CONSTRAINT "valid_dates" CHECK (("end_date" >= "start_date")),
    CONSTRAINT "valid_event_type" CHECK (("event_type" = ANY (ARRAY['music'::"text", 'food and drink'::"text", 'art'::"text", 'sports'::"text", 'festival'::"text", 'carnival'::"text", 'family'::"text", 'wellness'::"text", 'general'::"text"]))),
    CONSTRAINT "valid_prices" CHECK ((("ticket_price_min" IS NULL) OR ("ticket_price_max" IS NULL) OR ("ticket_price_max" >= "ticket_price_min"))),
    CONSTRAINT "valid_status" CHECK (("status" = ANY (ARRAY['draft'::"text", 'published'::"text", 'cancelled'::"text", 'postponed'::"text", 'completed'::"text"])))
);


ALTER TABLE "public"."events" OWNER TO "postgres";


COMMENT ON COLUMN "public"."events"."floor_plan_url" IS 'Public URL of the uploaded floor plan image (PNG/JPG). Lives in the event-floorplans Storage bucket.';



COMMENT ON COLUMN "public"."events"."floor_plan_markers" IS 'Array of floor-plan elements, discriminated by "type" (entries with no type are legacy pins). pin: {id,type?,x,y,label,icon,color,vendor_id,booth,size,description} · booth: {id,type,x,y,w,h,number,label,icon,color,vendor_id,size,description} · zone: {id,type,x,y,w,h,label,color,description} · table: {id,type,x,y,w,h,shape,color} · text: {id,type,x,y,label,color,fontSize}. x/y are CENTER fractions (0-1) of the canvas; w/h are fractions of canvas width/height — resolution-agnostic. Renderers that only understand pins can fall back to showing any element as a pin at its centre.';



COMMENT ON COLUMN "public"."events"."tabs" IS 'Ordered array of tab configs: [{"key": "home", "label": "Home"}, ...].
   Valid keys: home | schedule | map | vendors | my_plan | tickets | info | sponsors | events | concierge.
   If NULL the app falls back to the SERIES_TABS default for the event_type.';



CREATE OR REPLACE VIEW "public"."event_retention_30d" AS
 WITH "attendees" AS (
         SELECT DISTINCT "a"."event_id",
            COALESCE(("a"."user_id")::"text", "a"."anon_device_id") AS "attendee"
           FROM "public"."event_analytics_events" "a"
          WHERE (COALESCE(("a"."user_id")::"text", "a"."anon_device_id") IS NOT NULL)
        ), "windows" AS (
         SELECT "ev"."id" AS "event_id",
            COALESCE("ev"."end_date", "ev"."start_date") AS "ended_on"
           FROM "public"."events" "ev"
        )
 SELECT "w"."event_id",
    "count"(DISTINCT "att"."attendee") AS "event_attendees",
    "count"(DISTINCT "att"."attendee") FILTER (WHERE (EXISTS ( SELECT 1
           FROM "public"."event_analytics_events" "later"
          WHERE ((COALESCE(("later"."user_id")::"text", "later"."anon_device_id") = "att"."attendee") AND (("later"."created_at")::"date" > "w"."ended_on") AND (("later"."created_at")::"date" <= ("w"."ended_on" + 30)))))) AS "retained_30d"
   FROM ("attendees" "att"
     JOIN "windows" "w" ON (("w"."event_id" = "att"."event_id")))
  GROUP BY "w"."event_id";


ALTER VIEW "public"."event_retention_30d" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_schedule_days" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "date" "date" NOT NULL,
    "label" character varying(50),
    "date_display" character varying(20),
    "description" "text",
    "gates_open" time without time zone,
    "gates_close" time without time zone,
    "is_cancelled" boolean DEFAULT false,
    "day_number" integer DEFAULT 1,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."event_schedule_days" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_schedule_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "day_id" "uuid" NOT NULL,
    "track_id" "uuid",
    "title" character varying(200) NOT NULL,
    "subtitle" character varying(200),
    "description" "text",
    "start_time" timestamp with time zone NOT NULL,
    "end_time" timestamp with time zone NOT NULL,
    "original_start_time" timestamp with time zone,
    "original_end_time" timestamp with time zone,
    "status" "public"."schedule_item_status" DEFAULT 'scheduled'::"public"."schedule_item_status",
    "delay_minutes" integer DEFAULT 0,
    "status_message" "text",
    "category" character varying(50),
    "tags" "text"[],
    "image_url" "text",
    "venue_override" character varying(200),
    "is_featured" boolean DEFAULT false,
    "is_must_see" boolean DEFAULT false,
    "version" integer DEFAULT 1,
    "is_published" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."event_schedule_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_schedule_meta" (
    "event_id" "uuid" NOT NULL,
    "current_version" integer DEFAULT 1,
    "last_updated" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."event_schedule_meta" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_schedule_tracks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "name" character varying(100) NOT NULL,
    "short_name" character varying(20),
    "description" "text",
    "color" character varying(7) DEFAULT '#0077CC'::character varying,
    "icon" character varying(50),
    "track_type" "public"."schedule_track_type" DEFAULT 'stage'::"public"."schedule_track_type",
    "venue_section" character varying(100),
    "display_order" integer DEFAULT 0,
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."event_schedule_tracks" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."event_series_rollup" AS
 SELECT COALESCE("ev"."parent_event_id", "ev"."id") AS "parent_event_id",
    "a"."event_name",
    "count"(*) AS "total",
    "count"(DISTINCT COALESCE(("a"."user_id")::"text", "a"."anon_device_id")) AS "unique_attendees",
    "count"(DISTINCT "a"."event_id") AS "events_with_activity"
   FROM ("public"."event_analytics_events" "a"
     JOIN "public"."events" "ev" ON (("ev"."id" = "a"."event_id")))
  GROUP BY COALESCE("ev"."parent_event_id", "ev"."id"), "a"."event_name";


ALTER VIEW "public"."event_series_rollup" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_sponsors" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "sponsor_id" "uuid" NOT NULL,
    "tier" "text" NOT NULL,
    "display_tier_label" "text",
    "display_order" integer DEFAULT 0,
    "is_featured" boolean DEFAULT false,
    "custom_tagline" "text",
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."event_sponsors" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_transport_routes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "color" "text" NOT NULL,
    "direction" "text" DEFAULT 'both'::"text",
    "frequency" "text",
    "display_order" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "event_transport_routes_direction_check" CHECK (("direction" = ANY (ARRAY['to_event'::"text", 'return'::"text", 'both'::"text"])))
);


ALTER TABLE "public"."event_transport_routes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_transport_stops" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "route_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "notes" "text",
    "image_url" "text",
    "latitude" numeric,
    "longitude" numeric,
    "display_order" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."event_transport_stops" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_transport_times" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "route_id" "uuid" NOT NULL,
    "stop_id" "uuid" NOT NULL,
    "time" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."event_transport_times" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_updates" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "message" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."event_updates" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."event_vendors" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "vendor_id" "uuid" NOT NULL,
    "booth_number" "text",
    "is_featured" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "zone" "text",
    "tags" "text"[],
    "filter_tags" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "display_name" "text"
);


ALTER TABLE "public"."event_vendors" OWNER TO "postgres";


COMMENT ON COLUMN "public"."event_vendors"."zone" IS 'Event-specific location/group label for vendor filtering, such as ''Di Truck Stop'', ''Courtyard'', or ''Main Lawn''. Cuisine/category filters continue to live in event_vendors.tags.';



COMMENT ON COLUMN "public"."event_vendors"."tags" IS 'Filter tags for this vendor at this event e.g. {coffee, seafood, vegan}';



CREATE TABLE IF NOT EXISTS "public"."vendor_menu_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_vendor_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "price" numeric(10,2),
    "currency" "text",
    "category" "text",
    "is_special" boolean DEFAULT false,
    "is_sold_out" boolean DEFAULT false,
    "image_url" "text",
    "sort_order" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "tags" "text"[],
    "price_label" "text"
);


ALTER TABLE "public"."vendor_menu_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."vendors" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "vendor_type" "text",
    "logo_url" "text",
    "cover_image_url" "text",
    "instagram" "text",
    "website" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "place_id" "uuid",
    "place_slug" "text"
);


ALTER TABLE "public"."vendors" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."event_vendors_with_menu" AS
 SELECT "e"."id" AS "event_id",
    "e"."slug" AS "event_slug",
    "e"."title" AS "event_title",
    "e"."town" AS "event_town",
    "e"."parish" AS "event_parish",
    "e"."start_date",
    "e"."end_date",
    "e"."currency" AS "event_currency",
    "v"."id" AS "vendor_id",
    "v"."name" AS "vendor_name",
    "v"."description" AS "vendor_description",
    "v"."vendor_type",
    "v"."logo_url",
    "v"."cover_image_url",
    "v"."instagram",
    "v"."website",
    "v"."place_id" AS "vendor_place_id",
    "p"."id" AS "place_id",
    "p"."slug" AS "place_slug",
    "p"."name" AS "place_name",
    "p"."image" AS "place_image",
    "p"."category" AS "place_category",
    "ev"."id" AS "event_vendor_id",
    "ev"."booth_number",
    "ev"."is_featured" AS "vendor_is_featured",
    "mi"."id" AS "menu_item_id",
    "mi"."name" AS "menu_item_name",
    "mi"."description" AS "menu_item_description",
    "mi"."price",
    COALESCE("mi"."currency", "e"."currency") AS "currency",
    "mi"."category" AS "menu_category",
    "mi"."tags",
    "mi"."is_special",
    "mi"."is_sold_out",
    "mi"."image_url" AS "menu_image_url",
    "mi"."sort_order"
   FROM (((("public"."events" "e"
     JOIN "public"."event_vendors" "ev" ON (("ev"."event_id" = "e"."id")))
     JOIN "public"."vendors" "v" ON (("v"."id" = "ev"."vendor_id")))
     LEFT JOIN "public"."places" "p" ON (("p"."id" = "v"."place_id")))
     LEFT JOIN "public"."vendor_menu_items" "mi" ON (("mi"."event_vendor_id" = "ev"."id")));


ALTER VIEW "public"."event_vendors_with_menu" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."favorites" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" DEFAULT "gen_random_uuid"(),
    "place_id" "uuid" DEFAULT "gen_random_uuid"(),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "country" "text"
);


ALTER TABLE "public"."favorites" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."favourite_guides" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "guide_slug" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "country" "text"
);


ALTER TABLE "public"."favourite_guides" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."specials" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "place_id" "uuid",
    "title" "text" NOT NULL,
    "description" "text",
    "special_type" "text" NOT NULL,
    "start_date" timestamp with time zone NOT NULL,
    "end_date" timestamp with time zone NOT NULL,
    "recurring_days" "text"[] DEFAULT '{}'::"text"[],
    "recurring_rule" "text",
    "discount_percentage" numeric(5,2),
    "discount_amount" numeric(10,2),
    "partner_name" "text",
    "priority" integer DEFAULT 0,
    "active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "start_time" time without time zone,
    "end_time" time without time zone,
    "special_slug" "text",
    "image_urls" "text"[] DEFAULT '{}'::"text"[],
    "address_line1" "text",
    "address_line2" "text",
    "town" "text",
    "parish" "text",
    "latitude" numeric(10,8),
    "longitude" numeric(11,8),
    "price_type" "text",
    "price_amount" numeric(10,2),
    "currency" "text" DEFAULT 'JMD'::"text",
    "age_restriction" "text",
    "event_category" "text",
    "event_tags" "text"[] DEFAULT '{}'::"text"[],
    "host_name" "text",
    "ticket_link" "text",
    "rsvp_link" "text",
    "country" "text",
    "instagram_url" "text",
    "event_slug" "text",
    "menu_items" "jsonb",
    "submission_status" "text" DEFAULT 'approved'::"text" NOT NULL,
    "submitted_at" timestamp with time zone,
    "submitted_via" "text",
    "review_note" "text",
    "reviewed_at" timestamp with time zone,
    "reviewed_by" "text",
    "capacity" integer,
    "billing_account_id" "uuid",
    "billing_usage_id" "uuid",
    "billing_status" "text" DEFAULT 'included'::"text" NOT NULL,
    "billing_amount" numeric,
    "billing_currency" "text" DEFAULT 'JMD'::"text" NOT NULL,
    "billing_note" "text",
    "bookings_enabled" boolean DEFAULT false NOT NULL,
    CONSTRAINT "special_type_allowed" CHECK (("special_type" = ANY (ARRAY['partnership'::"text", 'local_discount'::"text", 'seasonal'::"text", 'general'::"text", 'event'::"text", 'travel_special'::"text"]))),
    CONSTRAINT "specials_billing_status_check" CHECK (("billing_status" = ANY (ARRAY['included'::"text", 'pending_billable'::"text", 'billable'::"text", 'void'::"text"]))),
    CONSTRAINT "specials_special_type_check" CHECK (("special_type" = ANY (ARRAY['partnership'::"text", 'local_discount'::"text", 'seasonal'::"text", 'general'::"text", 'event'::"text", 'travel_special'::"text"]))),
    CONSTRAINT "specials_submission_status_check" CHECK (("submission_status" = ANY (ARRAY['draft'::"text", 'pending'::"text", 'approved'::"text", 'rejected'::"text"])))
);


ALTER TABLE "public"."specials" OWNER TO "postgres";


COMMENT ON COLUMN "public"."specials"."capacity" IS 'Maximum confirmed-or-pending reservations before new ones are routed to the waitlist. NULL = unlimited.';



COMMENT ON COLUMN "public"."specials"."bookings_enabled" IS 'Whether this special accepts reservations through TRODDR. When false, the detail page falls back to ticket_link / rsvp_link as before.';



CREATE TABLE IF NOT EXISTS "public"."visited" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "place_id" "uuid" DEFAULT "gen_random_uuid"(),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "notes" "text",
    "vote" "text",
    "country" "text",
    "visit_count" integer DEFAULT 1 NOT NULL,
    CONSTRAINT "visited_vote_check" CHECK (("vote" = ANY (ARRAY['up'::"text", 'down'::"text"])))
);


ALTER TABLE "public"."visited" OWNER TO "postgres";


COMMENT ON TABLE "public"."visited" IS 'This is a duplicate of favorites';



CREATE OR REPLACE VIEW "public"."user_visit_counts" WITH ("security_invoker"='on') AS
 SELECT "user_id",
    "place_id",
    ("count"(*))::integer AS "visits"
   FROM "public"."visited" "v"
  GROUP BY "user_id", "place_id";


ALTER VIEW "public"."user_visit_counts" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."featured_places" WITH ("security_invoker"='on') AS
 SELECT "p"."id",
    "p"."name",
    "p"."slug",
    "p"."town",
    "p"."parish",
    "p"."category",
    "p"."image",
    "p"."rating",
    "p"."latitude",
    "p"."longitude",
    "p"."price_range",
    "p"."cuisine",
    "p"."type",
    "p"."meal_type",
    "p"."recommended_dishes",
    "p"."is_featured",
    COALESCE("count"(DISTINCT "f"."user_id"), (0)::bigint) AS "favorite_count",
    COALESCE("sum"("vc"."visits"), (0)::bigint) AS "visit_count",
    "s"."id" AS "special_id",
    "s"."title" AS "special_title",
    "s"."description" AS "special_description",
    "s"."special_type",
    "s"."partner_name",
    "s"."priority",
    "s"."start_date" AS "special_start_date",
    "s"."end_date" AS "special_end_date"
   FROM ((("public"."places" "p"
     LEFT JOIN "public"."specials" "s" ON ((("s"."place_id" = "p"."id") AND ("s"."active" = true) AND ((CURRENT_DATE >= ("s"."start_date")::"date") AND (CURRENT_DATE <= ("s"."end_date")::"date")))))
     LEFT JOIN "public"."favorites" "f" ON (("f"."place_id" = "p"."id")))
     LEFT JOIN "public"."user_visit_counts" "vc" ON (("vc"."place_id" = "p"."id")))
  WHERE (("p"."is_featured" = true) OR ("s"."id" IS NOT NULL))
  GROUP BY "p"."id", "p"."name", "p"."slug", "p"."town", "p"."parish", "p"."category", "p"."image", "p"."rating", "p"."latitude", "p"."longitude", "p"."price_range", "p"."cuisine", "p"."type", "p"."meal_type", "p"."recommended_dishes", "p"."is_featured", "s"."id", "s"."title", "s"."description", "s"."special_type", "s"."partner_name", "s"."priority", "s"."start_date", "s"."end_date";


ALTER VIEW "public"."featured_places" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."feedback" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "user_id" "uuid",
    "username" "text",
    "category" "text" NOT NULL,
    "feedback" "text" NOT NULL,
    "upvotes" integer DEFAULT 0,
    "status" "text" DEFAULT 'submitted'::"text",
    "team_response" "text",
    "responded_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "feedback_status_check" CHECK (("status" = ANY (ARRAY['submitted'::"text", 'under_review'::"text", 'planned'::"text", 'in_progress'::"text", 'completed'::"text"])))
);


ALTER TABLE "public"."feedback" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."feedback_sorted" AS
 SELECT "id",
    "user_id",
    "username",
    "category",
    "feedback",
    "upvotes",
    "status",
    "team_response",
    "responded_at",
    "created_at"
   FROM "public"."feedback"
  ORDER BY "upvotes" DESC, "created_at" DESC;


ALTER VIEW "public"."feedback_sorted" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."guide_analytics" AS
 SELECT "entity_id" AS "guide_id",
    "count"(*) FILTER (WHERE ("event_name" = 'guide_viewed'::"text")) AS "total_views",
    "count"(DISTINCT "session_id") FILTER (WHERE ("event_name" = 'guide_viewed'::"text")) AS "unique_viewers",
    "count"(*) FILTER (WHERE ("event_name" = 'guide_saved'::"text")) AS "saves",
    "count"(*) FILTER (WHERE ("event_name" = 'share_clicked'::"text")) AS "shares",
    "max"("created_at") FILTER (WHERE ("event_name" = 'guide_viewed'::"text")) AS "last_viewed"
   FROM "public"."analytics_events" "e"
  WHERE ("entity_type" = 'guide'::"text")
  GROUP BY "entity_id";


ALTER VIEW "public"."guide_analytics" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."guide_route_steps" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "guide_slug" "text" NOT NULL,
    "place_slug" "text",
    "step_order" integer NOT NULL,
    "step_type" "text" DEFAULT 'place'::"text",
    "section" "text",
    "duration_minutes" integer,
    "start_offset_minutes" integer,
    "notes" "text",
    "transport_to_next" "text",
    "travel_time_to_next" integer,
    "distance_to_next_km" numeric(5,2),
    "is_optional" boolean DEFAULT false,
    "country" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "guide_route_steps_section_check" CHECK (("section" = ANY (ARRAY['morning'::"text", 'afternoon'::"text", 'evening'::"text", 'night'::"text"]))),
    CONSTRAINT "guide_route_steps_step_type_check" CHECK (("step_type" = ANY (ARRAY['place'::"text", 'activity'::"text", 'transition'::"text"])))
);


ALTER TABLE "public"."guide_route_steps" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."guide_spots" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "guide_slug" "text",
    "place_slug" "text",
    "custom_blurb" "text",
    "section" "text",
    "order" integer,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "country" "text"
);


ALTER TABLE "public"."guide_spots" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."guides" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "title" "text",
    "slug" "text" NOT NULL,
    "image_url" "text",
    "description" "text",
    "location" "text",
    "category" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "place_slugs" "text",
    "type" "text",
    "is_itinerary_guide" boolean DEFAULT false,
    "country" "text",
    "is_guided_route" boolean DEFAULT false,
    "total_duration_minutes" integer,
    "best_for" "text"
);


ALTER TABLE "public"."guides" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hotel_availability" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "place_id" "uuid" NOT NULL,
    "room_type_id" "uuid" NOT NULL,
    "stay_date" "date" NOT NULL,
    "available_rooms" integer DEFAULT 0 NOT NULL,
    "is_closed" boolean DEFAULT false NOT NULL,
    "is_blackout" boolean DEFAULT false NOT NULL,
    "closed_to_arrival" boolean DEFAULT false NOT NULL,
    "closed_to_departure" boolean DEFAULT false NOT NULL,
    "min_nights" integer DEFAULT 1,
    "max_nights" integer,
    "base_nightly_rate" numeric(12,2),
    "currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."hotel_availability" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hotel_inventory_holds" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "place_id" "uuid" NOT NULL,
    "room_type_id" "uuid" NOT NULL,
    "booking_id" "uuid",
    "rooms_held" integer DEFAULT 1 NOT NULL,
    "check_in_date" "date" NOT NULL,
    "check_out_date" "date" NOT NULL,
    "session_id" "text",
    "expires_at" timestamp with time zone NOT NULL,
    "released_at" timestamp with time zone,
    "is_converted" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."hotel_inventory_holds" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hotel_rate_plans" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "room_type_id" "uuid" NOT NULL,
    "place_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "cancellation_policy" "text",
    "meal_plan" "text",
    "inclusions" "text",
    "is_refundable" boolean DEFAULT true NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."hotel_rate_plans" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."hotel_room_types" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "place_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "max_guests" integer DEFAULT 2 NOT NULL,
    "base_occupancy" integer DEFAULT 1,
    "room_count" integer DEFAULT 1 NOT NULL,
    "amenities" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "images" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "display_order" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."hotel_room_types" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."invoice_counters" (
    "year" integer NOT NULL,
    "last_number" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."invoice_counters" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."invoice_line_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "invoice_id" "uuid" NOT NULL,
    "item_type" "text" NOT NULL,
    "product_code" "text",
    "description" "text" NOT NULL,
    "quantity" numeric DEFAULT 1 NOT NULL,
    "unit_amount" numeric DEFAULT 0 NOT NULL,
    "amount" numeric DEFAULT 0 NOT NULL,
    "period_start" "date",
    "period_end" "date",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "invoice_line_items_item_type_check" CHECK (("item_type" = ANY (ARRAY['founding_partner_subscription'::"text", 'otr_basic'::"text", 'otr_premium'::"text", 'location_insights'::"text", 'company_insights'::"text", 'event_lite'::"text", 'event_pro'::"text", 'major_event_hub'::"text", 'flagship_event'::"text", 'carnival_hub'::"text", 'carnival_band_hub'::"text", 'carnival_event_listing'::"text", 'carnival_event_pro'::"text", 'event_series_hub'::"text", 'event_insights'::"text", 'premium_event_map'::"text", 'sponsor_activation'::"text", 'sponsor_report'::"text", 'custom'::"text"])))
);


ALTER TABLE "public"."invoice_line_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."invoices" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_account_id" "uuid" NOT NULL,
    "invoice_number" "text",
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "issue_date" "date",
    "due_date" "date",
    "period_start" "date",
    "period_end" "date",
    "subtotal" numeric DEFAULT 0 NOT NULL,
    "discount_amount" numeric DEFAULT 0 NOT NULL,
    "discount_note" "text",
    "total" numeric DEFAULT 0 NOT NULL,
    "notes" "text",
    "payment_instructions" "text",
    "internal_notes" "text",
    "issued_at" timestamp with time zone,
    "paid_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "invoices_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'issued'::"text", 'payment_reported'::"text", 'paid'::"text", 'rejected'::"text", 'void'::"text", 'overdue'::"text"])))
);


ALTER TABLE "public"."invoices" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."itineraries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" DEFAULT "gen_random_uuid"(),
    "title" "text",
    "destination" "text",
    "start_date" "date",
    "end_date" "date",
    "slugs" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "place_count" integer,
    "trip_completed" boolean DEFAULT false,
    "alerts_enabled" boolean DEFAULT false,
    "country" "text",
    "source_itinerary_id" "uuid",
    "start_location" "text"
);


ALTER TABLE "public"."itineraries" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."itinerary_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "entry_id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "itinerary_id" "uuid" NOT NULL,
    "event_id" "uuid" NOT NULL,
    "planned_day" "text",
    "time_slot" "text",
    "start_time" "text",
    "end_time" "text",
    "order" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"()
);

ALTER TABLE ONLY "public"."itinerary_events" REPLICA IDENTITY FULL;


ALTER TABLE "public"."itinerary_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."itinerary_places" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "itinerary_id" "uuid" NOT NULL,
    "place_id" "uuid",
    "planned_day" "date",
    "planned_time" "text",
    "sort_order" smallint,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "origin" "text",
    "origin_lat" double precision,
    "origin_lng" double precision,
    "destination" "text",
    "destination_lat" double precision,
    "destination_lng" double precision,
    "order" integer,
    "visited" boolean DEFAULT false,
    "country" "text",
    "entry_id" "uuid" DEFAULT "gen_random_uuid"(),
    "time_slot" "text",
    "is_note" boolean DEFAULT false NOT NULL,
    "note_text" "text",
    CONSTRAINT "itinerary_places_time_slot_check" CHECK (("time_slot" = ANY (ARRAY['morning'::"text", 'lunch'::"text", 'afternoon'::"text", 'dinner'::"text", 'evening'::"text"])))
);

ALTER TABLE ONLY "public"."itinerary_places" REPLICA IDENTITY FULL;


ALTER TABLE "public"."itinerary_places" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."itinerary_shares" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "itinerary_id" "uuid" NOT NULL,
    "token" "text" NOT NULL,
    "expires_at" timestamp with time zone,
    "created_by" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "view_count" integer DEFAULT 0 NOT NULL
);


ALTER TABLE "public"."itinerary_shares" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."loyalty_program_locations" (
    "program_id" "uuid" NOT NULL,
    "place_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."loyalty_program_locations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."loyalty_redemptions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "program_id" "uuid" NOT NULL,
    "card_id" "uuid" NOT NULL,
    "place_id" "uuid" NOT NULL,
    "user_id" "uuid",
    "reward" "text" NOT NULL,
    "stamps_spent" integer NOT NULL,
    "cycle_number" integer DEFAULT 1 NOT NULL,
    "source" "text" DEFAULT 'partner_dashboard'::"text" NOT NULL,
    "redeemed_by" "text",
    "notes" "text",
    "redeemed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "loyalty_redemptions_source_check" CHECK (("source" = ANY (ARRAY['app'::"text", 'partner_dashboard'::"text", 'staff'::"text", 'migration'::"text", 'other'::"text"])))
);


ALTER TABLE "public"."loyalty_redemptions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."loyalty_visits" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "card_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "place_id" "uuid" NOT NULL,
    "nfc_tag_id" "text",
    "stamped_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."loyalty_visits" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."mas_bands" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "season_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "slug" "text" NOT NULL,
    "tagline" "text",
    "logo_url" "text",
    "cover_url" "text",
    "description" "text",
    "accent_color" "text",
    "website_url" "text",
    "ig_handle" "text",
    "registration_url" "text",
    "registration_deadline" "date",
    "band_launch_event_id" "uuid",
    "sections" "jsonb" DEFAULT '[]'::"jsonb",
    "sort_order" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."mas_bands" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."member_perks" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "place_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "description" "text" NOT NULL,
    "membership_tier" "text" DEFAULT 'all'::"text",
    "booking_url" "text",
    "starts_at" timestamp with time zone,
    "ends_at" timestamp with time zone,
    "is_active" boolean DEFAULT true,
    "requires_login" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "headline" "text",
    "subheadline" "text",
    "offer_type" "text" DEFAULT 'member_offer'::"text",
    "value_display" "text",
    "value_label" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb"
);


ALTER TABLE "public"."member_perks" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."menu_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "place_id" "uuid" NOT NULL,
    "canonical_name" "text" NOT NULL,
    "aliases" "text"[] DEFAULT '{}'::"text"[] NOT NULL,
    "category" "text",
    "description" "text",
    "price" numeric,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "elo_rating" integer DEFAULT 1000 NOT NULL,
    "comparison_count" integer DEFAULT 0 NOT NULL,
    "total_reviews" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "menu_items_category_check" CHECK (("category" = ANY (ARRAY['breakfast'::"text", 'main'::"text", 'dessert'::"text", 'coffee'::"text", 'cocktail'::"text", 'drink'::"text", 'appetizer'::"text", 'side'::"text"])))
);


ALTER TABLE "public"."menu_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."nfc_tags" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "tag_code" "public"."citext" NOT NULL,
    "place_id" "uuid",
    "event_id" "uuid",
    "tag_type" "text" NOT NULL,
    "xp_override" integer,
    "label" "text",
    "active" boolean DEFAULT true NOT NULL,
    "expires_at" timestamp with time zone,
    "deactivated_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "fallback_code" "public"."citext",
    CONSTRAINT "nfc_tags_code_length" CHECK ((("length"(("tag_code")::"text") >= 6) AND ("length"(("tag_code")::"text") <= 32))),
    CONSTRAINT "nfc_tags_fallback_code_lowercase_check" CHECK ((("fallback_code" IS NULL) OR (("fallback_code")::"text" = "lower"(("fallback_code")::"text")))),
    CONSTRAINT "nfc_tags_has_target" CHECK ((("place_id" IS NOT NULL) OR ("event_id" IS NOT NULL))),
    CONSTRAINT "nfc_tags_tag_code_lowercase_check" CHECK ((("tag_code")::"text" = "lower"(("tag_code")::"text"))),
    CONSTRAINT "nfc_tags_tag_type_check" CHECK (("tag_type" = ANY (ARRAY['loyalty'::"text", 'checkin'::"text", 'sponsor_activation'::"text", 'passport'::"text"])))
);


ALTER TABLE "public"."nfc_tags" OWNER TO "postgres";


COMMENT ON TABLE "public"."nfc_tags" IS 'NFC tag registry. Access restricted to service_role via Edge Functions. RLS denies all client access by default.';



CREATE TABLE IF NOT EXISTS "public"."notification_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "itinerary_id" "uuid",
    "notification_type" "text" NOT NULL,
    "sent_at" timestamp with time zone DEFAULT "now"(),
    "special_id" "uuid",
    "schedule_item_id" "uuid",
    "achievement_id" "text",
    "title" "text",
    "body" "text",
    "delivery_status" "text",
    "visit_id" "uuid",
    "collaboration_id" "uuid",
    "trip_id" "uuid",
    "event_id" "uuid"
);


ALTER TABLE "public"."notification_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."organizers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "slug" "text" NOT NULL,
    "logo_url" "text",
    "bio" "text",
    "email" "text",
    "phone" "text",
    "instagram" "text",
    "website_url" "text",
    "verified" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."organizers" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."partner_messages" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "partner_id" "uuid",
    "place_id" "uuid",
    "event_id" "uuid",
    "source_page" "text",
    "subject" "text",
    "message" "text" NOT NULL,
    "status" "text" DEFAULT 'new'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "resolved_at" timestamp with time zone,
    CONSTRAINT "partner_messages_status_check" CHECK (("status" = ANY (ARRAY['new'::"text", 'in_progress'::"text", 'resolved'::"text"])))
);


ALTER TABLE "public"."partner_messages" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."partners" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "name" "text" NOT NULL,
    "contact_email" "text",
    "notes" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."partners" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."passport_entries" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "loyalty_program_id" "uuid",
    "user_loyalty_card_id" "uuid",
    "business_name" "text" NOT NULL,
    "reward" "text",
    "completed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "total_stamps" integer NOT NULL,
    "completed_cycles" integer DEFAULT 1,
    "primary_color" "text",
    "accent_color" "text",
    "text_color" "text",
    "secondary_color" "text",
    "watermark_icon" "text",
    "card_texture" "text",
    "tier" "text" DEFAULT 'standard'::"text",
    "edition_name" "text",
    "event_id" "uuid",
    "snapshot" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."passport_entries" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payment_confirmations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "invoice_id" "uuid" NOT NULL,
    "company_account_id" "uuid" NOT NULL,
    "submitted_by" "uuid",
    "payment_method" "text" NOT NULL,
    "paid_on" "date" NOT NULL,
    "reference_number" "text" NOT NULL,
    "receipt_url" "text",
    "notes" "text",
    "status" "text" DEFAULT 'submitted'::"text" NOT NULL,
    "review_note" "text",
    "reviewed_at" timestamp with time zone,
    "reviewed_by" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "receipt_filename" "text",
    "receipt_size_bytes" bigint,
    "receipt_mime" "text",
    CONSTRAINT "payment_confirmations_payment_method_check" CHECK (("payment_method" = ANY (ARRAY['bank_transfer'::"text", 'cash'::"text", 'cheque'::"text", 'card'::"text", 'mobile_money'::"text", 'other'::"text"]))),
    CONSTRAINT "payment_confirmations_status_check" CHECK (("status" = ANY (ARRAY['submitted'::"text", 'approved'::"text", 'rejected'::"text", 'needs_clarification'::"text"])))
);


ALTER TABLE "public"."payment_confirmations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."payment_instructions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "bank_name" "text" NOT NULL,
    "account_name" "text" NOT NULL,
    "branch_name" "text",
    "currency" "text" NOT NULL,
    "account_type" "text",
    "account_number" "text",
    "routing_or_swift" "text",
    "payment_notes" "text",
    "active" boolean DEFAULT true NOT NULL,
    "display_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "payment_instructions_currency_check" CHECK (("currency" = ANY (ARRAY['USD'::"text", 'JMD'::"text"])))
);


ALTER TABLE "public"."payment_instructions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."performer_group_members" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "group_performer_id" "uuid" NOT NULL,
    "member_performer_id" "uuid" NOT NULL,
    "display_order" integer DEFAULT 0 NOT NULL,
    "role_in_session" "text"
);


ALTER TABLE "public"."performer_group_members" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."performer_schedule" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "performer_id" "uuid" NOT NULL,
    "schedule_item_id" "uuid" NOT NULL,
    "role" "text"
);


ALTER TABLE "public"."performer_schedule" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."performers" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "slug" "text" NOT NULL,
    "profile_type" "text" DEFAULT 'performer'::"text" NOT NULL,
    "name" "text" NOT NULL,
    "position" "text",
    "bio" "text",
    "image_url" "text",
    "cover_image_url" "text",
    "company_name" "text",
    "company_logo_url" "text",
    "company_description" "text",
    "company_website" "text",
    "session_title" "text",
    "session_format" "text",
    "session_description" "text",
    "award_category" "text",
    "award_year" integer,
    "award_status" "text",
    "instagram_url" "text",
    "linkedin_url" "text",
    "twitter_url" "text",
    "website_url" "text",
    "spotify_url" "text",
    "youtube_url" "text",
    "primary_category" "text",
    "tags" "text"[] DEFAULT '{}'::"text"[],
    "extra_fields" "jsonb" DEFAULT '{}'::"jsonb",
    "event_slug" "text",
    "place_id" "uuid",
    "town" "text",
    "parish" "text",
    "country" "text",
    "status" "text" DEFAULT 'draft'::"text" NOT NULL,
    "active" boolean DEFAULT true NOT NULL,
    "priority" integer DEFAULT 0 NOT NULL,
    "is_group" boolean DEFAULT false NOT NULL,
    "view_count" integer DEFAULT 0 NOT NULL,
    "created_by" "uuid",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "performers_award_status_check" CHECK (("award_status" = ANY (ARRAY['nominee'::"text", 'finalist'::"text", 'winner'::"text"]))),
    CONSTRAINT "performers_profile_type_check" CHECK (("profile_type" = ANY (ARRAY['performer'::"text", 'speaker'::"text", 'awardee'::"text", 'host'::"text", 'vendor'::"text", 'moderator'::"text"]))),
    CONSTRAINT "performers_session_format_check" CHECK (("session_format" = ANY (ARRAY['keynote'::"text", 'panel'::"text", 'fireside'::"text", 'workshop'::"text", 'performance'::"text"]))),
    CONSTRAINT "performers_status_check" CHECK (("status" = ANY (ARRAY['draft'::"text", 'published'::"text", 'archived'::"text"])))
);


ALTER TABLE "public"."performers" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."place_analytics" AS
 SELECT "entity_id" AS "place_id",
    "count"(*) FILTER (WHERE ("event_name" = 'place_viewed'::"text")) AS "total_views",
    "count"(DISTINCT "session_id") FILTER (WHERE ("event_name" = 'place_viewed'::"text")) AS "unique_viewers",
    "count"(*) FILTER (WHERE (("event_name" = 'place_viewed'::"text") AND ("created_at" >= "date_trunc"('day'::"text", "now"())))) AS "views_today",
    "count"(*) FILTER (WHERE (("event_name" = 'place_viewed'::"text") AND ("created_at" >= ("now"() - '7 days'::interval)))) AS "views_this_week",
    "count"(*) FILTER (WHERE (("event_name" = 'place_viewed'::"text") AND ("created_at" >= ("now"() - '30 days'::interval)))) AS "views_this_month",
    "max"("created_at") FILTER (WHERE ("event_name" = 'place_viewed'::"text")) AS "last_viewed",
    "count"(*) FILTER (WHERE ("event_name" = 'place_saved'::"text")) AS "saves",
    "count"(*) FILTER (WHERE ("event_name" = 'menu_viewed'::"text")) AS "menu_opens",
    "count"(*) FILTER (WHERE ("event_name" = ANY (ARRAY['outbound_link_clicked'::"text", 'website_clicked'::"text", 'instagram_clicked'::"text", 'phone_clicked'::"text", 'directions_clicked'::"text", 'booking_clicked'::"text"]))) AS "outbound_clicks",
    "count"(*) FILTER (WHERE ("event_name" = 'booking_clicked'::"text")) AS "booking_clicks",
    "count"(*) FILTER (WHERE ("event_name" = 'loyalty_check_in'::"text")) AS "loyalty_check_ins"
   FROM "public"."analytics_events" "e"
  WHERE ("entity_type" = 'place'::"text")
  GROUP BY "entity_id";


ALTER VIEW "public"."place_analytics" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."visited_feedback" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "place_id" "uuid" NOT NULL,
    "rating_service" integer,
    "rating_vibe" integer,
    "rating_value" integer,
    "rating_wait_time" integer,
    "rating_cleanliness" integer,
    "quick_tags" "text"[] DEFAULT '{}'::"text"[],
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "rating_taste" integer,
    "rating_ambiance" integer,
    "rating_speed" integer,
    "would_return" boolean,
    "context" "text" DEFAULT 'general'::"text" NOT NULL,
    "rating_comfort" integer,
    "rating_wifi" integer,
    "rating_facilities" integer,
    "rating_experience" integer,
    "rating_safety" integer,
    "rating_organization" integer,
    CONSTRAINT "visited_feedback_rating_cleanliness_check" CHECK ((("rating_cleanliness" >= 1) AND ("rating_cleanliness" <= 5))),
    CONSTRAINT "visited_feedback_rating_comfort_check" CHECK ((("rating_comfort" IS NULL) OR (("rating_comfort" >= 1) AND ("rating_comfort" <= 5)))),
    CONSTRAINT "visited_feedback_rating_experience_check" CHECK ((("rating_experience" IS NULL) OR (("rating_experience" >= 1) AND ("rating_experience" <= 5)))),
    CONSTRAINT "visited_feedback_rating_facilities_check" CHECK ((("rating_facilities" IS NULL) OR (("rating_facilities" >= 1) AND ("rating_facilities" <= 5)))),
    CONSTRAINT "visited_feedback_rating_organization_check" CHECK ((("rating_organization" IS NULL) OR (("rating_organization" >= 1) AND ("rating_organization" <= 5)))),
    CONSTRAINT "visited_feedback_rating_safety_check" CHECK ((("rating_safety" IS NULL) OR (("rating_safety" >= 1) AND ("rating_safety" <= 5)))),
    CONSTRAINT "visited_feedback_rating_service_check" CHECK ((("rating_service" >= 1) AND ("rating_service" <= 5))),
    CONSTRAINT "visited_feedback_rating_value_check" CHECK ((("rating_value" >= 1) AND ("rating_value" <= 5))),
    CONSTRAINT "visited_feedback_rating_vibe_check" CHECK ((("rating_vibe" >= 1) AND ("rating_vibe" <= 5))),
    CONSTRAINT "visited_feedback_rating_wait_time_check" CHECK ((("rating_wait_time" >= 1) AND ("rating_wait_time" <= 5))),
    CONSTRAINT "visited_feedback_rating_wifi_check" CHECK ((("rating_wifi" IS NULL) OR (("rating_wifi" >= 1) AND ("rating_wifi" <= 5))))
);


ALTER TABLE "public"."visited_feedback" OWNER TO "postgres";


COMMENT ON TABLE "public"."visited_feedback" IS 'Stores user sentiment feedback after marking a place as visited. Includes ratings across 5 UX dimensions and quick sentiment tags.';



COMMENT ON COLUMN "public"."visited_feedback"."quick_tags" IS 'Array of sentiment tags (normalized), e.g., "friendly staff", "great vibe".';



CREATE OR REPLACE VIEW "public"."place_sentiment_summary" WITH ("security_invoker"='true') AS
 WITH "feedback_stats" AS (
         SELECT "vf"."place_id",
            "count"(*) AS "total_reviews",
            "round"("avg"("vf"."rating_service"), 1) AS "avg_service",
            "round"("avg"("vf"."rating_vibe"), 1) AS "avg_vibe",
            "round"("avg"("vf"."rating_value"), 1) AS "avg_value",
            "round"("avg"("vf"."rating_wait_time"), 1) AS "avg_wait_time",
            "round"("avg"("vf"."rating_cleanliness"), 1) AS "avg_cleanliness",
            "round"("avg"(((((((COALESCE("vf"."rating_service", 0) + COALESCE("vf"."rating_vibe", 0)) + COALESCE("vf"."rating_value", 0)) + COALESCE("vf"."rating_wait_time", 0)) + COALESCE("vf"."rating_cleanliness", 0)))::numeric / 5.0)), 1) AS "avg_overall"
           FROM "public"."visited_feedback" "vf"
          GROUP BY "vf"."place_id"
        ), "tag_counts" AS (
         SELECT "t"."place_id",
            "t"."tag",
            "count"(*) AS "tag_count"
           FROM ( SELECT "visited_feedback"."place_id",
                    "unnest"("visited_feedback"."quick_tags") AS "tag"
                   FROM "public"."visited_feedback"
                  WHERE (("visited_feedback"."quick_tags" IS NOT NULL) AND ("array_length"("visited_feedback"."quick_tags", 1) > 0))) "t"
          GROUP BY "t"."place_id", "t"."tag"
        ), "ranked" AS (
         SELECT "tag_counts"."place_id",
            "tag_counts"."tag",
            "tag_counts"."tag_count",
            "row_number"() OVER (PARTITION BY "tag_counts"."place_id" ORDER BY "tag_counts"."tag_count" DESC) AS "rn"
           FROM "tag_counts"
        ), "top_tags" AS (
         SELECT "ranked"."place_id",
            "json_agg"("json_build_object"('tag', "ranked"."tag", 'count', "ranked"."tag_count") ORDER BY "ranked"."tag_count" DESC) FILTER (WHERE ("ranked"."rn" <= 5)) AS "top_5_tags"
           FROM "ranked"
          GROUP BY "ranked"."place_id"
        )
 SELECT "fs"."place_id",
    "fs"."total_reviews",
    "fs"."avg_service",
    "fs"."avg_vibe",
    "fs"."avg_value",
    "fs"."avg_wait_time",
    "fs"."avg_cleanliness",
    "fs"."avg_overall",
    COALESCE("tt"."top_5_tags", '[]'::json) AS "top_tags"
   FROM ("feedback_stats" "fs"
     LEFT JOIN "top_tags" "tt" ON (("fs"."place_id" = "tt"."place_id")))
  WHERE ("fs"."total_reviews" >= 5);


ALTER VIEW "public"."place_sentiment_summary" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."place_special_hours" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "place_id" "uuid" NOT NULL,
    "date" "date" NOT NULL,
    "is_closed" boolean DEFAULT true NOT NULL,
    "open_time" time without time zone,
    "close_time" time without time zone,
    "kitchen_open" time without time zone,
    "kitchen_close" time without time zone,
    "reason" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."place_special_hours" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."place_specials" (
    "id" "uuid" DEFAULT "extensions"."uuid_generate_v4"() NOT NULL,
    "place_id" "uuid" NOT NULL,
    "title" "text" NOT NULL,
    "special_type" "text" NOT NULL,
    "description" "text",
    "recurring_days" "text"[] NOT NULL,
    "start_time" time without time zone,
    "end_time" time without time zone,
    "price_amount" "text",
    "currency" "text",
    "is_active" boolean DEFAULT true,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."place_specials" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."place_visit_events" (
    "id" bigint NOT NULL,
    "user_id" "uuid" NOT NULL,
    "place_id" "uuid" NOT NULL,
    "visited_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "source" "text" DEFAULT 'manual'::"text",
    "note" "text",
    CONSTRAINT "place_visit_events_source_check" CHECK (("source" = ANY (ARRAY['manual'::"text", 'checkin'::"text", 'import'::"text"])))
);


ALTER TABLE "public"."place_visit_events" OWNER TO "postgres";


CREATE SEQUENCE IF NOT EXISTS "public"."place_visit_events_id_seq"
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


ALTER SEQUENCE "public"."place_visit_events_id_seq" OWNER TO "postgres";


ALTER SEQUENCE "public"."place_visit_events_id_seq" OWNED BY "public"."place_visit_events"."id";



CREATE TABLE IF NOT EXISTS "public"."push_tokens" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "token" "text" NOT NULL,
    "platform" "text" NOT NULL,
    "device_id" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "push_tokens_platform_check" CHECK (("platform" = ANY (ARRAY['ios'::"text", 'android'::"text"])))
);


ALTER TABLE "public"."push_tokens" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ranking_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "event_type" "text" NOT NULL,
    "category" "text",
    "place_slug_a" "text",
    "place_slug_b" "text",
    "winner_slug" "text",
    "elo_before_a" integer,
    "elo_before_b" integer,
    "elo_after_a" integer,
    "elo_after_b" integer,
    "manual_rank_from" integer,
    "manual_rank_to" integer,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."ranking_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."recommended_dishes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "place_id" "uuid" DEFAULT "gen_random_uuid"(),
    "dish_name" "text",
    "dish_description" "text",
    "dish_image_url" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "place_slug" "text",
    "tags" "text",
    "country" "text"
);


ALTER TABLE "public"."recommended_dishes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."redemption_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "card_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "redeemed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "redeemed_by" "text"
);


ALTER TABLE "public"."redemption_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."saved_events" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "event_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."saved_events" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."saved_experiences" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "experience_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'interested'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "saved_experiences_status_check" CHECK (("status" = ANY (ARRAY['interested'::"text", 'attending'::"text"])))
);


ALTER TABLE "public"."saved_experiences" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."schedule_change_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "schedule_item_id" "uuid",
    "change_type" character varying(20) NOT NULL,
    "change_summary" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."schedule_change_log" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."schedule_full" AS
 SELECT "si"."id",
    "si"."event_id",
    "si"."day_id",
    "si"."track_id",
    "si"."title",
    "si"."subtitle",
    "si"."description",
    "si"."start_time",
    "si"."end_time",
    "si"."original_start_time",
    "si"."original_end_time",
    "si"."status",
    "si"."delay_minutes",
    "si"."status_message",
    "si"."category",
    "si"."tags",
    "si"."image_url",
    "si"."is_featured",
    "si"."is_must_see",
    "si"."version",
    "si"."updated_at",
    "sd"."date" AS "day_date",
    "sd"."label" AS "day_label",
    "sd"."date_display" AS "day_display",
    "sd"."day_number",
    "st"."name" AS "track_name",
    "st"."short_name" AS "track_short_name",
    "st"."color" AS "track_color",
    "st"."icon" AS "track_icon",
    "st"."track_type",
    COALESCE("si"."venue_override", "st"."venue_section") AS "venue",
    (EXTRACT(epoch FROM ("si"."end_time" - "si"."start_time")) / (60)::numeric) AS "duration_minutes"
   FROM (("public"."event_schedule_items" "si"
     JOIN "public"."event_schedule_days" "sd" ON (("si"."day_id" = "sd"."id")))
     JOIN "public"."event_schedule_tracks" "st" ON (("si"."track_id" = "st"."id")))
  WHERE ("si"."is_published" = true);


ALTER VIEW "public"."schedule_full" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."special_analytics" AS
 SELECT "entity_id" AS "special_id",
    "count"(*) FILTER (WHERE ("event_name" = 'special_viewed'::"text")) AS "total_views",
    "count"(*) FILTER (WHERE ("event_name" = 'special_clicked'::"text")) AS "clicks",
    "count"(*) FILTER (WHERE ("event_name" = 'special_redeemed'::"text")) AS "redemptions",
    "max"("created_at") FILTER (WHERE ("event_name" = 'special_viewed'::"text")) AS "last_viewed"
   FROM "public"."analytics_events" "e"
  WHERE ("entity_type" = 'special'::"text")
  GROUP BY "entity_id";


ALTER VIEW "public"."special_analytics" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."special_interactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "special_id" "uuid" NOT NULL,
    "status" "text" DEFAULT 'interested'::"text",
    "vote" "text",
    "rating" numeric(2,1),
    "note" "text",
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "quick_tags" "text"[] DEFAULT '{}'::"text"[],
    "rating_value" numeric(2,1),
    "rating_vibe" numeric(2,1),
    "rating_experience" numeric(2,1),
    "rating_organisation" numeric(2,1),
    "rating_taste" numeric(2,1),
    "rating_portions" numeric(2,1),
    "rating_presentation" numeric(2,1),
    "rating_drinks" numeric(2,1),
    "rating_comfort" integer,
    "rating_service" integer,
    "rating_cleanliness" integer,
    "rating_location" integer,
    CONSTRAINT "special_interactions_dimension_rating_check" CHECK (((("rating_value" IS NULL) OR (("rating_value" >= (1)::numeric) AND ("rating_value" <= (5)::numeric))) AND (("rating_vibe" IS NULL) OR (("rating_vibe" >= (1)::numeric) AND ("rating_vibe" <= (5)::numeric))) AND (("rating_experience" IS NULL) OR (("rating_experience" >= (1)::numeric) AND ("rating_experience" <= (5)::numeric))) AND (("rating_organisation" IS NULL) OR (("rating_organisation" >= (1)::numeric) AND ("rating_organisation" <= (5)::numeric))) AND (("rating_taste" IS NULL) OR (("rating_taste" >= (1)::numeric) AND ("rating_taste" <= (5)::numeric))) AND (("rating_portions" IS NULL) OR (("rating_portions" >= (1)::numeric) AND ("rating_portions" <= (5)::numeric))) AND (("rating_presentation" IS NULL) OR (("rating_presentation" >= (1)::numeric) AND ("rating_presentation" <= (5)::numeric))) AND (("rating_drinks" IS NULL) OR (("rating_drinks" >= (1)::numeric) AND ("rating_drinks" <= (5)::numeric))) AND (("rating_comfort" IS NULL) OR (("rating_comfort" >= 1) AND ("rating_comfort" <= 5))) AND (("rating_service" IS NULL) OR (("rating_service" >= 1) AND ("rating_service" <= 5))) AND (("rating_cleanliness" IS NULL) OR (("rating_cleanliness" >= 1) AND ("rating_cleanliness" <= 5))) AND (("rating_location" IS NULL) OR (("rating_location" >= 1) AND ("rating_location" <= 5))))),
    CONSTRAINT "special_interactions_rating_check" CHECK ((("rating" IS NULL) OR (("rating" >= (1)::numeric) AND ("rating" <= (5)::numeric)))),
    CONSTRAINT "special_interactions_status_check" CHECK ((("status" IS NULL) OR ("status" = ANY (ARRAY['interested'::"text", 'going'::"text", 'attended'::"text"])))),
    CONSTRAINT "special_interactions_vote_check" CHECK ((("vote" IS NULL) OR ("vote" = ANY (ARRAY['up'::"text", 'down'::"text"]))))
);


ALTER TABLE "public"."special_interactions" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."special_community_stats" AS
 WITH "interaction_stats" AS (
         SELECT "special_interactions"."special_id",
            "count"(DISTINCT "special_interactions"."user_id") FILTER (WHERE ("special_interactions"."status" = 'interested'::"text")) AS "interested_count",
            "count"(DISTINCT "special_interactions"."user_id") FILTER (WHERE ("special_interactions"."status" = 'going'::"text")) AS "going_count",
            "count"(DISTINCT "special_interactions"."user_id") FILTER (WHERE ("special_interactions"."status" = 'attended'::"text")) AS "attended_count",
            "count"(*) FILTER (WHERE ("special_interactions"."vote" = 'up'::"text")) AS "up_votes",
            "count"(*) FILTER (WHERE ("special_interactions"."vote" = 'down'::"text")) AS "down_votes",
            "round"("avg"("special_interactions"."rating"), 1) AS "avg_rating",
            "round"("avg"("special_interactions"."rating_value"), 1) AS "avg_rating_value",
            "round"("avg"("special_interactions"."rating_vibe"), 1) AS "avg_rating_vibe",
            "round"("avg"("special_interactions"."rating_experience"), 1) AS "avg_rating_experience",
            "round"("avg"("special_interactions"."rating_organisation"), 1) AS "avg_rating_organisation",
            "round"("avg"("special_interactions"."rating_taste"), 1) AS "avg_rating_taste",
            "round"("avg"("special_interactions"."rating_portions"), 1) AS "avg_rating_portions",
            "round"("avg"("special_interactions"."rating_presentation"), 1) AS "avg_rating_presentation",
            "round"("avg"("special_interactions"."rating_drinks"), 1) AS "avg_rating_drinks"
           FROM "public"."special_interactions"
          GROUP BY "special_interactions"."special_id"
        ), "tag_counts" AS (
         SELECT "si"."special_id",
            "tag"."tag",
            "count"(*) AS "tag_count"
           FROM ("public"."special_interactions" "si"
             CROSS JOIN LATERAL "unnest"("si"."quick_tags") "tag"("tag"))
          GROUP BY "si"."special_id", "tag"."tag"
        ), "top_tags" AS (
         SELECT "ranked"."special_id",
            "array_agg"("ranked"."tag" ORDER BY "ranked"."tag_count" DESC, "ranked"."tag") AS "top_tags"
           FROM ( SELECT "tag_counts"."special_id",
                    "tag_counts"."tag",
                    "tag_counts"."tag_count",
                    "row_number"() OVER (PARTITION BY "tag_counts"."special_id" ORDER BY "tag_counts"."tag_count" DESC, "tag_counts"."tag") AS "rn"
                   FROM "tag_counts") "ranked"
          WHERE ("ranked"."rn" <= 6)
          GROUP BY "ranked"."special_id"
        )
 SELECT "s"."special_id",
    "s"."interested_count",
    "s"."going_count",
    "s"."attended_count",
    "s"."up_votes",
    "s"."down_votes",
    "s"."avg_rating",
    "s"."avg_rating_value",
    "s"."avg_rating_vibe",
    "s"."avg_rating_experience",
    "s"."avg_rating_organisation",
    "s"."avg_rating_taste",
    "s"."avg_rating_portions",
    "s"."avg_rating_presentation",
    "s"."avg_rating_drinks",
    COALESCE("t"."top_tags", '{}'::"text"[]) AS "top_tags"
   FROM ("interaction_stats" "s"
     LEFT JOIN "top_tags" "t" ON (("t"."special_id" = "s"."special_id")));


ALTER VIEW "public"."special_community_stats" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."special_visits" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "special_id" "uuid" NOT NULL,
    "visited_at" timestamp with time zone DEFAULT "now"(),
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."special_visits" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."sponsor_activation_funnel" AS
 SELECT "event_id",
    "sponsor_id",
    "activation_id",
    "count"(*) FILTER (WHERE ("event_name" = 'sponsor_view'::"text")) AS "views",
    "count"(*) FILTER (WHERE ("event_name" = 'sponsor_link_click'::"text")) AS "link_clicks",
    "count"(*) FILTER (WHERE ("event_name" = 'activation_checkin'::"text")) AS "checkins",
    "count"(*) FILTER (WHERE ("event_name" = 'activation_redemption'::"text")) AS "redemptions",
    "count"(DISTINCT COALESCE(("user_id")::"text", "anon_device_id")) FILTER (WHERE ("event_name" = 'activation_checkin'::"text")) AS "unique_checkins",
    "count"(DISTINCT COALESCE(("user_id")::"text", "anon_device_id")) FILTER (WHERE ("event_name" = 'activation_redemption'::"text")) AS "unique_redemptions"
   FROM "public"."event_analytics_events" "e"
  WHERE ("sponsor_id" IS NOT NULL)
  GROUP BY "event_id", "sponsor_id", "activation_id";


ALTER VIEW "public"."sponsor_activation_funnel" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."sponsor_analytics_rollup" AS
 SELECT "event_id",
    "sponsor_id",
    "event_name",
    "count"(*) AS "total",
    "count"(DISTINCT COALESCE(("user_id")::"text", "anon_device_id")) AS "unique_attendees"
   FROM "public"."event_analytics_events" "e"
  WHERE ("sponsor_id" IS NOT NULL)
  GROUP BY "event_id", "sponsor_id", "event_name";


ALTER VIEW "public"."sponsor_analytics_rollup" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."subscription_plans" (
    "key" "text" NOT NULL,
    "name" "text" NOT NULL,
    "description" "text",
    "included_locations" integer DEFAULT 1 NOT NULL,
    "included_admins" integer DEFAULT 1 NOT NULL,
    "monthly_price" numeric,
    "annual_price" numeric,
    "currency" "text" DEFAULT 'USD'::"text" NOT NULL,
    "entitlements" "jsonb" DEFAULT '[]'::"jsonb" NOT NULL,
    "is_active" boolean DEFAULT true NOT NULL,
    "sort_order" integer DEFAULT 0 NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "plan_family" "text" DEFAULT 'standard'::"text" NOT NULL,
    "specials_per_location" integer DEFAULT 0 NOT NULL,
    CONSTRAINT "subscription_plans_plan_family_check" CHECK (("plan_family" = ANY (ARRAY['standard'::"text", 'loyalty'::"text", 'event'::"text", 'sponsor'::"text"])))
);


ALTER TABLE "public"."subscription_plans" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."subscriptions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "company_account_id" "uuid" NOT NULL,
    "plan_key" "text",
    "billing_cycle" "text",
    "status" "text" DEFAULT 'invoice_issued'::"text" NOT NULL,
    "current_period_start" "date",
    "paid_through" "date",
    "activated_at" timestamp with time zone,
    "canceled_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "subscriptions_billing_cycle_check" CHECK (("billing_cycle" = ANY (ARRAY['monthly'::"text", 'annual'::"text"]))),
    CONSTRAINT "subscriptions_status_check" CHECK (("status" = ANY (ARRAY['invoice_issued'::"text", 'payment_pending_review'::"text", 'active'::"text", 'past_due'::"text", 'read_only'::"text", 'expired'::"text", 'canceled'::"text"])))
);


ALTER TABLE "public"."subscriptions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."suggested_places" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "spot_name" "text",
    "category" "text",
    "location" "text",
    "country" "text",
    "recommended" "text",
    "description" "text",
    "contact_info" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone,
    "user_id" "uuid"
);


ALTER TABLE "public"."suggested_places" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."ticket_locations" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "name" "text" NOT NULL,
    "address" "text",
    "parish" "text",
    "town" "text",
    "contact_phone" "text",
    "opening_hours" "text",
    "latitude" numeric,
    "longitude" numeric,
    "is_active" boolean DEFAULT true,
    "display_order" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "ticket_url" "text",
    "is_online" boolean DEFAULT false,
    "logo_url" "text",
    "provider_type" "text",
    "place_slug" "text"
);


ALTER TABLE "public"."ticket_locations" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trip_activity" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "user_id" "uuid",
    "activity_type" "text" NOT NULL,
    "entity_type" "text",
    "entity_id" "uuid",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb",
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."trip_activity" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trip_change_requests" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "proposed_by" "uuid",
    "change_type" "text" NOT NULL,
    "target_entity_type" "text",
    "target_entry_id" "uuid",
    "payload" "jsonb" DEFAULT '{}'::"jsonb",
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "resolved_at" timestamp with time zone,
    CONSTRAINT "trip_change_requests_change_type_check" CHECK (("change_type" = 'delete_item'::"text")),
    CONSTRAINT "trip_change_requests_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'applied'::"text", 'rejected'::"text", 'cancelled'::"text"]))),
    CONSTRAINT "trip_change_requests_target_entity_type_check" CHECK (("target_entity_type" = ANY (ARRAY['place'::"text", 'event'::"text"])))
);

ALTER TABLE ONLY "public"."trip_change_requests" REPLICA IDENTITY FULL;


ALTER TABLE "public"."trip_change_requests" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trip_change_votes" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "request_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "vote" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "trip_change_votes_vote_check" CHECK (("vote" = ANY (ARRAY['approve'::"text", 'reject'::"text"])))
);

ALTER TABLE ONLY "public"."trip_change_votes" REPLICA IDENTITY FULL;


ALTER TABLE "public"."trip_change_votes" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trip_collaborators" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "trip_id" "uuid" NOT NULL,
    "invitee_id" "uuid",
    "invited_by" "uuid" NOT NULL,
    "status" "text" DEFAULT 'pending'::"text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "role" "text" DEFAULT 'editor'::"text" NOT NULL,
    "invite_token" "uuid" DEFAULT "gen_random_uuid"(),
    "invite_expires_at" timestamp with time zone DEFAULT ("now"() + '02:00:00'::interval),
    "invite_accepted_at" timestamp with time zone,
    CONSTRAINT "trip_collaborators_role_check" CHECK (("role" = ANY (ARRAY['owner'::"text", 'editor'::"text", 'viewer'::"text"]))),
    CONSTRAINT "trip_collaborators_status_check" CHECK (("status" = ANY (ARRAY['pending'::"text", 'accepted'::"text", 'declined'::"text"])))
);

ALTER TABLE ONLY "public"."trip_collaborators" REPLICA IDENTITY FULL;


ALTER TABLE "public"."trip_collaborators" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."trip_completions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "itinerary_id" "uuid" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "completed_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "total_places" integer DEFAULT 0,
    "visited_places" integer DEFAULT 0,
    "destination" "text",
    "country" "text",
    "completion_percentage" numeric(5,2) DEFAULT 100,
    "xp_awarded" integer DEFAULT 0,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb"
);


ALTER TABLE "public"."trip_completions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user" (
    "email" "text" NOT NULL,
    "onboarding_done" boolean DEFAULT false,
    "last_active_at" timestamp without time zone,
    "interests" "text",
    "username" "text",
    "phone_number" "text",
    "role" "text" DEFAULT '''user'''::"text",
    "created_at" timestamp with time zone,
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "location_opt_in" boolean DEFAULT false,
    "onesignal_id" "text",
    "expo_push_token" "text",
    "push_opt_in" boolean DEFAULT false,
    "push_last_registered_at" timestamp with time zone
);


ALTER TABLE "public"."user" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_achievements" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "achievement_id" "text" NOT NULL,
    "unlocked_at" timestamp with time zone DEFAULT "now"(),
    "progress" integer DEFAULT 0,
    "max_progress" integer DEFAULT 1,
    "is_completed" boolean DEFAULT false,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_achievements" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_checkins" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "place_id" "uuid",
    "event_id" "uuid",
    "nfc_tag_id" "uuid",
    "checkin_type" "text" NOT NULL,
    "source" "text" DEFAULT 'nfc'::"text" NOT NULL,
    "xp_earned" integer DEFAULT 0 NOT NULL,
    "idempotency_key" "text",
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "user_checkins_checkin_type_check" CHECK (("checkin_type" = ANY (ARRAY['loyalty'::"text", 'visit'::"text", 'event_entry'::"text", 'activation'::"text"]))),
    CONSTRAINT "user_checkins_has_target" CHECK ((("place_id" IS NOT NULL) OR ("event_id" IS NOT NULL))),
    CONSTRAINT "user_checkins_source_check" CHECK (("source" = ANY (ARRAY['nfc'::"text", 'manual'::"text"])))
);


ALTER TABLE "public"."user_checkins" OWNER TO "postgres";


COMMENT ON TABLE "public"."user_checkins" IS 'User check-in records. Read: own rows only via RLS. Write: service_role only via process-nfc-checkin Edge Function.';



CREATE TABLE IF NOT EXISTS "public"."user_event_interactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "event_id" "uuid" NOT NULL,
    "interaction_type" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "country" "text",
    CONSTRAINT "valid_interaction" CHECK (("interaction_type" = ANY (ARRAY['saved'::"text", 'going'::"text", 'interested'::"text", 'viewed'::"text"])))
);


ALTER TABLE "public"."user_event_interactions" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_favorite_items" (
    "user_id" "uuid" NOT NULL,
    "menu_item_id" "uuid" NOT NULL,
    "favorited_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."user_favorite_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_item_logs" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "menu_item_id" "uuid" NOT NULL,
    "place_id" "uuid" NOT NULL,
    "would_order_again" boolean,
    "notes" "text",
    "visit_date" "date" DEFAULT CURRENT_DATE NOT NULL,
    "is_public" boolean DEFAULT false NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "sentiment" "text",
    CONSTRAINT "user_item_logs_sentiment_check" CHECK (("sentiment" = ANY (ARRAY['loved'::"text", 'ok'::"text", 'not_for_me'::"text"])))
);


ALTER TABLE "public"."user_item_logs" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_loyalty_cards" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "program_id" "uuid" NOT NULL,
    "current_stamps" integer DEFAULT 0 NOT NULL,
    "is_redeemed" boolean DEFAULT false NOT NULL,
    "last_stamped_at" timestamp with time zone,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "completed_cycles" integer DEFAULT 0
);


ALTER TABLE "public"."user_loyalty_cards" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_month_rankings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "place_slug" "text" NOT NULL,
    "year" integer NOT NULL,
    "month" integer NOT NULL,
    "rank" integer NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_month_rankings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_place_rankings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "place_id" "uuid" NOT NULL,
    "category" "text" NOT NULL,
    "elo_score" integer DEFAULT 1000,
    "is_ranked" boolean DEFAULT false,
    "comparison_count" integer DEFAULT 0,
    "manual_rank" integer,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_place_rankings" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."user_place_visit_counts" WITH ("security_invoker"='on') AS
 SELECT "user_id",
    "place_id",
    ("count"(*))::integer AS "visit_count",
    "min"("visited_at") AS "first_visited_at",
    "max"("visited_at") AS "last_visited_at"
   FROM "public"."place_visit_events"
  GROUP BY "user_id", "place_id";


ALTER VIEW "public"."user_place_visit_counts" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_saved_menu_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "event_id" "uuid",
    "vendor_id" "uuid" NOT NULL,
    "vendor_name" "text",
    "menu_item_name" "text" NOT NULL,
    "menu_item_price" "text",
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);


ALTER TABLE "public"."user_saved_menu_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_saved_schedule_items" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "event_id" "uuid" NOT NULL,
    "schedule_item_id" "uuid" NOT NULL,
    "notify_on_change" boolean DEFAULT true,
    "notify_before_minutes" integer DEFAULT 15,
    "personal_note" "text",
    "saved_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_saved_schedule_items" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_schedule_plans" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "event_id" "uuid" NOT NULL,
    "schedule_item_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"()
);


ALTER TABLE "public"."user_schedule_plans" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_stats" (
    "user_id" "uuid" NOT NULL,
    "total_points" integer DEFAULT 0,
    "level" integer DEFAULT 1,
    "current_streak" integer DEFAULT 0,
    "longest_streak" integer DEFAULT 0,
    "last_activity_date" "date",
    "parishes_visited" integer DEFAULT 0,
    "places_visited" integer DEFAULT 0,
    "trips_completed" integer DEFAULT 0,
    "created_at" timestamp with time zone DEFAULT "now"(),
    "updated_at" timestamp with time zone DEFAULT "now"(),
    "lifetime_xp" integer DEFAULT 0 NOT NULL,
    "tier_points" integer DEFAULT 0 NOT NULL,
    "tier" "text" DEFAULT 'Explorer'::"text" NOT NULL,
    CONSTRAINT "user_stats_tier_check" CHECK (("tier" = ANY (ARRAY['Explorer'::"text", 'Insider'::"text", 'TasteMaker'::"text", 'Gold'::"text", 'Passport Elite'::"text"])))
);


ALTER TABLE "public"."user_stats" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_tour_progress" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "guide_slug" "text" NOT NULL,
    "completed_step_ids" "uuid"[] DEFAULT '{}'::"uuid"[],
    "current_step_order" integer DEFAULT 1,
    "started_at" timestamp with time zone DEFAULT "now"(),
    "completed_at" timestamp with time zone
);


ALTER TABLE "public"."user_tour_progress" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."user_vendor_item_ratings" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid",
    "event_id" "uuid" NOT NULL,
    "vendor_id" "text" NOT NULL,
    "item_name" "text" NOT NULL,
    "rating" "text" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"(),
    CONSTRAINT "user_vendor_item_ratings_rating_check" CHECK (("rating" = ANY (ARRAY['liked'::"text", 'disliked'::"text"])))
);


ALTER TABLE "public"."user_vendor_item_ratings" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."xp_transactions" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "transaction_type" "text" NOT NULL,
    "source_type" "text" NOT NULL,
    "source_id" "text",
    "xp_amount" integer NOT NULL,
    "metadata" "jsonb" DEFAULT '{}'::"jsonb" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "action_key" "text",
    CONSTRAINT "xp_transactions_transaction_type_check" CHECK (("transaction_type" = ANY (ARRAY['earn'::"text", 'redeem'::"text", 'reverse'::"text", 'adjustment'::"text"])))
);


ALTER TABLE "public"."xp_transactions" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."user_xp_totals" AS
 SELECT "user_id",
    COALESCE("sum"("xp_amount"), (0)::bigint) AS "total_xp"
   FROM "public"."xp_transactions"
  GROUP BY "user_id";


ALTER VIEW "public"."user_xp_totals" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."vibe_tags" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "event_id" "uuid" NOT NULL,
    "marker_id" "text" NOT NULL,
    "tag" "text" NOT NULL,
    "user_id" "uuid" NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL
);

ALTER TABLE ONLY "public"."vibe_tags" REPLICA IDENTITY FULL;


ALTER TABLE "public"."vibe_tags" OWNER TO "postgres";


CREATE OR REPLACE VIEW "public"."view_guide_details" AS
 SELECT "gs"."guide_slug",
    "g"."title",
    "g"."type",
    "g"."description" AS "guide_description",
    "g"."image_url" AS "guide_image",
    "gs"."place_slug",
    "p"."id",
    "p"."name",
    "p"."price_range",
    "p"."perfect_for",
    COALESCE(NULLIF("gs"."custom_blurb", ''::"text"), "p"."description") AS "description",
    "gs"."custom_blurb",
    COALESCE("gs"."section", 'Featured'::"text") AS "section",
    ("gs"."order")::bigint AS "ordering",
    "p"."image",
    "p"."google_maps_link",
    "p"."address",
    "p"."parish",
    "p"."category",
    "p"."town",
    "p"."cuisine",
    "p"."latitude",
    "p"."longitude",
    "p"."opening_hours"
   FROM (("public"."guide_spots" "gs"
     JOIN "public"."guides" "g" ON (("g"."slug" = "gs"."guide_slug")))
     JOIN "public"."places" "p" ON (("p"."slug" = "gs"."place_slug")))
UNION ALL
 SELECT "g"."slug" AS "guide_slug",
    "g"."title",
    "g"."type",
    "g"."description" AS "guide_description",
    "g"."image_url" AS "guide_image",
    TRIM(BOTH FROM "u"."raw_slug") AS "place_slug",
    "p"."id",
    "p"."name",
    "p"."price_range",
    "p"."perfect_for",
    "p"."description",
    NULL::"text" AS "custom_blurb",
    'Featured'::"text" AS "section",
    "u"."idx" AS "ordering",
    "p"."image",
    "p"."google_maps_link",
    "p"."address",
    "p"."parish",
    "p"."category",
    "p"."town",
    "p"."cuisine",
    "p"."latitude",
    "p"."longitude",
    "p"."opening_hours"
   FROM (("public"."guides" "g"
     CROSS JOIN LATERAL "unnest"("regexp_split_to_array"("g"."place_slugs", '\s*[;,|\|]\s*'::"text")) WITH ORDINALITY "u"("raw_slug", "idx"))
     JOIN "public"."places" "p" ON (("p"."slug" = TRIM(BOTH FROM "u"."raw_slug"))))
  WHERE (("g"."place_slugs" IS NOT NULL) AND (TRIM(BOTH FROM "g"."place_slugs") <> ''::"text") AND (TRIM(BOTH FROM "u"."raw_slug") <> ''::"text") AND (NOT (EXISTS ( SELECT 1
           FROM "public"."guide_spots" "gs2"
          WHERE ("gs2"."guide_slug" = "g"."slug")))));


ALTER VIEW "public"."view_guide_details" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."visit_log" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "user_id" "uuid" NOT NULL,
    "place_id" "uuid" NOT NULL,
    "visited_at" timestamp with time zone DEFAULT "now"(),
    "country" "text"
);


ALTER TABLE "public"."visit_log" OWNER TO "postgres";


CREATE TABLE IF NOT EXISTS "public"."xp_rules" (
    "id" "uuid" DEFAULT "gen_random_uuid"() NOT NULL,
    "rule_key" "text" NOT NULL,
    "source_type" "text" NOT NULL,
    "xp_amount" integer NOT NULL,
    "description" "text",
    "is_active" boolean DEFAULT true NOT NULL,
    "created_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    "updated_at" timestamp with time zone DEFAULT "now"() NOT NULL,
    CONSTRAINT "xp_rules_xp_amount_check" CHECK (("xp_amount" > 0))
);


ALTER TABLE "public"."xp_rules" OWNER TO "postgres";


ALTER TABLE ONLY "public"."place_visit_events" ALTER COLUMN "id" SET DEFAULT "nextval"('"public"."place_visit_events_id_seq"'::"regclass");



ALTER TABLE ONLY "public"."achievements"
    ADD CONSTRAINT "achievements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."admin_tokens"
    ADD CONSTRAINT "admin_tokens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."admin_tokens"
    ADD CONSTRAINT "admin_tokens_token_key" UNIQUE ("token");



ALTER TABLE ONLY "public"."alerts"
    ADD CONSTRAINT "alerts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."analytics_events"
    ADD CONSTRAINT "analytics_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."app_config"
    ADD CONSTRAINT "app_config_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."app_settings"
    ADD CONSTRAINT "app_settings_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."bands"
    ADD CONSTRAINT "bands_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bands"
    ADD CONSTRAINT "bands_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."billing_accounts"
    ADD CONSTRAINT "billing_accounts_partner_id_key" UNIQUE ("partner_id");



ALTER TABLE ONLY "public"."billing_accounts"
    ADD CONSTRAINT "billing_accounts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."billing_audit_log"
    ADD CONSTRAINT "billing_audit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."billing_notifications"
    ADD CONSTRAINT "billing_notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."billing_products"
    ADD CONSTRAINT "billing_products_pkey" PRIMARY KEY ("code");



ALTER TABLE ONLY "public"."billing_settings"
    ADD CONSTRAINT "billing_settings_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."billing_usage"
    ADD CONSTRAINT "billing_usage_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."booking_cancellation_policies"
    ADD CONSTRAINT "booking_cancellation_policies_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."booking_notification_logs"
    ADD CONSTRAINT "booking_notification_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."booking_room_allocations"
    ADD CONSTRAINT "booking_room_allocations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."booking_timeline_events"
    ADD CONSTRAINT "booking_timeline_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_token_key" UNIQUE ("token");



ALTER TABLE ONLY "public"."businesses"
    ADD CONSTRAINT "businesses_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."businesses"
    ADD CONSTRAINT "businesses_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."company_accounts"
    ADD CONSTRAINT "company_accounts_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."company_entitlements"
    ADD CONSTRAINT "company_entitlements_company_account_id_entitlement_key_key" UNIQUE ("company_account_id", "entitlement_key");



ALTER TABLE ONLY "public"."company_entitlements"
    ADD CONSTRAINT "company_entitlements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."company_events"
    ADD CONSTRAINT "company_events_company_account_id_event_id_relationship_typ_key" UNIQUE ("company_account_id", "event_id", "relationship_type");



ALTER TABLE ONLY "public"."company_events"
    ADD CONSTRAINT "company_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."company_locations"
    ADD CONSTRAINT "company_locations_company_account_id_place_id_key" UNIQUE ("company_account_id", "place_id");



ALTER TABLE ONLY "public"."company_locations"
    ADD CONSTRAINT "company_locations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."company_onboarding_invites"
    ADD CONSTRAINT "company_onboarding_invites_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."company_onboarding_invites"
    ADD CONSTRAINT "company_onboarding_invites_token_key" UNIQUE ("token");



ALTER TABLE ONLY "public"."company_requests"
    ADD CONSTRAINT "company_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."company_setup_requests"
    ADD CONSTRAINT "company_setup_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."company_users"
    ADD CONSTRAINT "company_users_company_account_id_email_key" UNIQUE ("company_account_id", "email");



ALTER TABLE ONLY "public"."company_users"
    ADD CONSTRAINT "company_users_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."dish_likes"
    ADD CONSTRAINT "dish_likes_dish_id_user_id_key" UNIQUE ("dish_id", "user_id");



ALTER TABLE ONLY "public"."dish_likes"
    ADD CONSTRAINT "dish_likes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."entitlement_definitions"
    ADD CONSTRAINT "entitlement_definitions_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."event_analytics_events"
    ADD CONSTRAINT "event_analytics_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_bands"
    ADD CONSTRAINT "event_bands_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_bands"
    ADD CONSTRAINT "event_bands_unique" UNIQUE ("event_id", "band_id");



ALTER TABLE ONLY "public"."event_interests"
    ADD CONSTRAINT "event_interests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_interests"
    ADD CONSTRAINT "event_interests_user_event_unique" UNIQUE ("user_id", "event_id");



ALTER TABLE ONLY "public"."event_interests"
    ADD CONSTRAINT "event_interests_user_id_event_id_key" UNIQUE ("user_id", "event_id");



ALTER TABLE ONLY "public"."event_map_invites"
    ADD CONSTRAINT "event_map_invites_pkey" PRIMARY KEY ("token");



ALTER TABLE ONLY "public"."event_map_points"
    ADD CONSTRAINT "event_map_points_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_notification_deliveries"
    ADD CONSTRAINT "event_notification_deliveries_event_id_user_id_notification_key" UNIQUE ("event_id", "user_id", "notification_type");



ALTER TABLE ONLY "public"."event_notification_deliveries"
    ADD CONSTRAINT "event_notification_deliveries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_partner_submission_assets"
    ADD CONSTRAINT "event_partner_submission_assets_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_partner_submissions"
    ADD CONSTRAINT "event_partner_submissions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_partner_submissions"
    ADD CONSTRAINT "event_partner_submissions_token_key" UNIQUE ("token");



ALTER TABLE ONLY "public"."event_push_notifications"
    ADD CONSTRAINT "event_push_notifications_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_schedule_days"
    ADD CONSTRAINT "event_schedule_days_event_id_date_key" UNIQUE ("event_id", "date");



ALTER TABLE ONLY "public"."event_schedule_days"
    ADD CONSTRAINT "event_schedule_days_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_schedule_items"
    ADD CONSTRAINT "event_schedule_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_schedule_meta"
    ADD CONSTRAINT "event_schedule_meta_pkey" PRIMARY KEY ("event_id");



ALTER TABLE ONLY "public"."event_schedule_tracks"
    ADD CONSTRAINT "event_schedule_tracks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_sponsor_activations"
    ADD CONSTRAINT "event_sponsor_activations_nfc_token_key" UNIQUE ("nfc_token");



ALTER TABLE ONLY "public"."event_sponsor_activations"
    ADD CONSTRAINT "event_sponsor_activations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_sponsor_activations"
    ADD CONSTRAINT "event_sponsor_activations_qr_code_token_key" UNIQUE ("qr_code_token");



ALTER TABLE ONLY "public"."event_sponsors"
    ADD CONSTRAINT "event_sponsors_event_id_sponsor_id_key" UNIQUE ("event_id", "sponsor_id");



ALTER TABLE ONLY "public"."event_sponsors"
    ADD CONSTRAINT "event_sponsors_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_transport_routes"
    ADD CONSTRAINT "event_transport_routes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_transport_stops"
    ADD CONSTRAINT "event_transport_stops_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_transport_times"
    ADD CONSTRAINT "event_transport_times_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_updates"
    ADD CONSTRAINT "event_updates_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."event_vendors"
    ADD CONSTRAINT "event_vendors_event_id_vendor_id_key" UNIQUE ("event_id", "vendor_id");



ALTER TABLE ONLY "public"."event_vendors"
    ADD CONSTRAINT "event_vendors_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."favorites"
    ADD CONSTRAINT "favorites_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."favourite_guides"
    ADD CONSTRAINT "favourite_guides_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."feedback"
    ADD CONSTRAINT "feedback_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."guide_route_steps"
    ADD CONSTRAINT "guide_route_steps_guide_slug_step_order_key" UNIQUE ("guide_slug", "step_order");



ALTER TABLE ONLY "public"."guide_route_steps"
    ADD CONSTRAINT "guide_route_steps_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."guide_spots"
    ADD CONSTRAINT "guide_spots_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."guide_spots"
    ADD CONSTRAINT "guide_spots_unique" UNIQUE ("guide_slug", "place_slug");



ALTER TABLE ONLY "public"."guides"
    ADD CONSTRAINT "guides_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."guides"
    ADD CONSTRAINT "guides_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."hotel_availability"
    ADD CONSTRAINT "hotel_availability_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hotel_availability"
    ADD CONSTRAINT "hotel_availability_room_type_id_stay_date_key" UNIQUE ("room_type_id", "stay_date");



ALTER TABLE ONLY "public"."hotel_inventory_holds"
    ADD CONSTRAINT "hotel_inventory_holds_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hotel_rate_plans"
    ADD CONSTRAINT "hotel_rate_plans_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."hotel_room_types"
    ADD CONSTRAINT "hotel_room_types_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."insider_status_settings"
    ADD CONSTRAINT "insider_status_settings_pkey" PRIMARY KEY ("place_id");



ALTER TABLE ONLY "public"."invoice_counters"
    ADD CONSTRAINT "invoice_counters_pkey" PRIMARY KEY ("year");



ALTER TABLE ONLY "public"."invoice_line_items"
    ADD CONSTRAINT "invoice_line_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."invoices"
    ADD CONSTRAINT "invoices_invoice_number_key" UNIQUE ("invoice_number");



ALTER TABLE ONLY "public"."invoices"
    ADD CONSTRAINT "invoices_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."itineraries"
    ADD CONSTRAINT "itineraries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."itinerary_events"
    ADD CONSTRAINT "itinerary_events_entry_id_key" UNIQUE ("entry_id");



ALTER TABLE ONLY "public"."itinerary_events"
    ADD CONSTRAINT "itinerary_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."itinerary_places"
    ADD CONSTRAINT "itinerary_places_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."itinerary_shares"
    ADD CONSTRAINT "itinerary_shares_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."itinerary_shares"
    ADD CONSTRAINT "itinerary_shares_token_key" UNIQUE ("token");



ALTER TABLE ONLY "public"."loyalty_program_locations"
    ADD CONSTRAINT "loyalty_program_locations_pkey" PRIMARY KEY ("program_id", "place_id");



ALTER TABLE ONLY "public"."loyalty_programs"
    ADD CONSTRAINT "loyalty_programs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."loyalty_redemptions"
    ADD CONSTRAINT "loyalty_redemptions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."loyalty_visits"
    ADD CONSTRAINT "loyalty_visits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mas_bands"
    ADD CONSTRAINT "mas_bands_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."mas_bands"
    ADD CONSTRAINT "mas_bands_season_slug_key" UNIQUE ("season_id", "slug");



ALTER TABLE ONLY "public"."mas_bands"
    ADD CONSTRAINT "mas_bands_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."member_perks"
    ADD CONSTRAINT "member_perks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."menu_items"
    ADD CONSTRAINT "menu_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."nfc_tags"
    ADD CONSTRAINT "nfc_tags_fallback_code_key" UNIQUE ("fallback_code");



ALTER TABLE ONLY "public"."nfc_tags"
    ADD CONSTRAINT "nfc_tags_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."nfc_tags"
    ADD CONSTRAINT "nfc_tags_tag_code_key" UNIQUE ("tag_code");



ALTER TABLE ONLY "public"."notification_log"
    ADD CONSTRAINT "notification_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."organizers"
    ADD CONSTRAINT "organizers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."organizers"
    ADD CONSTRAINT "organizers_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."partner_messages"
    ADD CONSTRAINT "partner_messages_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."partner_perks"
    ADD CONSTRAINT "partner_perks_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."partners"
    ADD CONSTRAINT "partners_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."passport_entries"
    ADD CONSTRAINT "passport_entries_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payment_confirmations"
    ADD CONSTRAINT "payment_confirmations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."payment_instructions"
    ADD CONSTRAINT "payment_instructions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."performer_group_members"
    ADD CONSTRAINT "performer_group_members_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."performer_group_members"
    ADD CONSTRAINT "performer_group_unique" UNIQUE ("group_performer_id", "member_performer_id");



ALTER TABLE ONLY "public"."performer_schedule"
    ADD CONSTRAINT "performer_schedule_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."performer_schedule"
    ADD CONSTRAINT "performer_schedule_unique" UNIQUE ("performer_id", "schedule_item_id");



ALTER TABLE ONLY "public"."performers"
    ADD CONSTRAINT "performers_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."performers"
    ADD CONSTRAINT "performers_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."perk_redemptions"
    ADD CONSTRAINT "perk_redemptions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."place_checkin_settings"
    ADD CONSTRAINT "place_checkin_settings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."place_checkin_settings"
    ADD CONSTRAINT "place_checkin_settings_place_id_key" UNIQUE ("place_id");



ALTER TABLE ONLY "public"."place_special_hours"
    ADD CONSTRAINT "place_special_hours_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."place_specials"
    ADD CONSTRAINT "place_specials_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."place_visit_events"
    ADD CONSTRAINT "place_visit_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."places"
    ADD CONSTRAINT "places_partner_access_token_key" UNIQUE ("partner_access_token");



ALTER TABLE ONLY "public"."places"
    ADD CONSTRAINT "places_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."places"
    ADD CONSTRAINT "places_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."push_tokens"
    ADD CONSTRAINT "push_tokens_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."push_tokens"
    ADD CONSTRAINT "push_tokens_user_token_unique" UNIQUE ("user_id", "token");



ALTER TABLE ONLY "public"."ranking_events"
    ADD CONSTRAINT "ranking_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."recommended_dishes"
    ADD CONSTRAINT "recommended_dishes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."redemption_events"
    ADD CONSTRAINT "redemption_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."saved_events"
    ADD CONSTRAINT "saved_events_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."saved_events"
    ADD CONSTRAINT "saved_events_user_event_unique" UNIQUE ("user_id", "event_id");



ALTER TABLE ONLY "public"."saved_experiences"
    ADD CONSTRAINT "saved_experiences_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."saved_experiences"
    ADD CONSTRAINT "saved_experiences_user_id_experience_id_key" UNIQUE ("user_id", "experience_id");



ALTER TABLE ONLY "public"."schedule_change_log"
    ADD CONSTRAINT "schedule_change_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."special_interactions"
    ADD CONSTRAINT "special_interactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."special_interactions"
    ADD CONSTRAINT "special_interactions_user_id_special_id_key" UNIQUE ("user_id", "special_id");



ALTER TABLE ONLY "public"."special_interactions"
    ADD CONSTRAINT "special_interactions_user_special_unique" UNIQUE ("user_id", "special_id");



ALTER TABLE ONLY "public"."special_visits"
    ADD CONSTRAINT "special_visits_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."specials"
    ADD CONSTRAINT "specials_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sponsors"
    ADD CONSTRAINT "sponsors_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."sponsors"
    ADD CONSTRAINT "sponsors_slug_key" UNIQUE ("slug");



ALTER TABLE ONLY "public"."subscription_plans"
    ADD CONSTRAINT "subscription_plans_pkey" PRIMARY KEY ("key");



ALTER TABLE ONLY "public"."subscriptions"
    ADD CONSTRAINT "subscriptions_company_account_id_key" UNIQUE ("company_account_id");



ALTER TABLE ONLY "public"."subscriptions"
    ADD CONSTRAINT "subscriptions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."suggested_places"
    ADD CONSTRAINT "suggested_places_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."ticket_locations"
    ADD CONSTRAINT "ticket_locations_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_activity"
    ADD CONSTRAINT "trip_activity_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_change_requests"
    ADD CONSTRAINT "trip_change_requests_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_change_votes"
    ADD CONSTRAINT "trip_change_votes_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_change_votes"
    ADD CONSTRAINT "trip_change_votes_request_id_user_id_key" UNIQUE ("request_id", "user_id");



ALTER TABLE ONLY "public"."trip_collaborators"
    ADD CONSTRAINT "trip_collaborators_invite_token_key" UNIQUE ("invite_token");



ALTER TABLE ONLY "public"."trip_collaborators"
    ADD CONSTRAINT "trip_collaborators_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."trip_collaborators"
    ADD CONSTRAINT "trip_collaborators_trip_id_invitee_id_key" UNIQUE ("trip_id", "invitee_id");



ALTER TABLE ONLY "public"."trip_completions"
    ADD CONSTRAINT "trip_completions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_achievements"
    ADD CONSTRAINT "user_achievements_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_achievements"
    ADD CONSTRAINT "user_achievements_user_achievement_unique" UNIQUE ("user_id", "achievement_id");



ALTER TABLE ONLY "public"."user_checkins"
    ADD CONSTRAINT "user_checkins_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user"
    ADD CONSTRAINT "user_email_key" UNIQUE ("email");



ALTER TABLE ONLY "public"."user_event_activity"
    ADD CONSTRAINT "user_event_activity_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_event_interactions"
    ADD CONSTRAINT "user_event_interactions_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_event_interactions"
    ADD CONSTRAINT "user_event_interactions_user_id_event_id_interaction_type_key" UNIQUE ("user_id", "event_id", "interaction_type");



ALTER TABLE ONLY "public"."user_favorite_items"
    ADD CONSTRAINT "user_favorite_items_pkey" PRIMARY KEY ("user_id", "menu_item_id");



ALTER TABLE ONLY "public"."user_item_logs"
    ADD CONSTRAINT "user_item_logs_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_loyalty_cards"
    ADD CONSTRAINT "user_loyalty_cards_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_loyalty_cards"
    ADD CONSTRAINT "user_loyalty_cards_user_id_program_id_key" UNIQUE ("user_id", "program_id");



ALTER TABLE ONLY "public"."user_month_rankings"
    ADD CONSTRAINT "user_month_rankings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_month_rankings"
    ADD CONSTRAINT "user_month_rankings_unique" UNIQUE ("user_id", "year", "month", "place_slug");



ALTER TABLE ONLY "public"."user"
    ADD CONSTRAINT "user_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_place_rankings"
    ADD CONSTRAINT "user_place_rankings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_place_rankings"
    ADD CONSTRAINT "user_place_rankings_unique" UNIQUE ("user_id", "place_id");



ALTER TABLE ONLY "public"."user_saved_menu_items"
    ADD CONSTRAINT "user_saved_menu_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_saved_menu_items"
    ADD CONSTRAINT "user_saved_menu_items_user_id_vendor_id_menu_item_name_key" UNIQUE ("user_id", "vendor_id", "menu_item_name");



ALTER TABLE ONLY "public"."user_saved_schedule_items"
    ADD CONSTRAINT "user_saved_schedule_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_saved_schedule_items"
    ADD CONSTRAINT "user_saved_schedule_items_user_id_schedule_item_id_key" UNIQUE ("user_id", "schedule_item_id");



ALTER TABLE ONLY "public"."user_schedule_plans"
    ADD CONSTRAINT "user_schedule_plans_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_schedule_plans"
    ADD CONSTRAINT "user_schedule_plans_user_id_schedule_item_id_key" UNIQUE ("user_id", "schedule_item_id");



ALTER TABLE ONLY "public"."user_stats"
    ADD CONSTRAINT "user_stats_pkey" PRIMARY KEY ("user_id");



ALTER TABLE ONLY "public"."user_tour_progress"
    ADD CONSTRAINT "user_tour_progress_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_tour_progress"
    ADD CONSTRAINT "user_tour_progress_user_id_guide_slug_key" UNIQUE ("user_id", "guide_slug");



ALTER TABLE ONLY "public"."user_vendor_item_ratings"
    ADD CONSTRAINT "user_vendor_item_ratings_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."user_vendor_item_ratings"
    ADD CONSTRAINT "user_vendor_item_ratings_user_id_event_id_vendor_id_item_na_key" UNIQUE ("user_id", "event_id", "vendor_id", "item_name");



ALTER TABLE ONLY "public"."vendor_menu_items"
    ADD CONSTRAINT "vendor_menu_items_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."vendors"
    ADD CONSTRAINT "vendors_name_unique" UNIQUE ("name");



ALTER TABLE ONLY "public"."vendors"
    ADD CONSTRAINT "vendors_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."vibe_tags"
    ADD CONSTRAINT "vibe_tags_event_id_marker_id_user_id_key" UNIQUE ("event_id", "marker_id", "user_id");



ALTER TABLE ONLY "public"."vibe_tags"
    ADD CONSTRAINT "vibe_tags_pkey" PRIMARY KEY ("id");



ALTER TABLE "public"."vibe_tags"
    ADD CONSTRAINT "vibe_tags_tag_line_status_check" CHECK (("tag" = ANY (ARRAY['no_line'::"text", 'short'::"text", 'moving'::"text", 'packed'::"text"]))) NOT VALID;



ALTER TABLE ONLY "public"."visit_log"
    ADD CONSTRAINT "visit_log_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."visited_feedback"
    ADD CONSTRAINT "visited_feedback_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."visited"
    ADD CONSTRAINT "visited_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."xp_rules"
    ADD CONSTRAINT "xp_rules_pkey" PRIMARY KEY ("id");



ALTER TABLE ONLY "public"."xp_rules"
    ADD CONSTRAINT "xp_rules_rule_key_key" UNIQUE ("rule_key");



ALTER TABLE ONLY "public"."xp_rules"
    ADD CONSTRAINT "xp_rules_source_type_key" UNIQUE ("source_type");



ALTER TABLE ONLY "public"."xp_transactions"
    ADD CONSTRAINT "xp_transactions_pkey" PRIMARY KEY ("id");



CREATE INDEX "alerts_active_idx" ON "public"."alerts" USING "btree" ("start_date", "end_date");



CREATE INDEX "alerts_applies_to_idx" ON "public"."alerts" USING "btree" ("applies_to");



CREATE INDEX "alerts_country_idx" ON "public"."alerts" USING "btree" ("country");



CREATE INDEX "alerts_parish_idx" ON "public"."alerts" USING "btree" ("parish");



CREATE INDEX "alerts_place_id_idx" ON "public"."alerts" USING "btree" ("place_id");



CREATE INDEX "analytics_events_entity_event_idx" ON "public"."analytics_events" USING "btree" ("entity_type", "entity_id", "event_name", "created_at" DESC);



CREATE INDEX "analytics_events_entity_idx" ON "public"."analytics_events" USING "btree" ("entity_type", "entity_id", "created_at" DESC);



CREATE INDEX "analytics_events_event_created_idx" ON "public"."analytics_events" USING "btree" ("event_name", "created_at" DESC);



CREATE INDEX "analytics_events_session_entity_idx" ON "public"."analytics_events" USING "btree" ("entity_type", "entity_id", "session_id");



CREATE INDEX "analytics_events_user_idx" ON "public"."analytics_events" USING "btree" ("user_id", "created_at" DESC) WHERE ("user_id" IS NOT NULL);



CREATE INDEX "billing_accounts_partner_idx" ON "public"."billing_accounts" USING "btree" ("partner_id");



CREATE INDEX "billing_audit_company_idx" ON "public"."billing_audit_log" USING "btree" ("company_account_id", "created_at" DESC);



CREATE INDEX "billing_notifications_status_idx" ON "public"."billing_notifications" USING "btree" ("status", "created_at");



CREATE INDEX "billing_usage_partner_cycle_idx" ON "public"."billing_usage" USING "btree" ("partner_id", "cycle_start", "cycle_end");



CREATE INDEX "billing_usage_place_cycle_idx" ON "public"."billing_usage" USING "btree" ("place_id", "cycle_start", "cycle_end");



CREATE UNIQUE INDEX "billing_usage_source_unique" ON "public"."billing_usage" USING "btree" ("source_type", "source_id", "usage_type");



CREATE INDEX "bookings_commission_status_idx" ON "public"."bookings" USING "btree" ("commission_status", "created_at" DESC) WHERE ("booking_type" = 'stay'::"text");



CREATE INDEX "bookings_feedback_pending_idx" ON "public"."bookings" USING "btree" ("visit_date", "status") WHERE (("booking_type" = 'day_pass'::"text") AND ("feedback_requested_at" IS NULL));



CREATE INDEX "bookings_place_idx" ON "public"."bookings" USING "btree" ("place_id", "status", "created_at" DESC);



CREATE INDEX "bookings_special_idx" ON "public"."bookings" USING "btree" ("special_id", "status", "created_at" DESC) WHERE ("special_id" IS NOT NULL);



CREATE INDEX "bookings_type_idx" ON "public"."bookings" USING "btree" ("booking_type", "status");



CREATE INDEX "bookings_user_idx" ON "public"."bookings" USING "btree" ("user_id", "status", "created_at" DESC);



CREATE INDEX "businesses_listing_id_idx" ON "public"."businesses" USING "btree" ("listing_id");



CREATE INDEX "company_entitlements_company_idx" ON "public"."company_entitlements" USING "btree" ("company_account_id");



CREATE INDEX "company_events_company_idx" ON "public"."company_events" USING "btree" ("company_account_id");



CREATE INDEX "company_events_event_idx" ON "public"."company_events" USING "btree" ("event_id");



CREATE INDEX "company_locations_company_idx" ON "public"."company_locations" USING "btree" ("company_account_id");



CREATE INDEX "company_requests_status_idx" ON "public"."company_requests" USING "btree" ("status");



CREATE INDEX "company_setup_requests_user_idx" ON "public"."company_setup_requests" USING "btree" ("user_id");



CREATE INDEX "company_users_company_idx" ON "public"."company_users" USING "btree" ("company_account_id");



CREATE INDEX "company_users_email_idx" ON "public"."company_users" USING "btree" ("lower"("email"));



CREATE INDEX "company_users_user_idx" ON "public"."company_users" USING "btree" ("user_id");



CREATE INDEX "dish_likes_country_idx" ON "public"."dish_likes" USING "btree" ("country");



CREATE INDEX "dish_likes_place_id_idx" ON "public"."dish_likes" USING "btree" ("place_id");



CREATE INDEX "dish_likes_user_id_idx" ON "public"."dish_likes" USING "btree" ("user_id");



CREATE INDEX "eae_event_name_idx" ON "public"."event_analytics_events" USING "btree" ("event_id", "event_name", "created_at");



CREATE INDEX "eae_sponsor_idx" ON "public"."event_analytics_events" USING "btree" ("sponsor_id") WHERE ("sponsor_id" IS NOT NULL);



CREATE INDEX "eae_user_idx" ON "public"."event_analytics_events" USING "btree" ("user_id") WHERE ("user_id" IS NOT NULL);



CREATE INDEX "eae_vendor_idx" ON "public"."event_analytics_events" USING "btree" ("vendor_id") WHERE ("vendor_id" IS NOT NULL);



CREATE INDEX "eps_event_id_idx" ON "public"."event_partner_submissions" USING "btree" ("event_id");



CREATE INDEX "event_interests_event_id_idx" ON "public"."event_interests" USING "btree" ("event_id");



CREATE INDEX "event_interests_event_idx" ON "public"."event_interests" USING "btree" ("event_id");



CREATE INDEX "event_interests_status_idx" ON "public"."event_interests" USING "btree" ("status");



CREATE INDEX "event_interests_user_id_idx" ON "public"."event_interests" USING "btree" ("user_id");



CREATE INDEX "event_map_invites_event_idx" ON "public"."event_map_invites" USING "btree" ("event_id", "created_at" DESC);



CREATE INDEX "event_notification_deliveries_event_idx" ON "public"."event_notification_deliveries" USING "btree" ("event_id");



CREATE INDEX "event_notification_deliveries_user_idx" ON "public"."event_notification_deliveries" USING "btree" ("user_id");



CREATE INDEX "event_partner_submission_assets_submission_id_idx" ON "public"."event_partner_submission_assets" USING "btree" ("submission_id");



CREATE INDEX "event_partner_submission_assets_token_idx" ON "public"."event_partner_submission_assets" USING "btree" ("token");



CREATE INDEX "event_partner_submissions_created_at_idx" ON "public"."event_partner_submissions" USING "btree" ("created_at" DESC);



CREATE INDEX "event_partner_submissions_status_idx" ON "public"."event_partner_submissions" USING "btree" ("status");



CREATE INDEX "event_partner_submissions_token_idx" ON "public"."event_partner_submissions" USING "btree" ("token");



CREATE INDEX "event_push_event_idx" ON "public"."event_push_notifications" USING "btree" ("event_id");



CREATE INDEX "event_sponsor_activations_event_id_idx" ON "public"."event_sponsor_activations" USING "btree" ("event_id");



CREATE INDEX "event_sponsor_activations_qr_token_idx" ON "public"."event_sponsor_activations" USING "btree" ("qr_code_token");



CREATE INDEX "event_sponsor_activations_sponsor_id_idx" ON "public"."event_sponsor_activations" USING "btree" ("sponsor_id");



CREATE INDEX "event_vendors_event_zone_idx" ON "public"."event_vendors" USING "btree" ("event_id", "zone") WHERE ("zone" IS NOT NULL);



CREATE INDEX "events_country_idx" ON "public"."events" USING "btree" ("country");



CREATE INDEX "events_parent_event_idx" ON "public"."events" USING "btree" ("parent_event_id");



CREATE INDEX "events_partner_access_token_idx" ON "public"."events" USING "btree" ("partner_access_token");



CREATE UNIQUE INDEX "events_partner_access_token_key" ON "public"."events" USING "btree" ("partner_access_token");



CREATE INDEX "events_partner_id_idx" ON "public"."events" USING "btree" ("partner_id");



CREATE INDEX "favorites_country_idx" ON "public"."favorites" USING "btree" ("country");



CREATE INDEX "favorites_place_id_idx" ON "public"."favorites" USING "btree" ("place_id");



CREATE INDEX "favourite_guides_country_idx" ON "public"."favourite_guides" USING "btree" ("country");



CREATE INDEX "feedback_user_id_idx" ON "public"."feedback" USING "btree" ("user_id");



CREATE INDEX "guide_spots_country_idx" ON "public"."guide_spots" USING "btree" ("country");



CREATE INDEX "guides_country_idx" ON "public"."guides" USING "btree" ("country");



CREATE INDEX "idx_bands_slug" ON "public"."bands" USING "btree" ("slug");



CREATE INDEX "idx_days_event" ON "public"."event_schedule_days" USING "btree" ("event_id");



CREATE INDEX "idx_event_bands_band_id" ON "public"."event_bands" USING "btree" ("band_id");



CREATE INDEX "idx_event_bands_event_id" ON "public"."event_bands" USING "btree" ("event_id");



CREATE INDEX "idx_event_map_points_event" ON "public"."event_map_points" USING "btree" ("event_id");



CREATE INDEX "idx_event_map_points_vendor" ON "public"."event_map_points" USING "btree" ("event_vendor_id");



CREATE INDEX "idx_event_sponsors_active" ON "public"."event_sponsors" USING "btree" ("is_active");



CREATE INDEX "idx_event_sponsors_event" ON "public"."event_sponsors" USING "btree" ("event_id");



CREATE INDEX "idx_event_sponsors_tier" ON "public"."event_sponsors" USING "btree" ("tier");



CREATE INDEX "idx_event_updates_event_id" ON "public"."event_updates" USING "btree" ("event_id");



CREATE INDEX "idx_events_active" ON "public"."events" USING "btree" ("start_date", "end_date", "status") WHERE ("deleted_at" IS NULL);



CREATE INDEX "idx_events_band_id" ON "public"."events" USING "btree" ("band_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "idx_events_featured" ON "public"."events" USING "btree" ("is_featured", "priority" DESC, "start_date") WHERE (("deleted_at" IS NULL) AND ("status" = 'published'::"text"));



CREATE INDEX "idx_events_location" ON "public"."events" USING "btree" ("parish", "town") WHERE (("deleted_at" IS NULL) AND ("status" = 'published'::"text"));



CREATE INDEX "idx_events_parent_event_id" ON "public"."events" USING "btree" ("parent_event_id");



CREATE INDEX "idx_events_place" ON "public"."events" USING "btree" ("place_id") WHERE ("deleted_at" IS NULL);



CREATE INDEX "idx_events_slug" ON "public"."events" USING "btree" ("slug") WHERE ("deleted_at" IS NULL);



CREATE INDEX "idx_events_type" ON "public"."events" USING "btree" ("event_type") WHERE (("deleted_at" IS NULL) AND ("status" = 'published'::"text"));



CREATE INDEX "idx_favourite_guides_guide_slug" ON "public"."favourite_guides" USING "btree" ("guide_slug");



CREATE INDEX "idx_favourite_guides_user_id" ON "public"."favourite_guides" USING "btree" ("user_id");



CREATE INDEX "idx_guide_spots_guide_slug" ON "public"."guide_spots" USING "btree" ("guide_slug");



CREATE INDEX "idx_guide_spots_place_slug" ON "public"."guide_spots" USING "btree" ("place_slug");



CREATE INDEX "idx_hotel_availability_date_range" ON "public"."hotel_availability" USING "btree" ("room_type_id", "stay_date");



CREATE INDEX "idx_hotel_rate_plans_room_type" ON "public"."hotel_rate_plans" USING "btree" ("room_type_id");



CREATE INDEX "idx_hotel_room_types_place" ON "public"."hotel_room_types" USING "btree" ("place_id");



CREATE INDEX "idx_inventory_holds_active" ON "public"."hotel_inventory_holds" USING "btree" ("room_type_id", "check_in_date", "check_out_date") WHERE (("released_at" IS NULL) AND ("is_converted" = false));



CREATE INDEX "idx_items_day" ON "public"."event_schedule_items" USING "btree" ("day_id");



CREATE INDEX "idx_items_event" ON "public"."event_schedule_items" USING "btree" ("event_id");



CREATE INDEX "idx_items_start" ON "public"."event_schedule_items" USING "btree" ("start_time");



CREATE INDEX "idx_items_track" ON "public"."event_schedule_items" USING "btree" ("track_id");



CREATE INDEX "idx_items_version" ON "public"."event_schedule_items" USING "btree" ("version");



CREATE INDEX "idx_itinerary_places_itinerary_id" ON "public"."itinerary_places" USING "btree" ("itinerary_id");



CREATE INDEX "idx_itinerary_places_place_id" ON "public"."itinerary_places" USING "btree" ("place_id");



CREATE INDEX "idx_loyalty_redemptions_card" ON "public"."loyalty_redemptions" USING "btree" ("card_id", "redeemed_at" DESC);



CREATE INDEX "idx_loyalty_redemptions_program" ON "public"."loyalty_redemptions" USING "btree" ("program_id", "redeemed_at" DESC);



CREATE INDEX "idx_mas_bands_season" ON "public"."mas_bands" USING "btree" ("season_id", "sort_order");



CREATE INDEX "idx_member_perks_is_active" ON "public"."member_perks" USING "btree" ("is_active");



CREATE INDEX "idx_member_perks_membership_tier" ON "public"."member_perks" USING "btree" ("membership_tier");



CREATE INDEX "idx_member_perks_offer_type" ON "public"."member_perks" USING "btree" ("offer_type");



CREATE INDEX "idx_member_perks_place_id" ON "public"."member_perks" USING "btree" ("place_id");



CREATE INDEX "idx_notification_log_lookup" ON "public"."notification_log" USING "btree" ("user_id", "itinerary_id", "notification_type");



CREATE INDEX "idx_ranking_events_type" ON "public"."ranking_events" USING "btree" ("event_type", "created_at" DESC);



CREATE INDEX "idx_ranking_events_user" ON "public"."ranking_events" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "idx_rankings_elo" ON "public"."user_place_rankings" USING "btree" ("user_id", "category", "elo_score" DESC);



CREATE INDEX "idx_rankings_unranked" ON "public"."user_place_rankings" USING "btree" ("user_id", "is_ranked") WHERE ("is_ranked" = false);



CREATE INDEX "idx_rankings_user_category" ON "public"."user_place_rankings" USING "btree" ("user_id", "category", "is_ranked");



CREATE INDEX "idx_room_allocations_booking" ON "public"."booking_room_allocations" USING "btree" ("booking_id");



CREATE INDEX "idx_room_allocations_room_dates" ON "public"."booking_room_allocations" USING "btree" ("room_type_id", "check_in_date", "check_out_date");



CREATE INDEX "idx_saved_item" ON "public"."user_saved_schedule_items" USING "btree" ("schedule_item_id");



CREATE INDEX "idx_saved_user" ON "public"."user_saved_schedule_items" USING "btree" ("user_id");



CREATE INDEX "idx_sponsors_active" ON "public"."sponsors" USING "btree" ("is_active");



CREATE INDEX "idx_sponsors_slug" ON "public"."sponsors" USING "btree" ("slug");



CREATE INDEX "idx_ticket_locations_event_id" ON "public"."ticket_locations" USING "btree" ("event_id");



CREATE INDEX "idx_timeline_events_booking" ON "public"."booking_timeline_events" USING "btree" ("booking_id", "created_at" DESC);



CREATE INDEX "idx_tracks_event" ON "public"."event_schedule_tracks" USING "btree" ("event_id");



CREATE INDEX "idx_transport_routes_event_id" ON "public"."event_transport_routes" USING "btree" ("event_id");



CREATE INDEX "idx_transport_stops_route_id" ON "public"."event_transport_stops" USING "btree" ("route_id");



CREATE INDEX "idx_transport_times_route_id" ON "public"."event_transport_times" USING "btree" ("route_id");



CREATE INDEX "idx_transport_times_stop_id" ON "public"."event_transport_times" USING "btree" ("stop_id");



CREATE INDEX "idx_uea_entity" ON "public"."user_event_activity" USING "btree" ("entity_type", "entity_id");



CREATE INDEX "idx_uea_event" ON "public"."user_event_activity" USING "btree" ("event_id");



CREATE INDEX "idx_uea_redeemed" ON "public"."user_event_activity" USING "btree" ("event_id", "user_id", "entity_type", "activity_type") WHERE ("activity_type" = 'redeemed'::"text");



CREATE INDEX "idx_uea_user" ON "public"."user_event_activity" USING "btree" ("user_id");



CREATE INDEX "idx_user_interactions_event" ON "public"."user_event_interactions" USING "btree" ("event_id", "interaction_type");



CREATE INDEX "idx_user_interactions_user" ON "public"."user_event_interactions" USING "btree" ("user_id", "interaction_type");



CREATE INDEX "idx_visited_feedback_created_at" ON "public"."visited_feedback" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_visited_feedback_place_id" ON "public"."visited_feedback" USING "btree" ("place_id");



CREATE INDEX "idx_visited_feedback_user_id" ON "public"."visited_feedback" USING "btree" ("user_id");



CREATE INDEX "idx_xp_transactions_created_at" ON "public"."xp_transactions" USING "btree" ("created_at" DESC);



CREATE INDEX "idx_xp_transactions_source_type" ON "public"."xp_transactions" USING "btree" ("source_type");



CREATE INDEX "idx_xp_transactions_user_created_at" ON "public"."xp_transactions" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "idx_xp_transactions_user_id" ON "public"."xp_transactions" USING "btree" ("user_id");



CREATE INDEX "invoice_line_items_invoice_idx" ON "public"."invoice_line_items" USING "btree" ("invoice_id");



CREATE INDEX "invoices_company_idx" ON "public"."invoices" USING "btree" ("company_account_id");



CREATE INDEX "invoices_status_idx" ON "public"."invoices" USING "btree" ("status");



CREATE INDEX "itineraries_country_idx" ON "public"."itineraries" USING "btree" ("country");



CREATE INDEX "itinerary_events_event_idx" ON "public"."itinerary_events" USING "btree" ("event_id");



CREATE INDEX "itinerary_events_itinerary_idx" ON "public"."itinerary_events" USING "btree" ("itinerary_id", "planned_day");



CREATE INDEX "itinerary_places_country_idx" ON "public"."itinerary_places" USING "btree" ("country");



CREATE INDEX "itinerary_shares_created_by_idx" ON "public"."itinerary_shares" USING "btree" ("created_by");



CREATE UNIQUE INDEX "itinerary_shares_one_per_trip" ON "public"."itinerary_shares" USING "btree" ("itinerary_id");



CREATE INDEX "itinerary_shares_token_idx" ON "public"."itinerary_shares" USING "btree" ("token");



CREATE INDEX "loyalty_program_locations_place_idx" ON "public"."loyalty_program_locations" USING "btree" ("place_id");



CREATE INDEX "loyalty_programs_place_id_idx" ON "public"."loyalty_programs" USING "btree" ("place_id");



CREATE INDEX "loyalty_visits_card_id_idx" ON "public"."loyalty_visits" USING "btree" ("card_id");



CREATE INDEX "loyalty_visits_place_id_idx" ON "public"."loyalty_visits" USING "btree" ("place_id");



CREATE INDEX "loyalty_visits_stamped_at_idx" ON "public"."loyalty_visits" USING "btree" ("stamped_at");



CREATE INDEX "loyalty_visits_user_id_idx" ON "public"."loyalty_visits" USING "btree" ("user_id");



CREATE INDEX "menu_items_place_idx" ON "public"."menu_items" USING "btree" ("place_id");



CREATE UNIQUE INDEX "menu_items_place_name_uniq" ON "public"."menu_items" USING "btree" ("place_id", "lower"("canonical_name"));



CREATE INDEX "nfc_tags_active_idx" ON "public"."nfc_tags" USING "btree" ("active") WHERE ("active" = true);



CREATE INDEX "nfc_tags_event_id_idx" ON "public"."nfc_tags" USING "btree" ("event_id") WHERE ("event_id" IS NOT NULL);



CREATE INDEX "nfc_tags_event_idx" ON "public"."nfc_tags" USING "btree" ("event_id");



CREATE INDEX "nfc_tags_expires_at_idx" ON "public"."nfc_tags" USING "btree" ("expires_at") WHERE ("expires_at" IS NOT NULL);



CREATE UNIQUE INDEX "nfc_tags_fallback_code_uniq" ON "public"."nfc_tags" USING "btree" ("fallback_code") WHERE ("fallback_code" IS NOT NULL);



CREATE INDEX "nfc_tags_place_id_idx" ON "public"."nfc_tags" USING "btree" ("place_id") WHERE ("place_id" IS NOT NULL);



CREATE INDEX "nfc_tags_place_idx" ON "public"."nfc_tags" USING "btree" ("place_id");



CREATE INDEX "notification_log_dedupe_collab" ON "public"."notification_log" USING "btree" ("user_id", "collaboration_id", "notification_type");



CREATE INDEX "notification_log_dedupe_loyalty" ON "public"."notification_log" USING "btree" ("user_id", "visit_id", "notification_type");



CREATE INDEX "notification_log_type_sent_idx" ON "public"."notification_log" USING "btree" ("notification_type", "sent_at" DESC);



CREATE INDEX "notification_log_user_sent_idx" ON "public"."notification_log" USING "btree" ("user_id", "sent_at" DESC);



CREATE INDEX "onboarding_invites_company_idx" ON "public"."company_onboarding_invites" USING "btree" ("company_account_id");



CREATE INDEX "onboarding_invites_email_idx" ON "public"."company_onboarding_invites" USING "btree" ("lower"("email"));



CREATE INDEX "partner_messages_created_at_idx" ON "public"."partner_messages" USING "btree" ("created_at" DESC);



CREATE INDEX "partner_messages_partner_idx" ON "public"."partner_messages" USING "btree" ("partner_id");



CREATE INDEX "partner_messages_status_idx" ON "public"."partner_messages" USING "btree" ("status");



CREATE INDEX "partner_perks_place_active_idx" ON "public"."partner_perks" USING "btree" ("place_id", "active");



CREATE INDEX "passport_entries_user_idx" ON "public"."passport_entries" USING "btree" ("user_id", "completed_at" DESC);



CREATE INDEX "payment_confirmations_invoice_idx" ON "public"."payment_confirmations" USING "btree" ("invoice_id");



CREATE INDEX "payment_confirmations_status_idx" ON "public"."payment_confirmations" USING "btree" ("status");



CREATE INDEX "performers_event_slug_idx" ON "public"."performers" USING "btree" ("event_slug");



CREATE INDEX "performers_place_id_idx" ON "public"."performers" USING "btree" ("place_id");



CREATE INDEX "performers_priority_idx" ON "public"."performers" USING "btree" ("priority" DESC);



CREATE INDEX "performers_profile_type_idx" ON "public"."performers" USING "btree" ("profile_type");



CREATE INDEX "performers_slug_idx" ON "public"."performers" USING "btree" ("slug");



CREATE INDEX "performers_status_idx" ON "public"."performers" USING "btree" ("status");



CREATE INDEX "perk_redemptions_perk_idx" ON "public"."perk_redemptions" USING "btree" ("perk_id");



CREATE INDEX "perk_redemptions_user_idx" ON "public"."perk_redemptions" USING "btree" ("user_id", "redeemed_at" DESC);



CREATE INDEX "place_checkin_settings_place_idx" ON "public"."place_checkin_settings" USING "btree" ("place_id");



CREATE INDEX "place_special_hours_date_idx" ON "public"."place_special_hours" USING "btree" ("date");



CREATE UNIQUE INDEX "place_special_hours_unique" ON "public"."place_special_hours" USING "btree" ("place_id", "date");



CREATE INDEX "place_specials_active_idx" ON "public"."place_specials" USING "btree" ("is_active");



CREATE INDEX "place_specials_place_id_idx" ON "public"."place_specials" USING "btree" ("place_id");



CREATE INDEX "place_specials_type_idx" ON "public"."place_specials" USING "btree" ("special_type");



CREATE INDEX "places_day_pass_available_idx" ON "public"."places" USING "btree" ("day_pass_available") WHERE ("day_pass_available" = true);



CREATE INDEX "places_hospitality_group_idx" ON "public"."places" USING "btree" ("hospitality_group");



CREATE INDEX "places_partner_access_token_idx" ON "public"."places" USING "btree" ("partner_access_token");



CREATE INDEX "places_partner_id_idx" ON "public"."places" USING "btree" ("partner_id");



CREATE INDEX "push_tokens_token_idx" ON "public"."push_tokens" USING "btree" ("token");



CREATE INDEX "push_tokens_user_id_idx" ON "public"."push_tokens" USING "btree" ("user_id");



CREATE INDEX "push_tokens_user_idx" ON "public"."push_tokens" USING "btree" ("user_id");



CREATE INDEX "pve_place_time_idx" ON "public"."place_visit_events" USING "btree" ("place_id", "visited_at" DESC);



CREATE INDEX "pve_user_place_time_idx" ON "public"."place_visit_events" USING "btree" ("user_id", "place_id", "visited_at" DESC);



CREATE INDEX "recommended_dishes_country_idx" ON "public"."recommended_dishes" USING "btree" ("country");



CREATE INDEX "recommended_dishes_place_id_idx" ON "public"."recommended_dishes" USING "btree" ("place_id");



CREATE INDEX "redemption_events_card_id_idx" ON "public"."redemption_events" USING "btree" ("card_id");



CREATE INDEX "redemption_events_user_id_idx" ON "public"."redemption_events" USING "btree" ("user_id");



CREATE INDEX "saved_events_event_id_idx" ON "public"."saved_events" USING "btree" ("event_id");



CREATE INDEX "saved_events_event_idx" ON "public"."saved_events" USING "btree" ("event_id");



CREATE INDEX "saved_events_user_id_idx" ON "public"."saved_events" USING "btree" ("user_id");



CREATE INDEX "special_interactions_special_id_status_idx" ON "public"."special_interactions" USING "btree" ("special_id", "status");



CREATE INDEX "special_interactions_special_id_vote_idx" ON "public"."special_interactions" USING "btree" ("special_id", "vote");



CREATE INDEX "special_interactions_special_idx" ON "public"."special_interactions" USING "btree" ("special_id");



CREATE INDEX "special_interactions_user_id_idx" ON "public"."special_interactions" USING "btree" ("user_id");



CREATE INDEX "special_interactions_user_idx" ON "public"."special_interactions" USING "btree" ("user_id");



CREATE INDEX "special_visits_special_id_user_id_idx" ON "public"."special_visits" USING "btree" ("special_id", "user_id");



CREATE INDEX "special_visits_special_idx" ON "public"."special_visits" USING "btree" ("special_id");



CREATE INDEX "special_visits_user_id_idx" ON "public"."special_visits" USING "btree" ("user_id");



CREATE INDEX "special_visits_user_special_idx" ON "public"."special_visits" USING "btree" ("user_id", "special_id");



CREATE INDEX "specials_billing_usage_idx" ON "public"."specials" USING "btree" ("billing_usage_id");



CREATE INDEX "specials_country_idx" ON "public"."specials" USING "btree" ("country");



CREATE INDEX "specials_submission_status_idx" ON "public"."specials" USING "btree" ("submission_status");



CREATE INDEX "suggested_places_country_idx" ON "public"."suggested_places" USING "btree" ("country");



CREATE INDEX "suggested_places_user_id_idx" ON "public"."suggested_places" USING "btree" ("user_id");



CREATE INDEX "trip_activity_trip_idx" ON "public"."trip_activity" USING "btree" ("trip_id", "created_at" DESC);



CREATE INDEX "trip_change_requests_trip_idx" ON "public"."trip_change_requests" USING "btree" ("trip_id", "status", "created_at" DESC);



CREATE INDEX "trip_change_votes_request_idx" ON "public"."trip_change_votes" USING "btree" ("request_id");



CREATE INDEX "trip_collaborators_invite_token_idx" ON "public"."trip_collaborators" USING "btree" ("invite_token");



CREATE INDEX "trip_collaborators_invitee_idx" ON "public"."trip_collaborators" USING "btree" ("invitee_id");



CREATE INDEX "trip_collaborators_token_active_idx" ON "public"."trip_collaborators" USING "btree" ("invite_token") WHERE ("status" = 'pending'::"text");



CREATE INDEX "trip_collaborators_trip_idx" ON "public"."trip_collaborators" USING "btree" ("trip_id");



CREATE INDEX "trip_completions_completed_at_idx" ON "public"."trip_completions" USING "btree" ("completed_at" DESC);



CREATE INDEX "trip_completions_itinerary_id_idx" ON "public"."trip_completions" USING "btree" ("itinerary_id");



CREATE INDEX "trip_completions_user_id_idx" ON "public"."trip_completions" USING "btree" ("user_id");



CREATE UNIQUE INDEX "unique_track_per_event" ON "public"."event_schedule_tracks" USING "btree" ("event_id", "name");



CREATE UNIQUE INDEX "unique_user_event_activity" ON "public"."user_event_activity" USING "btree" ("user_id", "event_id", "entity_type", "entity_id", "activity_type");



CREATE UNIQUE INDEX "unique_user_place_feedback" ON "public"."visited_feedback" USING "btree" ("user_id", "place_id");



CREATE UNIQUE INDEX "uq_xp_achievement_once_per_user" ON "public"."xp_transactions" USING "btree" ("user_id", "source_type", "source_id") WHERE (("source_type" = 'achievement'::"text") AND ("transaction_type" = 'earn'::"text"));



CREATE UNIQUE INDEX "uq_xp_unique_source_once_per_user" ON "public"."xp_transactions" USING "btree" ("user_id", "source_type", "source_id") WHERE (("source_id" IS NOT NULL) AND ("transaction_type" = 'earn'::"text") AND ("source_type" = ANY (ARRAY['verified_visit'::"text", 'event_checkin'::"text", 'itinerary_completed'::"text", 'booking_completed'::"text", 'referral_signup'::"text", 'sponsor_activation'::"text"])));



CREATE INDEX "user_achievements_achievement_id_idx" ON "public"."user_achievements" USING "btree" ("achievement_id");



CREATE INDEX "user_achievements_user_id_idx" ON "public"."user_achievements" USING "btree" ("user_id");



CREATE INDEX "user_checkins_event_created_idx" ON "public"."user_checkins" USING "btree" ("event_id", "created_at" DESC) WHERE ("event_id" IS NOT NULL);



CREATE UNIQUE INDEX "user_checkins_idempotency_idx" ON "public"."user_checkins" USING "btree" ("user_id", "idempotency_key") WHERE ("idempotency_key" IS NOT NULL);



CREATE INDEX "user_checkins_place_created_idx" ON "public"."user_checkins" USING "btree" ("place_id", "created_at" DESC) WHERE ("place_id" IS NOT NULL);



CREATE INDEX "user_checkins_source_idx" ON "public"."user_checkins" USING "btree" ("source");



CREATE INDEX "user_checkins_user_created_idx" ON "public"."user_checkins" USING "btree" ("user_id", "created_at" DESC);



CREATE INDEX "user_checkins_user_event_idx" ON "public"."user_checkins" USING "btree" ("user_id", "event_id", "created_at" DESC);



CREATE INDEX "user_checkins_user_event_time_idx" ON "public"."user_checkins" USING "btree" ("user_id", "event_id", "created_at" DESC) WHERE ("event_id" IS NOT NULL);



CREATE INDEX "user_checkins_user_place_idx" ON "public"."user_checkins" USING "btree" ("user_id", "place_id", "created_at" DESC);



CREATE INDEX "user_checkins_user_place_time_idx" ON "public"."user_checkins" USING "btree" ("user_id", "place_id", "created_at" DESC) WHERE ("place_id" IS NOT NULL);



CREATE INDEX "user_event_activity_country_idx" ON "public"."user_event_activity" USING "btree" ("country");



CREATE INDEX "user_event_activity_entity_idx" ON "public"."user_event_activity" USING "btree" ("entity_type", "entity_id");



CREATE UNIQUE INDEX "user_event_activity_idempotency_idx" ON "public"."user_event_activity" USING "btree" ("user_id", "idempotency_key") WHERE ("idempotency_key" IS NOT NULL);



CREATE UNIQUE INDEX "user_event_activity_idempotency_key_idx" ON "public"."user_event_activity" USING "btree" ("user_id", "idempotency_key") WHERE ("idempotency_key" IS NOT NULL);



CREATE INDEX "user_event_activity_user_event_idx" ON "public"."user_event_activity" USING "btree" ("user_id", "event_id");



CREATE INDEX "user_event_interactions_country_idx" ON "public"."user_event_interactions" USING "btree" ("country");



CREATE INDEX "user_item_logs_item_idx" ON "public"."user_item_logs" USING "btree" ("menu_item_id");



CREATE INDEX "user_item_logs_place_public_idx" ON "public"."user_item_logs" USING "btree" ("place_id") WHERE "is_public";



CREATE INDEX "user_item_logs_user_place_idx" ON "public"."user_item_logs" USING "btree" ("user_id", "place_id");



CREATE INDEX "user_loyalty_cards_program_id_idx" ON "public"."user_loyalty_cards" USING "btree" ("program_id");



CREATE INDEX "user_loyalty_cards_user_id_idx" ON "public"."user_loyalty_cards" USING "btree" ("user_id");



CREATE INDEX "user_saved_menu_items_user_event_idx" ON "public"."user_saved_menu_items" USING "btree" ("user_id", "event_id");



CREATE INDEX "user_saved_menu_items_vendor_idx" ON "public"."user_saved_menu_items" USING "btree" ("vendor_id");



CREATE INDEX "user_vendor_item_ratings_event_id_user_id_idx" ON "public"."user_vendor_item_ratings" USING "btree" ("event_id", "user_id");



CREATE INDEX "vibe_tags_event_created_idx" ON "public"."vibe_tags" USING "btree" ("event_id", "created_at" DESC);



CREATE INDEX "vibe_tags_event_marker_idx" ON "public"."vibe_tags" USING "btree" ("event_id", "marker_id");



CREATE INDEX "visit_log_country_idx" ON "public"."visit_log" USING "btree" ("country");



CREATE INDEX "visit_log_place_id_idx" ON "public"."visit_log" USING "btree" ("place_id");



CREATE INDEX "visit_log_user_id_idx" ON "public"."visit_log" USING "btree" ("user_id");



CREATE INDEX "visited_country_idx" ON "public"."visited" USING "btree" ("country");



CREATE INDEX "visited_feedback_place_context_idx" ON "public"."visited_feedback" USING "btree" ("place_id", "context");



CREATE UNIQUE INDEX "visited_feedback_user_place_context_uniq" ON "public"."visited_feedback" USING "btree" ("user_id", "place_id", "context");



CREATE INDEX "visited_place_id_idx" ON "public"."visited" USING "btree" ("place_id");



CREATE UNIQUE INDEX "visited_user_place_unique" ON "public"."visited" USING "btree" ("user_id", "place_id");



CREATE INDEX "xp_transactions_action_idx" ON "public"."xp_transactions" USING "btree" ("user_id", "action_key");



CREATE UNIQUE INDEX "xp_transactions_dedupe_idx" ON "public"."xp_transactions" USING "btree" ("user_id", "action_key", "source_type", "source_id") WHERE (("source_id" IS NOT NULL) AND ("source_type" IS NOT NULL));



CREATE INDEX "xp_transactions_user_idx" ON "public"."xp_transactions" USING "btree" ("user_id", "created_at" DESC);



CREATE OR REPLACE VIEW "public"."event_activation_summary" AS
 SELECT "a"."id",
    "a"."event_id",
    "a"."sponsor_id",
    "a"."name",
    "a"."zone",
    "a"."days_active",
    "a"."start_time",
    "a"."end_time",
    "a"."troddr_offer",
    "a"."qr_code_token",
    "a"."display_order",
    "s"."name" AS "sponsor_name",
    "s"."brand_color" AS "sponsor_brand_color",
    "s"."logo_url" AS "sponsor_logo_url",
    "count"("uea"."id") AS "checkin_count"
   FROM (("public"."event_sponsor_activations" "a"
     JOIN "public"."sponsors" "s" ON (("s"."id" = "a"."sponsor_id")))
     LEFT JOIN "public"."user_event_activity" "uea" ON ((("uea"."entity_id" = "a"."id") AND ("uea"."entity_type" = 'sponsor_activation'::"text") AND ("uea"."activity_type" = 'visited'::"text"))))
  WHERE ("a"."is_active" = true)
  GROUP BY "a"."id", "s"."name", "s"."brand_color", "s"."logo_url";



CREATE OR REPLACE TRIGGER "auto_create_ranking" AFTER INSERT ON "public"."visited" FOR EACH ROW EXECUTE FUNCTION "public"."create_ranking_on_visit"();



CREATE OR REPLACE TRIGGER "bookings_assign_waitlist" BEFORE INSERT ON "public"."bookings" FOR EACH ROW EXECUTE FUNCTION "public"."assign_special_waitlist_position"();



CREATE OR REPLACE TRIGGER "bookings_notify_partner_insert" AFTER INSERT ON "public"."bookings" FOR EACH ROW WHEN (("new"."status" = 'pending'::"text")) EXECUTE FUNCTION "public"."invoke_notify_partner_booking"();



CREATE OR REPLACE TRIGGER "bookings_populate_guest_snapshot" BEFORE INSERT ON "public"."bookings" FOR EACH ROW EXECUTE FUNCTION "public"."populate_booking_guest_snapshot"();



CREATE OR REPLACE TRIGGER "bookings_updated_at" BEFORE UPDATE ON "public"."bookings" FOR EACH ROW EXECUTE FUNCTION "public"."set_bookings_updated_at"();



CREATE OR REPLACE TRIGGER "calculate_popularity" BEFORE INSERT OR UPDATE OF "going_count", "interested_count" ON "public"."events" FOR EACH ROW EXECUTE FUNCTION "public"."update_event_popularity"();



CREATE OR REPLACE TRIGGER "company_requests_notify" AFTER INSERT ON "public"."company_requests" FOR EACH ROW EXECUTE FUNCTION "public"."_trg_request_notify"();



CREATE OR REPLACE TRIGGER "company_setup_requests_notify" AFTER INSERT ON "public"."company_setup_requests" FOR EACH ROW EXECUTE FUNCTION "public"."_trg_setup_request_notify"();



CREATE OR REPLACE TRIGGER "events_updated_at" BEFORE UPDATE ON "public"."events" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



CREATE OR REPLACE TRIGGER "invoices_notify" AFTER UPDATE ON "public"."invoices" FOR EACH ROW EXECUTE FUNCTION "public"."_trg_invoice_notify"();



CREATE OR REPLACE TRIGGER "mas_bands_updated_at" BEFORE UPDATE ON "public"."mas_bands" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



CREATE OR REPLACE TRIGGER "normalize_quick_tags_trigger" BEFORE INSERT OR UPDATE ON "public"."visited_feedback" FOR EACH ROW EXECUTE FUNCTION "public"."normalize_quick_tags"();



CREATE OR REPLACE TRIGGER "notify-booking-status-on-update" AFTER UPDATE ON "public"."bookings" FOR EACH ROW EXECUTE FUNCTION "supabase_functions"."http_request"('https://rprpwudhplodaqmmwqkf.supabase.co/functions/v1/notify-booking-status', 'POST', '{"Content-type":"application/json","Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJwcnB3dWRocGxvZGFxbW13cWtmIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MDI4NzI4OSwiZXhwIjoyMDY1ODYzMjg5fQ.25otmTY0x8oeaPW8CjHyv1YQTZDwV5SzzSYGnqH1DvM"}', '{}', '5000');



CREATE OR REPLACE TRIGGER "notify-partner-booking-on-insert" AFTER INSERT ON "public"."bookings" FOR EACH ROW EXECUTE FUNCTION "supabase_functions"."http_request"('https://rprpwudhplodaqmmwqkf.supabase.co/functions/v1/notify-partner-booking', 'POST', '{"Content-type":"application/json","Authorization":"Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJwcnB3dWRocGxvZGFxbW13cWtmIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImlhdCI6MTc1MDI4NzI4OSwiZXhwIjoyMDY1ODYzMjg5fQ.25otmTY0x8oeaPW8CjHyv1YQTZDwV5SzzSYGnqH1DvM"}', '{}', '5000');



CREATE OR REPLACE TRIGGER "notify-partner-submission" AFTER INSERT OR UPDATE ON "public"."event_partner_submissions" FOR EACH ROW EXECUTE FUNCTION "supabase_functions"."http_request"('https://rprpwudhplodaqmmwqkf.supabase.co/functions/v1/notify-partner-submission', 'POST', '{"Content-type":"application/json"}', '{}', '5000');



CREATE OR REPLACE TRIGGER "partner_perks_updated_at" BEFORE UPDATE ON "public"."partner_perks" FOR EACH ROW EXECUTE FUNCTION "public"."set_partner_perks_updated_at"();



CREATE OR REPLACE TRIGGER "payment_confirmations_notify" AFTER UPDATE ON "public"."payment_confirmations" FOR EACH ROW EXECUTE FUNCTION "public"."_trg_confirmation_notify"();



CREATE OR REPLACE TRIGGER "place_checkin_settings_updated_at" BEFORE UPDATE ON "public"."place_checkin_settings" FOR EACH ROW EXECUTE FUNCTION "public"."set_place_checkin_settings_updated_at"();



CREATE OR REPLACE TRIGGER "prevent_duplicate_visits_trigger" BEFORE INSERT ON "public"."visited" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_duplicate_visits"();



CREATE OR REPLACE TRIGGER "set_updated_at" BEFORE UPDATE ON "public"."performers" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "special_interactions_updated_at" BEFORE UPDATE ON "public"."special_interactions" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "subscriptions_notify" AFTER UPDATE ON "public"."subscriptions" FOR EACH ROW EXECUTE FUNCTION "public"."_trg_subscription_notify"();



CREATE OR REPLACE TRIGGER "t_bump_versions" BEFORE UPDATE ON "public"."event_schedule_items" FOR EACH ROW EXECUTE FUNCTION "public"."bump_schedule_version"();



CREATE OR REPLACE TRIGGER "t_days_updated" BEFORE UPDATE ON "public"."event_schedule_days" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



CREATE OR REPLACE TRIGGER "t_ensure_meta" BEFORE INSERT ON "public"."event_schedule_items" FOR EACH ROW EXECUTE FUNCTION "public"."ensure_schedule_meta"();



CREATE OR REPLACE TRIGGER "t_items_updated" BEFORE UPDATE ON "public"."event_schedule_items" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



CREATE OR REPLACE TRIGGER "t_tracks_updated" BEFORE UPDATE ON "public"."event_schedule_tracks" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at"();



CREATE OR REPLACE TRIGGER "taste_note_elo_after_insert" AFTER INSERT ON "public"."user_item_logs" FOR EACH ROW EXECUTE FUNCTION "public"."_taste_note_elo_trigger"();



CREATE OR REPLACE TRIGGER "trg_after_xp_transaction_insert" AFTER INSERT ON "public"."xp_transactions" FOR EACH ROW EXECUTE FUNCTION "public"."after_xp_transaction_insert"();



CREATE OR REPLACE TRIGGER "trg_award_achievement_bonus_xp" AFTER INSERT ON "public"."user_achievements" FOR EACH ROW EXECUTE FUNCTION "public"."award_achievement_bonus_xp"();



CREATE OR REPLACE TRIGGER "trg_booking_timeline" AFTER INSERT OR UPDATE OF "status" ON "public"."bookings" FOR EACH ROW EXECUTE FUNCTION "public"."tg_booking_timeline"();



CREATE OR REPLACE TRIGGER "trg_cleanup_expired_invites" AFTER INSERT ON "public"."trip_collaborators" FOR EACH ROW EXECUTE FUNCTION "public"."fn_cleanup_expired_invites"();



CREATE OR REPLACE TRIGGER "trg_copy_submission_to_event" BEFORE UPDATE OF "status" ON "public"."event_partner_submissions" FOR EACH ROW EXECUTE FUNCTION "public"."copy_submission_to_event"();



CREATE OR REPLACE TRIGGER "trg_event_partner_submissions_updated_at" BEFORE UPDATE ON "public"."event_partner_submissions" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_event_sponsor_activations_updated_at" BEFORE UPDATE ON "public"."event_sponsor_activations" FOR EACH ROW EXECUTE FUNCTION "public"."set_updated_at"();



CREATE OR REPLACE TRIGGER "trg_notify_loyalty_stamp" AFTER INSERT ON "public"."loyalty_visits" FOR EACH ROW EXECUTE FUNCTION "public"."fn_notify_loyalty_stamp"();



CREATE OR REPLACE TRIGGER "trg_notify_trip_collaborator" AFTER INSERT ON "public"."trip_collaborators" FOR EACH ROW EXECUTE FUNCTION "public"."fn_notify_trip_collaborator"();



CREATE OR REPLACE TRIGGER "trg_partner_message_email" AFTER INSERT ON "public"."partner_messages" FOR EACH ROW EXECUTE FUNCTION "public"."tg_partner_message_email"();



CREATE OR REPLACE TRIGGER "trg_prevent_xp_transaction_delete" BEFORE DELETE ON "public"."xp_transactions" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_xp_transaction_mutation"();



CREATE OR REPLACE TRIGGER "trg_prevent_xp_transaction_update" BEFORE UPDATE ON "public"."xp_transactions" FOR EACH ROW EXECUTE FUNCTION "public"."prevent_xp_transaction_mutation"();



CREATE OR REPLACE TRIGGER "trg_recalc_user_stats" AFTER UPDATE OF "current_streak", "trips_completed" ON "public"."user_stats" FOR EACH ROW EXECUTE FUNCTION "public"."update_user_stats_from_all"();



CREATE OR REPLACE TRIGGER "trg_special_email" AFTER UPDATE OF "submission_status" ON "public"."specials" FOR EACH ROW EXECUTE FUNCTION "public"."tg_special_email"();



CREATE OR REPLACE TRIGGER "trg_submission_email" AFTER UPDATE OF "status" ON "public"."event_partner_submissions" FOR EACH ROW EXECUTE FUNCTION "public"."tg_submission_email"();



CREATE OR REPLACE TRIGGER "trg_update_user_stats" AFTER INSERT OR DELETE OR UPDATE ON "public"."user_achievements" FOR EACH ROW EXECUTE FUNCTION "public"."update_user_stats_from_all"();



CREATE OR REPLACE TRIGGER "update_nfc_tags_updated_at" BEFORE UPDATE ON "public"."nfc_tags" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_rankings_timestamp" BEFORE UPDATE ON "public"."user_place_rankings" FOR EACH ROW EXECUTE FUNCTION "public"."update_updated_at_column"();



CREATE OR REPLACE TRIGGER "update_visited_feedback_timestamp" BEFORE UPDATE ON "public"."visited_feedback" FOR EACH ROW EXECUTE FUNCTION "public"."update_visited_feedback_timestamp"();



CREATE OR REPLACE TRIGGER "vendors_place_slug_sync" BEFORE INSERT OR UPDATE OF "place_id" ON "public"."vendors" FOR EACH ROW EXECUTE FUNCTION "public"."sync_vendor_place_slug"();



ALTER TABLE ONLY "public"."alerts"
    ADD CONSTRAINT "alerts_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."analytics_events"
    ADD CONSTRAINT "analytics_events_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."billing_accounts"
    ADD CONSTRAINT "billing_accounts_partner_id_fkey" FOREIGN KEY ("partner_id") REFERENCES "public"."partners"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."billing_audit_log"
    ADD CONSTRAINT "billing_audit_log_company_account_id_fkey" FOREIGN KEY ("company_account_id") REFERENCES "public"."company_accounts"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."billing_notifications"
    ADD CONSTRAINT "billing_notifications_company_account_id_fkey" FOREIGN KEY ("company_account_id") REFERENCES "public"."company_accounts"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."billing_usage"
    ADD CONSTRAINT "billing_usage_billing_account_id_fkey" FOREIGN KEY ("billing_account_id") REFERENCES "public"."billing_accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."billing_usage"
    ADD CONSTRAINT "billing_usage_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."billing_usage"
    ADD CONSTRAINT "billing_usage_partner_id_fkey" FOREIGN KEY ("partner_id") REFERENCES "public"."partners"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."billing_usage"
    ADD CONSTRAINT "billing_usage_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."booking_cancellation_policies"
    ADD CONSTRAINT "booking_cancellation_policies_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."booking_cancellation_policies"
    ADD CONSTRAINT "booking_cancellation_policies_rate_plan_id_fkey" FOREIGN KEY ("rate_plan_id") REFERENCES "public"."hotel_rate_plans"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."booking_notification_logs"
    ADD CONSTRAINT "booking_notification_logs_booking_id_fkey" FOREIGN KEY ("booking_id") REFERENCES "public"."bookings"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."booking_room_allocations"
    ADD CONSTRAINT "booking_room_allocations_booking_id_fkey" FOREIGN KEY ("booking_id") REFERENCES "public"."bookings"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."booking_room_allocations"
    ADD CONSTRAINT "booking_room_allocations_rate_plan_id_fkey" FOREIGN KEY ("rate_plan_id") REFERENCES "public"."hotel_rate_plans"("id");



ALTER TABLE ONLY "public"."booking_room_allocations"
    ADD CONSTRAINT "booking_room_allocations_room_type_id_fkey" FOREIGN KEY ("room_type_id") REFERENCES "public"."hotel_room_types"("id");



ALTER TABLE ONLY "public"."booking_timeline_events"
    ADD CONSTRAINT "booking_timeline_events_booking_id_fkey" FOREIGN KEY ("booking_id") REFERENCES "public"."bookings"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_rate_plan_id_fkey" FOREIGN KEY ("rate_plan_id") REFERENCES "public"."hotel_rate_plans"("id");



ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_room_type_id_fkey" FOREIGN KEY ("room_type_id") REFERENCES "public"."hotel_room_types"("id");



ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_special_id_fkey" FOREIGN KEY ("special_id") REFERENCES "public"."specials"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."bookings"
    ADD CONSTRAINT "bookings_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."businesses"
    ADD CONSTRAINT "businesses_id_fkey" FOREIGN KEY ("id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."company_entitlements"
    ADD CONSTRAINT "company_entitlements_company_account_id_fkey" FOREIGN KEY ("company_account_id") REFERENCES "public"."company_accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."company_entitlements"
    ADD CONSTRAINT "company_entitlements_entitlement_key_fkey" FOREIGN KEY ("entitlement_key") REFERENCES "public"."entitlement_definitions"("key");



ALTER TABLE ONLY "public"."company_events"
    ADD CONSTRAINT "company_events_company_account_id_fkey" FOREIGN KEY ("company_account_id") REFERENCES "public"."company_accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."company_events"
    ADD CONSTRAINT "company_events_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."company_events"
    ADD CONSTRAINT "company_events_package_product_code_fkey" FOREIGN KEY ("package_product_code") REFERENCES "public"."billing_products"("code");



ALTER TABLE ONLY "public"."company_locations"
    ADD CONSTRAINT "company_locations_company_account_id_fkey" FOREIGN KEY ("company_account_id") REFERENCES "public"."company_accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."company_locations"
    ADD CONSTRAINT "company_locations_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."company_onboarding_invites"
    ADD CONSTRAINT "company_onboarding_invites_company_account_id_fkey" FOREIGN KEY ("company_account_id") REFERENCES "public"."company_accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."company_requests"
    ADD CONSTRAINT "company_requests_company_account_id_fkey" FOREIGN KEY ("company_account_id") REFERENCES "public"."company_accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."company_requests"
    ADD CONSTRAINT "company_requests_related_event_id_fkey" FOREIGN KEY ("related_event_id") REFERENCES "public"."events"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."company_requests"
    ADD CONSTRAINT "company_requests_related_location_id_fkey" FOREIGN KEY ("related_location_id") REFERENCES "public"."company_locations"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."company_requests"
    ADD CONSTRAINT "company_requests_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "public"."company_users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."company_setup_requests"
    ADD CONSTRAINT "company_setup_requests_created_company_id_fkey" FOREIGN KEY ("created_company_id") REFERENCES "public"."company_accounts"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."company_users"
    ADD CONSTRAINT "company_users_company_account_id_fkey" FOREIGN KEY ("company_account_id") REFERENCES "public"."company_accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."company_users"
    ADD CONSTRAINT "company_users_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."dish_likes"
    ADD CONSTRAINT "dish_likes_dish_id_fkey" FOREIGN KEY ("dish_id") REFERENCES "public"."recommended_dishes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dish_likes"
    ADD CONSTRAINT "dish_likes_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."dish_likes"
    ADD CONSTRAINT "dish_likes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_analytics_events"
    ADD CONSTRAINT "event_analytics_events_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_interests"
    ADD CONSTRAINT "event_interests_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_interests"
    ADD CONSTRAINT "event_interests_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_map_invites"
    ADD CONSTRAINT "event_map_invites_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_map_points"
    ADD CONSTRAINT "event_map_points_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_map_points"
    ADD CONSTRAINT "event_map_points_event_vendor_id_fkey" FOREIGN KEY ("event_vendor_id") REFERENCES "public"."event_vendors"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_notification_deliveries"
    ADD CONSTRAINT "event_notification_deliveries_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_notification_deliveries"
    ADD CONSTRAINT "event_notification_deliveries_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_partner_submission_assets"
    ADD CONSTRAINT "event_partner_submission_assets_submission_id_fkey" FOREIGN KEY ("submission_id") REFERENCES "public"."event_partner_submissions"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_partner_submissions"
    ADD CONSTRAINT "event_partner_submissions_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."event_push_notifications"
    ADD CONSTRAINT "event_push_notifications_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_schedule_days"
    ADD CONSTRAINT "event_schedule_days_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_schedule_items"
    ADD CONSTRAINT "event_schedule_items_day_id_fkey" FOREIGN KEY ("day_id") REFERENCES "public"."event_schedule_days"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_schedule_items"
    ADD CONSTRAINT "event_schedule_items_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_schedule_items"
    ADD CONSTRAINT "event_schedule_items_track_id_fkey" FOREIGN KEY ("track_id") REFERENCES "public"."event_schedule_tracks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_schedule_meta"
    ADD CONSTRAINT "event_schedule_meta_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_schedule_tracks"
    ADD CONSTRAINT "event_schedule_tracks_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_sponsor_activations"
    ADD CONSTRAINT "event_sponsor_activations_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_sponsor_activations"
    ADD CONSTRAINT "event_sponsor_activations_event_sponsor_id_fkey" FOREIGN KEY ("event_sponsor_id") REFERENCES "public"."event_sponsors"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_sponsor_activations"
    ADD CONSTRAINT "event_sponsor_activations_sponsor_id_fkey" FOREIGN KEY ("sponsor_id") REFERENCES "public"."sponsors"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_sponsors"
    ADD CONSTRAINT "event_sponsors_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_sponsors"
    ADD CONSTRAINT "event_sponsors_sponsor_id_fkey" FOREIGN KEY ("sponsor_id") REFERENCES "public"."sponsors"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_transport_routes"
    ADD CONSTRAINT "event_transport_routes_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_transport_stops"
    ADD CONSTRAINT "event_transport_stops_route_id_fkey" FOREIGN KEY ("route_id") REFERENCES "public"."event_transport_routes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_transport_times"
    ADD CONSTRAINT "event_transport_times_route_id_fkey" FOREIGN KEY ("route_id") REFERENCES "public"."event_transport_routes"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_transport_times"
    ADD CONSTRAINT "event_transport_times_stop_id_fkey" FOREIGN KEY ("stop_id") REFERENCES "public"."event_transport_stops"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_updates"
    ADD CONSTRAINT "event_updates_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_vendors"
    ADD CONSTRAINT "event_vendors_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_vendors"
    ADD CONSTRAINT "event_vendors_vendor_id_fkey" FOREIGN KEY ("vendor_id") REFERENCES "public"."vendors"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_band_id_fkey" FOREIGN KEY ("band_id") REFERENCES "public"."mas_bands"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_organizer_id_fkey" FOREIGN KEY ("organizer_id") REFERENCES "public"."organizers"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_parent_event_fk" FOREIGN KEY ("parent_event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_partner_id_fkey" FOREIGN KEY ("partner_id") REFERENCES "public"."partners"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."events"
    ADD CONSTRAINT "events_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."favorites"
    ADD CONSTRAINT "favorites_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id");



ALTER TABLE ONLY "public"."favourite_guides"
    ADD CONSTRAINT "favourite_guides_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."feedback"
    ADD CONSTRAINT "feedback_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."event_bands"
    ADD CONSTRAINT "fk_band" FOREIGN KEY ("band_id") REFERENCES "public"."bands"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."event_bands"
    ADD CONSTRAINT "fk_event" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."guide_spots"
    ADD CONSTRAINT "fk_guide_slug" FOREIGN KEY ("guide_slug") REFERENCES "public"."guides"("slug");



ALTER TABLE ONLY "public"."itinerary_places"
    ADD CONSTRAINT "fk_itinerary_id" FOREIGN KEY ("itinerary_id") REFERENCES "public"."itineraries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."guide_spots"
    ADD CONSTRAINT "fk_place_slug" FOREIGN KEY ("place_slug") REFERENCES "public"."places"("slug");



ALTER TABLE ONLY "public"."guide_route_steps"
    ADD CONSTRAINT "guide_route_steps_guide_slug_fkey" FOREIGN KEY ("guide_slug") REFERENCES "public"."guides"("slug");



ALTER TABLE ONLY "public"."guide_route_steps"
    ADD CONSTRAINT "guide_route_steps_place_slug_fkey" FOREIGN KEY ("place_slug") REFERENCES "public"."places"("slug");



ALTER TABLE ONLY "public"."hotel_availability"
    ADD CONSTRAINT "hotel_availability_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hotel_availability"
    ADD CONSTRAINT "hotel_availability_room_type_id_fkey" FOREIGN KEY ("room_type_id") REFERENCES "public"."hotel_room_types"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hotel_inventory_holds"
    ADD CONSTRAINT "hotel_inventory_holds_booking_id_fkey" FOREIGN KEY ("booking_id") REFERENCES "public"."bookings"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."hotel_inventory_holds"
    ADD CONSTRAINT "hotel_inventory_holds_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hotel_inventory_holds"
    ADD CONSTRAINT "hotel_inventory_holds_room_type_id_fkey" FOREIGN KEY ("room_type_id") REFERENCES "public"."hotel_room_types"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hotel_rate_plans"
    ADD CONSTRAINT "hotel_rate_plans_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hotel_rate_plans"
    ADD CONSTRAINT "hotel_rate_plans_room_type_id_fkey" FOREIGN KEY ("room_type_id") REFERENCES "public"."hotel_room_types"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."hotel_room_types"
    ADD CONSTRAINT "hotel_room_types_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."insider_status_settings"
    ADD CONSTRAINT "insider_status_settings_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."invoice_line_items"
    ADD CONSTRAINT "invoice_line_items_invoice_id_fkey" FOREIGN KEY ("invoice_id") REFERENCES "public"."invoices"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."invoice_line_items"
    ADD CONSTRAINT "invoice_line_items_product_code_fkey" FOREIGN KEY ("product_code") REFERENCES "public"."billing_products"("code");



ALTER TABLE ONLY "public"."invoices"
    ADD CONSTRAINT "invoices_company_account_id_fkey" FOREIGN KEY ("company_account_id") REFERENCES "public"."company_accounts"("id") ON DELETE RESTRICT;



ALTER TABLE ONLY "public"."itinerary_events"
    ADD CONSTRAINT "itinerary_events_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."itinerary_events"
    ADD CONSTRAINT "itinerary_events_itinerary_id_fkey" FOREIGN KEY ("itinerary_id") REFERENCES "public"."itineraries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."itinerary_places"
    ADD CONSTRAINT "itinerary_places_itinerary_id_fkey" FOREIGN KEY ("itinerary_id") REFERENCES "public"."itineraries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."itinerary_places"
    ADD CONSTRAINT "itinerary_places_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id");



ALTER TABLE ONLY "public"."itinerary_shares"
    ADD CONSTRAINT "itinerary_shares_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."itinerary_shares"
    ADD CONSTRAINT "itinerary_shares_itinerary_id_fkey" FOREIGN KEY ("itinerary_id") REFERENCES "public"."itineraries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."loyalty_program_locations"
    ADD CONSTRAINT "loyalty_program_locations_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."loyalty_program_locations"
    ADD CONSTRAINT "loyalty_program_locations_program_id_fkey" FOREIGN KEY ("program_id") REFERENCES "public"."loyalty_programs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."loyalty_programs"
    ADD CONSTRAINT "loyalty_programs_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."loyalty_redemptions"
    ADD CONSTRAINT "loyalty_redemptions_card_id_fkey" FOREIGN KEY ("card_id") REFERENCES "public"."user_loyalty_cards"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."loyalty_redemptions"
    ADD CONSTRAINT "loyalty_redemptions_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."loyalty_redemptions"
    ADD CONSTRAINT "loyalty_redemptions_program_id_fkey" FOREIGN KEY ("program_id") REFERENCES "public"."loyalty_programs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."loyalty_visits"
    ADD CONSTRAINT "loyalty_visits_card_id_fkey" FOREIGN KEY ("card_id") REFERENCES "public"."user_loyalty_cards"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."loyalty_visits"
    ADD CONSTRAINT "loyalty_visits_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id");



ALTER TABLE ONLY "public"."loyalty_visits"
    ADD CONSTRAINT "loyalty_visits_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."mas_bands"
    ADD CONSTRAINT "mas_bands_band_launch_event_id_fkey" FOREIGN KEY ("band_launch_event_id") REFERENCES "public"."events"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."mas_bands"
    ADD CONSTRAINT "mas_bands_season_id_fkey" FOREIGN KEY ("season_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."member_perks"
    ADD CONSTRAINT "member_perks_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."menu_items"
    ADD CONSTRAINT "menu_items_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."menu_items"
    ADD CONSTRAINT "menu_items_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."nfc_tags"
    ADD CONSTRAINT "nfc_tags_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."nfc_tags"
    ADD CONSTRAINT "nfc_tags_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."notification_log"
    ADD CONSTRAINT "notification_log_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."partner_messages"
    ADD CONSTRAINT "partner_messages_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."partner_messages"
    ADD CONSTRAINT "partner_messages_partner_id_fkey" FOREIGN KEY ("partner_id") REFERENCES "public"."partners"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."partner_messages"
    ADD CONSTRAINT "partner_messages_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."partner_perks"
    ADD CONSTRAINT "partner_perks_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."passport_entries"
    ADD CONSTRAINT "passport_entries_loyalty_program_id_fkey" FOREIGN KEY ("loyalty_program_id") REFERENCES "public"."loyalty_programs"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."passport_entries"
    ADD CONSTRAINT "passport_entries_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."passport_entries"
    ADD CONSTRAINT "passport_entries_user_loyalty_card_id_fkey" FOREIGN KEY ("user_loyalty_card_id") REFERENCES "public"."user_loyalty_cards"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."payment_confirmations"
    ADD CONSTRAINT "payment_confirmations_company_account_id_fkey" FOREIGN KEY ("company_account_id") REFERENCES "public"."company_accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payment_confirmations"
    ADD CONSTRAINT "payment_confirmations_invoice_id_fkey" FOREIGN KEY ("invoice_id") REFERENCES "public"."invoices"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."payment_confirmations"
    ADD CONSTRAINT "payment_confirmations_submitted_by_fkey" FOREIGN KEY ("submitted_by") REFERENCES "public"."company_users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."performer_group_members"
    ADD CONSTRAINT "performer_group_members_group_performer_id_fkey" FOREIGN KEY ("group_performer_id") REFERENCES "public"."performers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."performer_group_members"
    ADD CONSTRAINT "performer_group_members_member_performer_id_fkey" FOREIGN KEY ("member_performer_id") REFERENCES "public"."performers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."performer_schedule"
    ADD CONSTRAINT "performer_schedule_performer_id_fkey" FOREIGN KEY ("performer_id") REFERENCES "public"."performers"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."performer_schedule"
    ADD CONSTRAINT "performer_schedule_schedule_item_id_fkey" FOREIGN KEY ("schedule_item_id") REFERENCES "public"."event_schedule_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."performers"
    ADD CONSTRAINT "performers_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."performers"
    ADD CONSTRAINT "performers_event_slug_fkey" FOREIGN KEY ("event_slug") REFERENCES "public"."events"("slug") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."performers"
    ADD CONSTRAINT "performers_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."perk_redemptions"
    ADD CONSTRAINT "perk_redemptions_booking_id_fkey" FOREIGN KEY ("booking_id") REFERENCES "public"."bookings"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."perk_redemptions"
    ADD CONSTRAINT "perk_redemptions_checkin_id_fkey" FOREIGN KEY ("checkin_id") REFERENCES "public"."user_checkins"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."perk_redemptions"
    ADD CONSTRAINT "perk_redemptions_perk_id_fkey" FOREIGN KEY ("perk_id") REFERENCES "public"."partner_perks"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."perk_redemptions"
    ADD CONSTRAINT "perk_redemptions_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."perk_redemptions"
    ADD CONSTRAINT "perk_redemptions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."place_checkin_settings"
    ADD CONSTRAINT "place_checkin_settings_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."place_special_hours"
    ADD CONSTRAINT "place_special_hours_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."place_specials"
    ADD CONSTRAINT "place_specials_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."place_visit_events"
    ADD CONSTRAINT "place_visit_events_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."place_visit_events"
    ADD CONSTRAINT "place_visit_events_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."places"
    ADD CONSTRAINT "places_parent_place_id_fkey" FOREIGN KEY ("parent_place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."places"
    ADD CONSTRAINT "places_partner_id_fkey" FOREIGN KEY ("partner_id") REFERENCES "public"."partners"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."push_tokens"
    ADD CONSTRAINT "push_tokens_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."ranking_events"
    ADD CONSTRAINT "ranking_events_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."recommended_dishes"
    ADD CONSTRAINT "recommended_dishes_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id");



ALTER TABLE ONLY "public"."redemption_events"
    ADD CONSTRAINT "redemption_events_card_id_fkey" FOREIGN KEY ("card_id") REFERENCES "public"."user_loyalty_cards"("id");



ALTER TABLE ONLY "public"."redemption_events"
    ADD CONSTRAINT "redemption_events_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."saved_events"
    ADD CONSTRAINT "saved_events_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."saved_events"
    ADD CONSTRAINT "saved_events_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."saved_experiences"
    ADD CONSTRAINT "saved_experiences_experience_id_fkey" FOREIGN KEY ("experience_id") REFERENCES "public"."specials"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."saved_experiences"
    ADD CONSTRAINT "saved_experiences_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."schedule_change_log"
    ADD CONSTRAINT "schedule_change_log_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."schedule_change_log"
    ADD CONSTRAINT "schedule_change_log_schedule_item_id_fkey" FOREIGN KEY ("schedule_item_id") REFERENCES "public"."event_schedule_items"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."special_interactions"
    ADD CONSTRAINT "special_interactions_special_id_fkey" FOREIGN KEY ("special_id") REFERENCES "public"."specials"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."special_interactions"
    ADD CONSTRAINT "special_interactions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."special_visits"
    ADD CONSTRAINT "special_visits_special_id_fkey" FOREIGN KEY ("special_id") REFERENCES "public"."specials"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."special_visits"
    ADD CONSTRAINT "special_visits_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."specials"
    ADD CONSTRAINT "specials_billing_account_id_fkey" FOREIGN KEY ("billing_account_id") REFERENCES "public"."billing_accounts"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."specials"
    ADD CONSTRAINT "specials_billing_usage_id_fkey" FOREIGN KEY ("billing_usage_id") REFERENCES "public"."billing_usage"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."specials"
    ADD CONSTRAINT "specials_event_slug_fkey" FOREIGN KEY ("event_slug") REFERENCES "public"."events"("slug");



ALTER TABLE ONLY "public"."specials"
    ADD CONSTRAINT "specials_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."subscriptions"
    ADD CONSTRAINT "subscriptions_company_account_id_fkey" FOREIGN KEY ("company_account_id") REFERENCES "public"."company_accounts"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."subscriptions"
    ADD CONSTRAINT "subscriptions_plan_key_fkey" FOREIGN KEY ("plan_key") REFERENCES "public"."subscription_plans"("key");



ALTER TABLE ONLY "public"."suggested_places"
    ADD CONSTRAINT "suggested_places_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "public"."user"("id");



ALTER TABLE ONLY "public"."ticket_locations"
    ADD CONSTRAINT "ticket_locations_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_activity"
    ADD CONSTRAINT "trip_activity_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."itineraries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_activity"
    ADD CONSTRAINT "trip_activity_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."trip_change_requests"
    ADD CONSTRAINT "trip_change_requests_proposed_by_fkey" FOREIGN KEY ("proposed_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."trip_change_requests"
    ADD CONSTRAINT "trip_change_requests_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."itineraries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_change_votes"
    ADD CONSTRAINT "trip_change_votes_request_id_fkey" FOREIGN KEY ("request_id") REFERENCES "public"."trip_change_requests"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_change_votes"
    ADD CONSTRAINT "trip_change_votes_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_collaborators"
    ADD CONSTRAINT "trip_collaborators_invited_by_fkey" FOREIGN KEY ("invited_by") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_collaborators"
    ADD CONSTRAINT "trip_collaborators_invitee_id_fkey" FOREIGN KEY ("invitee_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_collaborators"
    ADD CONSTRAINT "trip_collaborators_trip_id_fkey" FOREIGN KEY ("trip_id") REFERENCES "public"."itineraries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_completions"
    ADD CONSTRAINT "trip_completions_itinerary_id_fkey" FOREIGN KEY ("itinerary_id") REFERENCES "public"."itineraries"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."trip_completions"
    ADD CONSTRAINT "trip_completions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_achievements"
    ADD CONSTRAINT "user_achievements_achievement_id_fkey" FOREIGN KEY ("achievement_id") REFERENCES "public"."achievements"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_achievements"
    ADD CONSTRAINT "user_achievements_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_checkins"
    ADD CONSTRAINT "user_checkins_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."user_checkins"
    ADD CONSTRAINT "user_checkins_nfc_tag_id_fkey" FOREIGN KEY ("nfc_tag_id") REFERENCES "public"."nfc_tags"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."user_checkins"
    ADD CONSTRAINT "user_checkins_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."user_checkins"
    ADD CONSTRAINT "user_checkins_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_event_activity"
    ADD CONSTRAINT "user_event_activity_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_event_activity"
    ADD CONSTRAINT "user_event_activity_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_event_interactions"
    ADD CONSTRAINT "user_event_interactions_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_event_interactions"
    ADD CONSTRAINT "user_event_interactions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_favorite_items"
    ADD CONSTRAINT "user_favorite_items_menu_item_id_fkey" FOREIGN KEY ("menu_item_id") REFERENCES "public"."menu_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_favorite_items"
    ADD CONSTRAINT "user_favorite_items_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_item_logs"
    ADD CONSTRAINT "user_item_logs_menu_item_id_fkey" FOREIGN KEY ("menu_item_id") REFERENCES "public"."menu_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_item_logs"
    ADD CONSTRAINT "user_item_logs_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_item_logs"
    ADD CONSTRAINT "user_item_logs_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_loyalty_cards"
    ADD CONSTRAINT "user_loyalty_cards_program_id_fkey" FOREIGN KEY ("program_id") REFERENCES "public"."loyalty_programs"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_loyalty_cards"
    ADD CONSTRAINT "user_loyalty_cards_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_month_rankings"
    ADD CONSTRAINT "user_month_rankings_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_place_rankings"
    ADD CONSTRAINT "user_place_rankings_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_place_rankings"
    ADD CONSTRAINT "user_place_rankings_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_saved_menu_items"
    ADD CONSTRAINT "user_saved_menu_items_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_saved_schedule_items"
    ADD CONSTRAINT "user_saved_schedule_items_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_saved_schedule_items"
    ADD CONSTRAINT "user_saved_schedule_items_schedule_item_id_fkey" FOREIGN KEY ("schedule_item_id") REFERENCES "public"."event_schedule_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_saved_schedule_items"
    ADD CONSTRAINT "user_saved_schedule_items_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_schedule_plans"
    ADD CONSTRAINT "user_schedule_plans_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."events"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_schedule_plans"
    ADD CONSTRAINT "user_schedule_plans_schedule_item_id_fkey" FOREIGN KEY ("schedule_item_id") REFERENCES "public"."event_schedule_items"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_schedule_plans"
    ADD CONSTRAINT "user_schedule_plans_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_stats"
    ADD CONSTRAINT "user_stats_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."user_tour_progress"
    ADD CONSTRAINT "user_tour_progress_guide_slug_fkey" FOREIGN KEY ("guide_slug") REFERENCES "public"."guides"("slug");



ALTER TABLE ONLY "public"."user_tour_progress"
    ADD CONSTRAINT "user_tour_progress_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id");



ALTER TABLE ONLY "public"."user_vendor_item_ratings"
    ADD CONSTRAINT "user_vendor_item_ratings_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."vendor_menu_items"
    ADD CONSTRAINT "vendor_menu_items_event_vendor_id_fkey" FOREIGN KEY ("event_vendor_id") REFERENCES "public"."event_vendors"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."vendors"
    ADD CONSTRAINT "vendors_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE SET NULL;



ALTER TABLE ONLY "public"."vibe_tags"
    ADD CONSTRAINT "vibe_tags_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."visit_log"
    ADD CONSTRAINT "visit_log_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."visit_log"
    ADD CONSTRAINT "visit_log_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."visited_feedback"
    ADD CONSTRAINT "visited_feedback_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."visited_feedback"
    ADD CONSTRAINT "visited_feedback_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



ALTER TABLE ONLY "public"."visited"
    ADD CONSTRAINT "visited_place_id_fkey" FOREIGN KEY ("place_id") REFERENCES "public"."places"("id");



ALTER TABLE ONLY "public"."xp_transactions"
    ADD CONSTRAINT "xp_transactions_user_id_fkey" FOREIGN KEY ("user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;



CREATE POLICY "A user can manage their own visits" ON "public"."visit_log" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Admins can update all feedback" ON "public"."feedback" FOR UPDATE TO "service_role" USING (true);



CREATE POLICY "Allow authenticated inserts" ON "public"."suggested_places" FOR INSERT WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Allow public read of itinerary_shares" ON "public"."itinerary_shares" FOR SELECT USING (true);



CREATE POLICY "Allow public read of shared itineraries only" ON "public"."itineraries" FOR SELECT USING (("id" IN ( SELECT "itinerary_shares"."itinerary_id"
   FROM "public"."itinerary_shares")));



CREATE POLICY "Allow read access to all users" ON "public"."guides" FOR SELECT USING (true);



CREATE POLICY "Allow read access to all users" ON "public"."places" FOR SELECT USING (true);



CREATE POLICY "Allow read access to all users" ON "public"."recommended_dishes" FOR SELECT USING (true);



CREATE POLICY "Allow users to manage their own profiles" ON "public"."user" TO "authenticated" USING (("id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Allow users to update their own itinerary places" ON "public"."itinerary_places" FOR UPDATE USING ((EXISTS ( SELECT 1
   FROM "public"."itineraries"
  WHERE (("itineraries"."id" = "itinerary_places"."itinerary_id") AND ("itineraries"."user_id" = ( SELECT "auth"."uid"() AS "uid")))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."itineraries"
  WHERE (("itineraries"."id" = "itinerary_places"."itinerary_id") AND ("itineraries"."user_id" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "Anyone can read event interests" ON "public"."event_interests" FOR SELECT USING (true);



CREATE POLICY "Anyone can view active loyalty programs" ON "public"."loyalty_programs" FOR SELECT USING (("is_active" = true));



CREATE POLICY "Authenticated can manage activations" ON "public"."event_sponsor_activations" TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Authenticated users can create" ON "public"."events" FOR INSERT TO "authenticated" WITH CHECK (true);



CREATE POLICY "Authenticated users can insert feedback" ON "public"."feedback" FOR INSERT TO "authenticated" WITH CHECK (((( SELECT "auth"."uid"() AS "uid") = "user_id") OR ("user_id" IS NULL)));



CREATE POLICY "Authenticated users can manage event sponsors" ON "public"."event_sponsors" USING (("auth"."role"() = 'authenticated'::"text")) WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated users can manage sponsors" ON "public"."sponsors" USING (("auth"."role"() = 'authenticated'::"text")) WITH CHECK (("auth"."role"() = 'authenticated'::"text"));



CREATE POLICY "Authenticated users can read assets" ON "public"."event_partner_submission_assets" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can read submissions" ON "public"."event_partner_submissions" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "Authenticated users can update submissions" ON "public"."event_partner_submissions" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



CREATE POLICY "Block all this table" ON "public"."organizers" USING (false);



CREATE POLICY "Business can view own profile" ON "public"."businesses" FOR SELECT USING (("id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Delete own month rankings" ON "public"."user_month_rankings" FOR DELETE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Insert own month rankings" ON "public"."user_month_rankings" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Invitee reads own invites" ON "public"."trip_collaborators" FOR SELECT USING (("invitee_id" = "auth"."uid"()));



CREATE POLICY "Invitee updates own invites" ON "public"."trip_collaborators" FOR UPDATE USING (("invitee_id" = "auth"."uid"())) WITH CHECK (("invitee_id" = "auth"."uid"()));



CREATE POLICY "No client deletes" ON "public"."app_config" FOR DELETE USING (false);



CREATE POLICY "No client inserts" ON "public"."app_config" FOR INSERT WITH CHECK (false);



CREATE POLICY "No client updates" ON "public"."app_config" FOR UPDATE USING (false);



CREATE POLICY "Owner can insert visited" ON "public"."visited" FOR INSERT WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Owner can update visited" ON "public"."visited" FOR UPDATE USING (("user_id" = "auth"."uid"())) WITH CHECK (("user_id" = "auth"."uid"()));



CREATE POLICY "Public can create submissions" ON "public"."event_partner_submissions" FOR INSERT TO "authenticated", "anon" WITH CHECK (true);



CREATE POLICY "Public can insert assets metadata" ON "public"."event_partner_submission_assets" FOR INSERT TO "authenticated", "anon" WITH CHECK (true);



CREATE POLICY "Public can read activations" ON "public"."event_sponsor_activations" FOR SELECT TO "authenticated", "anon" USING (("is_active" = true));



CREATE POLICY "Public can read feedback" ON "public"."feedback" FOR SELECT USING (true);



CREATE POLICY "Public can read own submission by token" ON "public"."event_partner_submissions" FOR SELECT TO "anon" USING (true);



CREATE POLICY "Public can update assets metadata" ON "public"."event_partner_submission_assets" FOR UPDATE TO "authenticated", "anon" USING (true) WITH CHECK (true);



CREATE POLICY "Public can update submissions by token" ON "public"."event_partner_submissions" FOR UPDATE TO "anon" USING (true) WITH CHECK (true);



CREATE POLICY "Public can view active NFC tags" ON "public"."nfc_tags" FOR SELECT USING (("active" = true));



CREATE POLICY "Public can view active event sponsors" ON "public"."event_sponsors" FOR SELECT USING (("is_active" = true));



CREATE POLICY "Public can view active specials" ON "public"."specials" FOR SELECT USING (("active" = true));



CREATE POLICY "Public can view active sponsors" ON "public"."sponsors" FOR SELECT USING (("is_active" = true));



CREATE POLICY "Public events are viewable" ON "public"."events" FOR SELECT USING ((("status" = 'published'::"text") AND ("deleted_at" IS NULL)));



CREATE POLICY "Public read alerts" ON "public"."alerts" FOR SELECT USING (true);



CREATE POLICY "Public read days" ON "public"."event_schedule_days" FOR SELECT USING (true);



CREATE POLICY "Public read items" ON "public"."event_schedule_items" FOR SELECT USING (("is_published" = true));



CREATE POLICY "Public read of app config" ON "public"."app_config" FOR SELECT USING (true);



CREATE POLICY "Public read routes" ON "public"."event_transport_routes" FOR SELECT USING (true);



CREATE POLICY "Public read stops" ON "public"."event_transport_stops" FOR SELECT USING (true);



CREATE POLICY "Public read times" ON "public"."event_transport_times" FOR SELECT USING (true);



CREATE POLICY "Public read tracks" ON "public"."event_schedule_tracks" FOR SELECT USING (("is_active" = true));



CREATE POLICY "Select own month rankings" ON "public"."user_month_rankings" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Service can manage alerts" ON "public"."alerts" TO "service_role" USING (true) WITH CHECK (true);



CREATE POLICY "Service role full access" ON "public"."push_tokens" TO "service_role" USING (true);



CREATE POLICY "Trip owner manages collaborators" ON "public"."trip_collaborators" USING ((EXISTS ( SELECT 1
   FROM "public"."itineraries" "i"
  WHERE (("i"."id" = "trip_collaborators"."trip_id") AND ("i"."user_id" = "auth"."uid"()))))) WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."itineraries" "i"
  WHERE (("i"."id" = "trip_collaborators"."trip_id") AND ("i"."user_id" = "auth"."uid"())))));



CREATE POLICY "Update own month rankings" ON "public"."user_month_rankings" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "User can read and write their own data" ON "public"."visited" TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "User can read and write their own favorites" ON "public"."favorites" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can add their own favourite guides" ON "public"."favourite_guides" FOR INSERT WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can create own interactions" ON "public"."user_event_interactions" FOR INSERT TO "authenticated" WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can delete own events" ON "public"."events" FOR DELETE TO "authenticated" USING (("created_by" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can delete own interactions" ON "public"."special_interactions" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can delete own interactions" ON "public"."user_event_interactions" FOR DELETE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can delete their own activity" ON "public"."user_event_activity" FOR DELETE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can delete their own feedback" ON "public"."feedback" FOR DELETE TO "authenticated" USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can delete their own itinerary places" ON "public"."itinerary_places" FOR DELETE USING ((EXISTS ( SELECT 1
   FROM "public"."itineraries"
  WHERE (("itineraries"."id" = "itinerary_places"."itinerary_id") AND ("itineraries"."user_id" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "Users can delete their own plans" ON "public"."user_schedule_plans" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can delete their own schedule plans" ON "public"."user_schedule_plans" FOR DELETE TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can delete their own sentiment feedback" ON "public"."visited_feedback" FOR DELETE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can delete their saved experiences" ON "public"."saved_experiences" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert into their own iti" ON "public"."itinerary_places" FOR INSERT WITH CHECK ((EXISTS ( SELECT 1
   FROM "public"."itineraries"
  WHERE (("itineraries"."id" = "itinerary_places"."itinerary_id") AND ("itineraries"."user_id" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "Users can insert own interactions" ON "public"."special_interactions" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own activity" ON "public"."user_event_activity" FOR INSERT WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can insert their own plans" ON "public"."user_schedule_plans" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own schedule plans" ON "public"."user_schedule_plans" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can insert their own sentiment feedback" ON "public"."visited_feedback" FOR INSERT WITH CHECK (((( SELECT "auth"."uid"() AS "uid") = "user_id") OR ("user_id" IS NULL)));



CREATE POLICY "Users can like" ON "public"."dish_likes" FOR INSERT TO "authenticated" WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can manage own saved events" ON "public"."saved_events" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can manage own tokens" ON "public"."push_tokens" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can manage their own interests" ON "public"."event_interests" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can manage their own itineraries" ON "public"."itineraries" USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can read own interactions" ON "public"."special_interactions" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can read their likes" ON "public"."dish_likes" FOR SELECT USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can remove their like" ON "public"."dish_likes" FOR DELETE USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can remove their own favourite guides" ON "public"."favourite_guides" FOR DELETE USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can save experiences" ON "public"."saved_experiences" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update own events" ON "public"."events" FOR UPDATE TO "authenticated" USING (("created_by" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("created_by" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can update own interactions" ON "public"."special_interactions" FOR UPDATE USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update own interactions" ON "public"."user_event_interactions" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can update their own activity" ON "public"."user_event_activity" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can update their own loyalty cards" ON "public"."user_loyalty_cards" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can update their own sentiment feedback" ON "public"."visited_feedback" FOR UPDATE USING ((( SELECT "auth"."uid"() AS "uid") = "user_id")) WITH CHECK ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can update their saved experiences" ON "public"."saved_experiences" FOR UPDATE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view all sentiment feedback" ON "public"."visited_feedback" FOR SELECT USING (true);



CREATE POLICY "Users can view own check-ins" ON "public"."user_checkins" FOR SELECT TO "authenticated" USING (("user_id" = "auth"."uid"()));



CREATE POLICY "Users can view own checkins" ON "public"."user_checkins" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view own interactions" ON "public"."user_event_interactions" FOR SELECT TO "authenticated" USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can view own notifications" ON "public"."notification_log" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own XP transactions" ON "public"."xp_transactions" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own activity" ON "public"."user_event_activity" FOR SELECT USING ((( SELECT "auth"."uid"() AS "uid") = "user_id"));



CREATE POLICY "Users can view their own favourite guides" ON "public"."favourite_guides" FOR SELECT USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "Users can view their own itinerary places" ON "public"."itinerary_places" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."itineraries"
  WHERE (("itineraries"."id" = "itinerary_places"."itinerary_id") AND ("itineraries"."user_id" = ( SELECT "auth"."uid"() AS "uid"))))));



CREATE POLICY "Users can view their own loyalty cards" ON "public"."user_loyalty_cards" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own loyalty visits" ON "public"."loyalty_visits" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own plans" ON "public"."user_schedule_plans" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own redemptions" ON "public"."redemption_events" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their own schedule plans" ON "public"."user_schedule_plans" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users can view their saved experiences" ON "public"."saved_experiences" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users delete own saves" ON "public"."user_saved_schedule_items" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users manage own item ratings" ON "public"."user_vendor_item_ratings" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "Users manage own visits" ON "public"."special_visits" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users read own saves" ON "public"."user_saved_schedule_items" FOR SELECT USING (("auth"."uid"() = "user_id"));



CREATE POLICY "Users save items" ON "public"."user_saved_schedule_items" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "XP rules are readable" ON "public"."xp_rules" FOR SELECT TO "authenticated" USING (true);



CREATE POLICY "ach_read" ON "public"."achievements" FOR SELECT USING (true);



ALTER TABLE "public"."achievements" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "active event sponsors are publicly readable" ON "public"."event_sponsors" FOR SELECT TO "authenticated", "anon" USING ((COALESCE("is_active", true) = true));



CREATE POLICY "active sponsors are publicly readable" ON "public"."sponsors" FOR SELECT TO "authenticated", "anon" USING ((COALESCE("is_active", true) = true));



ALTER TABLE "public"."admin_tokens" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."alerts" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "allow authenticated upvotes" ON "public"."feedback" FOR UPDATE TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."analytics_events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "analytics_events_insert" ON "public"."analytics_events" FOR INSERT TO "authenticated", "anon" WITH CHECK ((("user_id" IS NULL) OR ("user_id" = "auth"."uid"())));



ALTER TABLE "public"."app_config" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."app_settings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "authenticated manage place specials" ON "public"."place_specials" TO "authenticated" USING (true) WITH CHECK (true);



ALTER TABLE "public"."bands" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."billing_accounts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."billing_audit_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."billing_notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."billing_products" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."billing_settings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."billing_usage" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."booking_cancellation_policies" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."booking_notification_logs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."booking_room_allocations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."booking_timeline_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."bookings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."businesses" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."company_accounts" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."company_entitlements" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."company_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."company_locations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."company_onboarding_invites" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."company_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."company_setup_requests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."company_users" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "delete own visits" ON "public"."place_visit_events" FOR DELETE USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."dish_likes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."entitlement_definitions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_analytics_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_bands" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_interests" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_map_invites" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_notification_deliveries" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_partner_submission_assets" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_partner_submissions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_push_notifications" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_schedule_days" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_schedule_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_schedule_tracks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_sponsor_activations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_sponsors" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_transport_routes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_transport_stops" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."event_transport_times" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."favorites" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."favourite_guides" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."feedback" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."guide_spots" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."guides" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hotel_availability" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hotel_inventory_holds" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hotel_rate_plans" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."hotel_room_types" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "insert own visits" ON "public"."place_visit_events" FOR INSERT WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."insider_status_settings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "insider_status_settings_read_all" ON "public"."insider_status_settings" FOR SELECT USING (true);



ALTER TABLE "public"."invoice_counters" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."invoice_line_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."invoices" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."itineraries" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "itineraries_select_collaborators" ON "public"."itineraries" FOR SELECT USING ("public"."is_trip_collaborator"("id"));



ALTER TABLE "public"."itinerary_events" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "itinerary_events_delete" ON "public"."itinerary_events" FOR DELETE USING (((EXISTS ( SELECT 1
   FROM "public"."itineraries" "i"
  WHERE (("i"."id" = "itinerary_events"."itinerary_id") AND ("i"."user_id" = "auth"."uid"())))) OR (EXISTS ( SELECT 1
   FROM "public"."trip_collaborators" "tc"
  WHERE (("tc"."trip_id" = "itinerary_events"."itinerary_id") AND ("tc"."invitee_id" = "auth"."uid"()) AND ("tc"."status" = 'accepted'::"text"))))));



CREATE POLICY "itinerary_events_insert" ON "public"."itinerary_events" FOR INSERT WITH CHECK (((EXISTS ( SELECT 1
   FROM "public"."itineraries" "i"
  WHERE (("i"."id" = "itinerary_events"."itinerary_id") AND ("i"."user_id" = "auth"."uid"())))) OR (EXISTS ( SELECT 1
   FROM "public"."trip_collaborators" "tc"
  WHERE (("tc"."trip_id" = "itinerary_events"."itinerary_id") AND ("tc"."invitee_id" = "auth"."uid"()) AND ("tc"."status" = 'accepted'::"text"))))));



CREATE POLICY "itinerary_events_select" ON "public"."itinerary_events" FOR SELECT USING (((EXISTS ( SELECT 1
   FROM "public"."itineraries" "i"
  WHERE (("i"."id" = "itinerary_events"."itinerary_id") AND ("i"."user_id" = "auth"."uid"())))) OR (EXISTS ( SELECT 1
   FROM "public"."trip_collaborators" "tc"
  WHERE (("tc"."trip_id" = "itinerary_events"."itinerary_id") AND ("tc"."invitee_id" = "auth"."uid"()) AND ("tc"."status" = 'accepted'::"text"))))));



CREATE POLICY "itinerary_events_update" ON "public"."itinerary_events" FOR UPDATE USING (((EXISTS ( SELECT 1
   FROM "public"."itineraries" "i"
  WHERE (("i"."id" = "itinerary_events"."itinerary_id") AND ("i"."user_id" = "auth"."uid"())))) OR (EXISTS ( SELECT 1
   FROM "public"."trip_collaborators" "tc"
  WHERE (("tc"."trip_id" = "itinerary_events"."itinerary_id") AND ("tc"."invitee_id" = "auth"."uid"()) AND ("tc"."status" = 'accepted'::"text"))))));



ALTER TABLE "public"."itinerary_places" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "itinerary_places_collaborators_all" ON "public"."itinerary_places" USING ("public"."is_trip_collaborator"("itinerary_id")) WITH CHECK ("public"."is_trip_collaborator"("itinerary_id"));



ALTER TABLE "public"."itinerary_shares" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."loyalty_program_locations" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "loyalty_program_locations_select_all" ON "public"."loyalty_program_locations" FOR SELECT USING (true);



ALTER TABLE "public"."loyalty_programs" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."loyalty_redemptions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."loyalty_visits" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."mas_bands" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "mas_bands_admin_write" ON "public"."mas_bands" USING (("auth"."role"() = 'service_role'::"text"));



CREATE POLICY "mas_bands_public_read" ON "public"."mas_bands" FOR SELECT USING (true);



ALTER TABLE "public"."member_perks" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."menu_items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "menu_items_insert_authed" ON "public"."menu_items" FOR INSERT WITH CHECK (("auth"."uid"() = "created_by"));



CREATE POLICY "menu_items_select_all" ON "public"."menu_items" FOR SELECT USING (true);



ALTER TABLE "public"."nfc_tags" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."notification_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."organizers" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "owner_can_read_write_share" ON "public"."itinerary_shares" TO "authenticated" USING (("created_by" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("created_by" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."partner_messages" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."partner_perks" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "partner_perks_read_active" ON "public"."partner_perks" FOR SELECT USING (("active" = true));



ALTER TABLE "public"."partners" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."passport_entries" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "passport_entries_select_own" ON "public"."passport_entries" FOR SELECT USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."payment_confirmations" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."payment_instructions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "performer_group_members_public_read" ON "public"."performer_group_members" FOR SELECT USING (true);



CREATE POLICY "performer_schedule_public_read" ON "public"."performer_schedule" FOR SELECT USING (true);



CREATE POLICY "performers_public_read" ON "public"."performers" FOR SELECT USING (true);



ALTER TABLE "public"."perk_redemptions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "perk_redemptions_select_own" ON "public"."perk_redemptions" FOR SELECT USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."place_checkin_settings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "place_checkin_settings_read_all" ON "public"."place_checkin_settings" FOR SELECT USING (true);



ALTER TABLE "public"."place_special_hours" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."place_specials" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."place_visit_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."places" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "public read guide_spots" ON "public"."guide_spots" FOR SELECT USING (true);



CREATE POLICY "public read performer_group_members" ON "public"."performer_group_members" FOR SELECT USING (true);



CREATE POLICY "public read place specials" ON "public"."place_specials" FOR SELECT USING (("is_active" = true));



ALTER TABLE "public"."push_tokens" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "read own visits" ON "public"."place_visit_events" FOR SELECT USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."recommended_dishes" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."redemption_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."saved_events" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."saved_experiences" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."special_interactions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "special_interactions_delete_own" ON "public"."special_interactions" FOR DELETE TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "special_interactions_insert_own" ON "public"."special_interactions" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "special_interactions_select" ON "public"."special_interactions" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "special_interactions_update_own" ON "public"."special_interactions" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."special_visits" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "special_visits_delete_own" ON "public"."special_visits" FOR DELETE TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "special_visits_insert_own" ON "public"."special_visits" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "special_visits_select" ON "public"."special_visits" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."specials" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."sponsors" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."subscription_plans" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."subscriptions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."suggested_places" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."trip_activity" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trip_activity_insert_own" ON "public"."trip_activity" FOR INSERT WITH CHECK (("public"."has_trip_access"("trip_id") AND (("user_id" IS NULL) OR ("user_id" = "auth"."uid"()))));



CREATE POLICY "trip_activity_select" ON "public"."trip_activity" FOR SELECT USING ("public"."has_trip_access"("trip_id"));



ALTER TABLE "public"."trip_change_requests" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trip_change_requests_select" ON "public"."trip_change_requests" FOR SELECT USING ("public"."has_trip_access"("trip_id"));



ALTER TABLE "public"."trip_change_votes" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "trip_change_votes_select" ON "public"."trip_change_votes" FOR SELECT USING ((EXISTS ( SELECT 1
   FROM "public"."trip_change_requests" "r"
  WHERE (("r"."id" = "trip_change_votes"."request_id") AND "public"."has_trip_access"("r"."trip_id")))));



ALTER TABLE "public"."trip_collaborators" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."trip_completions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "ua_insert" ON "public"."user_achievements" FOR INSERT WITH CHECK (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "ua_select" ON "public"."user_achievements" FOR SELECT USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "ua_update" ON "public"."user_achievements" FOR UPDATE USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



CREATE POLICY "us_select" ON "public"."user_stats" FOR SELECT USING (("user_id" = ( SELECT "auth"."uid"() AS "uid")));



ALTER TABLE "public"."user" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_achievements" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_checkins" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_checkins_select_own" ON "public"."user_checkins" FOR SELECT USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."user_event_activity" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_event_interactions" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_favorite_items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_favorite_items_delete_own" ON "public"."user_favorite_items" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "user_favorite_items_insert_own" ON "public"."user_favorite_items" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "user_favorite_items_select_own" ON "public"."user_favorite_items" FOR SELECT USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."user_item_logs" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_item_logs_delete_own" ON "public"."user_item_logs" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "user_item_logs_insert_own" ON "public"."user_item_logs" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "user_item_logs_select_own_or_public" ON "public"."user_item_logs" FOR SELECT USING ((("auth"."uid"() = "user_id") OR "is_public"));



CREATE POLICY "user_item_logs_update_own" ON "public"."user_item_logs" FOR UPDATE USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."user_loyalty_cards" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_month_rankings" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_saved_menu_items" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "user_saved_menu_items_delete_own" ON "public"."user_saved_menu_items" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "user_saved_menu_items_insert_own" ON "public"."user_saved_menu_items" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "user_saved_menu_items_select_own" ON "public"."user_saved_menu_items" FOR SELECT USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."user_saved_schedule_items" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_schedule_plans" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_stats" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."user_vendor_item_ratings" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "users insert own bookings" ON "public"."bookings" FOR INSERT TO "authenticated" WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "users read own bookings" ON "public"."bookings" FOR SELECT TO "authenticated" USING (("auth"."uid"() = "user_id"));



CREATE POLICY "users update own bookings" ON "public"."bookings" FOR UPDATE TO "authenticated" USING (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."vendors" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "vendors are publicly readable" ON "public"."vendors" FOR SELECT USING (true);



ALTER TABLE "public"."vibe_tags" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "vibe_tags_delete_own" ON "public"."vibe_tags" FOR DELETE USING (("auth"."uid"() = "user_id"));



CREATE POLICY "vibe_tags_insert_own" ON "public"."vibe_tags" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "vibe_tags_select_all" ON "public"."vibe_tags" FOR SELECT USING (true);



CREATE POLICY "vibe_tags_update_own" ON "public"."vibe_tags" FOR UPDATE USING (("auth"."uid"() = "user_id")) WITH CHECK (("auth"."uid"() = "user_id"));



ALTER TABLE "public"."visit_log" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."visited" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."visited_feedback" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."xp_rules" ENABLE ROW LEVEL SECURITY;


ALTER TABLE "public"."xp_transactions" ENABLE ROW LEVEL SECURITY;


CREATE POLICY "xp_transactions_insert_own" ON "public"."xp_transactions" FOR INSERT WITH CHECK (("auth"."uid"() = "user_id"));



CREATE POLICY "xp_transactions_select_own" ON "public"."xp_transactions" FOR SELECT USING (("auth"."uid"() = "user_id"));





ALTER PUBLICATION "supabase_realtime" OWNER TO "postgres";






ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."itinerary_events";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."itinerary_places";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."trip_activity";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."trip_change_requests";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."trip_change_votes";



ALTER PUBLICATION "supabase_realtime" ADD TABLE ONLY "public"."trip_collaborators";









REVOKE USAGE ON SCHEMA "public" FROM PUBLIC;
GRANT USAGE ON SCHEMA "public" TO "postgres";
GRANT USAGE ON SCHEMA "public" TO "anon";
GRANT USAGE ON SCHEMA "public" TO "authenticated";
GRANT USAGE ON SCHEMA "public" TO "service_role";









GRANT ALL ON FUNCTION "public"."citextin"("cstring") TO "postgres";
GRANT ALL ON FUNCTION "public"."citextin"("cstring") TO "anon";
GRANT ALL ON FUNCTION "public"."citextin"("cstring") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citextin"("cstring") TO "service_role";



GRANT ALL ON FUNCTION "public"."citextout"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citextout"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citextout"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citextout"("public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citextrecv"("internal") TO "postgres";
GRANT ALL ON FUNCTION "public"."citextrecv"("internal") TO "anon";
GRANT ALL ON FUNCTION "public"."citextrecv"("internal") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citextrecv"("internal") TO "service_role";



GRANT ALL ON FUNCTION "public"."citextsend"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citextsend"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citextsend"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citextsend"("public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext"(boolean) TO "postgres";
GRANT ALL ON FUNCTION "public"."citext"(boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."citext"(boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext"(boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."citext"(character) TO "postgres";
GRANT ALL ON FUNCTION "public"."citext"(character) TO "anon";
GRANT ALL ON FUNCTION "public"."citext"(character) TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext"(character) TO "service_role";



GRANT ALL ON FUNCTION "public"."citext"("inet") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext"("inet") TO "anon";
GRANT ALL ON FUNCTION "public"."citext"("inet") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext"("inet") TO "service_role";


































































































































































































































































REVOKE ALL ON FUNCTION "public"."_activate_paid_invoice"("p_invoice_id" "uuid", "p_actor_label" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_activate_paid_invoice"("p_invoice_id" "uuid", "p_actor_label" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_admin_label"("p_token" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_admin_label"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."_apply_change_request"("_request_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."_apply_change_request"("_request_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_apply_change_request"("_request_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_assert_invoice_transition"("p_from" "text", "p_to" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_assert_invoice_transition"("p_from" "text", "p_to" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_assert_request_transition"("p_from" "text", "p_to" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_assert_request_transition"("p_from" "text", "p_to" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_billing_audit"("p_actor_type" "text", "p_actor_label" "text", "p_company_id" "uuid", "p_action" "text", "p_details" "jsonb", "p_invoice_id" "uuid", "p_subscription" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_billing_audit"("p_actor_type" "text", "p_actor_label" "text", "p_company_id" "uuid", "p_action" "text", "p_details" "jsonb", "p_invoice_id" "uuid", "p_subscription" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_billing_notify"("p_type" "text", "p_company_id" "uuid", "p_subject" "text", "p_body" "text", "p_invoice_id" "uuid", "p_request_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_billing_notify"("p_type" "text", "p_company_id" "uuid", "p_subject" "text", "p_body" "text", "p_invoice_id" "uuid", "p_request_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_billing_setting"("p_key" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_billing_setting"("p_key" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_event_billing"("p_event_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_event_billing"("p_event_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_event_billing"("p_event_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."_format_hours_text"("p_hours" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."_format_hours_text"("p_hours" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_format_hours_text"("p_hours" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_grant_entitlement"("p_company_id" "uuid", "p_key" "text", "p_source" "text", "p_starts" "date", "p_expires" "date", "p_invoice_id" "uuid", "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_grant_entitlement"("p_company_id" "uuid", "p_key" "text", "p_source" "text", "p_starts" "date", "p_expires" "date", "p_invoice_id" "uuid", "p_notes" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_invoice_effective_status"("p_status" "text", "p_due" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_invoice_effective_status"("p_status" "text", "p_due" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."_is_admin"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."_is_admin"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_is_admin"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."_normalize_event_type"("p_raw" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."_normalize_event_type"("p_raw" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_normalize_event_type"("p_raw" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."_partner_event_id_from_token"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."_partner_event_id_from_token"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_partner_event_id_from_token"("p_token" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_partner_token_company_id"("p_token" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_partner_token_company_id"("p_token" "text") TO "service_role";



GRANT ALL ON TABLE "public"."company_users" TO "anon";
GRANT ALL ON TABLE "public"."company_users" TO "authenticated";
GRANT ALL ON TABLE "public"."company_users" TO "service_role";



REVOKE ALL ON FUNCTION "public"."_resolve_company_user"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_resolve_company_user"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."_save_invoice"("p_company_id" "uuid", "p_invoice" "jsonb", "p_actor_type" "text", "p_actor_label" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_save_invoice"("p_company_id" "uuid", "p_invoice" "jsonb", "p_actor_type" "text", "p_actor_label" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."_send_email"("p_template" "text", "p_params" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."_send_email"("p_template" "text", "p_params" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_send_email"("p_template" "text", "p_params" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_submit_company_onboarding"("p_company_user_id" "uuid", "p_info" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_submit_company_onboarding"("p_company_user_id" "uuid", "p_info" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_submit_company_setup_request"("p_user_id" "uuid", "p_email" "text", "p_info" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_submit_company_setup_request"("p_user_id" "uuid", "p_email" "text", "p_info" "jsonb") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_submit_payment_confirmation"("p_company_user_id" "uuid", "p_invoice_id" "uuid", "p_payment_method" "text", "p_paid_on" "date", "p_reference" "text", "p_receipt_path" "text", "p_notes" "text", "p_receipt_filename" "text", "p_receipt_size_bytes" bigint, "p_receipt_mime" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_submit_payment_confirmation"("p_company_user_id" "uuid", "p_invoice_id" "uuid", "p_payment_method" "text", "p_paid_on" "date", "p_reference" "text", "p_receipt_path" "text", "p_notes" "text", "p_receipt_filename" "text", "p_receipt_size_bytes" bigint, "p_receipt_mime" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."_taste_elo_expected"("p_self" integer, "p_opp" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."_taste_elo_expected"("p_self" integer, "p_opp" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."_taste_elo_expected"("p_self" integer, "p_opp" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."_taste_elo_k"("p_count" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."_taste_elo_k"("p_count" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."_taste_elo_k"("p_count" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."_taste_note_apply"("p_log_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."_taste_note_apply"("p_log_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_taste_note_apply"("p_log_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."_taste_note_elo_trigger"() TO "anon";
GRANT ALL ON FUNCTION "public"."_taste_note_elo_trigger"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."_taste_note_elo_trigger"() TO "service_role";



GRANT ALL ON FUNCTION "public"."_taste_sentiment_rank"("p_s" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."_taste_sentiment_rank"("p_s" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_taste_sentiment_rank"("p_s" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."_taste_sentiment_score"("p_s" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."_taste_sentiment_score"("p_s" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."_taste_sentiment_score"("p_s" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."_trg_confirmation_notify"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_trg_confirmation_notify"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."_trg_invoice_notify"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_trg_invoice_notify"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."_trg_request_notify"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_trg_request_notify"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."_trg_setup_request_notify"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_trg_setup_request_notify"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."_trg_subscription_notify"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."_trg_subscription_notify"() TO "service_role";



GRANT ALL ON FUNCTION "public"."accept_onboarding_invite"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."accept_onboarding_invite"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."accept_onboarding_invite"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."accept_trip_invite"("_token" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."accept_trip_invite"("_token" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."accept_trip_invite"("_token" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."add_user_points"("_user" "uuid", "_points" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."add_user_points"("_user" "uuid", "_points" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."add_user_points"("_user" "uuid", "_points" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."add_visit"("_place_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."add_visit"("_place_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."add_visit"("_place_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_attach_event"("p_admin_token" "text", "p_company_id" "uuid", "p_event_id" "uuid", "p_relationship_type" "text", "p_include_children" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."admin_attach_event"("p_admin_token" "text", "p_company_id" "uuid", "p_event_id" "uuid", "p_relationship_type" "text", "p_include_children" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_attach_event"("p_admin_token" "text", "p_company_id" "uuid", "p_event_id" "uuid", "p_relationship_type" "text", "p_include_children" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_attach_location"("p_admin_token" "text", "p_company_id" "uuid", "p_place_id" "uuid", "p_label" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_attach_location"("p_admin_token" "text", "p_company_id" "uuid", "p_place_id" "uuid", "p_label" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_attach_location"("p_admin_token" "text", "p_company_id" "uuid", "p_place_id" "uuid", "p_label" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_billing_overview"("p_admin_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_billing_overview"("p_admin_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_billing_overview"("p_admin_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_configure_place_booking"("p_admin_token" "text", "p_place_id" "uuid", "p_accepts_stay_bookings" boolean, "p_booking_mode" "text", "p_bookings_email" "text", "p_booking_contact_name" "text", "p_check_in_time" "text", "p_check_out_time" "text", "p_min_nights" integer, "p_max_guests" integer, "p_cancellation_policy" "text", "p_deposit_instructions" "text", "p_deposit_required" boolean, "p_deposit_default_amount" numeric, "p_deposit_currency" "text", "p_commission_terms" "text", "p_taxes_fees_notes" "text", "p_hold_expiry_minutes" integer, "p_internal_booking_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_configure_place_booking"("p_admin_token" "text", "p_place_id" "uuid", "p_accepts_stay_bookings" boolean, "p_booking_mode" "text", "p_bookings_email" "text", "p_booking_contact_name" "text", "p_check_in_time" "text", "p_check_out_time" "text", "p_min_nights" integer, "p_max_guests" integer, "p_cancellation_policy" "text", "p_deposit_instructions" "text", "p_deposit_required" boolean, "p_deposit_default_amount" numeric, "p_deposit_currency" "text", "p_commission_terms" "text", "p_taxes_fees_notes" "text", "p_hold_expiry_minutes" integer, "p_internal_booking_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_configure_place_booking"("p_admin_token" "text", "p_place_id" "uuid", "p_accepts_stay_bookings" boolean, "p_booking_mode" "text", "p_bookings_email" "text", "p_booking_contact_name" "text", "p_check_in_time" "text", "p_check_out_time" "text", "p_min_nights" integer, "p_max_guests" integer, "p_cancellation_policy" "text", "p_deposit_instructions" "text", "p_deposit_required" boolean, "p_deposit_default_amount" numeric, "p_deposit_currency" "text", "p_commission_terms" "text", "p_taxes_fees_notes" "text", "p_hold_expiry_minutes" integer, "p_internal_booking_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_create_onboarding_invite"("p_admin_token" "text", "p_company_id" "uuid", "p_email" "text", "p_place_ids" "uuid"[], "p_event_ids" "uuid"[], "p_expires_days" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."admin_create_onboarding_invite"("p_admin_token" "text", "p_company_id" "uuid", "p_email" "text", "p_place_ids" "uuid"[], "p_event_ids" "uuid"[], "p_expires_days" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_create_onboarding_invite"("p_admin_token" "text", "p_company_id" "uuid", "p_email" "text", "p_place_ids" "uuid"[], "p_event_ids" "uuid"[], "p_expires_days" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_detach_event"("p_admin_token" "text", "p_company_event_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_detach_event"("p_admin_token" "text", "p_company_event_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_detach_event"("p_admin_token" "text", "p_company_event_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_detach_location"("p_admin_token" "text", "p_company_id" "uuid", "p_place_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_detach_location"("p_admin_token" "text", "p_company_id" "uuid", "p_place_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_detach_location"("p_admin_token" "text", "p_company_id" "uuid", "p_place_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_generate_renewal_invoice"("p_admin_token" "text", "p_company_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_generate_renewal_invoice"("p_admin_token" "text", "p_company_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_generate_renewal_invoice"("p_admin_token" "text", "p_company_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_get_billing_catalog"("p_admin_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_get_billing_catalog"("p_admin_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_get_billing_catalog"("p_admin_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_get_company"("p_admin_token" "text", "p_company_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_get_company"("p_admin_token" "text", "p_company_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_get_company"("p_admin_token" "text", "p_company_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_get_place_booking_config"("p_admin_token" "text", "p_place_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_get_place_booking_config"("p_admin_token" "text", "p_place_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_get_place_booking_config"("p_admin_token" "text", "p_place_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_issue_invoice"("p_admin_token" "text", "p_invoice_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_issue_invoice"("p_admin_token" "text", "p_invoice_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_issue_invoice"("p_admin_token" "text", "p_invoice_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_remove_company_user"("p_admin_token" "text", "p_company_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_remove_company_user"("p_admin_token" "text", "p_company_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_remove_company_user"("p_admin_token" "text", "p_company_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_review_company_setup"("p_admin_token" "text", "p_request_id" "uuid", "p_decision" "text", "p_note" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_review_company_setup"("p_admin_token" "text", "p_request_id" "uuid", "p_decision" "text", "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_review_company_setup"("p_admin_token" "text", "p_request_id" "uuid", "p_decision" "text", "p_note" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_review_payment"("p_admin_token" "text", "p_confirmation_id" "uuid", "p_decision" "text", "p_note" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_review_payment"("p_admin_token" "text", "p_confirmation_id" "uuid", "p_decision" "text", "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_review_payment"("p_admin_token" "text", "p_confirmation_id" "uuid", "p_decision" "text", "p_note" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_revoke_onboarding_invite"("p_admin_token" "text", "p_invite_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_revoke_onboarding_invite"("p_admin_token" "text", "p_invite_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_revoke_onboarding_invite"("p_admin_token" "text", "p_invite_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_run_billing_maintenance"("p_admin_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_run_billing_maintenance"("p_admin_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_run_billing_maintenance"("p_admin_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_save_invoice"("p_admin_token" "text", "p_invoice_id" "uuid", "p_invoice" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_save_invoice"("p_admin_token" "text", "p_invoice_id" "uuid", "p_invoice" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_save_invoice"("p_admin_token" "text", "p_invoice_id" "uuid", "p_invoice" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_search_events"("p_admin_token" "text", "p_query" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_search_events"("p_admin_token" "text", "p_query" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_search_events"("p_admin_token" "text", "p_query" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_search_partners"("p_admin_token" "text", "p_query" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_search_partners"("p_admin_token" "text", "p_query" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_search_partners"("p_admin_token" "text", "p_query" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_search_places"("p_admin_token" "text", "p_query" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_search_places"("p_admin_token" "text", "p_query" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_search_places"("p_admin_token" "text", "p_query" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_search_places_for_booking"("p_admin_token" "text", "p_query" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_search_places_for_booking"("p_admin_token" "text", "p_query" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_search_places_for_booking"("p_admin_token" "text", "p_query" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_set_availability"("p_admin_token" "text", "p_room_type_id" "uuid", "p_place_id" "uuid", "p_dates" "date"[], "p_available_rooms" integer, "p_is_closed" boolean, "p_is_blackout" boolean, "p_min_nights" integer, "p_base_nightly_rate" numeric, "p_currency" "text", "p_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_set_availability"("p_admin_token" "text", "p_room_type_id" "uuid", "p_place_id" "uuid", "p_dates" "date"[], "p_available_rooms" integer, "p_is_closed" boolean, "p_is_blackout" boolean, "p_min_nights" integer, "p_base_nightly_rate" numeric, "p_currency" "text", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_set_availability"("p_admin_token" "text", "p_room_type_id" "uuid", "p_place_id" "uuid", "p_dates" "date"[], "p_available_rooms" integer, "p_is_closed" boolean, "p_is_blackout" boolean, "p_min_nights" integer, "p_base_nightly_rate" numeric, "p_currency" "text", "p_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_set_billing_setting"("p_admin_token" "text", "p_key" "text", "p_value" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_set_billing_setting"("p_admin_token" "text", "p_key" "text", "p_value" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_set_billing_setting"("p_admin_token" "text", "p_key" "text", "p_value" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_set_entitlement"("p_admin_token" "text", "p_company_id" "uuid", "p_key" "text", "p_active" boolean, "p_expires_at" "date", "p_note" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_set_entitlement"("p_admin_token" "text", "p_company_id" "uuid", "p_key" "text", "p_active" boolean, "p_expires_at" "date", "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_set_entitlement"("p_admin_token" "text", "p_company_id" "uuid", "p_key" "text", "p_active" boolean, "p_expires_at" "date", "p_note" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_set_event_package"("p_admin_token" "text", "p_company_event_id" "uuid", "p_package_code" "text", "p_comped" boolean, "p_note" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_set_event_package"("p_admin_token" "text", "p_company_event_id" "uuid", "p_package_code" "text", "p_comped" boolean, "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_set_event_package"("p_admin_token" "text", "p_company_event_id" "uuid", "p_package_code" "text", "p_comped" boolean, "p_note" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_set_invoice_status"("p_admin_token" "text", "p_invoice_id" "uuid", "p_status" "text", "p_note" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_set_invoice_status"("p_admin_token" "text", "p_invoice_id" "uuid", "p_status" "text", "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_set_invoice_status"("p_admin_token" "text", "p_invoice_id" "uuid", "p_status" "text", "p_note" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_set_message_status"("p_admin_token" "text", "p_message_id" "uuid", "p_status" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_set_message_status"("p_admin_token" "text", "p_message_id" "uuid", "p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_set_message_status"("p_admin_token" "text", "p_message_id" "uuid", "p_status" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_set_notification_status"("p_admin_token" "text", "p_notification_id" "uuid", "p_status" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_set_notification_status"("p_admin_token" "text", "p_notification_id" "uuid", "p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_set_notification_status"("p_admin_token" "text", "p_notification_id" "uuid", "p_status" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_set_request_status"("p_admin_token" "text", "p_request_id" "uuid", "p_status" "text", "p_admin_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_set_request_status"("p_admin_token" "text", "p_request_id" "uuid", "p_status" "text", "p_admin_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_set_request_status"("p_admin_token" "text", "p_request_id" "uuid", "p_status" "text", "p_admin_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_set_special_status"("p_admin_token" "text", "p_special_id" "uuid", "p_status" "text", "p_review_note" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_set_special_status"("p_admin_token" "text", "p_special_id" "uuid", "p_status" "text", "p_review_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_set_special_status"("p_admin_token" "text", "p_special_id" "uuid", "p_status" "text", "p_review_note" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_set_submission_status"("p_admin_token" "text", "p_submission_id" "uuid", "p_status" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_set_submission_status"("p_admin_token" "text", "p_submission_id" "uuid", "p_status" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_set_submission_status"("p_admin_token" "text", "p_submission_id" "uuid", "p_status" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_set_subscription"("p_admin_token" "text", "p_company_id" "uuid", "p_action" "text", "p_plan_key" "text", "p_billing_cycle" "text", "p_paid_through" "date", "p_note" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_set_subscription"("p_admin_token" "text", "p_company_id" "uuid", "p_action" "text", "p_plan_key" "text", "p_billing_cycle" "text", "p_paid_through" "date", "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_set_subscription"("p_admin_token" "text", "p_company_id" "uuid", "p_action" "text", "p_plan_key" "text", "p_billing_cycle" "text", "p_paid_through" "date", "p_note" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_upsert_cancellation_policy"("p_admin_token" "text", "p_id" "uuid", "p_place_id" "uuid", "p_rate_plan_id" "uuid", "p_policy_name" "text", "p_policy_text" "text", "p_free_cancel_hours" integer, "p_is_non_refundable" boolean, "p_deposit_forfeiture_notes" "text", "p_is_default" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."admin_upsert_cancellation_policy"("p_admin_token" "text", "p_id" "uuid", "p_place_id" "uuid", "p_rate_plan_id" "uuid", "p_policy_name" "text", "p_policy_text" "text", "p_free_cancel_hours" integer, "p_is_non_refundable" boolean, "p_deposit_forfeiture_notes" "text", "p_is_default" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_upsert_cancellation_policy"("p_admin_token" "text", "p_id" "uuid", "p_place_id" "uuid", "p_rate_plan_id" "uuid", "p_policy_name" "text", "p_policy_text" "text", "p_free_cancel_hours" integer, "p_is_non_refundable" boolean, "p_deposit_forfeiture_notes" "text", "p_is_default" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_upsert_company"("p_admin_token" "text", "p_company_id" "uuid", "p_name" "text", "p_billing_email" "text", "p_contact_name" "text", "p_contact_phone" "text", "p_status" "text", "p_notes" "text", "p_account_type" "text", "p_source_type" "text", "p_source_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_upsert_company"("p_admin_token" "text", "p_company_id" "uuid", "p_name" "text", "p_billing_email" "text", "p_contact_name" "text", "p_contact_phone" "text", "p_status" "text", "p_notes" "text", "p_account_type" "text", "p_source_type" "text", "p_source_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_upsert_company"("p_admin_token" "text", "p_company_id" "uuid", "p_name" "text", "p_billing_email" "text", "p_contact_name" "text", "p_contact_phone" "text", "p_status" "text", "p_notes" "text", "p_account_type" "text", "p_source_type" "text", "p_source_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_upsert_company_user"("p_admin_token" "text", "p_company_id" "uuid", "p_email" "text", "p_name" "text", "p_role" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_upsert_company_user"("p_admin_token" "text", "p_company_id" "uuid", "p_email" "text", "p_name" "text", "p_role" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_upsert_company_user"("p_admin_token" "text", "p_company_id" "uuid", "p_email" "text", "p_name" "text", "p_role" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_upsert_payment_instruction"("p_admin_token" "text", "p_id" "uuid", "p_fields" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."admin_upsert_payment_instruction"("p_admin_token" "text", "p_id" "uuid", "p_fields" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_upsert_payment_instruction"("p_admin_token" "text", "p_id" "uuid", "p_fields" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_upsert_rate_plan"("p_admin_token" "text", "p_id" "uuid", "p_room_type_id" "uuid", "p_place_id" "uuid", "p_name" "text", "p_description" "text", "p_cancellation_policy" "text", "p_meal_plan" "text", "p_inclusions" "text", "p_is_refundable" boolean, "p_is_active" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."admin_upsert_rate_plan"("p_admin_token" "text", "p_id" "uuid", "p_room_type_id" "uuid", "p_place_id" "uuid", "p_name" "text", "p_description" "text", "p_cancellation_policy" "text", "p_meal_plan" "text", "p_inclusions" "text", "p_is_refundable" boolean, "p_is_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_upsert_rate_plan"("p_admin_token" "text", "p_id" "uuid", "p_room_type_id" "uuid", "p_place_id" "uuid", "p_name" "text", "p_description" "text", "p_cancellation_policy" "text", "p_meal_plan" "text", "p_inclusions" "text", "p_is_refundable" boolean, "p_is_active" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."admin_upsert_room_type"("p_admin_token" "text", "p_id" "uuid", "p_place_id" "uuid", "p_name" "text", "p_description" "text", "p_max_guests" integer, "p_base_occupancy" integer, "p_room_count" integer, "p_amenities" "text"[], "p_images" "text"[], "p_is_active" boolean, "p_display_order" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."admin_upsert_room_type"("p_admin_token" "text", "p_id" "uuid", "p_place_id" "uuid", "p_name" "text", "p_description" "text", "p_max_guests" integer, "p_base_occupancy" integer, "p_room_count" integer, "p_amenities" "text"[], "p_images" "text"[], "p_is_active" boolean, "p_display_order" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."admin_upsert_room_type"("p_admin_token" "text", "p_id" "uuid", "p_place_id" "uuid", "p_name" "text", "p_description" "text", "p_max_guests" integer, "p_base_occupancy" integer, "p_room_count" integer, "p_amenities" "text"[], "p_images" "text"[], "p_is_active" boolean, "p_display_order" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."after_xp_transaction_insert"() TO "anon";
GRANT ALL ON FUNCTION "public"."after_xp_transaction_insert"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."after_xp_transaction_insert"() TO "service_role";



GRANT ALL ON FUNCTION "public"."approve_event_submission"("p_submission_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."approve_event_submission"("p_submission_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."approve_event_submission"("p_submission_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."assign_partner_account"("p_partner_name" "text", "p_contact_email" "text", "p_place_slugs" "text"[], "p_event_slugs" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."assign_partner_account"("p_partner_name" "text", "p_contact_email" "text", "p_place_slugs" "text"[], "p_event_slugs" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."assign_partner_account"("p_partner_name" "text", "p_contact_email" "text", "p_place_slugs" "text"[], "p_event_slugs" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."assign_special_waitlist_position"() TO "anon";
GRANT ALL ON FUNCTION "public"."assign_special_waitlist_position"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."assign_special_waitlist_position"() TO "service_role";



GRANT ALL ON FUNCTION "public"."award_achievement_bonus_xp"() TO "anon";
GRANT ALL ON FUNCTION "public"."award_achievement_bonus_xp"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."award_achievement_bonus_xp"() TO "service_role";



GRANT ALL ON FUNCTION "public"."award_xp"("p_user_id" "uuid", "p_source_type" "text", "p_source_id" "text", "p_xp_amount" integer, "p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."award_xp"("p_user_id" "uuid", "p_source_type" "text", "p_source_id" "text", "p_xp_amount" integer, "p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."award_xp"("p_user_id" "uuid", "p_source_type" "text", "p_source_id" "text", "p_xp_amount" integer, "p_metadata" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."award_xp_by_rule"("p_user_id" "uuid", "p_rule_key" "text", "p_source_id" "text", "p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."award_xp_by_rule"("p_user_id" "uuid", "p_rule_key" "text", "p_source_id" "text", "p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."award_xp_by_rule"("p_user_id" "uuid", "p_rule_key" "text", "p_source_id" "text", "p_metadata" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."build_guest_profile_snapshot"("p_user_id" "uuid", "p_place_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."build_guest_profile_snapshot"("p_user_id" "uuid", "p_place_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."build_guest_profile_snapshot"("p_user_id" "uuid", "p_place_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."bulk_import_schedule_items"("p_token" "text", "p_items" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."bulk_import_schedule_items"("p_token" "text", "p_items" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."bulk_import_schedule_items"("p_token" "text", "p_items" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."bump_schedule_version"() TO "anon";
GRANT ALL ON FUNCTION "public"."bump_schedule_version"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."bump_schedule_version"() TO "service_role";



GRANT ALL ON FUNCTION "public"."bump_share_view"("_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."bump_share_view"("_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."bump_share_view"("_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."cancel_change_request"("_request_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."cancel_change_request"("_request_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."cancel_change_request"("_request_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."check_and_unlock"("_user" "uuid", "_event" "text", "_payload" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."check_and_unlock"("_user" "uuid", "_event" "text", "_payload" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."check_and_unlock"("_user" "uuid", "_event" "text", "_payload" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."checkin_in_app"("p_place_id" "uuid", "p_lat" double precision, "p_lng" double precision, "p_idempotency_key" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."checkin_in_app"("p_place_id" "uuid", "p_lat" double precision, "p_lng" double precision, "p_idempotency_key" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."checkin_in_app"("p_place_id" "uuid", "p_lat" double precision, "p_lng" double precision, "p_idempotency_key" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_cmp"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_cmp"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_cmp"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_cmp"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_eq"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_eq"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_eq"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_eq"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_ge"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_ge"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_ge"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_ge"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_gt"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_gt"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_gt"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_gt"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_hash"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_hash"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_hash"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_hash"("public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_hash_extended"("public"."citext", bigint) TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_hash_extended"("public"."citext", bigint) TO "anon";
GRANT ALL ON FUNCTION "public"."citext_hash_extended"("public"."citext", bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_hash_extended"("public"."citext", bigint) TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_larger"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_larger"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_larger"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_larger"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_le"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_le"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_le"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_le"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_lt"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_lt"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_lt"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_lt"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_ne"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_ne"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_ne"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_ne"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_cmp"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_cmp"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_cmp"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_cmp"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_ge"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_ge"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_ge"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_ge"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_gt"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_gt"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_gt"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_gt"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_le"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_le"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_le"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_le"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_pattern_lt"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_pattern_lt"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_pattern_lt"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_pattern_lt"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."citext_smaller"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."citext_smaller"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."citext_smaller"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."citext_smaller"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."cleanup_expired_holds"() TO "anon";
GRANT ALL ON FUNCTION "public"."cleanup_expired_holds"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."cleanup_expired_holds"() TO "service_role";



REVOKE ALL ON FUNCTION "public"."company_access_state"("p_company_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."company_access_state"("p_company_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."company_access_state"("p_company_id" "uuid") TO "service_role";



REVOKE ALL ON FUNCTION "public"."company_has_entitlement"("p_company_id" "uuid", "p_key" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."company_has_entitlement"("p_company_id" "uuid", "p_key" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."company_has_entitlement"("p_company_id" "uuid", "p_key" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."company_specials_usage"("p_company_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."company_specials_usage"("p_company_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."company_specials_usage"("p_company_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."copy_submission_to_event"() TO "anon";
GRANT ALL ON FUNCTION "public"."copy_submission_to_event"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."copy_submission_to_event"() TO "service_role";



GRANT ALL ON FUNCTION "public"."count_unique_visits"("p_place_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."count_unique_visits"("p_place_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."count_unique_visits"("p_place_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."count_unique_votes"("p_place_id" "uuid", "p_vote" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."count_unique_votes"("p_place_id" "uuid", "p_vote" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."count_unique_votes"("p_place_id" "uuid", "p_vote" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_event_map_invite"("p_token" "text", "p_designer_name" "text", "p_designer_email" "text", "p_scopes" "text"[], "p_expires_in_days" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."create_event_map_invite"("p_token" "text", "p_designer_name" "text", "p_designer_email" "text", "p_scopes" "text"[], "p_expires_in_days" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_event_map_invite"("p_token" "text", "p_designer_name" "text", "p_designer_email" "text", "p_scopes" "text"[], "p_expires_in_days" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."create_inventory_hold"("p_place_id" "uuid", "p_room_type_id" "uuid", "p_check_in" "date", "p_check_out" "date", "p_rooms" integer, "p_session_id" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."create_inventory_hold"("p_place_id" "uuid", "p_room_type_id" "uuid", "p_check_in" "date", "p_check_out" "date", "p_rooms" integer, "p_session_id" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_inventory_hold"("p_place_id" "uuid", "p_room_type_id" "uuid", "p_check_in" "date", "p_check_out" "date", "p_rooms" integer, "p_session_id" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."create_or_update_itinerary_share"("_itinerary_id" "uuid", "_expires_at" timestamp with time zone, "_regenerate" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."create_or_update_itinerary_share"("_itinerary_id" "uuid", "_expires_at" timestamp with time zone, "_regenerate" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_or_update_itinerary_share"("_itinerary_id" "uuid", "_expires_at" timestamp with time zone, "_regenerate" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."create_ranking_on_visit"() TO "anon";
GRANT ALL ON FUNCTION "public"."create_ranking_on_visit"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."create_ranking_on_visit"() TO "service_role";



GRANT ALL ON FUNCTION "public"."deactivate_expired_specials"() TO "anon";
GRANT ALL ON FUNCTION "public"."deactivate_expired_specials"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."deactivate_expired_specials"() TO "service_role";



GRANT ALL ON FUNCTION "public"."decline_trip_invite"("_token" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."decline_trip_invite"("_token" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."decline_trip_invite"("_token" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."decrement_event_going"("event_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."decrement_event_going"("event_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."decrement_event_going"("event_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."decrement_event_interested"("event_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."decrement_event_interested"("event_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."decrement_event_interested"("event_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."decrement_feedback_upvote"("fid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."decrement_feedback_upvote"("fid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."decrement_feedback_upvote"("fid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_event_sponsor"("p_token" "text", "p_event_sponsor_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_event_sponsor"("p_token" "text", "p_event_sponsor_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_event_sponsor"("p_token" "text", "p_event_sponsor_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_partner_closure"("p_token" "text", "p_closure_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_partner_closure"("p_token" "text", "p_closure_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_partner_closure"("p_token" "text", "p_closure_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_schedule_day"("p_token" "text", "p_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_schedule_day"("p_token" "text", "p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_schedule_day"("p_token" "text", "p_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_schedule_item"("p_token" "text", "p_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_schedule_item"("p_token" "text", "p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_schedule_item"("p_token" "text", "p_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_ticket_location"("p_token" "text", "p_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_ticket_location"("p_token" "text", "p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_ticket_location"("p_token" "text", "p_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_transport_route"("p_token" "text", "p_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_transport_route"("p_token" "text", "p_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_transport_route"("p_token" "text", "p_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."delete_user_and_data"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."delete_user_and_data"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."delete_user_and_data"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."ensure_schedule_meta"() TO "anon";
GRANT ALL ON FUNCTION "public"."ensure_schedule_meta"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."ensure_schedule_meta"() TO "service_role";



GRANT ALL ON FUNCTION "public"."event_push_cap_usage"("p_event_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."event_push_cap_usage"("p_event_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."event_push_cap_usage"("p_event_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."export_partner_bookings"("p_token" "text", "p_from_date" "date", "p_to_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."export_partner_bookings"("p_token" "text", "p_from_date" "date", "p_to_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."export_partner_bookings"("p_token" "text", "p_from_date" "date", "p_to_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_cleanup_expired_invites"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_cleanup_expired_invites"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_cleanup_expired_invites"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_notify_loyalty_stamp"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_notify_loyalty_stamp"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_notify_loyalty_stamp"() TO "service_role";



GRANT ALL ON FUNCTION "public"."fn_notify_trip_collaborator"() TO "anon";
GRANT ALL ON FUNCTION "public"."fn_notify_trip_collaborator"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."fn_notify_trip_collaborator"() TO "service_role";



GRANT ALL ON FUNCTION "public"."force_apply_change_request"("_request_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."force_apply_change_request"("_request_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."force_apply_change_request"("_request_id" "uuid") TO "service_role";



GRANT ALL ON TABLE "public"."places" TO "anon";
GRANT ALL ON TABLE "public"."places" TO "authenticated";
GRANT ALL ON TABLE "public"."places" TO "service_role";



GRANT ALL ON FUNCTION "public"."fuzzy_search_places"("q" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."fuzzy_search_places"("q" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."fuzzy_search_places"("q" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."generate_unique_event_slug"("p_title" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."generate_unique_event_slug"("p_title" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."generate_unique_event_slug"("p_title" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_admin_review_queue"("p_admin_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_admin_review_queue"("p_admin_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_admin_review_queue"("p_admin_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_billing_catalog_for_quote"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_billing_catalog_for_quote"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_billing_catalog_for_quote"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_booking_by_token"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_booking_by_token"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_booking_by_token"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_booking_detail_by_token"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_booking_detail_by_token"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_booking_detail_by_token"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_booking_guest_profile"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_booking_guest_profile"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_booking_guest_profile"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_bookings_by_partner_token"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_bookings_by_partner_token"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_bookings_by_partner_token"("p_token" "text") TO "service_role";



GRANT ALL ON TABLE "public"."place_checkin_settings" TO "anon";
GRANT ALL ON TABLE "public"."place_checkin_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."place_checkin_settings" TO "service_role";



GRANT ALL ON FUNCTION "public"."get_checkin_settings_by_partner_token"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_checkin_settings_by_partner_token"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_checkin_settings_by_partner_token"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_company_billing"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_company_billing"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_company_billing"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_event_billing_by_token"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_event_billing_by_token"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_event_billing_by_token"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_event_floor_plan_public"("p_slug" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_event_floor_plan_public"("p_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_event_floor_plan_public"("p_slug" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_event_sponsors_by_slug"("p_event_slug" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_event_sponsors_by_slug"("p_event_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_event_sponsors_by_slug"("p_event_slug" "text") TO "service_role";



GRANT ALL ON TABLE "public"."insider_status_settings" TO "anon";
GRANT ALL ON TABLE "public"."insider_status_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."insider_status_settings" TO "service_role";



GRANT ALL ON FUNCTION "public"."get_insider_settings_by_partner_token"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_insider_settings_by_partner_token"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_insider_settings_by_partner_token"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_itinerary_by_share_token"("_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_itinerary_by_share_token"("_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_itinerary_by_share_token"("_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_loyalty_analytics_by_token"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_loyalty_analytics_by_token"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_loyalty_analytics_by_token"("p_token" "text") TO "service_role";



GRANT ALL ON TABLE "public"."loyalty_programs" TO "anon";
GRANT ALL ON TABLE "public"."loyalty_programs" TO "authenticated";
GRANT ALL ON TABLE "public"."loyalty_programs" TO "service_role";



GRANT ALL ON FUNCTION "public"."get_loyalty_program_for_place"("p_place_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_loyalty_program_for_place"("p_place_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_loyalty_program_for_place"("p_place_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_loyalty_redemption_report_by_token"("p_token" "text", "p_report_date" "date") TO "anon";
GRANT ALL ON FUNCTION "public"."get_loyalty_redemption_report_by_token"("p_token" "text", "p_report_date" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_loyalty_redemption_report_by_token"("p_token" "text", "p_report_date" "date") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_my_entitlements"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_my_entitlements"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_entitlements"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_my_visit_history"() TO "anon";
GRANT ALL ON FUNCTION "public"."get_my_visit_history"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_my_visit_history"() TO "service_role";



GRANT ALL ON FUNCTION "public"."get_onboarding_invite"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_onboarding_invite"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_onboarding_invite"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_partner_billing_by_token"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_partner_billing_by_token"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_partner_billing_by_token"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_partner_bookings_v2"("p_token" "text", "p_status" "text", "p_type" "text", "p_from_date" "date", "p_to_date" "date", "p_guest_name" "text", "p_limit" integer, "p_offset" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_partner_bookings_v2"("p_token" "text", "p_status" "text", "p_type" "text", "p_from_date" "date", "p_to_date" "date", "p_guest_name" "text", "p_limit" integer, "p_offset" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_partner_bookings_v2"("p_token" "text", "p_status" "text", "p_type" "text", "p_from_date" "date", "p_to_date" "date", "p_guest_name" "text", "p_limit" integer, "p_offset" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_partner_by_token"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_partner_by_token"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_partner_by_token"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_partner_capabilities_by_token"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_partner_capabilities_by_token"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_partner_capabilities_by_token"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_partner_event_by_token"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_partner_event_by_token"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_partner_event_by_token"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_partner_event_extras_by_token"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_partner_event_extras_by_token"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_partner_event_extras_by_token"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_partner_feedback_by_token"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_partner_feedback_by_token"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_partner_feedback_by_token"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_partner_group_insights_by_token"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_partner_group_insights_by_token"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_partner_group_insights_by_token"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_partner_group_item_insights_by_token"("p_token" "text", "p_min_reviews" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_partner_group_item_insights_by_token"("p_token" "text", "p_min_reviews" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_partner_group_item_insights_by_token"("p_token" "text", "p_min_reviews" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_partner_item_insights_by_token"("p_token" "text", "p_min_reviews" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_partner_item_insights_by_token"("p_token" "text", "p_min_reviews" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_partner_item_insights_by_token"("p_token" "text", "p_min_reviews" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_partner_listing_by_token"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_partner_listing_by_token"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_partner_listing_by_token"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_partner_specials_by_token"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_partner_specials_by_token"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_partner_specials_by_token"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_partner_vendor_directory"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_partner_vendor_directory"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_partner_vendor_directory"("p_token" "text") TO "service_role";



GRANT ALL ON TABLE "public"."partner_perks" TO "anon";
GRANT ALL ON TABLE "public"."partner_perks" TO "authenticated";
GRANT ALL ON TABLE "public"."partner_perks" TO "service_role";



GRANT ALL ON FUNCTION "public"."get_perks_by_partner_token"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_perks_by_partner_token"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_perks_by_partner_token"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_place_public"("_slug" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_place_public"("_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_place_public"("_slug" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_place_rating"("p_user_id" "uuid", "p_place_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_place_rating"("p_user_id" "uuid", "p_place_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_place_rating"("p_user_id" "uuid", "p_place_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_shared_itinerary"("_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."get_shared_itinerary"("_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_shared_itinerary"("_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_shared_itinerary_by_id"("_itinerary_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_shared_itinerary_by_id"("_itinerary_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_shared_itinerary_by_id"("_itinerary_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_trip_invite_preview"("_token" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_trip_invite_preview"("_token" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_trip_invite_preview"("_token" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_achievements"("_user" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_achievements"("_user" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_achievements"("_user" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_ratings_batch"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_ratings_batch"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_ratings_batch"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."get_user_tier"("p_lifetime_xp" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."get_user_tier"("p_lifetime_xp" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_user_tier"("p_lifetime_xp" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."get_visit_summary"("_place" "uuid", "_user" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."get_visit_summary"("_place" "uuid", "_user" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."get_visit_summary"("_place" "uuid", "_user" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."handle_new_auth_user"() TO "anon";
GRANT ALL ON FUNCTION "public"."handle_new_auth_user"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."handle_new_auth_user"() TO "service_role";



GRANT ALL ON FUNCTION "public"."has_trip_access"("_trip_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."has_trip_access"("_trip_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."has_trip_access"("_trip_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."increment_event_going"("event_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."increment_event_going"("event_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."increment_event_going"("event_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."increment_event_interested"("event_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."increment_event_interested"("event_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."increment_event_interested"("event_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."increment_feedback_upvote"("fid" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."increment_feedback_upvote"("fid" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."increment_feedback_upvote"("fid" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."invoke_notify_partner_booking"() TO "anon";
GRANT ALL ON FUNCTION "public"."invoke_notify_partner_booking"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."invoke_notify_partner_booking"() TO "service_role";



GRANT ALL ON FUNCTION "public"."is_trip_collaborator"("_trip_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_trip_collaborator"("_trip_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_trip_collaborator"("_trip_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."is_trip_owner"("_trip_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."is_trip_owner"("_trip_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."is_trip_owner"("_trip_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."list_event_map_invites"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."list_event_map_invites"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."list_event_map_invites"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."list_partner_closures"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."list_partner_closures"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."list_partner_closures"("p_token" "text") TO "service_role";



REVOKE ALL ON FUNCTION "public"."next_invoice_number"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."next_invoice_number"() TO "service_role";



GRANT ALL ON FUNCTION "public"."normalize_quick_tags"() TO "anon";
GRANT ALL ON FUNCTION "public"."normalize_quick_tags"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."normalize_quick_tags"() TO "service_role";



GRANT ALL ON FUNCTION "public"."partner_get_billing_profile"("p_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."partner_get_billing_profile"("p_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."partner_get_billing_profile"("p_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."partner_update_billing_profile"("p_token" "text", "p_info" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."partner_update_billing_profile"("p_token" "text", "p_info" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."partner_update_billing_profile"("p_token" "text", "p_info" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."partner_update_booking"("p_partner_token" "text", "p_booking_id" "uuid", "p_action" "text", "p_data" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."partner_update_booking"("p_partner_token" "text", "p_booking_id" "uuid", "p_action" "text", "p_data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."partner_update_booking"("p_partner_token" "text", "p_booking_id" "uuid", "p_action" "text", "p_data" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."payment_instructions_for_currency"("p_currency" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."payment_instructions_for_currency"("p_currency" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."payment_instructions_for_currency"("p_currency" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."populate_booking_guest_snapshot"() TO "anon";
GRANT ALL ON FUNCTION "public"."populate_booking_guest_snapshot"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."populate_booking_guest_snapshot"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_duplicate_visits"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_duplicate_visits"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_duplicate_visits"() TO "service_role";



GRANT ALL ON FUNCTION "public"."prevent_xp_transaction_mutation"() TO "anon";
GRANT ALL ON FUNCTION "public"."prevent_xp_transaction_mutation"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."prevent_xp_transaction_mutation"() TO "service_role";



GRANT ALL ON FUNCTION "public"."propose_delete_item"("_trip_id" "uuid", "_target_entity_type" "text", "_target_entry_id" "uuid", "_payload" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."propose_delete_item"("_trip_id" "uuid", "_target_entity_type" "text", "_target_entry_id" "uuid", "_payload" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."propose_delete_item"("_trip_id" "uuid", "_target_entity_type" "text", "_target_entry_id" "uuid", "_payload" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."recalculate_user_xp"("p_user_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."recalculate_user_xp"("p_user_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."recalculate_user_xp"("p_user_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."record_loyalty_redemption_by_token"("p_token" "text", "p_card_id" "uuid", "p_redeemed_by" "text", "p_notes" "text", "p_source" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."record_loyalty_redemption_by_token"("p_token" "text", "p_card_id" "uuid", "p_redeemed_by" "text", "p_notes" "text", "p_source" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."record_loyalty_redemption_by_token"("p_token" "text", "p_card_id" "uuid", "p_redeemed_by" "text", "p_notes" "text", "p_source" "text") TO "service_role";



GRANT ALL ON TABLE "public"."perk_redemptions" TO "anon";
GRANT ALL ON TABLE "public"."perk_redemptions" TO "authenticated";
GRANT ALL ON TABLE "public"."perk_redemptions" TO "service_role";



GRANT ALL ON FUNCTION "public"."redeem_perk_by_partner_token"("p_token" "text", "p_perk_id" "uuid", "p_user_id" "uuid", "p_booking_id" "uuid", "p_checkin_id" "uuid", "p_redeemed_by" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."redeem_perk_by_partner_token"("p_token" "text", "p_perk_id" "uuid", "p_user_id" "uuid", "p_booking_id" "uuid", "p_checkin_id" "uuid", "p_redeemed_by" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."redeem_perk_by_partner_token"("p_token" "text", "p_perk_id" "uuid", "p_user_id" "uuid", "p_booking_id" "uuid", "p_checkin_id" "uuid", "p_redeemed_by" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_match"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_matches"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_replace"("public"."citext", "public"."citext", "text", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_split_to_array"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."regexp_split_to_table"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."release_inventory_hold"("p_hold_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."release_inventory_hold"("p_hold_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."release_inventory_hold"("p_hold_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."replace"("public"."citext", "public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."replace"("public"."citext", "public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."replace"("public"."citext", "public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."replace"("public"."citext", "public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."reserve_special_billing"("p_place_id" "uuid", "p_special_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."reserve_special_billing"("p_place_id" "uuid", "p_special_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."reserve_special_billing"("p_place_id" "uuid", "p_special_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."resolve_event_map_invite"("p_invite_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."resolve_event_map_invite"("p_invite_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."resolve_event_map_invite"("p_invite_token" "text") TO "service_role";



GRANT ALL ON TABLE "public"."bookings" TO "anon";
GRANT ALL ON TABLE "public"."bookings" TO "authenticated";
GRANT ALL ON TABLE "public"."bookings" TO "service_role";



GRANT ALL ON FUNCTION "public"."respond_to_booking"("p_token" "text", "p_status" "text", "p_message" "text", "p_proposed_date" "date", "p_proposed_time" "text", "p_responder_email" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."respond_to_booking"("p_token" "text", "p_status" "text", "p_message" "text", "p_proposed_date" "date", "p_proposed_time" "text", "p_responder_email" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."respond_to_booking"("p_token" "text", "p_status" "text", "p_message" "text", "p_proposed_date" "date", "p_proposed_time" "text", "p_responder_email" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."revoke_event_map_invite"("p_token" "text", "p_invite_token" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."revoke_event_map_invite"("p_token" "text", "p_invite_token" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."revoke_event_map_invite"("p_token" "text", "p_invite_token" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."revoke_itinerary_share"("_itinerary_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."revoke_itinerary_share"("_itinerary_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."revoke_itinerary_share"("_itinerary_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."search_stay_availability"("p_place_id" "uuid", "p_check_in" "date", "p_check_out" "date", "p_adults" integer, "p_children" integer, "p_rooms" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."search_stay_availability"("p_place_id" "uuid", "p_check_in" "date", "p_check_out" "date", "p_adults" integer, "p_children" integer, "p_rooms" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."search_stay_availability"("p_place_id" "uuid", "p_check_in" "date", "p_check_out" "date", "p_adults" integer, "p_children" integer, "p_rooms" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."send_partner_message"("p_token" "text", "p_subject" "text", "p_message" "text", "p_source_page" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."send_partner_message"("p_token" "text", "p_subject" "text", "p_message" "text", "p_source_page" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."send_partner_message"("p_token" "text", "p_subject" "text", "p_message" "text", "p_source_page" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."set_bookings_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_bookings_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_bookings_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_partner_perks_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_partner_perks_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_partner_perks_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_place_checkin_settings_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_place_checkin_settings_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_place_checkin_settings_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."set_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."split_part"("public"."citext", "public"."citext", integer) TO "postgres";
GRANT ALL ON FUNCTION "public"."split_part"("public"."citext", "public"."citext", integer) TO "anon";
GRANT ALL ON FUNCTION "public"."split_part"("public"."citext", "public"."citext", integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."split_part"("public"."citext", "public"."citext", integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."strpos"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."strpos"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."strpos"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."strpos"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."submit_billing_request"("p_request_type" "text", "p_message" "text", "p_related_location_id" "uuid", "p_related_event_id" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_billing_request"("p_request_type" "text", "p_message" "text", "p_related_location_id" "uuid", "p_related_event_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_billing_request"("p_request_type" "text", "p_message" "text", "p_related_location_id" "uuid", "p_related_event_id" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."submit_company_onboarding"("p_info" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_company_onboarding"("p_info" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_company_onboarding"("p_info" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."submit_company_setup_request"("p_info" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_company_setup_request"("p_info" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_company_setup_request"("p_info" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."submit_onboarding_profile"("p_profile" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_onboarding_profile"("p_profile" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_onboarding_profile"("p_profile" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."submit_onboarding_quote"("p_selection" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_onboarding_quote"("p_selection" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_onboarding_quote"("p_selection" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."submit_partner_special"("p_token" "text", "p_title" "text", "p_description" "text", "p_special_type" "text", "p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_start_time" time without time zone, "p_end_time" time without time zone, "p_image_url" "text", "p_discount_percentage" numeric, "p_discount_amount" numeric, "p_price_amount" numeric, "p_currency" "text", "p_event_category" "text", "p_tags" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."submit_partner_special"("p_token" "text", "p_title" "text", "p_description" "text", "p_special_type" "text", "p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_start_time" time without time zone, "p_end_time" time without time zone, "p_image_url" "text", "p_discount_percentage" numeric, "p_discount_amount" numeric, "p_price_amount" numeric, "p_currency" "text", "p_event_category" "text", "p_tags" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_partner_special"("p_token" "text", "p_title" "text", "p_description" "text", "p_special_type" "text", "p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_start_time" time without time zone, "p_end_time" time without time zone, "p_image_url" "text", "p_discount_percentage" numeric, "p_discount_amount" numeric, "p_price_amount" numeric, "p_currency" "text", "p_event_category" "text", "p_tags" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."submit_partner_special"("p_token" "text", "p_title" "text", "p_description" "text", "p_special_type" "text", "p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_start_time" time without time zone, "p_end_time" time without time zone, "p_image_url" "text", "p_discount_percentage" numeric, "p_discount_amount" numeric, "p_price_amount" numeric, "p_currency" "text", "p_event_category" "text", "p_tags" "text"[], "p_capacity" integer, "p_recurring_days" "text"[], "p_age_restriction" "text", "p_host_name" "text", "p_event_slug" "text", "p_ticket_link" "text", "p_rsvp_link" "text", "p_image_urls" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."submit_partner_special"("p_token" "text", "p_title" "text", "p_description" "text", "p_special_type" "text", "p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_start_time" time without time zone, "p_end_time" time without time zone, "p_image_url" "text", "p_discount_percentage" numeric, "p_discount_amount" numeric, "p_price_amount" numeric, "p_currency" "text", "p_event_category" "text", "p_tags" "text"[], "p_capacity" integer, "p_recurring_days" "text"[], "p_age_restriction" "text", "p_host_name" "text", "p_event_slug" "text", "p_ticket_link" "text", "p_rsvp_link" "text", "p_image_urls" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_partner_special"("p_token" "text", "p_title" "text", "p_description" "text", "p_special_type" "text", "p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_start_time" time without time zone, "p_end_time" time without time zone, "p_image_url" "text", "p_discount_percentage" numeric, "p_discount_amount" numeric, "p_price_amount" numeric, "p_currency" "text", "p_event_category" "text", "p_tags" "text"[], "p_capacity" integer, "p_recurring_days" "text"[], "p_age_restriction" "text", "p_host_name" "text", "p_event_slug" "text", "p_ticket_link" "text", "p_rsvp_link" "text", "p_image_urls" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."submit_payment_confirmation"("p_invoice_id" "uuid", "p_payment_method" "text", "p_paid_on" "date", "p_reference" "text", "p_receipt_path" "text", "p_notes" "text", "p_receipt_filename" "text", "p_receipt_size_bytes" bigint, "p_receipt_mime" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."submit_payment_confirmation"("p_invoice_id" "uuid", "p_payment_method" "text", "p_paid_on" "date", "p_reference" "text", "p_receipt_path" "text", "p_notes" "text", "p_receipt_filename" "text", "p_receipt_size_bytes" bigint, "p_receipt_mime" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."submit_payment_confirmation"("p_invoice_id" "uuid", "p_payment_method" "text", "p_paid_on" "date", "p_reference" "text", "p_receipt_path" "text", "p_notes" "text", "p_receipt_filename" "text", "p_receipt_size_bytes" bigint, "p_receipt_mime" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."sync_vendor_place_slug"() TO "anon";
GRANT ALL ON FUNCTION "public"."sync_vendor_place_slug"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."sync_vendor_place_slug"() TO "service_role";



GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticlike"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticnlike"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticregexeq"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."texticregexne"("public"."citext", "public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."tg_booking_timeline"() TO "anon";
GRANT ALL ON FUNCTION "public"."tg_booking_timeline"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tg_booking_timeline"() TO "service_role";



GRANT ALL ON FUNCTION "public"."tg_partner_message_email"() TO "anon";
GRANT ALL ON FUNCTION "public"."tg_partner_message_email"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tg_partner_message_email"() TO "service_role";



GRANT ALL ON FUNCTION "public"."tg_special_email"() TO "anon";
GRANT ALL ON FUNCTION "public"."tg_special_email"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tg_special_email"() TO "service_role";



GRANT ALL ON FUNCTION "public"."tg_submission_email"() TO "anon";
GRANT ALL ON FUNCTION "public"."tg_submission_email"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."tg_submission_email"() TO "service_role";



GRANT ALL ON FUNCTION "public"."track_event_metric"("p_event_id" "uuid", "p_event_name" "text", "p_anon_device_id" "text", "p_session_id" "text", "p_tab_key" "text", "p_vendor_id" "uuid", "p_sponsor_id" "uuid", "p_activation_id" "uuid", "p_band_id" "uuid", "p_notification_id" "uuid", "p_notification_category" "text", "p_target_url" "text", "p_metadata" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."track_event_metric"("p_event_id" "uuid", "p_event_name" "text", "p_anon_device_id" "text", "p_session_id" "text", "p_tab_key" "text", "p_vendor_id" "uuid", "p_sponsor_id" "uuid", "p_activation_id" "uuid", "p_band_id" "uuid", "p_notification_id" "uuid", "p_notification_category" "text", "p_target_url" "text", "p_metadata" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."track_event_metric"("p_event_id" "uuid", "p_event_name" "text", "p_anon_device_id" "text", "p_session_id" "text", "p_tab_key" "text", "p_vendor_id" "uuid", "p_sponsor_id" "uuid", "p_activation_id" "uuid", "p_band_id" "uuid", "p_notification_id" "uuid", "p_notification_category" "text", "p_target_url" "text", "p_metadata" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."translate"("public"."citext", "public"."citext", "text") TO "postgres";
GRANT ALL ON FUNCTION "public"."translate"("public"."citext", "public"."citext", "text") TO "anon";
GRANT ALL ON FUNCTION "public"."translate"("public"."citext", "public"."citext", "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."translate"("public"."citext", "public"."citext", "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."trip_other_voter_count"("_trip_id" "uuid", "_proposer" "uuid") TO "anon";
GRANT ALL ON FUNCTION "public"."trip_other_voter_count"("_trip_id" "uuid", "_proposer" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."trip_other_voter_count"("_trip_id" "uuid", "_proposer" "uuid") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_event_floor_plan"("p_token" "text", "p_floor_plan_url" "text", "p_floor_plan_markers" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."update_event_floor_plan"("p_token" "text", "p_floor_plan_url" "text", "p_floor_plan_markers" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_event_floor_plan"("p_token" "text", "p_floor_plan_url" "text", "p_floor_plan_markers" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_event_floor_plan_via_invite"("p_invite_token" "text", "p_floor_plan_markers" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."update_event_floor_plan_via_invite"("p_invite_token" "text", "p_floor_plan_markers" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_event_floor_plan_via_invite"("p_invite_token" "text", "p_floor_plan_markers" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_event_popularity"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_event_popularity"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_event_popularity"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_event_vendor"("p_token" "text", "p_event_vendor_id" "uuid", "p_vendor_name" "text", "p_booth_number" "text", "p_vendor_type" "text", "p_vendor_description" "text", "p_is_featured" boolean, "p_filter_tags" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."update_event_vendor"("p_token" "text", "p_event_vendor_id" "uuid", "p_vendor_name" "text", "p_booth_number" "text", "p_vendor_type" "text", "p_vendor_description" "text", "p_is_featured" boolean, "p_filter_tags" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_event_vendor"("p_token" "text", "p_event_vendor_id" "uuid", "p_vendor_name" "text", "p_booth_number" "text", "p_vendor_type" "text", "p_vendor_description" "text", "p_is_featured" boolean, "p_filter_tags" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."update_loyalty_program_by_token"("p_token" "text", "p_required_stamps" integer, "p_reward" "text", "p_spend_per_stamp" numeric, "p_fine_print" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."update_loyalty_program_by_token"("p_token" "text", "p_required_stamps" integer, "p_reward" "text", "p_spend_per_stamp" numeric, "p_fine_print" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_loyalty_program_by_token"("p_token" "text", "p_required_stamps" integer, "p_reward" "text", "p_spend_per_stamp" numeric, "p_fine_print" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_loyalty_program_by_token"("p_token" "text", "p_required_stamps" integer, "p_reward" "text", "p_spend_per_stamp" numeric, "p_fine_print" "text", "p_stamp_icon" "text", "p_stamp_logo_url" "text", "p_card_theme" "text", "p_silver_after_redemptions" integer, "p_gold_after_redemptions" integer, "p_platinum_after_redemptions" integer, "p_card_design_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."update_loyalty_program_by_token"("p_token" "text", "p_required_stamps" integer, "p_reward" "text", "p_spend_per_stamp" numeric, "p_fine_print" "text", "p_stamp_icon" "text", "p_stamp_logo_url" "text", "p_card_theme" "text", "p_silver_after_redemptions" integer, "p_gold_after_redemptions" integer, "p_platinum_after_redemptions" integer, "p_card_design_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_loyalty_program_by_token"("p_token" "text", "p_required_stamps" integer, "p_reward" "text", "p_spend_per_stamp" numeric, "p_fine_print" "text", "p_stamp_icon" "text", "p_stamp_logo_url" "text", "p_card_theme" "text", "p_silver_after_redemptions" integer, "p_gold_after_redemptions" integer, "p_platinum_after_redemptions" integer, "p_card_design_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_partner_event"("p_token" "text", "p_title" "text", "p_description" "text", "p_short_description" "text", "p_start_date" "date", "p_end_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_is_all_day" boolean, "p_timezone" "text", "p_venue_name" "text", "p_venue_address" "text", "p_parish" "text", "p_town" "text", "p_country" "text", "p_is_free" boolean, "p_ticket_price_min" numeric, "p_ticket_price_max" numeric, "p_currency" "text", "p_has_online_tickets" boolean, "p_is_sold_out" boolean, "p_ticket_url" "text", "p_capacity" integer, "p_min_age" integer, "p_dress_code" "text", "p_food_available" boolean, "p_alcohol_served" boolean, "p_organizer_name" "text", "p_contact_email" "text", "p_contact_phone" "text", "p_support_email" "text", "p_support_phone" "text", "p_support_url" "text", "p_website_url" "text", "p_instagram_url" "text", "p_featured_image_url" "text", "p_event_type" "text", "p_info_sections" "jsonb", "p_faq" "jsonb", "p_parking_image_url" "text", "p_parking_image_urls" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."update_partner_event"("p_token" "text", "p_title" "text", "p_description" "text", "p_short_description" "text", "p_start_date" "date", "p_end_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_is_all_day" boolean, "p_timezone" "text", "p_venue_name" "text", "p_venue_address" "text", "p_parish" "text", "p_town" "text", "p_country" "text", "p_is_free" boolean, "p_ticket_price_min" numeric, "p_ticket_price_max" numeric, "p_currency" "text", "p_has_online_tickets" boolean, "p_is_sold_out" boolean, "p_ticket_url" "text", "p_capacity" integer, "p_min_age" integer, "p_dress_code" "text", "p_food_available" boolean, "p_alcohol_served" boolean, "p_organizer_name" "text", "p_contact_email" "text", "p_contact_phone" "text", "p_support_email" "text", "p_support_phone" "text", "p_support_url" "text", "p_website_url" "text", "p_instagram_url" "text", "p_featured_image_url" "text", "p_event_type" "text", "p_info_sections" "jsonb", "p_faq" "jsonb", "p_parking_image_url" "text", "p_parking_image_urls" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_partner_event"("p_token" "text", "p_title" "text", "p_description" "text", "p_short_description" "text", "p_start_date" "date", "p_end_date" "date", "p_start_time" time without time zone, "p_end_time" time without time zone, "p_is_all_day" boolean, "p_timezone" "text", "p_venue_name" "text", "p_venue_address" "text", "p_parish" "text", "p_town" "text", "p_country" "text", "p_is_free" boolean, "p_ticket_price_min" numeric, "p_ticket_price_max" numeric, "p_currency" "text", "p_has_online_tickets" boolean, "p_is_sold_out" boolean, "p_ticket_url" "text", "p_capacity" integer, "p_min_age" integer, "p_dress_code" "text", "p_food_available" boolean, "p_alcohol_served" boolean, "p_organizer_name" "text", "p_contact_email" "text", "p_contact_phone" "text", "p_support_email" "text", "p_support_phone" "text", "p_support_url" "text", "p_website_url" "text", "p_instagram_url" "text", "p_featured_image_url" "text", "p_event_type" "text", "p_info_sections" "jsonb", "p_faq" "jsonb", "p_parking_image_url" "text", "p_parking_image_urls" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_partner_hours"("p_token" "text", "p_opening_hours_struct" "jsonb", "p_kitchen_hours_struct" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."update_partner_hours"("p_token" "text", "p_opening_hours_struct" "jsonb", "p_kitchen_hours_struct" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_partner_hours"("p_token" "text", "p_opening_hours_struct" "jsonb", "p_kitchen_hours_struct" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_partner_place_contact"("p_token" "text", "p_phone_number" "text", "p_website" "text", "p_instagram_url" "text", "p_menu_link" "text", "p_booking_link" "text", "p_booking_contact_email" "text", "p_bookings_email" "text", "p_day_pass_link" "text", "p_day_pass_notes" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."update_partner_place_contact"("p_token" "text", "p_phone_number" "text", "p_website" "text", "p_instagram_url" "text", "p_menu_link" "text", "p_booking_link" "text", "p_booking_contact_email" "text", "p_bookings_email" "text", "p_day_pass_link" "text", "p_day_pass_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_partner_place_contact"("p_token" "text", "p_phone_number" "text", "p_website" "text", "p_instagram_url" "text", "p_menu_link" "text", "p_booking_link" "text", "p_booking_contact_email" "text", "p_bookings_email" "text", "p_day_pass_link" "text", "p_day_pass_notes" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_partner_special"("p_token" "text", "p_special_id" "uuid", "p_title" "text", "p_description" "text", "p_special_type" "text", "p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_start_time" time without time zone, "p_end_time" time without time zone, "p_image_url" "text", "p_discount_percentage" numeric, "p_discount_amount" numeric, "p_price_amount" numeric, "p_currency" "text", "p_event_category" "text", "p_tags" "text"[], "p_capacity" integer, "p_recurring_days" "text"[], "p_age_restriction" "text", "p_host_name" "text", "p_event_slug" "text", "p_ticket_link" "text", "p_rsvp_link" "text", "p_clear_capacity" boolean, "p_clear_image" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."update_partner_special"("p_token" "text", "p_special_id" "uuid", "p_title" "text", "p_description" "text", "p_special_type" "text", "p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_start_time" time without time zone, "p_end_time" time without time zone, "p_image_url" "text", "p_discount_percentage" numeric, "p_discount_amount" numeric, "p_price_amount" numeric, "p_currency" "text", "p_event_category" "text", "p_tags" "text"[], "p_capacity" integer, "p_recurring_days" "text"[], "p_age_restriction" "text", "p_host_name" "text", "p_event_slug" "text", "p_ticket_link" "text", "p_rsvp_link" "text", "p_clear_capacity" boolean, "p_clear_image" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_partner_special"("p_token" "text", "p_special_id" "uuid", "p_title" "text", "p_description" "text", "p_special_type" "text", "p_start_date" timestamp with time zone, "p_end_date" timestamp with time zone, "p_start_time" time without time zone, "p_end_time" time without time zone, "p_image_url" "text", "p_discount_percentage" numeric, "p_discount_amount" numeric, "p_price_amount" numeric, "p_currency" "text", "p_event_category" "text", "p_tags" "text"[], "p_capacity" integer, "p_recurring_days" "text"[], "p_age_restriction" "text", "p_host_name" "text", "p_event_slug" "text", "p_ticket_link" "text", "p_rsvp_link" "text", "p_clear_capacity" boolean, "p_clear_image" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."update_place_ranks"("payload" "jsonb") TO "anon";
GRANT ALL ON FUNCTION "public"."update_place_ranks"("payload" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_place_ranks"("payload" "jsonb") TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_updated_at_column"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_user_stats_from_all"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_user_stats_from_all"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_user_stats_from_all"() TO "service_role";



GRANT ALL ON FUNCTION "public"."update_visited_feedback_timestamp"() TO "anon";
GRANT ALL ON FUNCTION "public"."update_visited_feedback_timestamp"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."update_visited_feedback_timestamp"() TO "service_role";



GRANT ALL ON FUNCTION "public"."upsert_checkin_settings_by_partner_token"("p_token" "text", "p_checkin_enabled" boolean, "p_nfc_enabled" boolean, "p_qr_enabled" boolean, "p_manual_code_enabled" boolean, "p_in_app_checkin_enabled" boolean, "p_requires_proximity" boolean, "p_xp_enabled" boolean, "p_loyalty_enabled" boolean, "p_cooldown_minutes" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_checkin_settings_by_partner_token"("p_token" "text", "p_checkin_enabled" boolean, "p_nfc_enabled" boolean, "p_qr_enabled" boolean, "p_manual_code_enabled" boolean, "p_in_app_checkin_enabled" boolean, "p_requires_proximity" boolean, "p_xp_enabled" boolean, "p_loyalty_enabled" boolean, "p_cooldown_minutes" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_checkin_settings_by_partner_token"("p_token" "text", "p_checkin_enabled" boolean, "p_nfc_enabled" boolean, "p_qr_enabled" boolean, "p_manual_code_enabled" boolean, "p_in_app_checkin_enabled" boolean, "p_requires_proximity" boolean, "p_xp_enabled" boolean, "p_loyalty_enabled" boolean, "p_cooldown_minutes" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."upsert_event_sponsor"("p_token" "text", "p_event_sponsor_id" "uuid", "p_sponsor_name" "text", "p_tier" "text", "p_display_tier_label" "text", "p_custom_tagline" "text", "p_logo_url" "text", "p_website" "text", "p_instagram" "text", "p_is_featured" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_event_sponsor"("p_token" "text", "p_event_sponsor_id" "uuid", "p_sponsor_name" "text", "p_tier" "text", "p_display_tier_label" "text", "p_custom_tagline" "text", "p_logo_url" "text", "p_website" "text", "p_instagram" "text", "p_is_featured" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_event_sponsor"("p_token" "text", "p_event_sponsor_id" "uuid", "p_sponsor_name" "text", "p_tier" "text", "p_display_tier_label" "text", "p_custom_tagline" "text", "p_logo_url" "text", "p_website" "text", "p_instagram" "text", "p_is_featured" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."upsert_event_vendor"("p_token" "text", "p_event_vendor_id" "uuid", "p_vendor_id" "uuid", "p_vendor_name" "text", "p_booth_number" "text", "p_vendor_type" "text", "p_vendor_description" "text", "p_is_featured" boolean, "p_zone" "text", "p_filter_tags" "text"[]) TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_event_vendor"("p_token" "text", "p_event_vendor_id" "uuid", "p_vendor_id" "uuid", "p_vendor_name" "text", "p_booth_number" "text", "p_vendor_type" "text", "p_vendor_description" "text", "p_is_featured" boolean, "p_zone" "text", "p_filter_tags" "text"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_event_vendor"("p_token" "text", "p_event_vendor_id" "uuid", "p_vendor_id" "uuid", "p_vendor_name" "text", "p_booth_number" "text", "p_vendor_type" "text", "p_vendor_description" "text", "p_is_featured" boolean, "p_zone" "text", "p_filter_tags" "text"[]) TO "service_role";



GRANT ALL ON FUNCTION "public"."upsert_insider_settings_by_partner_token"("p_token" "text", "p_guest_min" integer, "p_familiar_face_min" integer, "p_regular_min" integer, "p_house_favourite_min" integer) TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_insider_settings_by_partner_token"("p_token" "text", "p_guest_min" integer, "p_familiar_face_min" integer, "p_regular_min" integer, "p_house_favourite_min" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_insider_settings_by_partner_token"("p_token" "text", "p_guest_min" integer, "p_familiar_face_min" integer, "p_regular_min" integer, "p_house_favourite_min" integer) TO "service_role";



GRANT ALL ON FUNCTION "public"."upsert_partner_closure"("p_token" "text", "p_date" "date", "p_is_closed" boolean, "p_open_time" time without time zone, "p_close_time" time without time zone, "p_kitchen_open" time without time zone, "p_kitchen_close" time without time zone, "p_reason" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_partner_closure"("p_token" "text", "p_date" "date", "p_is_closed" boolean, "p_open_time" time without time zone, "p_close_time" time without time zone, "p_kitchen_open" time without time zone, "p_kitchen_close" time without time zone, "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_partner_closure"("p_token" "text", "p_date" "date", "p_is_closed" boolean, "p_open_time" time without time zone, "p_close_time" time without time zone, "p_kitchen_open" time without time zone, "p_kitchen_close" time without time zone, "p_reason" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."upsert_perk_by_partner_token"("p_token" "text", "p_perk_id" "uuid", "p_title" "text", "p_description" "text", "p_required_tier" "text", "p_perk_type" "text", "p_redemption_limit" integer, "p_active" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_perk_by_partner_token"("p_token" "text", "p_perk_id" "uuid", "p_title" "text", "p_description" "text", "p_required_tier" "text", "p_perk_type" "text", "p_redemption_limit" integer, "p_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_perk_by_partner_token"("p_token" "text", "p_perk_id" "uuid", "p_title" "text", "p_description" "text", "p_required_tier" "text", "p_perk_type" "text", "p_redemption_limit" integer, "p_active" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."upsert_schedule_day"("p_token" "text", "p_id" "uuid", "p_date" "date", "p_label" "text", "p_description" "text", "p_gates_open" time without time zone, "p_gates_close" time without time zone, "p_is_cancelled" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_schedule_day"("p_token" "text", "p_id" "uuid", "p_date" "date", "p_label" "text", "p_description" "text", "p_gates_open" time without time zone, "p_gates_close" time without time zone, "p_is_cancelled" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_schedule_day"("p_token" "text", "p_id" "uuid", "p_date" "date", "p_label" "text", "p_description" "text", "p_gates_open" time without time zone, "p_gates_close" time without time zone, "p_is_cancelled" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."upsert_schedule_item"("p_token" "text", "p_id" "uuid", "p_day_id" "uuid", "p_title" "text", "p_subtitle" "text", "p_start_time" timestamp with time zone, "p_end_time" timestamp with time zone, "p_venue_override" "text", "p_category" "text", "p_image_url" "text", "p_is_featured" boolean, "p_is_must_see" boolean, "p_is_published" boolean) TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_schedule_item"("p_token" "text", "p_id" "uuid", "p_day_id" "uuid", "p_title" "text", "p_subtitle" "text", "p_start_time" timestamp with time zone, "p_end_time" timestamp with time zone, "p_venue_override" "text", "p_category" "text", "p_image_url" "text", "p_is_featured" boolean, "p_is_must_see" boolean, "p_is_published" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_schedule_item"("p_token" "text", "p_id" "uuid", "p_day_id" "uuid", "p_title" "text", "p_subtitle" "text", "p_start_time" timestamp with time zone, "p_end_time" timestamp with time zone, "p_venue_override" "text", "p_category" "text", "p_image_url" "text", "p_is_featured" boolean, "p_is_must_see" boolean, "p_is_published" boolean) TO "service_role";



GRANT ALL ON FUNCTION "public"."upsert_ticket_location"("p_token" "text", "p_id" "uuid", "p_name" "text", "p_is_online" boolean, "p_ticket_url" "text", "p_provider_type" "text", "p_address" "text", "p_town" "text", "p_parish" "text", "p_contact_phone" "text", "p_opening_hours" "text", "p_latitude" double precision, "p_longitude" double precision, "p_place_slug" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_ticket_location"("p_token" "text", "p_id" "uuid", "p_name" "text", "p_is_online" boolean, "p_ticket_url" "text", "p_provider_type" "text", "p_address" "text", "p_town" "text", "p_parish" "text", "p_contact_phone" "text", "p_opening_hours" "text", "p_latitude" double precision, "p_longitude" double precision, "p_place_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_ticket_location"("p_token" "text", "p_id" "uuid", "p_name" "text", "p_is_online" boolean, "p_ticket_url" "text", "p_provider_type" "text", "p_address" "text", "p_town" "text", "p_parish" "text", "p_contact_phone" "text", "p_opening_hours" "text", "p_latitude" double precision, "p_longitude" double precision, "p_place_slug" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."upsert_transport_route"("p_token" "text", "p_id" "uuid", "p_name" "text", "p_color" "text", "p_direction" "text", "p_frequency" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."upsert_transport_route"("p_token" "text", "p_id" "uuid", "p_name" "text", "p_color" "text", "p_direction" "text", "p_frequency" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."upsert_transport_route"("p_token" "text", "p_id" "uuid", "p_name" "text", "p_color" "text", "p_direction" "text", "p_frequency" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."validate_place_slug"("p_slug" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."validate_place_slug"("p_slug" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."validate_place_slug"("p_slug" "text") TO "service_role";



GRANT ALL ON FUNCTION "public"."vote_change_request"("_request_id" "uuid", "_vote" "text") TO "anon";
GRANT ALL ON FUNCTION "public"."vote_change_request"("_request_id" "uuid", "_vote" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."vote_change_request"("_request_id" "uuid", "_vote" "text") TO "service_role";












GRANT ALL ON FUNCTION "public"."max"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."max"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."max"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."max"("public"."citext") TO "service_role";



GRANT ALL ON FUNCTION "public"."min"("public"."citext") TO "postgres";
GRANT ALL ON FUNCTION "public"."min"("public"."citext") TO "anon";
GRANT ALL ON FUNCTION "public"."min"("public"."citext") TO "authenticated";
GRANT ALL ON FUNCTION "public"."min"("public"."citext") TO "service_role";















GRANT ALL ON TABLE "public"."achievements" TO "anon";
GRANT ALL ON TABLE "public"."achievements" TO "authenticated";
GRANT ALL ON TABLE "public"."achievements" TO "service_role";



GRANT ALL ON TABLE "public"."event_sponsor_activations" TO "anon";
GRANT ALL ON TABLE "public"."event_sponsor_activations" TO "authenticated";
GRANT ALL ON TABLE "public"."event_sponsor_activations" TO "service_role";



GRANT ALL ON TABLE "public"."sponsors" TO "anon";
GRANT ALL ON TABLE "public"."sponsors" TO "authenticated";
GRANT ALL ON TABLE "public"."sponsors" TO "service_role";



GRANT ALL ON TABLE "public"."user_event_activity" TO "anon";
GRANT ALL ON TABLE "public"."user_event_activity" TO "authenticated";
GRANT ALL ON TABLE "public"."user_event_activity" TO "service_role";



GRANT ALL ON TABLE "public"."activation_funnel" TO "anon";
GRANT ALL ON TABLE "public"."activation_funnel" TO "authenticated";
GRANT ALL ON TABLE "public"."activation_funnel" TO "service_role";



GRANT ALL ON TABLE "public"."admin_tokens" TO "anon";
GRANT ALL ON TABLE "public"."admin_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."admin_tokens" TO "service_role";



GRANT ALL ON TABLE "public"."alerts" TO "anon";
GRANT ALL ON TABLE "public"."alerts" TO "authenticated";
GRANT ALL ON TABLE "public"."alerts" TO "service_role";



GRANT ALL ON TABLE "public"."analytics_events" TO "anon";
GRANT ALL ON TABLE "public"."analytics_events" TO "authenticated";
GRANT ALL ON TABLE "public"."analytics_events" TO "service_role";



GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."app_config" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."app_config" TO "authenticated";
GRANT ALL ON TABLE "public"."app_config" TO "service_role";



GRANT ALL ON TABLE "public"."app_settings" TO "anon";
GRANT ALL ON TABLE "public"."app_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."app_settings" TO "service_role";



GRANT ALL ON TABLE "public"."bands" TO "anon";
GRANT ALL ON TABLE "public"."bands" TO "authenticated";
GRANT ALL ON TABLE "public"."bands" TO "service_role";



GRANT ALL ON TABLE "public"."billing_accounts" TO "anon";
GRANT ALL ON TABLE "public"."billing_accounts" TO "authenticated";
GRANT ALL ON TABLE "public"."billing_accounts" TO "service_role";



GRANT ALL ON TABLE "public"."billing_audit_log" TO "anon";
GRANT ALL ON TABLE "public"."billing_audit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."billing_audit_log" TO "service_role";



GRANT ALL ON TABLE "public"."billing_notifications" TO "anon";
GRANT ALL ON TABLE "public"."billing_notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."billing_notifications" TO "service_role";



GRANT ALL ON TABLE "public"."billing_products" TO "anon";
GRANT ALL ON TABLE "public"."billing_products" TO "authenticated";
GRANT ALL ON TABLE "public"."billing_products" TO "service_role";



GRANT ALL ON TABLE "public"."billing_settings" TO "anon";
GRANT ALL ON TABLE "public"."billing_settings" TO "authenticated";
GRANT ALL ON TABLE "public"."billing_settings" TO "service_role";



GRANT ALL ON TABLE "public"."billing_usage" TO "anon";
GRANT ALL ON TABLE "public"."billing_usage" TO "authenticated";
GRANT ALL ON TABLE "public"."billing_usage" TO "service_role";



GRANT ALL ON TABLE "public"."booking_cancellation_policies" TO "anon";
GRANT ALL ON TABLE "public"."booking_cancellation_policies" TO "authenticated";
GRANT ALL ON TABLE "public"."booking_cancellation_policies" TO "service_role";



GRANT ALL ON TABLE "public"."booking_notification_logs" TO "anon";
GRANT ALL ON TABLE "public"."booking_notification_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."booking_notification_logs" TO "service_role";



GRANT ALL ON TABLE "public"."booking_room_allocations" TO "anon";
GRANT ALL ON TABLE "public"."booking_room_allocations" TO "authenticated";
GRANT ALL ON TABLE "public"."booking_room_allocations" TO "service_role";



GRANT ALL ON TABLE "public"."booking_timeline_events" TO "anon";
GRANT ALL ON TABLE "public"."booking_timeline_events" TO "authenticated";
GRANT ALL ON TABLE "public"."booking_timeline_events" TO "service_role";



GRANT ALL ON TABLE "public"."businesses" TO "anon";
GRANT ALL ON TABLE "public"."businesses" TO "authenticated";
GRANT ALL ON TABLE "public"."businesses" TO "service_role";



GRANT ALL ON TABLE "public"."company_accounts" TO "anon";
GRANT ALL ON TABLE "public"."company_accounts" TO "authenticated";
GRANT ALL ON TABLE "public"."company_accounts" TO "service_role";



GRANT ALL ON TABLE "public"."company_entitlements" TO "anon";
GRANT ALL ON TABLE "public"."company_entitlements" TO "authenticated";
GRANT ALL ON TABLE "public"."company_entitlements" TO "service_role";



GRANT ALL ON TABLE "public"."company_events" TO "anon";
GRANT ALL ON TABLE "public"."company_events" TO "authenticated";
GRANT ALL ON TABLE "public"."company_events" TO "service_role";



GRANT ALL ON TABLE "public"."company_locations" TO "anon";
GRANT ALL ON TABLE "public"."company_locations" TO "authenticated";
GRANT ALL ON TABLE "public"."company_locations" TO "service_role";



GRANT ALL ON TABLE "public"."company_onboarding_invites" TO "anon";
GRANT ALL ON TABLE "public"."company_onboarding_invites" TO "authenticated";
GRANT ALL ON TABLE "public"."company_onboarding_invites" TO "service_role";



GRANT ALL ON TABLE "public"."company_requests" TO "anon";
GRANT ALL ON TABLE "public"."company_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."company_requests" TO "service_role";



GRANT ALL ON TABLE "public"."company_setup_requests" TO "anon";
GRANT ALL ON TABLE "public"."company_setup_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."company_setup_requests" TO "service_role";



GRANT ALL ON TABLE "public"."dish_likes" TO "anon";
GRANT ALL ON TABLE "public"."dish_likes" TO "authenticated";
GRANT ALL ON TABLE "public"."dish_likes" TO "service_role";



GRANT ALL ON TABLE "public"."entitlement_definitions" TO "anon";
GRANT ALL ON TABLE "public"."entitlement_definitions" TO "authenticated";
GRANT ALL ON TABLE "public"."entitlement_definitions" TO "service_role";



GRANT ALL ON TABLE "public"."event_activation_summary" TO "anon";
GRANT ALL ON TABLE "public"."event_activation_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."event_activation_summary" TO "service_role";



GRANT ALL ON TABLE "public"."event_analytics" TO "anon";
GRANT ALL ON TABLE "public"."event_analytics" TO "authenticated";
GRANT ALL ON TABLE "public"."event_analytics" TO "service_role";



GRANT ALL ON TABLE "public"."event_analytics_events" TO "anon";
GRANT ALL ON TABLE "public"."event_analytics_events" TO "authenticated";
GRANT ALL ON TABLE "public"."event_analytics_events" TO "service_role";



GRANT ALL ON TABLE "public"."event_analytics_rollup" TO "anon";
GRANT ALL ON TABLE "public"."event_analytics_rollup" TO "authenticated";
GRANT ALL ON TABLE "public"."event_analytics_rollup" TO "service_role";



GRANT ALL ON TABLE "public"."event_bands" TO "anon";
GRANT ALL ON TABLE "public"."event_bands" TO "authenticated";
GRANT ALL ON TABLE "public"."event_bands" TO "service_role";



GRANT ALL ON TABLE "public"."event_interests" TO "anon";
GRANT ALL ON TABLE "public"."event_interests" TO "authenticated";
GRANT ALL ON TABLE "public"."event_interests" TO "service_role";



GRANT ALL ON TABLE "public"."event_map_invites" TO "anon";
GRANT ALL ON TABLE "public"."event_map_invites" TO "authenticated";
GRANT ALL ON TABLE "public"."event_map_invites" TO "service_role";



GRANT ALL ON TABLE "public"."event_map_points" TO "anon";
GRANT ALL ON TABLE "public"."event_map_points" TO "authenticated";
GRANT ALL ON TABLE "public"."event_map_points" TO "service_role";



GRANT ALL ON TABLE "public"."event_notification_deliveries" TO "anon";
GRANT ALL ON TABLE "public"."event_notification_deliveries" TO "authenticated";
GRANT ALL ON TABLE "public"."event_notification_deliveries" TO "service_role";



GRANT ALL ON TABLE "public"."event_partner_submission_assets" TO "anon";
GRANT ALL ON TABLE "public"."event_partner_submission_assets" TO "authenticated";
GRANT ALL ON TABLE "public"."event_partner_submission_assets" TO "service_role";



GRANT ALL ON TABLE "public"."event_partner_submissions" TO "anon";
GRANT ALL ON TABLE "public"."event_partner_submissions" TO "authenticated";
GRANT ALL ON TABLE "public"."event_partner_submissions" TO "service_role";



GRANT ALL ON TABLE "public"."event_partner_submission_summary" TO "anon";
GRANT ALL ON TABLE "public"."event_partner_submission_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."event_partner_submission_summary" TO "service_role";



GRANT ALL ON TABLE "public"."event_push_notifications" TO "anon";
GRANT ALL ON TABLE "public"."event_push_notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."event_push_notifications" TO "service_role";



GRANT ALL ON TABLE "public"."events" TO "anon";
GRANT ALL ON TABLE "public"."events" TO "authenticated";
GRANT ALL ON TABLE "public"."events" TO "service_role";



GRANT ALL ON TABLE "public"."event_retention_30d" TO "anon";
GRANT ALL ON TABLE "public"."event_retention_30d" TO "authenticated";
GRANT ALL ON TABLE "public"."event_retention_30d" TO "service_role";



GRANT ALL ON TABLE "public"."event_schedule_days" TO "anon";
GRANT ALL ON TABLE "public"."event_schedule_days" TO "authenticated";
GRANT ALL ON TABLE "public"."event_schedule_days" TO "service_role";



GRANT ALL ON TABLE "public"."event_schedule_items" TO "anon";
GRANT ALL ON TABLE "public"."event_schedule_items" TO "authenticated";
GRANT ALL ON TABLE "public"."event_schedule_items" TO "service_role";



GRANT ALL ON TABLE "public"."event_schedule_meta" TO "anon";
GRANT ALL ON TABLE "public"."event_schedule_meta" TO "authenticated";
GRANT ALL ON TABLE "public"."event_schedule_meta" TO "service_role";



GRANT ALL ON TABLE "public"."event_schedule_tracks" TO "anon";
GRANT ALL ON TABLE "public"."event_schedule_tracks" TO "authenticated";
GRANT ALL ON TABLE "public"."event_schedule_tracks" TO "service_role";



GRANT ALL ON TABLE "public"."event_series_rollup" TO "anon";
GRANT ALL ON TABLE "public"."event_series_rollup" TO "authenticated";
GRANT ALL ON TABLE "public"."event_series_rollup" TO "service_role";



GRANT ALL ON TABLE "public"."event_sponsors" TO "anon";
GRANT ALL ON TABLE "public"."event_sponsors" TO "authenticated";
GRANT ALL ON TABLE "public"."event_sponsors" TO "service_role";



GRANT ALL ON TABLE "public"."event_transport_routes" TO "anon";
GRANT ALL ON TABLE "public"."event_transport_routes" TO "authenticated";
GRANT ALL ON TABLE "public"."event_transport_routes" TO "service_role";



GRANT ALL ON TABLE "public"."event_transport_stops" TO "anon";
GRANT ALL ON TABLE "public"."event_transport_stops" TO "authenticated";
GRANT ALL ON TABLE "public"."event_transport_stops" TO "service_role";



GRANT ALL ON TABLE "public"."event_transport_times" TO "anon";
GRANT ALL ON TABLE "public"."event_transport_times" TO "authenticated";
GRANT ALL ON TABLE "public"."event_transport_times" TO "service_role";



GRANT ALL ON TABLE "public"."event_updates" TO "anon";
GRANT ALL ON TABLE "public"."event_updates" TO "authenticated";
GRANT ALL ON TABLE "public"."event_updates" TO "service_role";



GRANT ALL ON TABLE "public"."event_vendors" TO "anon";
GRANT ALL ON TABLE "public"."event_vendors" TO "authenticated";
GRANT ALL ON TABLE "public"."event_vendors" TO "service_role";



GRANT ALL ON TABLE "public"."vendor_menu_items" TO "anon";
GRANT ALL ON TABLE "public"."vendor_menu_items" TO "authenticated";
GRANT ALL ON TABLE "public"."vendor_menu_items" TO "service_role";



GRANT ALL ON TABLE "public"."vendors" TO "anon";
GRANT ALL ON TABLE "public"."vendors" TO "authenticated";
GRANT ALL ON TABLE "public"."vendors" TO "service_role";



GRANT ALL ON TABLE "public"."event_vendors_with_menu" TO "anon";
GRANT ALL ON TABLE "public"."event_vendors_with_menu" TO "authenticated";
GRANT ALL ON TABLE "public"."event_vendors_with_menu" TO "service_role";



GRANT ALL ON TABLE "public"."favorites" TO "anon";
GRANT ALL ON TABLE "public"."favorites" TO "authenticated";
GRANT ALL ON TABLE "public"."favorites" TO "service_role";



GRANT ALL ON TABLE "public"."favourite_guides" TO "anon";
GRANT ALL ON TABLE "public"."favourite_guides" TO "authenticated";
GRANT ALL ON TABLE "public"."favourite_guides" TO "service_role";



GRANT ALL ON TABLE "public"."specials" TO "anon";
GRANT ALL ON TABLE "public"."specials" TO "authenticated";
GRANT ALL ON TABLE "public"."specials" TO "service_role";



GRANT ALL ON TABLE "public"."visited" TO "anon";
GRANT ALL ON TABLE "public"."visited" TO "authenticated";
GRANT ALL ON TABLE "public"."visited" TO "service_role";



GRANT ALL ON TABLE "public"."user_visit_counts" TO "anon";
GRANT ALL ON TABLE "public"."user_visit_counts" TO "authenticated";
GRANT ALL ON TABLE "public"."user_visit_counts" TO "service_role";



GRANT ALL ON TABLE "public"."featured_places" TO "anon";
GRANT ALL ON TABLE "public"."featured_places" TO "authenticated";
GRANT ALL ON TABLE "public"."featured_places" TO "service_role";



GRANT ALL ON TABLE "public"."feedback" TO "anon";
GRANT ALL ON TABLE "public"."feedback" TO "authenticated";
GRANT ALL ON TABLE "public"."feedback" TO "service_role";



GRANT ALL ON TABLE "public"."feedback_sorted" TO "anon";
GRANT ALL ON TABLE "public"."feedback_sorted" TO "authenticated";
GRANT ALL ON TABLE "public"."feedback_sorted" TO "service_role";



GRANT ALL ON TABLE "public"."guide_analytics" TO "anon";
GRANT ALL ON TABLE "public"."guide_analytics" TO "authenticated";
GRANT ALL ON TABLE "public"."guide_analytics" TO "service_role";



GRANT ALL ON TABLE "public"."guide_route_steps" TO "anon";
GRANT ALL ON TABLE "public"."guide_route_steps" TO "authenticated";
GRANT ALL ON TABLE "public"."guide_route_steps" TO "service_role";



GRANT ALL ON TABLE "public"."guide_spots" TO "anon";
GRANT ALL ON TABLE "public"."guide_spots" TO "authenticated";
GRANT ALL ON TABLE "public"."guide_spots" TO "service_role";



GRANT ALL ON TABLE "public"."guides" TO "anon";
GRANT ALL ON TABLE "public"."guides" TO "authenticated";
GRANT ALL ON TABLE "public"."guides" TO "service_role";



GRANT ALL ON TABLE "public"."hotel_availability" TO "anon";
GRANT ALL ON TABLE "public"."hotel_availability" TO "authenticated";
GRANT ALL ON TABLE "public"."hotel_availability" TO "service_role";



GRANT ALL ON TABLE "public"."hotel_inventory_holds" TO "anon";
GRANT ALL ON TABLE "public"."hotel_inventory_holds" TO "authenticated";
GRANT ALL ON TABLE "public"."hotel_inventory_holds" TO "service_role";



GRANT ALL ON TABLE "public"."hotel_rate_plans" TO "anon";
GRANT ALL ON TABLE "public"."hotel_rate_plans" TO "authenticated";
GRANT ALL ON TABLE "public"."hotel_rate_plans" TO "service_role";



GRANT ALL ON TABLE "public"."hotel_room_types" TO "anon";
GRANT ALL ON TABLE "public"."hotel_room_types" TO "authenticated";
GRANT ALL ON TABLE "public"."hotel_room_types" TO "service_role";



GRANT ALL ON TABLE "public"."invoice_counters" TO "anon";
GRANT ALL ON TABLE "public"."invoice_counters" TO "authenticated";
GRANT ALL ON TABLE "public"."invoice_counters" TO "service_role";



GRANT ALL ON TABLE "public"."invoice_line_items" TO "anon";
GRANT ALL ON TABLE "public"."invoice_line_items" TO "authenticated";
GRANT ALL ON TABLE "public"."invoice_line_items" TO "service_role";



GRANT ALL ON TABLE "public"."invoices" TO "anon";
GRANT ALL ON TABLE "public"."invoices" TO "authenticated";
GRANT ALL ON TABLE "public"."invoices" TO "service_role";



GRANT ALL ON TABLE "public"."itineraries" TO "authenticated";
GRANT ALL ON TABLE "public"."itineraries" TO "service_role";



GRANT ALL ON TABLE "public"."itinerary_events" TO "anon";
GRANT ALL ON TABLE "public"."itinerary_events" TO "authenticated";
GRANT ALL ON TABLE "public"."itinerary_events" TO "service_role";



GRANT ALL ON TABLE "public"."itinerary_places" TO "authenticated";
GRANT ALL ON TABLE "public"."itinerary_places" TO "service_role";



GRANT ALL ON TABLE "public"."itinerary_shares" TO "authenticated";
GRANT ALL ON TABLE "public"."itinerary_shares" TO "service_role";



GRANT ALL ON TABLE "public"."loyalty_program_locations" TO "anon";
GRANT ALL ON TABLE "public"."loyalty_program_locations" TO "authenticated";
GRANT ALL ON TABLE "public"."loyalty_program_locations" TO "service_role";



GRANT ALL ON TABLE "public"."loyalty_redemptions" TO "anon";
GRANT ALL ON TABLE "public"."loyalty_redemptions" TO "authenticated";
GRANT ALL ON TABLE "public"."loyalty_redemptions" TO "service_role";



GRANT ALL ON TABLE "public"."loyalty_visits" TO "anon";
GRANT ALL ON TABLE "public"."loyalty_visits" TO "authenticated";
GRANT ALL ON TABLE "public"."loyalty_visits" TO "service_role";



GRANT ALL ON TABLE "public"."mas_bands" TO "anon";
GRANT ALL ON TABLE "public"."mas_bands" TO "authenticated";
GRANT ALL ON TABLE "public"."mas_bands" TO "service_role";



GRANT ALL ON TABLE "public"."member_perks" TO "anon";
GRANT ALL ON TABLE "public"."member_perks" TO "authenticated";
GRANT ALL ON TABLE "public"."member_perks" TO "service_role";



GRANT ALL ON TABLE "public"."menu_items" TO "anon";
GRANT ALL ON TABLE "public"."menu_items" TO "authenticated";
GRANT ALL ON TABLE "public"."menu_items" TO "service_role";



GRANT ALL ON TABLE "public"."nfc_tags" TO "anon";
GRANT ALL ON TABLE "public"."nfc_tags" TO "authenticated";
GRANT ALL ON TABLE "public"."nfc_tags" TO "service_role";



GRANT ALL ON TABLE "public"."notification_log" TO "anon";
GRANT ALL ON TABLE "public"."notification_log" TO "authenticated";
GRANT ALL ON TABLE "public"."notification_log" TO "service_role";



GRANT ALL ON TABLE "public"."organizers" TO "anon";
GRANT ALL ON TABLE "public"."organizers" TO "authenticated";
GRANT ALL ON TABLE "public"."organizers" TO "service_role";



GRANT ALL ON TABLE "public"."partner_messages" TO "anon";
GRANT ALL ON TABLE "public"."partner_messages" TO "authenticated";
GRANT ALL ON TABLE "public"."partner_messages" TO "service_role";



GRANT ALL ON TABLE "public"."partners" TO "anon";
GRANT ALL ON TABLE "public"."partners" TO "authenticated";
GRANT ALL ON TABLE "public"."partners" TO "service_role";



GRANT ALL ON TABLE "public"."passport_entries" TO "anon";
GRANT ALL ON TABLE "public"."passport_entries" TO "authenticated";
GRANT ALL ON TABLE "public"."passport_entries" TO "service_role";



GRANT ALL ON TABLE "public"."payment_confirmations" TO "anon";
GRANT ALL ON TABLE "public"."payment_confirmations" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_confirmations" TO "service_role";



GRANT ALL ON TABLE "public"."payment_instructions" TO "anon";
GRANT ALL ON TABLE "public"."payment_instructions" TO "authenticated";
GRANT ALL ON TABLE "public"."payment_instructions" TO "service_role";



GRANT ALL ON TABLE "public"."performer_group_members" TO "anon";
GRANT ALL ON TABLE "public"."performer_group_members" TO "authenticated";
GRANT ALL ON TABLE "public"."performer_group_members" TO "service_role";



GRANT ALL ON TABLE "public"."performer_schedule" TO "anon";
GRANT ALL ON TABLE "public"."performer_schedule" TO "authenticated";
GRANT ALL ON TABLE "public"."performer_schedule" TO "service_role";



GRANT ALL ON TABLE "public"."performers" TO "anon";
GRANT ALL ON TABLE "public"."performers" TO "authenticated";
GRANT ALL ON TABLE "public"."performers" TO "service_role";



GRANT ALL ON TABLE "public"."place_analytics" TO "anon";
GRANT ALL ON TABLE "public"."place_analytics" TO "authenticated";
GRANT ALL ON TABLE "public"."place_analytics" TO "service_role";



GRANT ALL ON TABLE "public"."visited_feedback" TO "anon";
GRANT ALL ON TABLE "public"."visited_feedback" TO "authenticated";
GRANT ALL ON TABLE "public"."visited_feedback" TO "service_role";



GRANT ALL ON TABLE "public"."place_sentiment_summary" TO "anon";
GRANT ALL ON TABLE "public"."place_sentiment_summary" TO "authenticated";
GRANT ALL ON TABLE "public"."place_sentiment_summary" TO "service_role";



GRANT ALL ON TABLE "public"."place_special_hours" TO "anon";
GRANT ALL ON TABLE "public"."place_special_hours" TO "authenticated";
GRANT ALL ON TABLE "public"."place_special_hours" TO "service_role";



GRANT ALL ON TABLE "public"."place_specials" TO "anon";
GRANT ALL ON TABLE "public"."place_specials" TO "authenticated";
GRANT ALL ON TABLE "public"."place_specials" TO "service_role";



GRANT ALL ON TABLE "public"."place_visit_events" TO "anon";
GRANT ALL ON TABLE "public"."place_visit_events" TO "authenticated";
GRANT ALL ON TABLE "public"."place_visit_events" TO "service_role";



GRANT ALL ON SEQUENCE "public"."place_visit_events_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."place_visit_events_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."place_visit_events_id_seq" TO "service_role";



GRANT ALL ON TABLE "public"."push_tokens" TO "anon";
GRANT ALL ON TABLE "public"."push_tokens" TO "authenticated";
GRANT ALL ON TABLE "public"."push_tokens" TO "service_role";



GRANT ALL ON TABLE "public"."ranking_events" TO "anon";
GRANT ALL ON TABLE "public"."ranking_events" TO "authenticated";
GRANT ALL ON TABLE "public"."ranking_events" TO "service_role";



GRANT ALL ON TABLE "public"."recommended_dishes" TO "anon";
GRANT ALL ON TABLE "public"."recommended_dishes" TO "authenticated";
GRANT ALL ON TABLE "public"."recommended_dishes" TO "service_role";



GRANT ALL ON TABLE "public"."redemption_events" TO "anon";
GRANT ALL ON TABLE "public"."redemption_events" TO "authenticated";
GRANT ALL ON TABLE "public"."redemption_events" TO "service_role";



GRANT ALL ON TABLE "public"."saved_events" TO "anon";
GRANT ALL ON TABLE "public"."saved_events" TO "authenticated";
GRANT ALL ON TABLE "public"."saved_events" TO "service_role";



GRANT ALL ON TABLE "public"."saved_experiences" TO "anon";
GRANT ALL ON TABLE "public"."saved_experiences" TO "authenticated";
GRANT ALL ON TABLE "public"."saved_experiences" TO "service_role";



GRANT ALL ON TABLE "public"."schedule_change_log" TO "anon";
GRANT ALL ON TABLE "public"."schedule_change_log" TO "authenticated";
GRANT ALL ON TABLE "public"."schedule_change_log" TO "service_role";



GRANT ALL ON TABLE "public"."schedule_full" TO "anon";
GRANT ALL ON TABLE "public"."schedule_full" TO "authenticated";
GRANT ALL ON TABLE "public"."schedule_full" TO "service_role";



GRANT ALL ON TABLE "public"."special_analytics" TO "anon";
GRANT ALL ON TABLE "public"."special_analytics" TO "authenticated";
GRANT ALL ON TABLE "public"."special_analytics" TO "service_role";



GRANT ALL ON TABLE "public"."special_interactions" TO "anon";
GRANT ALL ON TABLE "public"."special_interactions" TO "authenticated";
GRANT ALL ON TABLE "public"."special_interactions" TO "service_role";



GRANT ALL ON TABLE "public"."special_community_stats" TO "anon";
GRANT ALL ON TABLE "public"."special_community_stats" TO "authenticated";
GRANT ALL ON TABLE "public"."special_community_stats" TO "service_role";



GRANT ALL ON TABLE "public"."special_visits" TO "anon";
GRANT ALL ON TABLE "public"."special_visits" TO "authenticated";
GRANT ALL ON TABLE "public"."special_visits" TO "service_role";



GRANT ALL ON TABLE "public"."sponsor_activation_funnel" TO "anon";
GRANT ALL ON TABLE "public"."sponsor_activation_funnel" TO "authenticated";
GRANT ALL ON TABLE "public"."sponsor_activation_funnel" TO "service_role";



GRANT ALL ON TABLE "public"."sponsor_analytics_rollup" TO "anon";
GRANT ALL ON TABLE "public"."sponsor_analytics_rollup" TO "authenticated";
GRANT ALL ON TABLE "public"."sponsor_analytics_rollup" TO "service_role";



GRANT ALL ON TABLE "public"."subscription_plans" TO "anon";
GRANT ALL ON TABLE "public"."subscription_plans" TO "authenticated";
GRANT ALL ON TABLE "public"."subscription_plans" TO "service_role";



GRANT ALL ON TABLE "public"."subscriptions" TO "anon";
GRANT ALL ON TABLE "public"."subscriptions" TO "authenticated";
GRANT ALL ON TABLE "public"."subscriptions" TO "service_role";



GRANT ALL ON TABLE "public"."suggested_places" TO "anon";
GRANT ALL ON TABLE "public"."suggested_places" TO "authenticated";
GRANT ALL ON TABLE "public"."suggested_places" TO "service_role";



GRANT ALL ON TABLE "public"."ticket_locations" TO "anon";
GRANT ALL ON TABLE "public"."ticket_locations" TO "authenticated";
GRANT ALL ON TABLE "public"."ticket_locations" TO "service_role";



GRANT ALL ON TABLE "public"."trip_activity" TO "anon";
GRANT ALL ON TABLE "public"."trip_activity" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_activity" TO "service_role";



GRANT ALL ON TABLE "public"."trip_change_requests" TO "anon";
GRANT ALL ON TABLE "public"."trip_change_requests" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_change_requests" TO "service_role";



GRANT ALL ON TABLE "public"."trip_change_votes" TO "anon";
GRANT ALL ON TABLE "public"."trip_change_votes" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_change_votes" TO "service_role";



GRANT ALL ON TABLE "public"."trip_collaborators" TO "anon";
GRANT ALL ON TABLE "public"."trip_collaborators" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_collaborators" TO "service_role";



GRANT ALL ON TABLE "public"."trip_completions" TO "anon";
GRANT ALL ON TABLE "public"."trip_completions" TO "authenticated";
GRANT ALL ON TABLE "public"."trip_completions" TO "service_role";



GRANT ALL ON TABLE "public"."user" TO "anon";
GRANT ALL ON TABLE "public"."user" TO "authenticated";
GRANT ALL ON TABLE "public"."user" TO "service_role";



GRANT ALL ON TABLE "public"."user_achievements" TO "anon";
GRANT ALL ON TABLE "public"."user_achievements" TO "authenticated";
GRANT ALL ON TABLE "public"."user_achievements" TO "service_role";



GRANT ALL ON TABLE "public"."user_checkins" TO "anon";
GRANT ALL ON TABLE "public"."user_checkins" TO "authenticated";
GRANT ALL ON TABLE "public"."user_checkins" TO "service_role";



GRANT ALL ON TABLE "public"."user_event_interactions" TO "anon";
GRANT ALL ON TABLE "public"."user_event_interactions" TO "authenticated";
GRANT ALL ON TABLE "public"."user_event_interactions" TO "service_role";



GRANT ALL ON TABLE "public"."user_favorite_items" TO "anon";
GRANT ALL ON TABLE "public"."user_favorite_items" TO "authenticated";
GRANT ALL ON TABLE "public"."user_favorite_items" TO "service_role";



GRANT ALL ON TABLE "public"."user_item_logs" TO "anon";
GRANT ALL ON TABLE "public"."user_item_logs" TO "authenticated";
GRANT ALL ON TABLE "public"."user_item_logs" TO "service_role";



GRANT ALL ON TABLE "public"."user_loyalty_cards" TO "anon";
GRANT ALL ON TABLE "public"."user_loyalty_cards" TO "authenticated";
GRANT ALL ON TABLE "public"."user_loyalty_cards" TO "service_role";



GRANT ALL ON TABLE "public"."user_month_rankings" TO "anon";
GRANT ALL ON TABLE "public"."user_month_rankings" TO "authenticated";
GRANT ALL ON TABLE "public"."user_month_rankings" TO "service_role";



GRANT ALL ON TABLE "public"."user_place_rankings" TO "anon";
GRANT ALL ON TABLE "public"."user_place_rankings" TO "authenticated";
GRANT ALL ON TABLE "public"."user_place_rankings" TO "service_role";



GRANT ALL ON TABLE "public"."user_place_visit_counts" TO "anon";
GRANT ALL ON TABLE "public"."user_place_visit_counts" TO "authenticated";
GRANT ALL ON TABLE "public"."user_place_visit_counts" TO "service_role";



GRANT ALL ON TABLE "public"."user_saved_menu_items" TO "anon";
GRANT ALL ON TABLE "public"."user_saved_menu_items" TO "authenticated";
GRANT ALL ON TABLE "public"."user_saved_menu_items" TO "service_role";



GRANT ALL ON TABLE "public"."user_saved_schedule_items" TO "anon";
GRANT ALL ON TABLE "public"."user_saved_schedule_items" TO "authenticated";
GRANT ALL ON TABLE "public"."user_saved_schedule_items" TO "service_role";



GRANT ALL ON TABLE "public"."user_schedule_plans" TO "anon";
GRANT ALL ON TABLE "public"."user_schedule_plans" TO "authenticated";
GRANT ALL ON TABLE "public"."user_schedule_plans" TO "service_role";



GRANT ALL ON TABLE "public"."user_stats" TO "anon";
GRANT ALL ON TABLE "public"."user_stats" TO "authenticated";
GRANT ALL ON TABLE "public"."user_stats" TO "service_role";



GRANT ALL ON TABLE "public"."user_tour_progress" TO "anon";
GRANT ALL ON TABLE "public"."user_tour_progress" TO "authenticated";
GRANT ALL ON TABLE "public"."user_tour_progress" TO "service_role";



GRANT ALL ON TABLE "public"."user_vendor_item_ratings" TO "anon";
GRANT ALL ON TABLE "public"."user_vendor_item_ratings" TO "authenticated";
GRANT ALL ON TABLE "public"."user_vendor_item_ratings" TO "service_role";



GRANT ALL ON TABLE "public"."xp_transactions" TO "anon";
GRANT ALL ON TABLE "public"."xp_transactions" TO "authenticated";
GRANT ALL ON TABLE "public"."xp_transactions" TO "service_role";



GRANT ALL ON TABLE "public"."user_xp_totals" TO "anon";
GRANT ALL ON TABLE "public"."user_xp_totals" TO "authenticated";
GRANT ALL ON TABLE "public"."user_xp_totals" TO "service_role";



GRANT ALL ON TABLE "public"."vibe_tags" TO "anon";
GRANT ALL ON TABLE "public"."vibe_tags" TO "authenticated";
GRANT ALL ON TABLE "public"."vibe_tags" TO "service_role";



GRANT ALL ON TABLE "public"."view_guide_details" TO "anon";
GRANT ALL ON TABLE "public"."view_guide_details" TO "authenticated";
GRANT ALL ON TABLE "public"."view_guide_details" TO "service_role";



GRANT ALL ON TABLE "public"."visit_log" TO "anon";
GRANT ALL ON TABLE "public"."visit_log" TO "authenticated";
GRANT ALL ON TABLE "public"."visit_log" TO "service_role";



GRANT ALL ON TABLE "public"."xp_rules" TO "anon";
GRANT ALL ON TABLE "public"."xp_rules" TO "authenticated";
GRANT ALL ON TABLE "public"."xp_rules" TO "service_role";









ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON SEQUENCES TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON FUNCTIONS TO "service_role";






ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "postgres";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "anon";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "authenticated";
ALTER DEFAULT PRIVILEGES FOR ROLE "postgres" IN SCHEMA "public" GRANT ALL ON TABLES TO "service_role";






























