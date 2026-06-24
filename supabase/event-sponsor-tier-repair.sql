-- ============================================================
-- Event sponsor tier repair
-- ============================================================
-- The current mobile app renders these tier keys:
-- presenting, major, supporting, community, partner.
-- Dashboard business tiers such as gold/silver/bronze should be stored in
-- display_tier_label, while tier stays app-renderable.

update public.event_sponsors
   set tier = case lower(tier)
     when 'title' then 'presenting'
     when 'platinum' then 'presenting'
     when 'gold' then 'major'
     when 'silver' then 'supporting'
     when 'bronze' then 'supporting'
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
    or lower(tier) in ('gold', 'silver', 'bronze');
