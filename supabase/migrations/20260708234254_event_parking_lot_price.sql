-- Paid parking tiers (e.g. Sumfest Silver/Gold/Medallion). Price is optional
-- (free lots leave it null); currency defaults to USD for the JM event market.
alter table public.event_parking_lots
  add column if not exists price    numeric check (price is null or price >= 0),
  add column if not exists currency text not null default 'USD';;
