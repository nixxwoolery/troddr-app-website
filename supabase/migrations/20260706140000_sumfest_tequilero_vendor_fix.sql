-- Fix the Sumfest "Chill Spot / Booth 2" vendor identity.
--
-- That booth is Tequilero (tequila-based drinks) and the vendor row already
-- carries Tequilero's logo, its "Tequila Based Drinks" menu, and display_name
-- 'Tequilero' — but the row's `name` was left as 'Browns Town Jerk Hut', which
-- is what the vendor card shows as the title. The row (41b72636…) is used ONLY
-- by this one booth; the real Browns Town Jerk Hut is a different vendor row
-- (3004face…), so renaming this one is safe.

update public.vendors
   set name = 'Tequilero'
 where id = '41b72636-11d5-40ec-9337-8b930f3b1d2f'
   and name = 'Browns Town Jerk Hut';
