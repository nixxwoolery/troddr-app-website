-- ============================================================
-- TRODDR Company Billing — pricing & entitlement seed
-- Run AFTER company-billing.sql. Idempotent (upserts on key).
-- All prices USD. No GCT for now.
-- ============================================================

-- ------------------------------------------------------------
-- Entitlement definitions (feature access keys)
-- ------------------------------------------------------------
insert into public.entitlement_definitions (key, name, description, category) values
  ('dashboard_access',  'Dashboard access',        'Sign in to the company dashboard', 'core'),
  ('loyalty_program',   'Loyalty program',         'Run the TRODDR loyalty program at approved locations', 'core'),
  ('partner_bookings',  'Partner bookings',        'Receive and respond to booking requests', 'core'),
  ('otr_basic',         'On The Radar — Basic',    'Basic listing: image, basic data, contact/link buttons', 'listing'),
  ('otr_premium',       'On The Radar — Premium',  'Premium listing: menu/items, multiple images, booking flow, offers', 'listing'),
  ('location_insights', 'Location Insights',       'Per-location analytics dashboard', 'insights'),
  ('company_insights',  'Company Insights',        'Company-wide analytics rollup', 'insights'),
  ('event_lite',        'Event Lite',              'Large event listing / basic hub', 'event'),
  ('event_pro',         'Event Pro',               'Full event app experience without premium map', 'event'),
  ('major_event_hub',   'Major Event Hub',         'Multi-day / complex event hub, up to 9 tabs', 'event'),
  ('flagship_event',    'Flagship Event',          'Sumfest-scale full event app inside Troddr', 'event'),
  ('event_series_hub',  'Event Series Hub',        'Parent event + child events (e.g. JFDF)', 'event'),
  ('event_insights',    'Event Insights',          'Live event dashboard + post-event report', 'insights'),
  ('premium_event_map', 'Premium Event Map',       'Premium venue / floor-plan / multi-zone maps', 'event'),
  ('sponsor_activation','Sponsor Activation',      'Sponsor activation experiences inside an event', 'sponsor'),
  ('sponsor_report',    'Sponsor Report',          'Complete sponsor activation report', 'sponsor')
on conflict (key) do update
  set name = excluded.name, description = excluded.description,
      category = excluded.category, is_active = true;

-- ------------------------------------------------------------
-- Founding Partner / Loyalty plans (per company account)
-- Monthly prices are per month; annual is the discounted
-- pay-up-front price ($720/yr monthly-billed Single vs $588).
-- All plans grant the same core entitlements; limits differ.
-- ------------------------------------------------------------
insert into public.subscription_plans
  (key, name, description, included_locations, included_admins,
   monthly_price, annual_price, currency, entitlements, sort_order) values
  ('fp_single', 'Founding Partner — Single', '1 location, 1 admin',
    1, 1, 60, 588, 'USD',
    '["dashboard_access","loyalty_program","partner_bookings"]'::jsonb, 1),
  ('fp_duo', 'Founding Partner — Duo', '2 locations, 2 admins',
    2, 2, 120, 1056, 'USD',
    '["dashboard_access","loyalty_program","partner_bookings"]'::jsonb, 2),
  ('fp_trio', 'Founding Partner — Trio', '3 locations, 2 admins',
    3, 2, 180, 1500, 'USD',
    '["dashboard_access","loyalty_program","partner_bookings"]'::jsonb, 3),
  ('fp_group', 'Founding Partner — Group', '5 locations, 3 admins',
    5, 3, 300, 2352, 'USD',
    '["dashboard_access","loyalty_program","partner_bookings"]'::jsonb, 4)
on conflict (key) do update
  set name = excluded.name, description = excluded.description,
      included_locations = excluded.included_locations,
      included_admins = excluded.included_admins,
      monthly_price = excluded.monthly_price,
      annual_price = excluded.annual_price,
      entitlements = excluded.entitlements,
      sort_order = excluded.sort_order, is_active = true;

-- ------------------------------------------------------------
-- Product catalog (invoice line items)
-- Ranged products store min/max; admin enters the agreed price
-- on the invoice line. Extra admin users are REQUEST ONLY and
-- deliberately have no product here.
-- ------------------------------------------------------------
insert into public.billing_products
  (code, item_type, name, description, unit_amount, min_amount, max_amount,
   billing_unit, entitlements, metadata, sort_order) values

  -- On The Radar
  ('otr_basic_monthly',  'otr_basic',   'OTR Basic (monthly)',  '1 basic listing: image, basic data, contact/link buttons', 35, null, null, 'month', '["dashboard_access","otr_basic"]'::jsonb, '{}'::jsonb, 10),
  ('otr_basic_annual',   'otr_basic',   'OTR Basic (annual)',   '1 basic listing: image, basic data, contact/link buttons', 350, null, null, 'year', '["dashboard_access","otr_basic"]'::jsonb, '{}'::jsonb, 11),
  ('otr_premium_monthly','otr_premium', 'OTR Premium (monthly)','Premium listing: menu/items, multiple images, booking flow, offers/specials', 55, null, null, 'month', '["dashboard_access","otr_premium"]'::jsonb, '{}'::jsonb, 12),
  ('otr_premium_annual', 'otr_premium', 'OTR Premium (annual)', 'Premium listing: menu/items, multiple images, booking flow, offers/specials', 550, null, null, 'year', '["dashboard_access","otr_premium"]'::jsonb, '{}'::jsonb, 13),

  -- Insights (per location by default; company-wide rollup product)
  ('location_insights_monthly', 'location_insights', 'Location Insights (monthly)', 'Per-location analytics, billed per location', 30, null, null, 'per_location_month', '["location_insights"]'::jsonb, '{}'::jsonb, 20),
  ('location_insights_annual',  'location_insights', 'Location Insights (annual)',  'Per-location analytics, billed per location', 300, null, null, 'per_location_year', '["location_insights"]'::jsonb, '{}'::jsonb, 21),
  ('company_insights_monthly',  'company_insights',  'Company Insights (monthly)',  'Company-wide analytics rollup', 75, null, null, 'month', '["company_insights"]'::jsonb, '{}'::jsonb, 22),
  ('company_insights_annual',   'company_insights',  'Company Insights (annual)',   'Company-wide analytics rollup', 750, null, null, 'year', '["company_insights"]'::jsonb, '{}'::jsonb, 23),

  -- Troddr Events (team setup + software access)
  ('event_lite',      'event_lite',      'Event Lite',      'Large event listing/basic hub: Home, Info, Tickets, basic content. 2 push notifications.', 1500, null, null, 'one_time', '["event_lite"]'::jsonb, '{"push_cap": 2}'::jsonb, 30),
  ('event_pro',       'event_pro',       'Event Pro',       'Full event app without premium map: Home, Info, Tickets, Schedule/Events, Sponsors, My Plan, basic insights. 5 pushes.', 3500, null, null, 'one_time', '["event_pro"]'::jsonb, '{"push_cap": 5}'::jsonb, 31),
  ('major_event_hub', 'major_event_hub', 'Major Event Hub', 'Multi-day/complex hub, up to 9 tabs, Vendors, Sponsors, Schedule, My Plan, premium insights, end-of-event report. 10 pushes.', 6500, null, null, 'one_time', '["major_event_hub","event_insights"]'::jsonb, '{"push_cap": 10}'::jsonb, 32),
  ('flagship_event',  'flagship_event',  'Flagship Event',  'Sumfest-scale tentpole: full event app, premium map, complex schedules, sponsor layer, activations, advanced reporting. From $10,000.', null, 10000, null, 'one_time', '["flagship_event","event_insights","premium_event_map"]'::jsonb, '{"push_cap": "custom (15-25)"}'::jsonb, 33),

  -- Carnival (priced separately)
  ('carnival_hub',           'carnival_hub',           'Carnival Jamaica Hub',    'Carnival in Jamaica hub. From $10,000.', null, 10000, null, 'one_time', '["major_event_hub","event_insights","premium_event_map"]'::jsonb, '{}'::jsonb, 40),
  ('carnival_band_hub',      'carnival_band_hub',      'Carnival Band Hub',       'Per-band hub. $3,500–$6,500.', null, 3500, 6500, 'one_time', '["event_pro"]'::jsonb, '{}'::jsonb, 41),
  ('carnival_event_listing', 'carnival_event_listing', 'Carnival Event Listing',  'Single carnival event listing. $750–$1,500.', null, 750, 1500, 'one_time', '["event_lite"]'::jsonb, '{}'::jsonb, 42),
  ('carnival_event_pro',     'carnival_event_pro',     'Carnival Event Pro',      'Carnival event pro experience. $2,500–$3,500.', null, 2500, 3500, 'one_time', '["event_pro"]'::jsonb, '{}'::jsonb, 43),

  -- Event series (parent + child events, e.g. JFDF)
  ('event_series_hub',         'event_series_hub', 'Event Series Hub',          'Parent event + included child events (JFDF-style). $7,500–$9,500. Insights included at the higher end.', null, 7500, 9500, 'one_time', '["event_series_hub","major_event_hub"]'::jsonb, '{}'::jsonb, 50),
  ('event_series_extra_child', 'event_series_hub', 'Extra Child Event',         'Additional child event beyond included scope. $750–$1,000.', null, 750, 1000, 'one_time', '[]'::jsonb, '{}'::jsonb, 51),
  ('event_series_insights',    'event_insights',   'Event Series Insights',     'Series insights/reporting when not included. $1,500–$2,500.', null, 1500, 2500, 'one_time', '["event_insights"]'::jsonb, '{}'::jsonb, 52),

  -- Event Insights (live dashboard + post-event report)
  ('event_insights_pro',      'event_insights', 'Event Insights Pro',      'Live dashboard + post-event report.', 1500, null, null, 'one_time', '["event_insights"]'::jsonb, '{}'::jsonb, 60),
  ('major_event_insights',    'event_insights', 'Major Event Insights',    'Live dashboard + post-event report for major events.', 2500, null, null, 'one_time', '["event_insights"]'::jsonb, '{}'::jsonb, 61),
  ('flagship_event_insights', 'event_insights', 'Flagship Event Insights', 'Advanced insights for flagship events. From $4,000.', null, 4000, null, 'one_time', '["event_insights"]'::jsonb, '{}'::jsonb, 62),

  -- Premium event map (never included in Event Lite)
  ('map_basic_venue',     'premium_event_map', 'Basic Venue Map',              'Premium basic venue map.', 750, null, null, 'one_time', '["premium_event_map"]'::jsonb, '{}'::jsonb, 70),
  ('map_vendor_floor',    'premium_event_map', 'Vendor / Floor-Plan Map',      'Vendor & floor-plan premium map. Per venue/event for series: $750–$1,500.', 1500, null, null, 'one_time', '["premium_event_map"]'::jsonb, '{}'::jsonb, 71),
  ('map_complex_multizone','premium_event_map','Complex Multi-Zone Map',       'Complex multi-zone / multi-day map. From $2,500.', null, 2500, null, 'one_time', '["premium_event_map"]'::jsonb, '{}'::jsonb, 72),

  -- Sponsor products (sponsor billing is separate from organizer billing)
  ('sponsor_listing',        'sponsor_activation', 'Sponsor Activation Listing',       'Sponsor activation listing inside the event.', 500, null, null, 'one_time', '["sponsor_activation"]'::jsonb, '{}'::jsonb, 80),
  ('sponsor_digital_offer',  'sponsor_activation', 'Digital Offer / Redemption',       'Digital offer/redemption activation.', 1000, null, null, 'one_time', '["sponsor_activation"]'::jsonb, '{}'::jsonb, 81),
  ('sponsor_checkin',        'sponsor_activation', 'Check-In Activation',              'Check-in activation.', 1500, null, null, 'one_time', '["sponsor_activation"]'::jsonb, '{}'::jsonb, 82),
  ('sponsor_passport',       'sponsor_activation', 'Multi-Stop / Passport Activation', 'Multi-stop passport activation. From $2,500.', null, 2500, null, 'one_time', '["sponsor_activation"]'::jsonb, '{}'::jsonb, 83),
  ('sponsor_custom_branded', 'sponsor_activation', 'Custom Branded Activation',        'Custom branded activation. From $3,000.', null, 3000, null, 'one_time', '["sponsor_activation"]'::jsonb, '{}'::jsonb, 84),
  ('sponsor_full_report',    'sponsor_report',     'Sponsor Full Report',              'Complete sponsor activation report. $1,000–$2,000.', null, 1000, 2000, 'one_time', '["sponsor_report"]'::jsonb, '{}'::jsonb, 85),

  -- Onsite support: NOT in standard packages; quoted on request.
  ('onsite_support_day', 'custom', 'Onsite Support (per person per day)', '$750–$1,000/day per person, plus credentials, access, transport, meals. Quoted on request.', null, 750, 1000, 'per_day', '[]'::jsonb, '{}'::jsonb, 90)

on conflict (code) do update
  set item_type = excluded.item_type, name = excluded.name,
      description = excluded.description, unit_amount = excluded.unit_amount,
      min_amount = excluded.min_amount, max_amount = excluded.max_amount,
      billing_unit = excluded.billing_unit, entitlements = excluded.entitlements,
      metadata = excluded.metadata, sort_order = excluded.sort_order, is_active = true;
