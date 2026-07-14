create or replace function public.admin_get_low_rated_places(p_admin_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if not public._is_admin(p_admin_token) then
    return null;
  end if;

  return (
    select coalesce(jsonb_agg(jsonb_build_object(
      'place_id',  t.place_id,
      'name',      t.name,
      'slug',      t.slug,
      'n_reviews', t.n_reviews,
      'avg_score', t.avg_score,
      'last_at',   t.last_at
    ) order by t.avg_score asc), '[]'::jsonb)
    from (
      select vf.place_id,
             max(p.name) as name,
             max(p.slug) as slug,
             count(*) as n_reviews,
             round(avg(r.review_score), 2) as avg_score,
             max(vf.created_at) as last_at
        from public.visited_feedback vf
        join public.places p on p.id = vf.place_id
        cross join lateral (
          select avg(v) as review_score
            from unnest(array[
              vf.rating_taste, vf.rating_service, vf.rating_vibe,
              vf.rating_wait_time, vf.rating_value, vf.rating_comfort,
              vf.rating_cleanliness, vf.rating_facilities, vf.rating_experience,
              vf.rating_safety, vf.rating_organization
            ]) as v
           where v is not null
        ) r
       where r.review_score is not null
       group by vf.place_id
      having avg(r.review_score) < 3
    ) t
  );
end;
$$;

create or replace function public.admin_get_user_profile(
  p_admin_token text,
  p_user_id     uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $$
begin
  if not public._is_admin(p_admin_token) then
    return null;
  end if;

  return (
    select jsonb_build_object(
      'id',             u.id,
      'username',       u.username,
      'email',          u.email,
      'created_at',     u.created_at,
      'last_active_at', u.last_active_at,
      'push_opt_in',    u.push_opt_in,
      'counts', jsonb_build_object(
        'visited',        (select count(*) from public.visited v where v.user_id = u.id),
        'place_feedback', (select count(*) from public.visited_feedback vf where vf.user_id = u.id),
        'event_feedback', (select count(*) from public.event_feedback ef where ef.user_id = u.id),
        'item_ratings',   (select count(*) from public.user_vendor_item_ratings r where r.user_id = u.id),
        'saved_events',   (select count(*) from public.saved_events se where se.user_id = u.id),
        'loyalty_cards',  (select count(*) from public.user_loyalty_cards c where c.user_id = u.id),
        'checkins',       (select count(*) from public.user_checkins ck where ck.user_id = u.id)
      )
    )
    from public."user" u
    where u.id = p_user_id
  );
end;
$$;

grant execute on function public.admin_get_low_rated_places(text) to anon, authenticated;
grant execute on function public.admin_get_user_profile(text, uuid) to anon, authenticated;;
