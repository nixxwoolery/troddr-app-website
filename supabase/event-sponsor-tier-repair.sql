-- ============================================================
-- Event sponsor tier repair
-- ============================================================
-- The mobile app renders these tier keys:
-- presenting, major, gold, silver, bronze, supporting, community, partner.
-- Older dashboard options wrote title/platinum, which SponsorsTab fetches
-- successfully but filters out before rendering.

update public.event_sponsors
   set tier = case lower(tier)
     when 'title' then 'presenting'
     when 'platinum' then 'presenting'
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
 where lower(tier) not in ('presenting', 'major', 'gold', 'silver', 'bronze', 'supporting', 'community', 'partner');
