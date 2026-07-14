-- Kingston Kitchen vendor cleanup after final event-team review.
--
-- Removes vendors that should not appear in this event and corrects reviewed
-- filter tags for vendors that were showing under beverages / desserts by
-- mistake. Scoped to the Kingston Kitchen event only.

create temp table kk_remove_vendors (
  vendor_name text primary key
) on commit drop;
insert into kk_remove_vendors (vendor_name) values
  ('Karona''s Jerk Seafood'),
  ('Karona jerk seafood'),
  ('Anasha''s Sweet Treats'),
  ('Totto''s Sweets'),
  ('Gina''s Bakehouse'),
  ('BB''s Slushies'),
  ('Wah Gwaan Cafe'),
  ('Waah Gwaan Cafe'),
  ('Kamila''s Kitchen'),
  ('Anique Catering'),
  ('anique catering'),
  ('Allie''s OhMason'),
  ('Crustiano'),
  ('Dequaneo Restaurant');
-- Clear user-scoped saved/rated rows first so "My Plan" does not retain
-- removed vendors after the event vendor row disappears.
delete from public.user_saved_menu_items saved
using public.event_vendors ev, public.vendors vendor, kk_remove_vendors staged
where saved.event_id = ev.event_id
  and saved.vendor_id = ev.vendor_id
  and ev.vendor_id = vendor.id
  and lower(vendor.name) = lower(staged.vendor_name)
  and ev.event_id = 'd4a039ed-280b-4e49-8a11-51a1c461b99b'::uuid;
delete from public.user_vendor_item_ratings rating
using public.event_vendors ev, public.vendors vendor, kk_remove_vendors staged
where rating.event_id = ev.event_id
  and rating.vendor_id = ev.vendor_id::text
  and ev.vendor_id = vendor.id
  and lower(vendor.name) = lower(staged.vendor_name)
  and ev.event_id = 'd4a039ed-280b-4e49-8a11-51a1c461b99b'::uuid;
delete from public.user_event_activity activity
using public.event_vendors ev, public.vendors vendor, kk_remove_vendors staged
where activity.event_id = ev.event_id
  and activity.entity_type = 'vendor'
  and activity.entity_id = ev.vendor_id
  and ev.vendor_id = vendor.id
  and lower(vendor.name) = lower(staged.vendor_name)
  and ev.event_id = 'd4a039ed-280b-4e49-8a11-51a1c461b99b'::uuid;
-- vendor_menu_items and event_map_points are FK-cascaded from event_vendors.
delete from public.event_vendors ev
using public.vendors vendor, kk_remove_vendors staged
where ev.vendor_id = vendor.id
  and lower(vendor.name) = lower(staged.vendor_name)
  and ev.event_id = 'd4a039ed-280b-4e49-8a11-51a1c461b99b'::uuid;
create temp table kk_corrected_filters (
  vendor_name text primary key,
  tags text[] not null
) on commit drop;
insert into kk_corrected_filters (vendor_name, tags) values
  -- Tyschane's Kitchen has mains and cheesecake items, but should not be
  -- surfaced as a dessert vendor in the high-level vendor filters.
  ('Tyschane''s Kitchen', array['jamaican_caribbean']),

  -- These were reviewed as not belonging under beverages / drinks.
  ('Epicurean by Shan', array['jamaican_caribbean']),
  ('Epicurean by Shan/EpicFlames', array['jamaican_caribbean']),
  ('Jambless Restaurant', array['global_fusion','street_food']),
  ('Street Food Saturdays', array['street_food','jerk_bbq']),
  ('Street Food Saturdays River Dining Experience', array['street_food','jerk_bbq']),
  ('Candy Fruit', array['pastry']),
  ('Allspice catering', array['street_food']),
  ('Allspice Catering and events', array['street_food']);
-- Keep both tag columns aligned. The app currently reads event_vendors.tags,
-- while partner/dashboard helpers also know about filter_tags.
update public.event_vendors ev
set tags = staged.tags,
    filter_tags = staged.tags,
    updated_at = now()
from public.vendors vendor, kk_corrected_filters staged
where ev.vendor_id = vendor.id
  and lower(vendor.name) = lower(staged.vendor_name)
  and ev.event_id = 'd4a039ed-280b-4e49-8a11-51a1c461b99b'::uuid;
