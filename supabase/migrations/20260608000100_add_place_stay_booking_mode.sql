-- Add stay booking mode expected by mobile listing fetches.

alter table public.places
  add column if not exists stay_booking_mode text;

comment on column public.places.stay_booking_mode is
  'How a stay/place accepts bookings. Expected by mobile listing fetches.';

update public.places
   set stay_booking_mode = case
     when booking_link is not null and length(trim(booking_link)) > 0 then 'link'
     when bookings_email is not null and length(trim(bookings_email)) > 0 then 'email'
     when booking_contact_email is not null and length(trim(booking_contact_email)) > 0 then 'email'
     else 'none'
   end
 where stay_booking_mode is null;
