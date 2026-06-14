-- ============================================================
-- Group Insights RPC for partner-group.html
-- ------------------------------------------------------------
-- Aggregates guest-feedback metrics across every PLACE in the
-- partner's group (resolved the same way as the capabilities /
-- entity-picker RPC: partner_id, hospitality_group, or
-- parent_place_id), so the group landing can show a roll-up plus
-- a per-location leaderboard.
--
-- Read-only. Granted to anon (partner-token gated, like the other
-- partner analytics RPCs). Run AFTER feedback-analytics.sql.
-- Idempotent — safe to re-run.
-- ============================================================

create or replace function public.get_partner_group_insights_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place         places%rowtype;
  v_partner_id    uuid;
  v_group_key     text;
  v_root_place_id uuid;
  v_now           timestamptz := now();
  v_place_ids     uuid[];
begin
  select * into v_place from public.places where partner_access_token = p_token;

  if v_place.id is null then
    -- Group insights are place-based. An event-only token is still a
    -- valid partner, so return an empty (but ok) payload rather than null.
    if exists (select 1 from public.events where partner_access_token = p_token) then
      return jsonb_build_object('ok', true,
        'totals', jsonb_build_object('locations', 0, 'total', 0, 'count_30d', 0,
                  'count_7d', 0, 'would_return_rate', null, 'overall_rating', null),
        'locations', '[]'::jsonb, 'trend', '[]'::jsonb, 'top_tags', '[]'::jsonb);
    end if;
    return null; -- invalid / revoked token
  end if;

  v_partner_id    := v_place.partner_id;
  v_group_key     := nullif(trim(coalesce(v_place.hospitality_group, '')), '');
  v_root_place_id := coalesce(v_place.parent_place_id, v_place.id);

  select array_agg(id) into v_place_ids
    from public.places
   where (v_partner_id is not null and partner_id = v_partner_id)
      or (v_group_key is not null and hospitality_group = v_group_key)
      or (id = v_root_place_id or parent_place_id = v_root_place_id);

  if v_place_ids is null then
    v_place_ids := array[v_place.id];
  end if;

  return jsonb_build_object(
    'ok', true,

    'totals', (
      with fb as (select * from public.visited_feedback where place_id = any(v_place_ids))
      select jsonb_build_object(
        'locations',  array_length(v_place_ids, 1),
        'total',      (select count(*) from fb),
        'count_30d',  (select count(*) from fb where created_at >= v_now - interval '30 days'),
        'count_7d',   (select count(*) from fb where created_at >= v_now - interval '7 days'),
        'would_return_rate',
          (select case when count(*) filter (where would_return is not null) = 0 then null
                       else count(*) filter (where would_return = true)::float
                          / count(*) filter (where would_return is not null) end
             from fb),
        'overall_rating',
          (select round(avg(r)::numeric, 2)
             from fb, lateral (values
               (rating_service), (rating_vibe), (rating_value), (rating_wait_time),
               (rating_cleanliness), (rating_taste), (rating_ambiance), (rating_speed)
             ) v(r) where r is not null)
      )
    ),

    -- Per-location leaderboard (highest review count first).
    'locations', (
      select coalesce(jsonb_agg(loc order by (loc->>'total')::int desc, loc->>'name'), '[]'::jsonb)
      from (
        select jsonb_build_object(
          'id',     p.id,
          'name',   p.name,
          'slug',   p.slug,
          'town',   p.town,
          'parish', p.parish,
          'total',     (select count(*) from public.visited_feedback f where f.place_id = p.id),
          'count_30d', (select count(*) from public.visited_feedback f
                          where f.place_id = p.id and f.created_at >= v_now - interval '30 days'),
          'would_return_rate',
            (select case when count(*) filter (where would_return is not null) = 0 then null
                         else count(*) filter (where would_return = true)::float
                            / count(*) filter (where would_return is not null) end
               from public.visited_feedback f where f.place_id = p.id),
          'overall_rating',
            (select round(avg(r)::numeric, 2)
               from public.visited_feedback f, lateral (values
                 (f.rating_service), (f.rating_vibe), (f.rating_value), (f.rating_wait_time),
                 (f.rating_cleanliness), (f.rating_taste), (f.rating_ambiance), (f.rating_speed)
               ) v(r) where f.place_id = p.id and r is not null)
        ) as loc
        from public.places p
        where p.id = any(v_place_ids)
      ) sub
    ),

    -- Group-wide weekly review volume, last 12 weeks.
    'trend', (
      select coalesce(jsonb_agg(jsonb_build_object('week', week, 'count', n) order by week), '[]'::jsonb)
      from (
        select to_char(date_trunc('week', created_at)::date, 'YYYY-MM-DD') as week, count(*) as n
          from public.visited_feedback
         where place_id = any(v_place_ids)
           and created_at >= v_now - interval '12 weeks'
         group by date_trunc('week', created_at)
      ) t
    ),

    -- Most common quick-tags across the group.
    'top_tags', (
      with tags as (
        select unnest(quick_tags) as tag
          from public.visited_feedback where place_id = any(v_place_ids)
      )
      select coalesce(jsonb_agg(jsonb_build_object('tag', tag, 'count', n) order by n desc), '[]'::jsonb)
      from (
        select tag, count(*) as n from tags
         where tag is not null and tag <> ''
         group by tag order by count(*) desc limit 20
      ) t
    )
  );
end;
$$;

grant execute on function public.get_partner_group_insights_by_token(text) to anon;
