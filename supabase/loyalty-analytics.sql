-- ============================================================
-- Loyalty Analytics — RPC for partner-analytics.html
-- Reuses places.partner_access_token (same token as booking inbox).
-- Run this in the Supabase SQL editor.
-- ============================================================

create or replace function public.get_loyalty_analytics_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place_id  uuid;
  v_program   loyalty_programs%rowtype;
  v_now       timestamptz := now();
begin
  -- Resolve token → place via the existing partner token column
  select id
    into v_place_id
    from public.places
   where partner_access_token = p_token;

  if v_place_id is null then
    return null;
  end if;

  -- Active loyalty program for this place
  select *
    into v_program
    from public.loyalty_programs
   where place_id = v_place_id
     and is_active = true
   order by created_at desc
   limit 1;

  if v_program.id is null then
    -- Place exists but has no active program yet
    return jsonb_build_object(
      'place', (select jsonb_build_object('id', id, 'name', name)
                  from public.places where id = v_place_id),
      'program', null,
      'stats',   null,
      'members', '[]'::jsonb
    );
  end if;

  return jsonb_build_object(
    'place', (
      select jsonb_build_object('id', id, 'name', name)
        from public.places where id = v_place_id
    ),
    'program', jsonb_build_object(
      'id',               v_program.id,
      'required_stamps',  v_program.required_stamps,
      'reward',           v_program.reward,
      'earning_type',     v_program.earning_type,
      'primary_color',    v_program.primary_color,
      'accent_color',     v_program.accent_color,
      'text_color',       v_program.text_color,
      'secondary_color',  v_program.secondary_color,
      'watermark_icon',   v_program.watermark_icon,
      'fine_print',       v_program.fine_print
    ),
    'stats', (
      with cards as (
        select * from public.user_loyalty_cards where program_id = v_program.id
      ),
      visits as (
        select * from public.loyalty_visits where place_id = v_place_id
      ),
      per_member as (
        select user_id, count(*) as n
          from visits
         group by user_id
      )
      select jsonb_build_object(
        'total_members',
          (select count(*) from cards),

        'active_30d',
          (select count(distinct user_id)
             from visits
            where stamped_at >= v_now - interval '30 days'),

        'new_30d',
          (select count(*) from cards
            where created_at >= v_now - interval '30 days'),

        'total_visits',
          (select count(*) from visits),

        'rewards_earned',
          (select coalesce(sum(completed_cycles), 0) from cards),

        'close_to_reward',
          (select count(*) from cards
            where is_redeemed = false
              and current_stamps >= greatest(v_program.required_stamps - 2, 1)
              and current_stamps <  v_program.required_stamps),

        'dormant_60d',
          (select count(*) from cards
            where last_stamped_at is not null
              and last_stamped_at < v_now - interval '60 days'),

        'repeat_visit_rate',
          (select case
                    when count(*) = 0 then null
                    else count(*) filter (where n >= 2)::float / count(*)
                  end
             from per_member),

        'days_since_last_visit',
          (select case
                    when max(stamped_at) is null then null
                    else floor(extract(epoch from (v_now - max(stamped_at))) / 86400)::int
                  end
             from visits)
      )
    ),
    'members', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'card_id',           c.id,
            'user_id',           c.user_id,
            'current_stamps',    c.current_stamps,
            'completed_cycles',  c.completed_cycles,
            'is_redeemed',       c.is_redeemed,
            'last_stamped_at',   c.last_stamped_at,
            'created_at',        c.created_at
          )
          order by
            c.completed_cycles desc,
            c.current_stamps   desc,
            c.last_stamped_at  desc nulls last
        ),
        '[]'::jsonb
      )
      from public.user_loyalty_cards c
      where c.program_id = v_program.id
    )
  );
end;
$$;

-- Allow the anon role to call the RPC (it gates itself on the token).
grant execute on function public.get_loyalty_analytics_by_token(text) to anon;
