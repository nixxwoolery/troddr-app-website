-- ============================================================
-- Item Insights RPCs for partner-feedback.html + partner-group.html
-- ------------------------------------------------------------
-- Anonymous, aggregate leaderboards derived from app Taste Notes:
--   menu_items  — canonical dish/drink per place (elo_rating /
--                 total_reviews are anonymous aggregates).
--   user_item_logs — the only rating-bearing table; public rows
--                 (is_public = true) feed per-person aggregates
--                 and comments.
--
-- Read-only. Granted to anon (partner-token gated, like the other
-- partner analytics RPCs). Mirrors group-insights.sql conventions.
-- Idempotent — safe to re-run.
--
-- Privacy invariants (enforced here, not the client):
--   * comments + reorder rate read is_public = true ONLY
--   * min-count threshold (p_min_reviews) gates house_favourites
--     and the elo leaderboards before any row is shown
--   * user_id / identity is NEVER selected
-- ============================================================

-- ------------------------------------------------------------
-- Single place
-- ------------------------------------------------------------
create or replace function public.get_partner_item_insights_by_token(
  p_token text,
  p_min_reviews int default 5
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place places%rowtype;
begin
  select * into v_place from public.places where partner_access_token = p_token;

  if v_place.id is null then
    -- Event-only token is still a valid partner: empty-but-ok payload.
    if exists (select 1 from public.events where partner_access_token = p_token) then
      return jsonb_build_object('ok', true, 'place', null, 'min_reviews', p_min_reviews,
        'most_loved', '[]'::jsonb, 'lowest_rated', '[]'::jsonb, 'hidden_gems', '[]'::jsonb,
        'house_favourites', '[]'::jsonb, 'comments', '[]'::jsonb,
        'unavailable', jsonb_build_object(
          'trending', 'no elo history/snapshot stored yet',
          'most_saved', 'user_favorite_items dormant; user_saved_menu_items is event-scoped'));
    end if;
    return null; -- invalid / revoked token
  end if;

  return jsonb_build_object(
    'ok', true,
    'place', jsonb_build_object('id', v_place.id, 'name', v_place.name, 'slug', v_place.slug),
    'min_reviews', p_min_reviews,

    -- Highest Elo (min reviews) — anonymous aggregate, safe to rank.
    'most_loved', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'menu_item_id', id, 'name', canonical_name, 'category', category,
        'elo_rating', elo_rating, 'total_reviews', total_reviews) order by elo_rating desc), '[]'::jsonb)
      from (
        select id, canonical_name, category, elo_rating, total_reviews
          from public.menu_items
         where place_id = v_place.id and total_reviews >= p_min_reviews
         order by elo_rating desc limit 10
      ) t
    ),

    -- Lowest Elo (min reviews) — for attention.
    'lowest_rated', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'menu_item_id', id, 'name', canonical_name, 'category', category,
        'elo_rating', elo_rating, 'total_reviews', total_reviews) order by elo_rating asc), '[]'::jsonb)
      from (
        select id, canonical_name, category, elo_rating, total_reviews
          from public.menu_items
         where place_id = v_place.id and total_reviews >= p_min_reviews
         order by elo_rating asc limit 10
      ) t
    ),

    -- High Elo, low exposure.
    'hidden_gems', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'menu_item_id', id, 'name', canonical_name, 'category', category,
        'elo_rating', elo_rating, 'total_reviews', total_reviews) order by elo_rating desc), '[]'::jsonb)
      from (
        select id, canonical_name, category, elo_rating, total_reviews
          from public.menu_items
         where place_id = v_place.id
           and elo_rating >= 1100
           and total_reviews between 2 and greatest(p_min_reviews - 1, 2)
         order by elo_rating desc limit 10
      ) t
    ),

    -- Highest reorder rate — public logs + min-count threshold.
    'house_favourites', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'menu_item_id', mi.id, 'name', mi.canonical_name, 'category', mi.category,
        'reviews', s.n, 'reorder_rate', round(s.rate::numeric, 2)) order by s.rate desc), '[]'::jsonb)
      from (
        select menu_item_id, count(*) as n, avg((would_order_again)::int) as rate
          from public.user_item_logs
         where place_id = v_place.id and is_public = true
         group by menu_item_id
        having count(*) >= p_min_reviews
         order by avg((would_order_again)::int) desc nulls last
         limit 10
      ) s
      join public.menu_items mi on mi.id = s.menu_item_id
    ),

    -- Recent public comments — anonymous (no user_id).
    'comments', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'name', mi.canonical_name, 'notes', l.notes, 'sentiment', l.sentiment,
        'would_order_again', l.would_order_again, 'visit_date', l.visit_date) order by l.created_at desc), '[]'::jsonb)
      from (
        select menu_item_id, notes, sentiment, would_order_again, visit_date, created_at
          from public.user_item_logs
         where place_id = v_place.id and is_public = true
           and notes is not null and trim(notes) <> ''
         order by created_at desc limit 30
      ) l
      join public.menu_items mi on mi.id = l.menu_item_id
    ),

    -- Flagged, never fabricated.
    'unavailable', jsonb_build_object(
      'trending', 'no elo history/snapshot stored yet',
      'most_saved', 'user_favorite_items dormant; user_saved_menu_items is event-scoped'
    )
  );
end;
$$;

grant execute on function public.get_partner_item_insights_by_token(text, int) to anon;

