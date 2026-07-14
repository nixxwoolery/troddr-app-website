-- Insider Passes (/visits) must only show places that actually run the Insider
-- programme. get_my_visit_history() previously counted EVERY nfc check-in and
-- joined to places without filtering on insider_enabled, so a loyalty-only
-- place (e.g. Soup King) leaked in: tapping the puck there earns a loyalty
-- stamp, which writes a user_checkins row with source='nfc', and that was being
-- mis-counted as an Insider Pass visit.
--
-- Fix: a place only counts as an Insider Pass when
--   (a) insider is enabled, AND
--   (b) it is not part of an ACTIVE loyalty programme — neither as the owning
--       place nor as a linked location. Insider and Loyalty share the same NFC
--       puck, so this keeps loyalty taps out of Insider standing even if a
--       partner ever flips insider_enabled on for a loyalty venue.

CREATE OR REPLACE FUNCTION "public"."get_my_visit_history"()
RETURNS TABLE("place_id" "uuid", "place_name" "text", "place_slug" "text", "place_image" "text", "parish" "text", "category" "text", "insider_enabled" boolean, "visit_count" bigint, "first_visit" timestamp with time zone, "last_visit" timestamp with time zone, "guest_min" integer, "familiar_face_min" integer, "regular_min" integer, "house_favourite_min" integer)
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
    and coalesce(p.insider_enabled, false) = true
    and not exists (
      select 1 from public.loyalty_programs lp
      where lp.place_id = p.id and coalesce(lp.is_active, false)
    )
    and not exists (
      select 1
      from public.loyalty_program_locations lpl
      join public.loyalty_programs lp2 on lp2.id = lpl.program_id
      where lpl.place_id = p.id and coalesce(lp2.is_active, false)
    )
  group by p.id, p.name, p.slug, p.image, p.parish, p.category, p.insider_enabled,
           s.guest_min, s.familiar_face_min, s.regular_min, s.house_favourite_min
  order by max(uc.created_at) desc;
$$;
