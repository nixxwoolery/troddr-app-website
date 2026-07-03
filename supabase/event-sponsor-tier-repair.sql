-- ============================================================
-- Event sponsor tier repair
-- ============================================================
-- Restore dashboard/app business tiers from labels after older saves mapped
-- gold/silver/bronze into generic major/supporting buckets.

update public.event_sponsors
   set tier = case
     when lower(coalesce(display_tier_label, '')) like '%gold%' then 'gold'
     when lower(coalesce(display_tier_label, '')) like '%silver%' then 'silver'
     when lower(coalesce(display_tier_label, '')) like '%bronze%' then 'bronze'
     when lower(tier) in ('title', 'platinum', 'gold', 'silver', 'bronze',
                          'presenting', 'major', 'supporting', 'community', 'partner')
       then lower(tier)
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
 where lower(tier) not in ('title', 'platinum', 'gold', 'silver', 'bronze',
                           'presenting', 'major', 'supporting', 'community', 'partner')
    or lower(coalesce(display_tier_label, '')) like '%gold%'
    or lower(coalesce(display_tier_label, '')) like '%silver%'
    or lower(coalesce(display_tier_label, '')) like '%bronze%';
