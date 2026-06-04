-- ============================================================
-- Specials Analytics RPC for partner-specials.html
-- Returns place info, summary counts, per-special analytics.
-- ============================================================

create or replace function public.get_partner_specials_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place  places%rowtype;
  v_now    timestamptz := now();
begin
  select * into v_place
    from public.places
   where partner_access_token = p_token;

  if v_place.id is null then
    return null;
  end if;

  return jsonb_build_object(
    'place', jsonb_build_object(
      'id',   v_place.id,
      'name', v_place.name,
      'slug', v_place.slug
    ),

    'program', (
      select jsonb_build_object(
        'primary_color',   primary_color,
        'accent_color',    accent_color,
        'text_color',      text_color,
        'secondary_color', secondary_color
      )
      from public.loyalty_programs
      where place_id = v_place.id and is_active = true
      order by created_at desc limit 1
    ),

    'summary', (
      select jsonb_build_object(
        'total',     count(*),
        'active',    count(*) filter (where coalesce(active, true) = true
                                        and v_now between start_date and end_date),
        'upcoming',  count(*) filter (where coalesce(active, true) = true and v_now < start_date),
        'ended',     count(*) filter (where v_now > end_date),
        'inactive',  count(*) filter (where coalesce(active, true) = false),
        'total_visits',
          (select count(*) from public.special_visits
            where special_id in (select id from public.specials where place_id = v_place.id)),
        'total_interactions',
          (select count(*) from public.special_interactions
            where special_id in (select id from public.specials where place_id = v_place.id)),
        'total_ratings',
          (select count(*) from public.special_interactions
            where special_id in (select id from public.specials where place_id = v_place.id)
              and rating is not null)
      )
      from public.specials
      where place_id = v_place.id
    ),

    'specials', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',                  s.id,
        'title',               s.title,
        'description',         s.description,
        'special_type',        s.special_type,
        'special_slug',        s.special_slug,
        'start_date',          s.start_date,
        'end_date',            s.end_date,
        'start_time',          s.start_time,
        'end_time',            s.end_time,
        'is_active',           coalesce(s.active, true),
        'image_url',
          (case when s.image_urls is not null and array_length(s.image_urls, 1) > 0
                then s.image_urls[1] else null end),
        'image_urls',          s.image_urls,
        'discount_percentage', s.discount_percentage,
        'discount_amount',     s.discount_amount,
        'price_amount',        s.price_amount,
        'price_type',          s.price_type,
        'currency',            coalesce(nullif(s.currency, ''), 'JMD'),
        'recurring_days',      s.recurring_days,
        'event_category',      s.event_category,
        'priority',            coalesce(s.priority, 0),
        'lifecycle', (
          case
            when not coalesce(s.active, true) then 'inactive'
            when v_now < s.start_date then 'upcoming'
            when v_now > s.end_date then 'ended'
            else 'active'
          end
        ),
        'visits_count',
          (select count(*) from public.special_visits where special_id = s.id),
        'unique_visitors',
          (select count(distinct user_id) from public.special_visits where special_id = s.id),
        'interested_count',
          (select count(*) from public.special_interactions where special_id = s.id and status = 'interested'),
        'going_count',
          (select count(*) from public.special_interactions where special_id = s.id and status = 'going'),
        'attended_count',
          (select count(*) from public.special_interactions where special_id = s.id and status = 'attended'),
        'upvotes',
          (select count(*) from public.special_interactions where special_id = s.id and vote = 'up'),
        'downvotes',
          (select count(*) from public.special_interactions where special_id = s.id and vote = 'down'),
        'rating_avg',
          (select round(avg(rating)::numeric, 2) from public.special_interactions
            where special_id = s.id and rating is not null),
        'rating_count',
          (select count(*) from public.special_interactions
            where special_id = s.id and rating is not null),
        'avg_ratings', (
          select jsonb_build_object(
            'value',         round(avg(rating_value)::numeric,         2),
            'vibe',          round(avg(rating_vibe)::numeric,          2),
            'experience',    round(avg(rating_experience)::numeric,    2),
            'organisation',  round(avg(rating_organisation)::numeric,  2),
            'taste',         round(avg(rating_taste)::numeric,         2),
            'portions',      round(avg(rating_portions)::numeric,      2),
            'presentation',  round(avg(rating_presentation)::numeric,  2),
            'drinks',        round(avg(rating_drinks)::numeric,        2)
          )
          from public.special_interactions where special_id = s.id
        ),
        'top_tags', (
          select coalesce(
            jsonb_agg(jsonb_build_object('tag', tag, 'count', n) order by n desc),
            '[]'::jsonb)
          from (
            select tag, count(*) as n
            from (
              select unnest(quick_tags) as tag
              from public.special_interactions
              where special_id = s.id
            ) tags
            where tag is not null and tag <> ''
            group by tag
            order by count(*) desc
            limit 6
          ) t
        )
      ) order by
          (case when coalesce(s.active, true) = true and v_now between s.start_date and s.end_date then 0
                when coalesce(s.active, true) = true and v_now < s.start_date then 1
                else 2 end),
          s.priority desc nulls last,
          s.start_date desc
      ), '[]'::jsonb)
      from public.specials s
      where s.place_id = v_place.id
    )
  );
end;
$$;

grant execute on function public.get_partner_specials_by_token(text) to anon;
