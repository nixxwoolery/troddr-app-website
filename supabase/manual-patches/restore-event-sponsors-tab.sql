-- Emergency restore for the app Sponsors tab.
-- Run this in Supabase SQL Editor to put get_event_sponsors_by_slug back to
-- the known-good payload shape from the remote schema snapshot.

-- Normalize any raw dashboard tiers back to app-renderable tiers. Keep the
-- human-facing Gold/Silver/Bronze label in display_tier_label.
update public.event_sponsors
   set tier = case lower(tier)
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
   end,
       display_tier_label = coalesce(
         display_tier_label,
         case lower(tier)
           when 'title' then 'Title Sponsor'
           when 'platinum' then 'Platinum Sponsor'
           when 'gold' then 'Gold Sponsor'
           when 'silver' then 'Silver Sponsor'
           when 'bronze' then 'Bronze Sponsor'
           else null
         end
       ),
       updated_at = now()
 where lower(tier) not in ('presenting', 'major', 'supporting', 'community', 'partner')
    or lower(tier) in ('gold', 'silver', 'bronze', 'title', 'platinum');

create or replace function public.get_event_sponsors_by_slug(p_event_slug text)
returns jsonb
language sql
security definer
set search_path = public
as $$
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

grant execute on function public.get_event_sponsors_by_slug(text) to anon, authenticated;
