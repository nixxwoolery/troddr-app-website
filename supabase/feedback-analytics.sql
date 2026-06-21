-- ============================================================
-- Feedback Analytics RPC for partner-feedback.html
-- ============================================================

create or replace function public.get_partner_feedback_by_token(p_token text)
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
      select jsonb_build_object('id', id, 'name', name, 'slug', slug)
        from public.places where id = v_place_id
    ),

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
      )
      select jsonb_build_object(

        'total',     (select count(*) from fb),
        'count_30d', (select count(*) from fb where created_at >= v_now - interval '30 days'),
        'count_7d',  (select count(*) from fb where created_at >= v_now - interval '7 days'),

        'would_return_yes',
          (select count(*) from fb where would_return = true),

        'would_return_no',
          (select count(*) from fb where would_return = false),

        'would_return_rate',
          (select case
                    when count(*) filter (where would_return is not null) = 0 then null
                    else count(*) filter (where would_return = true)::float
                       / count(*) filter (where would_return is not null)
                  end
             from fb),

        'overall_rating',
          (select round(avg(r)::numeric, 2)
             from fb, lateral (values
               (rating_service), (rating_vibe), (rating_value),
               (rating_wait_time), (rating_cleanliness),
               (rating_taste), (rating_ambiance), (rating_speed)
             ) v(r) where r is not null),

        'contexts',
          (select coalesce(jsonb_object_agg(context, n), '{}'::jsonb)
             from (select context, count(*) as n from fb group by context) c)
      )
    ),

    'avg_ratings', (
      select jsonb_build_object(
        'service',     round(avg(rating_service)::numeric,     2),
        'vibe',        round(avg(rating_vibe)::numeric,        2),
        'value',       round(avg(rating_value)::numeric,       2),
        'wait_time',   round(avg(rating_wait_time)::numeric,   2),
        'cleanliness', round(avg(rating_cleanliness)::numeric, 2),
        'taste',       round(avg(rating_taste)::numeric,       2),
        'ambiance',    round(avg(rating_ambiance)::numeric,    2),
        'speed',       round(avg(rating_speed)::numeric,       2)
      )
      from public.visited_feedback where place_id = v_place_id
    ),

    -- Per-dimension 1..5 distribution
    'distributions', (
      with fb as (select * from public.visited_feedback where place_id = v_place_id)
      select jsonb_build_object(
        'service',     (select jsonb_build_object('1', count(*) filter (where rating_service     = 1), '2', count(*) filter (where rating_service     = 2), '3', count(*) filter (where rating_service     = 3), '4', count(*) filter (where rating_service     = 4), '5', count(*) filter (where rating_service     = 5)) from fb),
        'vibe',        (select jsonb_build_object('1', count(*) filter (where rating_vibe        = 1), '2', count(*) filter (where rating_vibe        = 2), '3', count(*) filter (where rating_vibe        = 3), '4', count(*) filter (where rating_vibe        = 4), '5', count(*) filter (where rating_vibe        = 5)) from fb),
        'value',       (select jsonb_build_object('1', count(*) filter (where rating_value       = 1), '2', count(*) filter (where rating_value       = 2), '3', count(*) filter (where rating_value       = 3), '4', count(*) filter (where rating_value       = 4), '5', count(*) filter (where rating_value       = 5)) from fb),
        'wait_time',   (select jsonb_build_object('1', count(*) filter (where rating_wait_time   = 1), '2', count(*) filter (where rating_wait_time   = 2), '3', count(*) filter (where rating_wait_time   = 3), '4', count(*) filter (where rating_wait_time   = 4), '5', count(*) filter (where rating_wait_time   = 5)) from fb),
        'cleanliness', (select jsonb_build_object('1', count(*) filter (where rating_cleanliness = 1), '2', count(*) filter (where rating_cleanliness = 2), '3', count(*) filter (where rating_cleanliness = 3), '4', count(*) filter (where rating_cleanliness = 4), '5', count(*) filter (where rating_cleanliness = 5)) from fb),
        'taste',       (select jsonb_build_object('1', count(*) filter (where rating_taste       = 1), '2', count(*) filter (where rating_taste       = 2), '3', count(*) filter (where rating_taste       = 3), '4', count(*) filter (where rating_taste       = 4), '5', count(*) filter (where rating_taste       = 5)) from fb),
        'ambiance',    (select jsonb_build_object('1', count(*) filter (where rating_ambiance    = 1), '2', count(*) filter (where rating_ambiance    = 2), '3', count(*) filter (where rating_ambiance    = 3), '4', count(*) filter (where rating_ambiance    = 4), '5', count(*) filter (where rating_ambiance    = 5)) from fb),
        'speed',       (select jsonb_build_object('1', count(*) filter (where rating_speed       = 1), '2', count(*) filter (where rating_speed       = 2), '3', count(*) filter (where rating_speed       = 3), '4', count(*) filter (where rating_speed       = 4), '5', count(*) filter (where rating_speed       = 5)) from fb)
      )
    ),

    'trend', (
      select coalesce(
        jsonb_agg(jsonb_build_object('week', week, 'count', n) order by week),
        '[]'::jsonb)
      from (
        select to_char(date_trunc('week', created_at)::date, 'YYYY-MM-DD') as week,
               count(*) as n
          from public.visited_feedback
         where place_id = v_place_id
           and created_at >= v_now - interval '12 weeks'
         group by date_trunc('week', created_at)
      ) t
    ),

    'top_tags', (
      with tags as (
        select unnest(quick_tags) as tag
          from public.visited_feedback
         where place_id = v_place_id
      )
      select coalesce(
        jsonb_agg(jsonb_build_object('tag', tag, 'count', n) order by n desc),
        '[]'::jsonb)
      from (
        select tag, count(*) as n
          from tags
         where tag is not null and tag <> ''
         group by tag
         order by count(*) desc
         limit 30
      ) t
    ),

    'feedback', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id',           id,
            'user_id',      user_id,
            'created_at',   created_at,
            'updated_at',   updated_at,
            'context',      context,
            'would_return', would_return,
            'quick_tags',   quick_tags,
            'ratings', jsonb_build_object(
              'service',     rating_service,
              'vibe',        rating_vibe,
              'value',       rating_value,
              'wait_time',   rating_wait_time,
              'cleanliness', rating_cleanliness,
              'taste',       rating_taste,
              'ambiance',    rating_ambiance,
              'speed',       rating_speed
            ),
            'items', (
              select coalesce(
                jsonb_agg(
                  jsonb_build_object(
                    'name',              item_notes.canonical_name,
                    'category',          item_notes.category,
                    'notes',             item_notes.notes,
                    'sentiment',         item_notes.sentiment,
                    'would_order_again', item_notes.would_order_again,
                    'visit_date',        item_notes.visit_date
                  ) order by item_notes.created_at
                ),
                '[]'::jsonb
              )
              from (
                select mi.canonical_name, mi.category, l.notes, l.sentiment,
                       l.would_order_again, l.visit_date, l.created_at
                  from public.user_item_logs l
                  join public.menu_items mi on mi.id = l.menu_item_id
                 where l.place_id = v_place_id
                   and l.user_id = recent.user_id
                   and l.is_public = true
                   and (
                     l.visit_date = recent.created_at::date
                     or (
                       l.visit_date is null
                       and l.created_at between recent.created_at - interval '24 hours'
                                            and recent.created_at + interval '24 hours'
                     )
                   )
                 order by l.created_at
                 limit 20
              ) item_notes
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
        limit 200
      ) recent
    )
  );
end;
$$;

grant execute on function public.get_partner_feedback_by_token(text) to anon;
