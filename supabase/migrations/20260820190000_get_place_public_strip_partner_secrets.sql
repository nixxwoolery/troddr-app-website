-- get_place_public is a public (anon-callable) lookup used by link-unfurl OG
-- cards and the app's place resolution. It returned to_jsonb(p) — the ENTIRE
-- places row — which leaked partner-only fields to any anonymous caller, most
-- seriously `partner_access_token` (a bearer credential that grants access to
-- the partner dashboard at /partner/*). Strip the sensitive keys; every
-- guest-facing field is preserved.

create or replace function public.get_place_public(_slug text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare r jsonb;
begin
  select to_jsonb(p) into r
  from places p
  where p.slug = _slug
  limit 1;

  if r is null then
    return null;
  end if;

  -- Remove partner-only / internal fields before returning to the public.
  return r - array[
    'partner_access_token',
    'partner_id',
    'internal_booking_notes',
    'booking_contact_email',
    'booking_contact_name',
    'bookings_email',
    'commission_terms',
    'stay_commission_terms'
  ]::text[];
end; $function$;
