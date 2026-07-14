-- Add menus for Reggae Sumfest vendors that have no menu items yet.
--
-- Source: RSF 2026 vendor-menus sheet. Sumfest already had all 55 vendors
-- (zones + booths) and menus for 15 of them; this fills the ~29 vendors that
-- were still empty. Contact info is intentionally not imported.
--
-- Idempotent + non-destructive: each vendor is matched by
-- (event_id, zone, booth_number) and only receives items when it currently
-- has NONE, so re-running never duplicates and vendors with existing menus
-- (and all booth/zone assignments) are left untouched.

do $$
declare
  v_event_id uuid := '3109c96c-6144-434b-918a-aca3cb0c2f46';
  v_ev_id uuid;
begin

  -- Cliff Side Bites / Booth 2 — Lisa
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Cliff Side Bites' and booth_number = '2'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Fish', NULL, NULL, NULL, 1),
      (v_ev_id, 'Jerk Chicken', NULL, NULL, NULL, 2),
      (v_ev_id, 'BBQ Wings', NULL, NULL, NULL, 3),
      (v_ev_id, 'BBQ Pigtail', NULL, NULL, NULL, 4),
      (v_ev_id, 'Soup', NULL, NULL, NULL, 5),
      (v_ev_id, 'Breadfruit', NULL, NULL, 'Sides', 6),
      (v_ev_id, 'Pressed Green Plantain', NULL, NULL, 'Sides', 7),
      (v_ev_id, 'Festival', NULL, NULL, 'Sides', 8),
      (v_ev_id, 'Bammy', NULL, NULL, 'Sides', 9),
      (v_ev_id, 'Fries', NULL, NULL, 'Sides', 10);
  end if;

  -- Cliff Side Bites / Booth 4 — Nikkidee Seafood Nyamins and More
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Cliff Side Bites' and booth_number = '4'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Escoveitch Fish', NULL, NULL, NULL, 1),
      (v_ev_id, 'Steam Fish & Okra', NULL, NULL, NULL, 2),
      (v_ev_id, 'Escoveitch Sprat', NULL, NULL, NULL, 3),
      (v_ev_id, 'Escoveitch Lobster', NULL, NULL, NULL, 4),
      (v_ev_id, 'Coconut Curry Lobster', NULL, NULL, NULL, 5),
      (v_ev_id, 'Ackee & Saltfish', NULL, NULL, NULL, 6),
      (v_ev_id, 'Calaloo & Saltfish', NULL, NULL, NULL, 7),
      (v_ev_id, 'Cabbage / Okra & Saltfish', NULL, NULL, NULL, 8),
      (v_ev_id, 'Fish / Conch Soup', NULL, NULL, NULL, 9),
      (v_ev_id, 'Pumpkin Vegetable Soup', NULL, NULL, NULL, 10),
      (v_ev_id, 'Vegan Stews', NULL, NULL, NULL, 11),
      (v_ev_id, 'Grilled Jerk Chicken', NULL, NULL, NULL, 12),
      (v_ev_id, 'Bammy (Fried/Steamed)', NULL, NULL, 'Sides', 13),
      (v_ev_id, 'Festival', NULL, NULL, 'Sides', 14),
      (v_ev_id, 'Saltfish Fritters', NULL, NULL, 'Sides', 15),
      (v_ev_id, 'Potato Fries', NULL, NULL, 'Sides', 16),
      (v_ev_id, 'Sweet Potato Fries', NULL, NULL, 'Sides', 17),
      (v_ev_id, 'Boil Corn', NULL, NULL, 'Sides', 18),
      (v_ev_id, 'Roast Breadfruit', NULL, NULL, 'Sides', 19),
      (v_ev_id, 'Boil Green Banana', NULL, NULL, 'Sides', 20),
      (v_ev_id, 'Fry Breadfruit', NULL, NULL, 'Sides', 21),
      (v_ev_id, 'Rice', NULL, NULL, 'Sides', 22);
  end if;

  -- Cliff Side Bites / Booth 7 — Fyahside
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Cliff Side Bites' and booth_number = '7'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Jerk Chicken', NULL, NULL, NULL, 1),
      (v_ev_id, 'Jerk Pork', NULL, NULL, NULL, 2),
      (v_ev_id, 'Jerk Sausage', NULL, NULL, NULL, 3),
      (v_ev_id, 'Escovitch Fish Fillet', NULL, NULL, NULL, 4),
      (v_ev_id, 'Roast Fish Fillet', NULL, NULL, NULL, 5),
      (v_ev_id, 'Soup', NULL, NULL, NULL, 6),
      (v_ev_id, 'Rice & Peas', NULL, NULL, 'Sides', 7),
      (v_ev_id, 'Festival', NULL, NULL, 'Sides', 8),
      (v_ev_id, 'Roast Breadfruit', NULL, NULL, 'Sides', 9),
      (v_ev_id, 'Fries', NULL, NULL, 'Sides', 10),
      (v_ev_id, 'Fried Sweet Potato', NULL, NULL, 'Sides', 11);
  end if;

  -- Cliff Side Bites / Booth 8 — Karona Jerk Seafood
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Cliff Side Bites' and booth_number = '8'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Jerk Fish', NULL, NULL, NULL, 1),
      (v_ev_id, 'Fry Fish', NULL, NULL, NULL, 2),
      (v_ev_id, 'Deep Fry Shrimp', NULL, NULL, NULL, 3),
      (v_ev_id, 'Jerk Shrimp', NULL, NULL, NULL, 4),
      (v_ev_id, 'Fry Conch', NULL, NULL, NULL, 5),
      (v_ev_id, 'Jerk Conch', NULL, NULL, NULL, 6),
      (v_ev_id, 'Popcorn Lobster', NULL, NULL, NULL, 7),
      (v_ev_id, 'Jerk Chicken', NULL, NULL, NULL, 8),
      (v_ev_id, 'Jerk Corn', NULL, NULL, NULL, 9),
      (v_ev_id, 'Fish Tea', NULL, NULL, 'Soup', 10),
      (v_ev_id, 'Conch Soup', NULL, NULL, 'Soup', 11),
      (v_ev_id, 'Bammy', NULL, NULL, 'Sides', 12),
      (v_ev_id, 'Festival', NULL, NULL, 'Sides', 13),
      (v_ev_id, 'Mashed Potatoes', NULL, NULL, 'Sides', 14),
      (v_ev_id, 'Vegetables', NULL, NULL, 'Sides', 15);
  end if;

  -- Cliff Side Bites / Booth 10 — DreZee Kitchen
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Cliff Side Bites' and booth_number = '10'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Escovitch Fish', '$4,000 up', 'JMD', NULL, 1),
      (v_ev_id, 'Steam Fish', '$4,000 up', 'JMD', NULL, 2),
      (v_ev_id, 'Curry & Garlic Butter Shrimp', '$4,500', 'JMD', NULL, 3),
      (v_ev_id, 'Escovitch Lobster', '$5,000 up', 'JMD', NULL, 4),
      (v_ev_id, 'Curry & Garlic Butter Lobster', '$5,000', 'JMD', NULL, 5),
      (v_ev_id, 'Ackee & Saltfish', '$3,500', 'JMD', NULL, 6),
      (v_ev_id, 'Crawfish Soup', 'sml $700 / lge $1,200', 'JMD', 'Soup', 7),
      (v_ev_id, 'Conch Soup', 'sml $700 / lge $1,200', 'JMD', 'Soup', 8),
      (v_ev_id, 'Rice & Peas', NULL, NULL, 'Sides', 9),
      (v_ev_id, 'Green Plantain', NULL, NULL, 'Sides', 10),
      (v_ev_id, 'Ripe Plantain', NULL, NULL, 'Sides', 11),
      (v_ev_id, 'Festival', NULL, NULL, 'Sides', 12),
      (v_ev_id, 'Saltfish Fritters', NULL, NULL, 'Sides', 13),
      (v_ev_id, 'Bammy', NULL, NULL, 'Sides', 14),
      (v_ev_id, 'Breadfruit', NULL, NULL, 'Sides', 15);
  end if;

  -- Di Truck Stop / Booth 1 — Pure Ultra Lounge
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Di Truck Stop' and booth_number = '1'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Wings', NULL, NULL, NULL, 1),
      (v_ev_id, 'Loaded Fries', NULL, NULL, NULL, 2),
      (v_ev_id, 'Pasta (Chicken & Shrimp)', NULL, NULL, NULL, 3),
      (v_ev_id, 'Burgers & Chicken Sandwich', NULL, NULL, NULL, 4),
      (v_ev_id, 'Plantain Cups', NULL, NULL, NULL, 5),
      (v_ev_id, 'Soup', NULL, NULL, NULL, 6);
  end if;

  -- Di Truck Stop / Booth 3 — Toykyia's catering
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Di Truck Stop' and booth_number = '3'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Wings & Fries (Spicy / Sweet Chilli / Barbecue)', NULL, NULL, NULL, 1),
      (v_ev_id, 'Barbeque Pigtail (served with festival)', NULL, NULL, NULL, 2),
      (v_ev_id, 'Pepper Shrimp & Sweet Corn', NULL, NULL, NULL, 3),
      (v_ev_id, 'Beef Burger', NULL, NULL, NULL, 4),
      (v_ev_id, 'Fish Burger', NULL, NULL, NULL, 5),
      (v_ev_id, 'Festival', NULL, NULL, 'Sides', 6),
      (v_ev_id, 'Fries', NULL, NULL, 'Sides', 7),
      (v_ev_id, 'Loaded Fries', NULL, NULL, 'Sides', 8),
      (v_ev_id, 'Boiled Sweet Corn', NULL, NULL, 'Sides', 9),
      (v_ev_id, 'Crayfish Soup', NULL, NULL, 'Soup', 10),
      (v_ev_id, 'Chicken Foot Soup', NULL, NULL, 'Soup', 11),
      (v_ev_id, 'Vegetable Pumpkin Soup', NULL, NULL, 'Soup', 12);
  end if;

  -- Di Truck Stop / Booth 6 — VSM Nikki's Kitchen
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Di Truck Stop' and booth_number = '6'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Nikki''s Fried Chicken', NULL, NULL, NULL, 1),
      (v_ev_id, 'Escoveitch Fish (M) or (L)', NULL, NULL, NULL, 2),
      (v_ev_id, 'Escoveitch Lobster', NULL, NULL, NULL, 3),
      (v_ev_id, 'Roast Conch', NULL, NULL, NULL, 4),
      (v_ev_id, 'Jerk Chicken Tacos', NULL, NULL, NULL, 5),
      (v_ev_id, 'Lobster Tacos', NULL, NULL, NULL, 6),
      (v_ev_id, 'Seafood Soup', NULL, NULL, NULL, 7),
      (v_ev_id, 'Sweet Potato Pudding', NULL, NULL, NULL, 8),
      (v_ev_id, 'Fries', NULL, NULL, 'Sides', 9),
      (v_ev_id, 'Festival (2)', NULL, NULL, 'Sides', 10),
      (v_ev_id, 'Bammy (2)', NULL, NULL, 'Sides', 11),
      (v_ev_id, 'Breadfruit', NULL, NULL, 'Sides', 12),
      (v_ev_id, 'Rice & Peas', NULL, NULL, 'Sides', 13);
  end if;

  -- Food District / Booth 3 — Paris Ruby Gourmet
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Food District' and booth_number = '3'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Paris Ruby Cakes', NULL, NULL, NULL, 1),
      (v_ev_id, 'Paris Ruby Sandwiches', NULL, NULL, NULL, 2),
      (v_ev_id, 'Fish and Bammy', NULL, NULL, NULL, 3),
      (v_ev_id, 'Soup', NULL, NULL, NULL, 4);
  end if;

  -- Food District / Booth 4 — Popcorn Burger World
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Food District' and booth_number = '4'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Oxtail', '$5,000', 'JMD', 'Mains', 1),
      (v_ev_id, 'Curry Goat', '$2,500', 'JMD', 'Mains', 2),
      (v_ev_id, 'Jerk Pork', '$3,500', 'JMD', 'Mains', 3),
      (v_ev_id, 'Jerk Fish', '$3,500', 'JMD', 'Mains', 4),
      (v_ev_id, 'Cow Foot', '$3,000', 'JMD', 'Mains', 5),
      (v_ev_id, 'Mofongo', '$2,000-$2,500', 'JMD', 'Mains', 6),
      (v_ev_id, 'Curry Shrimp', '$3,500', 'JMD', 'Mains', 7),
      (v_ev_id, 'Coconut Garlic Shrimp', '$3,500', 'JMD', 'Mains', 8),
      (v_ev_id, 'Mama''s Jerk 1/4 Chicken', '$3,000', 'JMD', 'Mains', 9),
      (v_ev_id, 'Fried, Baked & BBQ Chicken', '$3,000', 'JMD', 'Mains', 10),
      (v_ev_id, 'Chicken Feet Soup', '$800', 'JMD', 'Soup', 11),
      (v_ev_id, 'Manish Water Soup', '$1,000', 'JMD', 'Soup', 12),
      (v_ev_id, 'Bammy', '$500', 'JMD', 'Sides', 13),
      (v_ev_id, 'Festival', '$300', 'JMD', 'Sides', 14),
      (v_ev_id, 'Rice & Peas', '$700', 'JMD', 'Sides', 15),
      (v_ev_id, 'Vegetable Rice', '$700', 'JMD', 'Sides', 16),
      (v_ev_id, 'Gungo Peas Rice', '$700', 'JMD', 'Sides', 17),
      (v_ev_id, 'Mashed Potatoes', '$500 / $1,000', 'JMD', 'Sides', 18),
      (v_ev_id, 'Baked Mac & Cheese', '$1,000', 'JMD', 'Sides', 19),
      (v_ev_id, 'Roasted Breadfruit', '$300', 'JMD', 'Sides', 20),
      (v_ev_id, 'Fried Breadfruit', '$300', 'JMD', 'Sides', 21),
      (v_ev_id, 'Fries', '$800 / $1,000', 'JMD', 'Sides', 22),
      (v_ev_id, 'Cheese Fries', '$1,300', 'JMD', 'Sides', 23),
      (v_ev_id, 'Hot Dog', '$1,000', 'JMD', 'Hot Dogs', 24),
      (v_ev_id, 'Chilli Dog', '$1,500', 'JMD', 'Hot Dogs', 25),
      (v_ev_id, 'Crazy Dog', '$1,500', 'JMD', 'Hot Dogs', 26),
      (v_ev_id, 'Cheese Dog', '$1,200', 'JMD', 'Hot Dogs', 27),
      (v_ev_id, 'Full House', '$1,500', 'JMD', 'Hot Dogs', 28),
      (v_ev_id, 'Pineapple Dog', '$1,300', 'JMD', 'Hot Dogs', 29),
      (v_ev_id, 'Burger Plate', '$2,500', 'JMD', 'Burgers & More', 30),
      (v_ev_id, 'Burger', '$2,000', 'JMD', 'Burgers & More', 31),
      (v_ev_id, 'Nachos & Cheese', '$1,000 / $1,500', 'JMD', 'Burgers & More', 32),
      (v_ev_id, 'Taco', '$2,500', 'JMD', 'Burgers & More', 33),
      (v_ev_id, 'Fruiti Smoothie (Matcha / Dragon Fruit / Taro Boba)', '$1,500 - $2,000', 'JMD', 'Sweet Treats', 34),
      (v_ev_id, 'Ice Cream - Single Scoop', '$1,300', 'JMD', 'Sweet Treats', 35),
      (v_ev_id, 'Ice Cream - Double Scoop', '$2,000', 'JMD', 'Sweet Treats', 36),
      (v_ev_id, 'Snow Cone', '$800 - $1,000+', 'JMD', 'Sweet Treats', 37),
      (v_ev_id, 'Gourmet Popcorn (Rainbow & Butter)', '$1,000', 'JMD', 'Sweet Treats', 38);
  end if;

  -- Food District / Booth 6 — Sunshine Bakery & Restaurant
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Food District' and booth_number = '6'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Curried Reindeer', NULL, NULL, 'Main Dishes', 1),
      (v_ev_id, 'Curried Conch', NULL, NULL, 'Main Dishes', 2),
      (v_ev_id, 'Roasted Lobster', NULL, NULL, 'Main Dishes', 3),
      (v_ev_id, 'Curried Shrimp', NULL, NULL, 'Main Dishes', 4),
      (v_ev_id, 'Curried Goat', NULL, NULL, 'Main Dishes', 5),
      (v_ev_id, 'Fried Chicken', NULL, NULL, 'Main Dishes', 6),
      (v_ev_id, 'Fried Fish', NULL, NULL, 'Main Dishes', 7),
      (v_ev_id, 'Jerk Chicken', NULL, NULL, 'Main Dishes', 8),
      (v_ev_id, 'Jerk Pork', NULL, NULL, 'Main Dishes', 9),
      (v_ev_id, 'Oxtail', NULL, NULL, 'Main Dishes', 10),
      (v_ev_id, 'Red Peas Soup', NULL, NULL, 'Soups', 11),
      (v_ev_id, 'Nine Peas Soup', NULL, NULL, 'Soups', 12),
      (v_ev_id, 'Vegetable Soup', NULL, NULL, 'Soups', 13),
      (v_ev_id, 'Rice and Peas', NULL, NULL, 'Sides', 14),
      (v_ev_id, 'Festival', NULL, NULL, 'Sides', 15),
      (v_ev_id, 'Bammy', NULL, NULL, 'Sides', 16),
      (v_ev_id, 'Pressed Plantains', NULL, NULL, 'Sides', 17),
      (v_ev_id, 'Fresh Bread', NULL, NULL, 'Bakery Items', 18),
      (v_ev_id, 'Bulla Cakes', NULL, NULL, 'Bakery Items', 19),
      (v_ev_id, 'Spice Buns', NULL, NULL, 'Bakery Items', 20),
      (v_ev_id, 'Coconut Drops', NULL, NULL, 'Bakery Items', 21),
      (v_ev_id, 'Rock Cakes', NULL, NULL, 'Bakery Items', 22),
      (v_ev_id, 'Gizzada (Coconut Tart)', NULL, NULL, 'Bakery Items', 23);
  end if;

  -- Food District / Booth 7 — Top Chef
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Food District' and booth_number = '7'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Country Coconut Chicken Ramen', '$500', 'JMD', 'Soup', 1),
      (v_ev_id, 'Teriyaki Jerk Chicken (per 1/4)', '$2,000', 'JMD', 'Mains', 2),
      (v_ev_id, 'Jerk Chicken (per 1/4)', '$2,000', 'JMD', 'Mains', 3),
      (v_ev_id, 'Char Siu Jerk Pork (1/2 lb)', '$2,300', 'JMD', 'Mains', 4),
      (v_ev_id, 'Jerk Pork (1/2 lb)', '$2,300', 'JMD', 'Mains', 5),
      (v_ev_id, 'Stir Fry Pepper Shrimp', '$2,500', 'JMD', 'Mains', 6),
      (v_ev_id, 'Sweet Chilli Fish Fillet', '$2,300', 'JMD', 'Mains', 7),
      (v_ev_id, 'Vegetable Chow Mein', '$1,500', 'JMD', 'Mains', 8),
      (v_ev_id, 'Vegetable Fried Rice', NULL, NULL, 'Sides', 9),
      (v_ev_id, 'Furikake Fries', NULL, NULL, 'Sides', 10),
      (v_ev_id, 'Festival', NULL, NULL, 'Sides', 11),
      (v_ev_id, 'Sticky Noodles', NULL, NULL, 'Sides', 12),
      (v_ev_id, 'Combo Box (2 mains + 2 sides)', '$4,500', 'JMD', 'Combo', 13);
  end if;

  -- Food District / Booth 8 — Earl's Soup and Hot Dog Shop
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Food District' and booth_number = '8'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Corn Pork Soup', NULL, NULL, 'Soups', 1),
      (v_ev_id, 'Chicken Foot, Neck & Back Soup', NULL, NULL, 'Soups', 2),
      (v_ev_id, 'Conch & Crayfish Soup', NULL, NULL, 'Soups', 3),
      (v_ev_id, 'Beef, Cow Skin & Cow Foot Soup', NULL, NULL, 'Soups', 4),
      (v_ev_id, 'Boil Corn', NULL, NULL, 'Soups', 5),
      (v_ev_id, 'Bad Dawg Sausages', NULL, NULL, 'Hot Dogs', 6),
      (v_ev_id, 'Chicken Sausages', NULL, NULL, 'Hot Dogs', 7),
      (v_ev_id, 'Fry Fish', NULL, NULL, 'Food', 8),
      (v_ev_id, 'Fry Chicken', NULL, NULL, 'Food', 9),
      (v_ev_id, 'Brown Stew Pork', NULL, NULL, 'Food', 10),
      (v_ev_id, 'Bammy', NULL, NULL, 'Sides', 11),
      (v_ev_id, 'Rice & Peas', NULL, NULL, 'Sides', 12),
      (v_ev_id, 'Festival', NULL, NULL, 'Sides', 13),
      (v_ev_id, 'Breadfruit', NULL, NULL, 'Sides', 14),
      (v_ev_id, 'Fritters', NULL, NULL, 'Sides', 15),
      (v_ev_id, 'Vegetables and Pasta', NULL, NULL, 'Sides', 16);
  end if;

  -- Food District / Booth 9 — Scotchies
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Food District' and booth_number = '9'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Jerk Chicken', NULL, NULL, NULL, 1),
      (v_ev_id, 'Jerk Pork', NULL, NULL, NULL, 2),
      (v_ev_id, 'Festival', NULL, NULL, 'Sides', 3),
      (v_ev_id, 'Corn', NULL, NULL, 'Sides', 4),
      (v_ev_id, 'Bammy', NULL, NULL, 'Sides', 5),
      (v_ev_id, 'Rice n Peas', NULL, NULL, 'Sides', 6),
      (v_ev_id, 'Fries', NULL, NULL, 'Sides', 7),
      (v_ev_id, 'Plantain', NULL, NULL, 'Sides', 8),
      (v_ev_id, 'Yam / Breadfruit / Sweet Potato', NULL, NULL, 'Sides', 9),
      (v_ev_id, 'Roti', NULL, NULL, 'Sides', 10);
  end if;

  -- Food District / Booth 10 — Fry Fry
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Food District' and booth_number = '10'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Chicken n Wedges', NULL, NULL, NULL, 1),
      (v_ev_id, 'Chicken Wings', NULL, NULL, NULL, 2),
      (v_ev_id, 'BBQ / Fry Chicken n Rice', NULL, NULL, NULL, 3),
      (v_ev_id, 'Stewed Beef', NULL, NULL, NULL, 4),
      (v_ev_id, 'Stewed Pork', NULL, NULL, NULL, 5),
      (v_ev_id, 'Curried Goat', NULL, NULL, NULL, 6),
      (v_ev_id, 'Slice Fish', NULL, NULL, NULL, 7);
  end if;

  -- Food District / Booth 12 — Jamaica Cold-Pressed Juices
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Food District' and booth_number = '12'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Fresh Sugarcane Juice Blends', NULL, NULL, NULL, 1),
      (v_ev_id, 'Jelly Coconuts', NULL, NULL, NULL, 2);
  end if;

  -- Food District / Booth 14 — Hermine's Homestyle
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Food District' and booth_number = '14'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Homestyle Chicken', NULL, NULL, NULL, 1),
      (v_ev_id, 'Curry Chicken', NULL, NULL, NULL, 2),
      (v_ev_id, 'Curry Goat', NULL, NULL, NULL, 3),
      (v_ev_id, 'Oxtail', NULL, NULL, NULL, 4),
      (v_ev_id, 'Cowfoot and Beans', NULL, NULL, NULL, 5),
      (v_ev_id, 'Curry Conch', NULL, NULL, NULL, 6),
      (v_ev_id, 'Steam Snapper', NULL, NULL, NULL, 7),
      (v_ev_id, 'Crayfish Soup', NULL, NULL, NULL, 8),
      (v_ev_id, 'Rice and Peas', NULL, NULL, NULL, 9);
  end if;

  -- Food District / Booth 15 — Hot and Spicy
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Food District' and booth_number = '15'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Festival', '$500', 'JMD', 'Appetizers & Sides', 1),
      (v_ev_id, 'Fried Breadfruit', '$500', 'JMD', 'Appetizers & Sides', 2),
      (v_ev_id, 'Roti', '$500', 'JMD', 'Appetizers & Sides', 3),
      (v_ev_id, 'Tossed Vegetable Salad', NULL, NULL, 'Appetizers & Sides', 4),
      (v_ev_id, 'Chicken Foot / Cow Skin w/ Red Peas Soup', 'sml $500 / lrg $1,000', 'JMD', 'Soup', 5),
      (v_ev_id, 'Escovitch Fish w/ Festival', '$4,500', 'JMD', 'Main Course', 6),
      (v_ev_id, 'Curried Goat w/ Rice & Peas', '$4,500', 'JMD', 'Main Course', 7),
      (v_ev_id, 'Fried Chicken w/ Rice & Peas', '$3,500', 'JMD', 'Main Course', 8),
      (v_ev_id, 'Jerk Chicken w/ Hardo Bread / Festival', NULL, NULL, 'Main Course', 9),
      (v_ev_id, 'Calaloo w/ Fried Dumplings', '$2,000', 'JMD', 'Breakfast', 10),
      (v_ev_id, 'Calaloo w/ Saltfish & Fried Dumplings', '$3,000', 'JMD', 'Breakfast', 11),
      (v_ev_id, 'Ackee & Saltfish w/ Fried Dumplings', '$4,000', 'JMD', 'Breakfast', 12);
  end if;

  -- Garden Terrace / Booth 2 — Flava Fingaz
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Garden Terrace' and booth_number = '2'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Combo 1: 6pcs Wings, Mac n Cheese and Rolls', NULL, NULL, NULL, 1),
      (v_ev_id, 'Combo 2: 2 Chicken Tacos and Creamy Corn', NULL, NULL, NULL, 2),
      (v_ev_id, 'Peppered Shrimp', NULL, NULL, NULL, 3),
      (v_ev_id, 'Soup', NULL, NULL, 'Extras', 4),
      (v_ev_id, 'Creamy Corn', NULL, NULL, 'Extras', 5),
      (v_ev_id, 'Mac n Cheese', NULL, NULL, 'Extras', 6),
      (v_ev_id, 'Rolls', NULL, NULL, 'Extras', 7),
      (v_ev_id, 'Donut', NULL, NULL, 'Extras', 8),
      (v_ev_id, 'Lychee Lemonade', NULL, NULL, 'Extras', 9),
      (v_ev_id, 'Other Confectioneries', NULL, NULL, 'Extras', 10);
  end if;

  -- Garden Terrace / Booth 6 — Little Caesars
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Garden Terrace' and booth_number = '6'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Cheese', NULL, NULL, 'Pizza', 1),
      (v_ev_id, 'Pepperoni', NULL, NULL, 'Pizza', 2),
      (v_ev_id, 'BBQ Chicken', NULL, NULL, 'Pizza', 3),
      (v_ev_id, 'Jerk Chicken', NULL, NULL, 'Pizza', 4);
  end if;

  -- Inner Circle / Booth 3 — Scotchies x Fry Fry
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Inner Circle' and booth_number = '3'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Jerk Chicken', NULL, NULL, NULL, 1),
      (v_ev_id, 'Jerk Pork', NULL, NULL, NULL, 2),
      (v_ev_id, 'Festival', NULL, NULL, 'Sides', 3),
      (v_ev_id, 'Corn', NULL, NULL, 'Sides', 4),
      (v_ev_id, 'Bammy', NULL, NULL, 'Sides', 5),
      (v_ev_id, 'Rice n Peas', NULL, NULL, 'Sides', 6),
      (v_ev_id, 'Fries', NULL, NULL, 'Sides', 7),
      (v_ev_id, 'Plantain', NULL, NULL, 'Sides', 8),
      (v_ev_id, 'Yam / Breadfruit / Sweet Potato', NULL, NULL, 'Sides', 9),
      (v_ev_id, 'Roti', NULL, NULL, 'Sides', 10);
  end if;

  -- Inner Circle / Booth 4 — Donchic Gourmet
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Inner Circle' and booth_number = '4'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Saltfish Fritter Balls', '$1,500', 'JMD', 'Bites', 1),
      (v_ev_id, 'Sweet Chilli Chicken/Shrimp Cone', '$2,500 / $3,000', 'JMD', 'Bites', 2),
      (v_ev_id, 'Gaza Corn', '$1,000', 'JMD', 'Bites', 3),
      (v_ev_id, 'Reggae Sliders (Beef)', '$2,500', 'JMD', 'Bites', 4),
      (v_ev_id, 'Wings (Honey Jerk / Buffalo with fries)', '$2,000', 'JMD', 'Bites', 5),
      (v_ev_id, 'Jerk Chicken with signature sauces', '$2,500', 'JMD', 'Munchies (Meals)', 6),
      (v_ev_id, 'Cream of Coconut Fish Fillet', '$2,800', 'JMD', 'Munchies (Meals)', 7),
      (v_ev_id, 'Gully Pasta (Rasta)', '$3,000', 'JMD', 'Munchies (Meals)', 8),
      (v_ev_id, 'Pineapple Jerk Pork Chops', '$3,000', 'JMD', 'Munchies (Meals)', 9),
      (v_ev_id, 'Mash Potatoes', '+$500', 'JMD', 'Sides', 10),
      (v_ev_id, 'Rice & Peas', NULL, NULL, 'Sides', 11),
      (v_ev_id, 'Truffle Fries / Loaded Fries', '$1,000', 'JMD', 'Sides', 12),
      (v_ev_id, 'Festival (2/3 per serving)', '$200 per extra', 'JMD', 'Sides', 13),
      (v_ev_id, 'Tropical Bloom Spritz', '$1,500', 'JMD', 'Donchic Refreshers', 14),
      (v_ev_id, 'Watermelon Pop', '$1,500', 'JMD', 'Donchic Refreshers', 15),
      (v_ev_id, 'Mango Coconut Sunrise', '$1,300', 'JMD', 'Donchic Refreshers', 16),
      (v_ev_id, 'Golden Hour Orange Honey', '$1,000', 'JMD', 'Donchic Refreshers', 17),
      (v_ev_id, 'Donchic Frozen Delights', '$2,000', 'JMD', 'Frozen Delights', 18);
  end if;

  -- Inner Circle / Booth 6 — Shanz Streetvybz Cafe
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Inner Circle' and booth_number = '6'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Seafood Medley Soup', 'sml $500 / med $800 / lge $1,200', 'JMD', NULL, 1),
      (v_ev_id, 'Jerk Chicken', '$2,000', 'JMD', NULL, 2),
      (v_ev_id, 'Roast Fish', '$3,000 up', 'JMD', NULL, 3),
      (v_ev_id, 'Saltfish Fritters', '$500 each', 'JMD', NULL, 4),
      (v_ev_id, 'Loaded Fries (chicken or bacon)', '$2,000', 'JMD', NULL, 5),
      (v_ev_id, 'Jerk Pork', '$2,500 up', 'JMD', NULL, 6),
      (v_ev_id, 'BBQ Pigtail', '$2,500 up', 'JMD', NULL, 7),
      (v_ev_id, 'Tacos (Shrimp / Beef / Chicken)', '$1,200 each / 3 for $3,000', 'JMD', NULL, 8),
      (v_ev_id, 'Festival', '$500', 'JMD', 'Sides', 9),
      (v_ev_id, 'Bammy', '$500', 'JMD', 'Sides', 10),
      (v_ev_id, 'Bread', '$500', 'JMD', 'Sides', 11),
      (v_ev_id, 'Rice and Peas', '$500', 'JMD', 'Sides', 12);
  end if;

  -- Inner Circle / Booth 8 — Wafflelady
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Inner Circle' and booth_number = '8'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Original Warm Sweet Belgium Waffle with Topping', NULL, NULL, NULL, 1);
  end if;

  -- Inner Circle / Booth 10 — VODA
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Inner Circle' and booth_number = '10'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Di Voda Burger', NULL, NULL, NULL, 1),
      (v_ev_id, 'Yardie Pasta', NULL, NULL, NULL, 2),
      (v_ev_id, 'Yard Style Jerk Chicken', NULL, NULL, NULL, 3),
      (v_ev_id, 'Yard Style Curry Goat and Roti', NULL, NULL, NULL, 4),
      (v_ev_id, 'Jamrock BBQ / Spicy Wings', NULL, NULL, NULL, 5),
      (v_ev_id, 'BBQ Glazed Pork Belly Strips', NULL, NULL, NULL, 6);
  end if;

  -- Yard Vibes / Booth 1 — Mama T's
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Yard Vibes' and booth_number = '1'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Jerk Chicken', '$2,000', 'JMD', NULL, 1),
      (v_ev_id, 'Fry Chicken', '$1,500', 'JMD', NULL, 2),
      (v_ev_id, 'Sweet Chilli Chicken', '$1,800', 'JMD', NULL, 3),
      (v_ev_id, 'Barbi-Fried Chicken', '$1,800', 'JMD', NULL, 4),
      (v_ev_id, 'Curry Goat', '$3,000', 'JMD', NULL, 5),
      (v_ev_id, 'BBQ (Jerk) Pork', '$2,500', 'JMD', NULL, 6),
      (v_ev_id, 'Seafood Rundown (fish, conch, shrimp in coconut sauce)', '$3,500', 'JMD', NULL, 7),
      (v_ev_id, 'Rice and Peas', '$300', 'JMD', 'Sides', 8),
      (v_ev_id, 'Pumpkin Rice', '$350', 'JMD', 'Sides', 9),
      (v_ev_id, 'Roti', '$300', 'JMD', 'Sides', 10),
      (v_ev_id, 'Festival', '$200', 'JMD', 'Sides', 11),
      (v_ev_id, 'Goat Soup (Manish Water)', '$500 / $1,000', 'JMD', 'Soups', 12),
      (v_ev_id, 'Red Peas Soup with Chicken', '$300 / $600', 'JMD', 'Soups', 13),
      (v_ev_id, 'Sweet Chilli Wings', '$1,300', 'JMD', 'Extras', 14),
      (v_ev_id, 'Ripe Plantain', '$500', 'JMD', 'Extras', 15),
      (v_ev_id, 'Baked Mac and Cheese', '$1,000', 'JMD', 'Extras', 16),
      (v_ev_id, 'Bread Pudding w/ Rum Sauce', '$800', 'JMD', 'Extras', 17);
  end if;

  -- Yard Vibes / Booth 2 — Dasm Mini Treats
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Yard Vibes' and booth_number = '2'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Mini Pans', '$1,200', 'JMD', NULL, 1),
      (v_ev_id, 'Iced Coffee', '$1,000', 'JMD', NULL, 2),
      (v_ev_id, 'Fruit Parfaits', '$1,000', 'JMD', NULL, 3),
      (v_ev_id, 'Cake Pops', '$600', 'JMD', NULL, 4),
      (v_ev_id, 'Slushy', '$500', 'JMD', NULL, 5),
      (v_ev_id, 'Yard Vibes Special (Mini Pan & Iced Coffee)', '$2,000', 'JMD', NULL, 6);
  end if;

  -- Yard Vibes / Booth 4 — Kingston Foods
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Yard Vibes' and booth_number = '4'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Roast Yam / Salt Fish / Ackee', NULL, NULL, NULL, 1),
      (v_ev_id, 'Roast Sweet Potato', NULL, NULL, NULL, 2),
      (v_ev_id, 'Jerk Chicken', NULL, NULL, NULL, 3),
      (v_ev_id, 'Jerk Pork', NULL, NULL, NULL, 4),
      (v_ev_id, 'Wings', NULL, NULL, NULL, 5),
      (v_ev_id, 'Fried Chicken', NULL, NULL, NULL, 6),
      (v_ev_id, 'Fritters', NULL, NULL, NULL, 7),
      (v_ev_id, 'Esco Fish', NULL, NULL, NULL, 8),
      (v_ev_id, 'Sandwiches & Wraps', NULL, NULL, NULL, 9),
      (v_ev_id, 'Soups', NULL, NULL, NULL, 10),
      (v_ev_id, 'Hot Dog', NULL, NULL, NULL, 11),
      (v_ev_id, 'Tea (Ginger, Mint, Coffee, Milo)', NULL, NULL, NULL, 12);
  end if;

  -- Yard Vibes / Booth 6 — KY's Grill Limited
  select id into v_ev_id from public.event_vendors
   where event_id = v_event_id and zone = 'Yard Vibes' and booth_number = '6'
   limit 1;
  if v_ev_id is not null and not exists (
       select 1 from public.vendor_menu_items where event_vendor_id = v_ev_id) then
    insert into public.vendor_menu_items
      (event_vendor_id, name, price_label, currency, category, sort_order) values
      (v_ev_id, 'Rotisserie Chicken', NULL, NULL, NULL, 1),
      (v_ev_id, 'Jerk Chicken', NULL, NULL, NULL, 2),
      (v_ev_id, 'Fried Chicken', NULL, NULL, NULL, 3),
      (v_ev_id, 'BBQ Chicken', NULL, NULL, NULL, 4),
      (v_ev_id, 'Burgers', NULL, NULL, NULL, 5),
      (v_ev_id, 'Fish & Chips', NULL, NULL, NULL, 6),
      (v_ev_id, 'Wings & Fries', NULL, NULL, NULL, 7),
      (v_ev_id, 'Wraps', NULL, NULL, NULL, 8),
      (v_ev_id, 'Pastas', NULL, NULL, NULL, 9),
      (v_ev_id, 'Sides (potato wedges, festivals, salads, and rice)', NULL, NULL, NULL, 10);
  end if;

end $$;
