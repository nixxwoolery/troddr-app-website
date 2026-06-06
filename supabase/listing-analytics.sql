-- ============================================================
-- Listing Analytics RPC for partner-listing.html
-- Reuses places.partner_access_token (same token as other partner pages).
-- ============================================================

create or replace function public.get_partner_listing_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place_id  uuid;
  v_now       timestamptz := now();
begin
  select id
    into v_place_id
    from public.places
   where partner_access_token = p_token;

  if v_place_id is null then
    return null;
  end if;

  return jsonb_build_object(

    'place', (
      select to_jsonb(p) - 'partner_access_token'
        from public.places p
       where p.id = v_place_id
    ),

    'closures', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',            id,
        'date',          date,
        'is_closed',     is_closed,
        'open_time',     open_time,
        'close_time',    close_time,
        'kitchen_open',  kitchen_open,
        'kitchen_close', kitchen_close,
        'reason',        reason
      ) order by date), '[]'::jsonb)
      from public.place_special_hours
      where place_id = v_place_id
        and date >= current_date - interval '7 days'
    ),

    -- Loyalty program (for brand colors, if one exists)
    'program', (
      select jsonb_build_object(
        'primary_color',   primary_color,
        'accent_color',    accent_color,
        'text_color',      text_color,
        'secondary_color', secondary_color
      )
      from public.loyalty_programs
      where place_id = v_place_id and is_active = true
      order by created_at desc
      limit 1
    ),

    'stats', (
      with fb as (
        select * from public.visited_feedback where place_id = v_place_id
      ),
      pve as (
        select * from public.place_visit_events where place_id = v_place_id
      )
      select jsonb_build_object(

        'marked_visits',
          (select count(*) from pve),

        'marked_visits_30d',
          (select count(*) from pve where visited_at >= v_now - interval '30 days'),

        'unique_visitors',
          (select count(distinct user_id) from pve),

        'feedback_count',
          (select count(*) from fb),

        'feedback_30d',
          (select count(*) from fb where created_at >= v_now - interval '30 days'),

        'would_return_rate',
          (select case
                    when count(*) filter (where would_return is not null) = 0 then null
                    else count(*) filter (where would_return = true)::float
                       / count(*) filter (where would_return is not null)
                  end
             from fb),

        'avg_ratings', jsonb_build_object(
          'service',     (select round(avg(rating_service)::numeric,    2) from fb),
          'vibe',        (select round(avg(rating_vibe)::numeric,       2) from fb),
          'value',       (select round(avg(rating_value)::numeric,      2) from fb),
          'wait_time',   (select round(avg(rating_wait_time)::numeric,  2) from fb),
          'cleanliness', (select round(avg(rating_cleanliness)::numeric,2) from fb),
          'taste',       (select round(avg(rating_taste)::numeric,      2) from fb),
          'ambiance',    (select round(avg(rating_ambiance)::numeric,   2) from fb),
          'speed',       (select round(avg(rating_speed)::numeric,      2) from fb)
        ),

        'overall_rating',
          (select round(avg(r)::numeric, 2)
             from fb, lateral (values
               (rating_service), (rating_vibe), (rating_value),
               (rating_wait_time), (rating_cleanliness),
               (rating_taste), (rating_ambiance), (rating_speed)
             ) v(r)
            where r is not null)
      )
    ),

    'top_tags', (
      with tags as (
        select unnest(quick_tags) as tag
          from public.visited_feedback
         where place_id = v_place_id
      )
      select coalesce(
        jsonb_agg(jsonb_build_object('tag', tag, 'count', n)
                  order by n desc),
        '[]'::jsonb)
      from (
        select tag, count(*) as n
          from tags
         where tag is not null and tag <> ''
         group by tag
         order by count(*) desc
         limit 12
      ) t
    ),

    'recent_feedback', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id',          id,
            'user_id',     user_id,
            'created_at',  created_at,
            'context',     context,
            'would_return', would_return,
            'quick_tags',  quick_tags,
            'ratings', jsonb_build_object(
              'service',     rating_service,
              'vibe',        rating_vibe,
              'value',       rating_value,
              'wait_time',   rating_wait_time,
              'cleanliness', rating_cleanliness,
              'taste',       rating_taste,
              'ambiance',    rating_ambiance,
              'speed',       rating_speed
            )
          )
          order by created_at desc
        ),
        '[]'::jsonb
      )
      from (
        select * from public.visited_feedback
        where place_id = v_place_id
        order by created_at desc
        limit 20
      ) recent
    )
  );
end;
$$;

grant execute on function public.get_partner_listing_by_token(text) to anon;
