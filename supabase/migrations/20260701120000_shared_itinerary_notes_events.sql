-- Shared itinerary payload: include note cards, stop notes, and event times.
--
-- The baseline get_shared_itinerary used an inner join from itinerary_places
-- to places, which silently dropped standalone note cards. It also returned
-- event rows separately but without their start/end time overrides. The app's
-- shared-trip save/import paths now preserve both places and events, so the
-- share RPC needs to expose the full shape.

create or replace function public.get_shared_itinerary(_token text)
returns json
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  result json;
begin
  select json_build_object(
    'itinerary', json_build_object(
      'id', i.id,
      'title', i.title,
      'destination', i.destination,
      'start_date', i.start_date,
      'end_date', i.end_date,
      'shared_by', i.user_id,
      'shared_by_name', u.username
    ),
    'places', coalesce((
      select json_agg(
        json_build_object(
          'id', p.id,
          'name', case when ip.is_note then 'Note' else p.name end,
          'slug', p.slug,
          'description', case when ip.is_note then ip.note_text else p.description end,
          'category', case when ip.is_note then 'note' else p.category end,
          'image', p.image,
          'rating', p.rating,
          'price_range', p.price_range,
          'town', p.town,
          'parish', p.parish,
          'latitude', p.latitude,
          'longitude', p.longitude,
          'visited', ip.visited,
          'planned_day', ip.planned_day,
          'planned_time', ip.planned_time,
          'time_slot', ip.time_slot,
          'order', ip."order",
          'entry_id', ip.entry_id,
          'is_note', ip.is_note,
          'note_text', ip.note_text
        )
        order by ip.planned_day nulls last, ip."order" nulls last, ip.created_at
      )
      from public.itinerary_places ip
      left join public.places p on p.id = ip.place_id
      where ip.itinerary_id = i.id
    ), '[]'::json),
    'events', coalesce((
      select json_agg(
        json_build_object(
          'id', e.id,
          'name', e.title,
          'slug', e.slug,
          'image', e.featured_image_url,
          'image_urls', e.image_urls,
          'venue_name', e.venue_name,
          'town', e.town,
          'parish', e.parish,
          'planned_day', ie.planned_day,
          'planned_time', ie.start_time,
          'time_slot', ie.time_slot,
          'start_time', ie.start_time,
          'end_time', ie.end_time,
          'order', ie."order",
          'entry_id', ie.entry_id,
          'is_event', true
        )
        order by ie.planned_day nulls last, ie."order" nulls last, ie.created_at
      )
      from public.itinerary_events ie
      join public.events e on e.id = ie.event_id
      where ie.itinerary_id = i.id
    ), '[]'::json)
  )
  into result
  from public.itineraries i
  join public.itinerary_shares s on s.itinerary_id = i.id
  left join public."user" u on u.id = i.user_id
  where s.token = _token
    and (s.expires_at is null or s.expires_at > now())
  limit 1;

  return result;
end;
$$;
grant all on function public.get_shared_itinerary(text) to anon, authenticated, service_role;
