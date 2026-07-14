-- ============================================================
-- TRODDR Admin — Feedback Inbox RPCs (Phase 2)
-- Idempotent. Safe to re-run.
--
-- Powers admin-feedback.html: one read RPC covering all four
-- feedback streams, plus a write RPC for app-feedback triage.
--
-- Streams:
--   event_feedback           post-event vote + 4 ratings + quick_tags
--   visited_feedback         place sentiment, 11 nullable rating dims + quick_tags
--   feedback                 general app feedback (status / team_response workflow)
--   user_vendor_item_ratings liked/disliked per vendor menu item at events
--
-- Place quick_tags are canonicalized. Production tags have no
-- underscores (friendlystaff, goodforgroups, …) and real synonym
-- pairs exist in the data (goodforgroups/greatforgroups,
-- goodforsolo/solofriendly); underscore variants from the older
-- Context Engine contract are mapped too, defensively.
-- ============================================================

create or replace function public.admin_get_feedback(
  p_admin_token text,
  p_days        integer default 365
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_days integer     := greatest(1, least(coalesce(p_days, 365), 3650));
  v_from timestamptz := now() - make_interval(days => v_days);
begin
  if not public._is_admin(p_admin_token) then
    return null;
  end if;

  return jsonb_build_object(

    'window_days', v_days,
    'generated_at', now(),

    'counts', jsonb_build_object(
      'event',    (select count(*) from public.event_feedback where created_at >= v_from),
      'place',    (select count(*) from public.visited_feedback where created_at >= v_from),
      'app_open', (select count(*) from public.feedback
                    where coalesce(status, 'submitted') not in ('resolved','closed','done')),
      'items',    (select count(*) from public.user_vendor_item_ratings where created_at >= v_from)
    ),

    -- ── Event feedback ─────────────────────────────────────
    'event', jsonb_build_object(
      'summary', (
        select jsonb_build_object(
          'total', count(*),
          'up',    count(*) filter (where vote = 'up'),
          'down',  count(*) filter (where vote = 'down'),
          'avgs',  jsonb_strip_nulls(jsonb_build_object(
            'experience',   round(avg(rating_experience), 1),
            'organization', round(avg(rating_organization), 1),
            'value',        round(avg(rating_value), 1),
            'food',         round(avg(rating_food), 1)
          ))
        )
        from public.event_feedback where created_at >= v_from
      ),
      'tags', (
        select coalesce(jsonb_agg(jsonb_build_object('tag', tag, 'n', n) order by n desc), '[]'::jsonb)
        from (
          select t.tag, count(*) as n
            from public.event_feedback ef, unnest(ef.quick_tags) as t(tag)
           where ef.created_at >= v_from
           group by t.tag
           order by count(*) desc
           limit 20
        ) s
      ),
      'items', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id',          ef.id,
          'created_at',  ef.created_at,
          'vote',        ef.vote,
          'ratings',     jsonb_strip_nulls(jsonb_build_object(
                           'experience',   ef.rating_experience,
                           'organization', ef.rating_organization,
                           'value',        ef.rating_value,
                           'food',         ef.rating_food)),
          'quick_tags',  coalesce(to_jsonb(ef.quick_tags), '[]'::jsonb),
          'username',    coalesce(u.username, 'anonymous'),
          'event_title', e.title,
          'event_slug',  e.slug
        ) order by ef.created_at desc), '[]'::jsonb)
        from (select * from public.event_feedback
               where created_at >= v_from
               order by created_at desc limit 200) ef
        left join public.events e on e.id = ef.event_id
        left join public."user" u on u.id = ef.user_id
      )
    ),

    -- ── Place sentiment (visited_feedback) ─────────────────
    'place', jsonb_build_object(
      'summary', (
        select jsonb_build_object(
          'total', count(*),
          'would_return',     count(*) filter (where would_return = true),
          'would_not_return', count(*) filter (where would_return = false),
          'avgs', jsonb_strip_nulls(jsonb_build_object(
            'taste',        round(avg(rating_taste), 1),
            'service',      round(avg(rating_service), 1),
            'vibe',         round(avg(rating_vibe), 1),
            'wait_time',    round(avg(rating_wait_time), 1),
            'value',        round(avg(rating_value), 1),
            'comfort',      round(avg(rating_comfort), 1),
            'cleanliness',  round(avg(rating_cleanliness), 1),
            'facilities',   round(avg(rating_facilities), 1),
            'experience',   round(avg(rating_experience), 1),
            'safety',       round(avg(rating_safety), 1),
            'organization', round(avg(rating_organization), 1)
          ))
        )
        from public.visited_feedback where created_at >= v_from
      ),
      'tags', (
        select coalesce(jsonb_agg(jsonb_build_object('tag', tag, 'n', n) order by n desc), '[]'::jsonb)
        from (
          select case t.tag
                   when 'greatforgroups'    then 'goodforgroups'
                   when 'great_for_groups'  then 'goodforgroups'
                   when 'good_for_groups'   then 'goodforgroups'
                   when 'group_friendly'    then 'goodforgroups'
                   when 'solofriendly'      then 'goodforsolo'
                   when 'solo_friendly'     then 'goodforsolo'
                   when 'good_for_solo'     then 'goodforsolo'
                   when 'greatforcouples'   then 'romantic'
                   when 'great_for_couples' then 'romantic'
                   when 'livelyvibe'        then 'lively'
                   when 'lively_vibe'       then 'lively'
                   else t.tag
                 end as tag,
                 count(*) as n
            from public.visited_feedback vf, unnest(vf.quick_tags) as t(tag)
           where vf.created_at >= v_from
           group by 1
           order by count(*) desc
           limit 25
        ) s
      ),
      'items', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id',           vf.id,
          'created_at',   vf.created_at,
          'place_name',   p.name,
          'place_slug',   p.slug,
          'username',     coalesce(u.username, 'anonymous'),
          'would_return', vf.would_return,
          'context',      vf.context,
          'ratings',      jsonb_strip_nulls(jsonb_build_object(
                            'taste',        vf.rating_taste,
                            'service',      vf.rating_service,
                            'vibe',         vf.rating_vibe,
                            'wait_time',    vf.rating_wait_time,
                            'value',        vf.rating_value,
                            'comfort',      vf.rating_comfort,
                            'cleanliness',  vf.rating_cleanliness,
                            'facilities',   vf.rating_facilities,
                            'experience',   vf.rating_experience,
                            'safety',       vf.rating_safety,
                            'organization', vf.rating_organization)),
          'quick_tags',   coalesce(to_jsonb(vf.quick_tags), '[]'::jsonb)
        ) order by vf.created_at desc), '[]'::jsonb)
        from (select * from public.visited_feedback
               where created_at >= v_from
               order by created_at desc limit 200) vf
        left join public.places p on p.id = vf.place_id
        left join public."user" u on u.id = vf.user_id
      )
    ),

    -- ── App feedback (full inbox, no window — needs triage) ─
    'app', jsonb_build_object(
      'items', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id',            f.id,
          'created_at',    f.created_at,
          'username',      coalesce(f.username, u.username, 'anonymous'),
          'category',      f.category,
          'feedback',      f.feedback,
          'status',        coalesce(f.status, 'submitted'),
          'team_response', f.team_response,
          'responded_at',  f.responded_at,
          'upvotes',       f.upvotes
        ) order by
            case when coalesce(f.status, 'submitted') in ('resolved','closed','done') then 1 else 0 end,
            f.created_at desc), '[]'::jsonb)
        from public.feedback f
        left join public."user" u on u.id = f.user_id
      )
    ),

    -- ── Item ratings (Taste-Notes style liked/disliked) ────
    'items_tab', jsonb_build_object(
      'summary', (
        select jsonb_build_object(
          'total',    count(*),
          'liked',    count(*) filter (where rating = 'liked'),
          'disliked', count(*) filter (where rating = 'disliked')
        )
        from public.user_vendor_item_ratings where created_at >= v_from
      ),
      'top_items', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'item',        t.item_name,
          'vendor',      t.vendor_name,
          'event_title', t.event_title,
          'liked',       t.liked,
          'disliked',    t.disliked
        ) order by (t.liked + t.disliked) desc), '[]'::jsonb)
        from (
          select r.item_name,
                 coalesce(max(v.name), 'Unknown vendor') as vendor_name,
                 max(e.title) as event_title,
                 count(*) filter (where r.rating = 'liked')    as liked,
                 count(*) filter (where r.rating = 'disliked') as disliked
            from public.user_vendor_item_ratings r
            left join public.vendors v on v.id::text = r.vendor_id
            left join public.events  e on e.id = r.event_id
           where r.created_at >= v_from
           group by r.item_name, r.vendor_id
           order by count(*) desc
           limit 25
        ) t
      ),
      'items', (
        select coalesce(jsonb_agg(jsonb_build_object(
          'id',          r.id,
          'created_at',  r.created_at,
          'item',        r.item_name,
          'rating',      r.rating,
          'vendor',      coalesce(v.name, 'Unknown vendor'),
          'event_title', e.title,
          'username',    coalesce(u.username, 'anonymous')
        ) order by r.created_at desc), '[]'::jsonb)
        from (select * from public.user_vendor_item_ratings
               where created_at >= v_from
               order by created_at desc limit 200) r
        left join public.vendors v on v.id::text = r.vendor_id
        left join public.events  e on e.id = r.event_id
        left join public."user"  u on u.id = r.user_id
      )
    )

  );
end;
$$;

-- ─────────────────────────────────────────────────────────────
-- App-feedback triage: set status and/or record a team response
-- ─────────────────────────────────────────────────────────────
create or replace function public.admin_set_app_feedback(
  p_admin_token   text,
  p_id            uuid,
  p_status        text default null,
  p_team_response text default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_row jsonb;
begin
  if not public._is_admin(p_admin_token) then
    return null;
  end if;

  if p_status is not null
     and p_status not in ('submitted','reviewing','resolved','closed') then
    raise exception 'invalid status: %', p_status;
  end if;

  update public.feedback
     set status        = coalesce(p_status, status),
         team_response = coalesce(p_team_response, team_response),
         responded_at  = case when p_team_response is not null then now() else responded_at end
   where id = p_id
   returning jsonb_build_object(
     'id', id, 'status', status,
     'team_response', team_response, 'responded_at', responded_at
   ) into v_row;

  return v_row;
end;
$$;

-- ─────────────────────────────────────────────────────────────
-- Grants — same access model as the other admin RPCs
-- ─────────────────────────────────────────────────────────────
grant execute on function public.admin_get_feedback(text, integer) to anon, authenticated;
grant execute on function public.admin_set_app_feedback(text, uuid, text, text) to anon, authenticated;
