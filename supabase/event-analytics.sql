-- ============================================================
-- Event Analytics RPC for partner-event.html
-- Resolves events.partner_access_token.
-- ============================================================

create or replace function public.get_partner_event_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event   events%rowtype;
  v_now     timestamptz := now();
  v_starts  timestamptz;
  v_ends    timestamptz;
  v_days    int;
  v_is_past boolean;
  v_tabs    jsonb;
begin
  select * into v_event
    from public.events
   where partner_access_token = p_token;

  if v_event.id is null then
    return null;
  end if;

  -- Compose timestamps from date + time (if available)
  v_starts := (v_event.start_date::timestamp
               + coalesce(v_event.start_time, '00:00'::time))
              at time zone coalesce(v_event.timezone, 'America/Jamaica');
  v_ends   := (coalesce(v_event.end_date, v_event.start_date)::timestamp
               + coalesce(v_event.end_time, '23:59'::time))
              at time zone coalesce(v_event.timezone, 'America/Jamaica');

  v_days    := floor(extract(epoch from (v_starts - v_now)) / 86400)::int;
  v_is_past := v_ends < v_now;

  v_tabs := coalesce(nullif(v_event.tabs, '')::jsonb, '[]'::jsonb);

  return jsonb_build_object(

    'event', (to_jsonb(v_event) - 'partner_access_token'),

    'stats', jsonb_build_object(
      'view_count',       coalesce(v_event.view_count, 0),
      'interested_count', coalesce(v_event.interested_count, 0),
      'going_count',      coalesce(v_event.going_count, 0),
      'capacity',         v_event.capacity,
      'is_sold_out',      coalesce(v_event.is_sold_out, false),
      'days_until_event', v_days,
      'is_past',          v_is_past,
      'is_today',         (v_starts::date = v_now::date),
      'has_tickets',      coalesce(v_event.has_online_tickets, false),
      'price_min',        v_event.ticket_price_min,
      'price_max',        v_event.ticket_price_max,
      'currency',         coalesce(nullif(v_event.currency, ''), 'JMD'),

      'capacity_fill_rate',
        (case
          when v_event.capacity is null or v_event.capacity = 0 then null
          else round(
            (coalesce(v_event.going_count, 0)::numeric / v_event.capacity) * 100,
            1)
        end),

      'view_to_interest_rate',
        (case
          when coalesce(v_event.view_count, 0) = 0 then null
          else round(
            (coalesce(v_event.interested_count, 0)::numeric / v_event.view_count) * 100,
            1)
        end),

      'interest_to_going_rate',
        (case
          when coalesce(v_event.interested_count, 0) = 0 then null
          else round(
            (coalesce(v_event.going_count, 0)::numeric / v_event.interested_count) * 100,
            1)
        end)
    ),

    'tabs', v_tabs,

    'capabilities', jsonb_build_object(
      'event',   true,
      'vendors', coalesce(
        (select bool_or(t->>'key' = 'vendors')
           from jsonb_array_elements(v_tabs) t),
        false)
    )
  );
end;
$$;

grant execute on function public.get_partner_event_by_token(text) to anon;
