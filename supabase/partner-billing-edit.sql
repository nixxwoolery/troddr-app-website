-- ============================================================
-- Partner dashboard -> editable billing PROFILE (contact details)
-- ------------------------------------------------------------
-- Lets a partner read and update the CONTACT / PROFILE fields of
-- their company billing account from /partner/billing using their
-- partner access token (place or event token).
--
-- SCOPE — contact/profile only. Mirrors the existing
-- update_partner_place_contact trust model (partner token already
-- authorizes writes to the partner's own business data).
--
--   Editable here:  registered/legal name, trading name, billing
--                   contact name, billing email, billing phone,
--                   address, country, tax id, preferred currency.
--
--   NEVER editable here (stays authenticated-only at
--   /company/billing): payment confirmations, plan/subscription
--   changes, invoices, location/event attachment, account status.
--   A leaked partner link can edit contact details but can never
--   move money or change entitlements.
--
-- Run AFTER company-billing-ops.sql and partner-billing-bridge.sql.
-- Idempotent — safe to re-run.
-- ============================================================

-- ------------------------------------------------------------
-- Helper: resolve a partner token to its owning company account id.
-- Same resolution order as get_partner_billing_by_token.
-- ------------------------------------------------------------
create or replace function public._partner_token_company_id(p_token text)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
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

revoke execute on function public._partner_token_company_id(text) from public, anon, authenticated;

-- ------------------------------------------------------------
-- Read the editable billing profile for the partner's company.
-- ------------------------------------------------------------
create or replace function public.partner_get_billing_profile(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place      places%rowtype;
  v_event_id   uuid;
  v_company_id uuid;
  v_c          company_accounts%rowtype;
begin
  if p_token is null or length(trim(p_token)) = 0 then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then
    select id into v_event_id from public.events where partner_access_token = p_token;
    if v_event_id is null then
      return jsonb_build_object('ok', false, 'error', 'invalid_token');
    end if;
  end if;

  v_company_id := public._partner_token_company_id(p_token);

  -- Existing billing account → return its saved details.
  if v_company_id is not null then
    select * into v_c from public.company_accounts where id = v_company_id;
    return jsonb_build_object(
      'ok', true, 'is_new', false,
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
  end if;

  -- No billing account yet. For a place token, return a blank but
  -- pre-filled profile so the partner can enter their own details and
  -- save (which creates the account). Events are admin-attached only.
  if v_place.id is not null then
    return jsonb_build_object(
      'ok', true, 'is_new', true,
      'profile', jsonb_build_object(
        'business_name',  v_place.name,
        'trading_name',   null,
        'contact_name',   null,
        'billing_email',  coalesce(nullif(v_place.bookings_email, ''), ''),
        'billing_phone',  coalesce(nullif(v_place.phone_number, ''), ''),
        'address',        null,
        'country',        'Jamaica',
        'tax_id',         null,
        'preferred_currency', 'USD'
      )
    );
  end if;

  return jsonb_build_object('ok', false, 'error', 'no_company',
    'message', 'Billing for events is set up by TRODDR — email billing@troddr.com to get started.');
end;
$$;

grant execute on function public.partner_get_billing_profile(text) to anon, authenticated;

-- ------------------------------------------------------------
-- Update the editable billing profile (contact details only).
-- ------------------------------------------------------------
create or replace function public.partner_update_billing_profile(
  p_token text,
  p_info  jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place      places%rowtype;
  v_event_id   uuid;
  v_company_id uuid;
  v_business   text;
  v_email      text;
  v_currency   text;
  v_trading    text;
  v_contact    text;
  v_phone      text;
  v_address    text;
  v_country    text;
  v_tax        text;
  v_created    boolean := false;
begin
  if p_token is null or length(trim(p_token)) = 0 then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;

  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then
    select id into v_event_id from public.events where partner_access_token = p_token;
    if v_event_id is null then
      return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
    end if;
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

  v_trading := nullif(trim(coalesce(p_info ->> 'trading_name', '')), '');
  v_contact := nullif(trim(coalesce(p_info ->> 'contact_name', '')), '');
  v_phone   := nullif(trim(coalesce(p_info ->> 'billing_phone', '')), '');
  v_address := nullif(trim(coalesce(p_info ->> 'address', '')), '');
  v_country := nullif(trim(coalesce(p_info ->> 'country', '')), '');
  v_tax     := nullif(trim(coalesce(p_info ->> 'tax_id', '')), '');

  v_company_id := public._partner_token_company_id(p_token);

  -- No billing account yet → create one and link this place (place tokens
  -- only — events stay admin-attached). This is a billing PROFILE only; no
  -- plan, entitlements, or invoices are created.
  if v_company_id is null then
    if v_place.id is null then
      return jsonb_build_object('ok', false, 'error',
        'Billing for events is set up by TRODDR — email billing@troddr.com to get started.');
    end if;

    insert into public.company_accounts
      (name, legal_name, trading_name, billing_email, contact_name, billing_phone,
       address, country, tax_id, preferred_currency, status, source_type, onboarding_status)
    values
      (v_business, v_business, v_trading, v_email, v_contact, v_phone,
       v_address, v_country, v_tax, v_currency, 'active', 'manual', 'complete')
    returning id into v_company_id;

    insert into public.company_locations
      (company_account_id, place_id, status, approved_by, label)
    values
      (v_company_id, v_place.id, 'approved', 'partner self-service', v_place.name)
    on conflict (company_account_id, place_id) do nothing;

    v_created := true;

    perform public._billing_audit('system', 'partner dashboard', v_company_id,
      'partner_billing_account_created',
      jsonb_build_object('channel', 'partner_link', 'place_id', v_place.id,
        'business_name', v_business, 'billing_email', v_email));

    return jsonb_build_object('ok', true, 'created', true, 'message', 'Billing details saved.');
  end if;

  -- Existing billing account → update its contact/profile fields.
  update public.company_accounts
     set name               = v_business,   -- display/account name shown on invoices
         legal_name         = v_business,
         trading_name       = v_trading,
         contact_name       = v_contact,
         billing_email      = v_email,
         billing_phone      = v_phone,
         address            = v_address,
         country            = v_country,
         tax_id             = v_tax,
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

  return jsonb_build_object('ok', true, 'created', false, 'message', 'Billing details saved.');
end;
$$;

grant execute on function public.partner_update_billing_profile(text, jsonb) to anon, authenticated;
