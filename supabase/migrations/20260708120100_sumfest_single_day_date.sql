-- Reggae Sumfest 2026 is represented by its event day in the app.
-- Keep the end date aligned with the July 18 start date so cards and detail
-- screens render a single date instead of an incorrect July 18-19 range.
update public.events
   set end_date = start_date
 where id = '3109c96c-6144-434b-918a-aca3cb0c2f46'
   and start_date = date '2026-07-18'
   and end_date is distinct from start_date;
