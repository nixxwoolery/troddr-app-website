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

grant execute on function public.partner_update_billing_profile(text, jsonb) to anon, authenticated;
