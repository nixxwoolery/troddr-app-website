-- ============================================================
-- Loyalty Analytics RPC for partner-analytics.html
-- Reuses places.partner_access_token (same token as booking inbox).
-- Run this in the Supabase SQL editor.
-- ============================================================

alter table public.loyalty_programs
  add column if not exists spend_per_stamp numeric(12,2),
  add column if not exists stamp_icon text not null default 'bowl',
  add column if not exists stamp_logo_url text,
  add column if not exists card_theme text not null default 'classic',
  add column if not exists silver_after_redemptions integer not null default 2,
  add column if not exists gold_after_redemptions integer not null default 5,
  add column if not exists platinum_after_redemptions integer not null default 10,
  add column if not exists card_design_notes text,
  add column if not exists updated_at timestamptz not null default now();

create table if not exists public.loyalty_redemptions (
  id             uuid primary key default gen_random_uuid(),
  program_id     uuid not null references public.loyalty_programs(id) on delete cascade,
  card_id        uuid not null references public.user_loyalty_cards(id) on delete cascade,
  place_id       uuid not null references public.places(id) on delete cascade,
  user_id        uuid,
  reward         text not null,
  stamps_spent   integer not null,
  cycle_number   integer not null default 1,
  source         text not null default 'partner_dashboard'
    check (source in ('app', 'partner_dashboard', 'staff', 'migration', 'other')),
  redeemed_by    text,
  notes          text,
  redeemed_at    timestamptz not null default now(),
  created_at     timestamptz not null default now()
);

create index if not exists idx_loyalty_redemptions_program
  on public.loyalty_redemptions(program_id, redeemed_at desc);

create index if not exists idx_loyalty_redemptions_card
  on public.loyalty_redemptions(card_id, redeemed_at desc);

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
      'spend_per_stamp',  v_program.spend_per_stamp,
      'earning_type',     v_program.earning_type,
      'stamp_icon',       v_program.stamp_icon,
      'stamp_logo_url',   v_program.stamp_logo_url,
      'card_theme',       v_program.card_theme,
      'silver_after_redemptions',   v_program.silver_after_redemptions,
      'gold_after_redemptions',     v_program.gold_after_redemptions,
      'platinum_after_redemptions', v_program.platinum_after_redemptions,
      'card_design_notes',          v_program.card_design_notes,
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
    ),
    'redemptions', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id',            r.id,
            'card_id',       r.card_id,
            'user_id',       r.user_id,
            'reward',        r.reward,
            'stamps_spent',  r.stamps_spent,
            'cycle_number',  r.cycle_number,
            'source',        r.source,
            'redeemed_by',   r.redeemed_by,
            'notes',         r.notes,
            'redeemed_at',   r.redeemed_at
          )
          order by r.redeemed_at desc
        ),
        '[]'::jsonb
      )
      from (
        select *
          from public.loyalty_redemptions
         where program_id = v_program.id
         order by redeemed_at desc
         limit 100
      ) r
    )
  );
end;
$$;

-- Allow the anon role to call the RPC (it gates itself on the token).
grant execute on function public.get_loyalty_analytics_by_token(text) to anon;


-- Partner-editable loyalty program settings. This intentionally only exposes
-- reward economics and guest-facing copy; brand styling remains admin-managed.
create or replace function public.update_loyalty_program_by_token(
  p_token text,
  p_required_stamps integer default null,
  p_reward text default null,
  p_spend_per_stamp numeric default null,
  p_fine_print text default null,
  p_stamp_icon text default null,
  p_stamp_logo_url text default null,
  p_card_theme text default null,
  p_silver_after_redemptions integer default null,
  p_gold_after_redemptions integer default null,
  p_platinum_after_redemptions integer default null,
  p_card_design_notes text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place_id uuid;
  v_program loyalty_programs%rowtype;
begin
  select id
    into v_place_id
    from public.places
   where partner_access_token = p_token;

  if v_place_id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid partner token');
  end if;

  select *
    into v_program
    from public.loyalty_programs
   where place_id = v_place_id
     and is_active = true
   order by created_at desc
   limit 1;

  if v_program.id is null then
    return jsonb_build_object('ok', false, 'error', 'No active loyalty program found');
  end if;

  if p_required_stamps is not null and (p_required_stamps < 1 or p_required_stamps > 100) then
    return jsonb_build_object('ok', false, 'error', 'Required stamps must be between 1 and 100');
  end if;

  if p_spend_per_stamp is not null and p_spend_per_stamp < 0 then
    return jsonb_build_object('ok', false, 'error', 'Spend per stamp cannot be negative');
  end if;

  if p_stamp_icon is not null and p_stamp_icon not in ('bowl','star','coffee','cocktail','leaf','music','logo') then
    return jsonb_build_object('ok', false, 'error', 'Choose a valid stamp icon');
  end if;

  if p_card_theme is not null and p_card_theme not in ('classic','silver','gold','platinum','brand') then
    return jsonb_build_object('ok', false, 'error', 'Choose a valid card design');
  end if;

  if p_silver_after_redemptions is not null and p_silver_after_redemptions < 1 then
    return jsonb_build_object('ok', false, 'error', 'Silver threshold must be at least 1');
  end if;

  if p_gold_after_redemptions is not null and p_gold_after_redemptions < 1 then
    return jsonb_build_object('ok', false, 'error', 'Gold threshold must be at least 1');
  end if;

  if p_platinum_after_redemptions is not null and p_platinum_after_redemptions < 1 then
    return jsonb_build_object('ok', false, 'error', 'Platinum threshold must be at least 1');
  end if;

  if coalesce(p_silver_after_redemptions, v_program.silver_after_redemptions) >=
     coalesce(p_gold_after_redemptions, v_program.gold_after_redemptions) then
    return jsonb_build_object('ok', false, 'error', 'Gold must unlock after Silver');
  end if;

  if coalesce(p_gold_after_redemptions, v_program.gold_after_redemptions) >=
     coalesce(p_platinum_after_redemptions, v_program.platinum_after_redemptions) then
    return jsonb_build_object('ok', false, 'error', 'Platinum must unlock after Gold');
  end if;

  update public.loyalty_programs
     set required_stamps = coalesce(p_required_stamps, required_stamps),
         reward          = coalesce(nullif(trim(p_reward), ''), reward),
         spend_per_stamp = p_spend_per_stamp,
         fine_print      = p_fine_print,
         stamp_icon      = coalesce(p_stamp_icon, stamp_icon),
         stamp_logo_url  = nullif(trim(p_stamp_logo_url), ''),
         card_theme      = coalesce(p_card_theme, card_theme),
         silver_after_redemptions   = coalesce(p_silver_after_redemptions, silver_after_redemptions),
         gold_after_redemptions     = coalesce(p_gold_after_redemptions, gold_after_redemptions),
         platinum_after_redemptions = coalesce(p_platinum_after_redemptions, platinum_after_redemptions),
         card_design_notes          = p_card_design_notes,
         updated_at      = now()
   where id = v_program.id
   returning * into v_program;

  return jsonb_build_object(
    'ok', true,
    'program', jsonb_build_object(
      'id',               v_program.id,
      'required_stamps',  v_program.required_stamps,
      'reward',           v_program.reward,
      'spend_per_stamp',  v_program.spend_per_stamp,
      'earning_type',     v_program.earning_type,
      'stamp_icon',       v_program.stamp_icon,
      'stamp_logo_url',   v_program.stamp_logo_url,
      'card_theme',       v_program.card_theme,
      'silver_after_redemptions',   v_program.silver_after_redemptions,
      'gold_after_redemptions',     v_program.gold_after_redemptions,
      'platinum_after_redemptions', v_program.platinum_after_redemptions,
      'card_design_notes',          v_program.card_design_notes,
      'primary_color',    v_program.primary_color,
      'accent_color',     v_program.accent_color,
      'text_color',       v_program.text_color,
      'secondary_color',  v_program.secondary_color,
      'watermark_icon',   v_program.watermark_icon,
      'fine_print',       v_program.fine_print
    )
  );
end;
$$;

grant execute on function public.update_loyalty_program_by_token(text, integer, text, numeric, text, text, text, text, integer, integer, integer, text) to anon;


create or replace function public.record_loyalty_redemption_by_token(
  p_token text,
  p_card_id uuid,
  p_redeemed_by text default null,
  p_notes text default null,
  p_source text default 'partner_dashboard'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place_id uuid;
  v_program loyalty_programs%rowtype;
  v_card user_loyalty_cards%rowtype;
  v_redemption loyalty_redemptions%rowtype;
begin
  select id
    into v_place_id
    from public.places
   where partner_access_token = p_token;

  if v_place_id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid partner token');
  end if;

  select *
    into v_program
    from public.loyalty_programs
   where place_id = v_place_id
     and is_active = true
   order by created_at desc
   limit 1;

  if v_program.id is null then
    return jsonb_build_object('ok', false, 'error', 'No active loyalty program found');
  end if;

  select *
    into v_card
    from public.user_loyalty_cards
   where id = p_card_id
     and program_id = v_program.id
   for update;

  if v_card.id is null then
    return jsonb_build_object('ok', false, 'error', 'Card not found for this program');
  end if;

  if v_card.current_stamps < v_program.required_stamps then
    return jsonb_build_object('ok', false, 'error', 'This card does not have enough stamps to redeem');
  end if;

  if p_source not in ('app', 'partner_dashboard', 'staff', 'migration', 'other') then
    p_source := 'other';
  end if;

  insert into public.loyalty_redemptions (
    program_id, card_id, place_id, user_id, reward, stamps_spent,
    cycle_number, source, redeemed_by, notes
  )
  values (
    v_program.id,
    v_card.id,
    v_place_id,
    v_card.user_id,
    coalesce(v_program.reward, 'Reward'),
    v_program.required_stamps,
    coalesce(v_card.completed_cycles, 0) + 1,
    p_source,
    nullif(trim(p_redeemed_by), ''),
    nullif(trim(p_notes), '')
  )
  returning * into v_redemption;

  update public.user_loyalty_cards
     set current_stamps   = greatest(current_stamps - v_program.required_stamps, 0),
         completed_cycles = coalesce(completed_cycles, 0) + 1,
         is_redeemed      = false
   where id = v_card.id
   returning * into v_card;

  return jsonb_build_object(
    'ok', true,
    'redemption', jsonb_build_object(
      'id',           v_redemption.id,
      'card_id',      v_redemption.card_id,
      'user_id',      v_redemption.user_id,
      'reward',       v_redemption.reward,
      'stamps_spent', v_redemption.stamps_spent,
      'cycle_number', v_redemption.cycle_number,
      'source',       v_redemption.source,
      'redeemed_by',  v_redemption.redeemed_by,
      'notes',        v_redemption.notes,
      'redeemed_at',  v_redemption.redeemed_at
    ),
    'card', jsonb_build_object(
      'card_id',          v_card.id,
      'user_id',          v_card.user_id,
      'current_stamps',   v_card.current_stamps,
      'completed_cycles', v_card.completed_cycles,
      'is_redeemed',      v_card.is_redeemed,
      'last_stamped_at',  v_card.last_stamped_at,
      'created_at',       v_card.created_at
    )
  );
end;
$$;

grant execute on function public.record_loyalty_redemption_by_token(text, uuid, text, text, text) to anon;


create or replace function public.get_loyalty_redemption_report_by_token(
  p_token text,
  p_report_date date default current_date
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place_id uuid;
  v_program loyalty_programs%rowtype;
  v_start timestamptz;
  v_end timestamptz;
begin
  select id
    into v_place_id
    from public.places
   where partner_access_token = p_token;

  if v_place_id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid partner token');
  end if;

  select *
    into v_program
    from public.loyalty_programs
   where place_id = v_place_id
     and is_active = true
   order by created_at desc
   limit 1;

  if v_program.id is null then
    return jsonb_build_object('ok', false, 'error', 'No active loyalty program found');
  end if;

  v_start := coalesce(p_report_date, current_date)::timestamptz;
  v_end := v_start + interval '1 day';

  return jsonb_build_object(
    'ok', true,
    'generated_at', now(),
    'report_date', coalesce(p_report_date, current_date),
    'place', (
      select jsonb_build_object('id', id, 'name', name)
        from public.places
       where id = v_place_id
    ),
    'program', jsonb_build_object(
      'id',              v_program.id,
      'required_stamps', v_program.required_stamps,
      'reward',          v_program.reward,
      'spend_per_stamp', v_program.spend_per_stamp
    ),
    'redemptions', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'id',           r.id,
            'card_id',      r.card_id,
            'user_id',      r.user_id,
            'reward',       r.reward,
            'stamps_spent', r.stamps_spent,
            'cycle_number', r.cycle_number,
            'source',       r.source,
            'redeemed_by',  r.redeemed_by,
            'notes',        r.notes,
            'redeemed_at',  r.redeemed_at
          )
          order by r.redeemed_at asc
        ),
        '[]'::jsonb
      )
      from public.loyalty_redemptions r
      where r.program_id = v_program.id
        and r.redeemed_at >= v_start
        and r.redeemed_at < v_end
    ),
    'open_cards', (
      select coalesce(
        jsonb_agg(
          jsonb_build_object(
            'card_id',          c.id,
            'user_id',          c.user_id,
            'current_stamps',   c.current_stamps,
            'completed_cycles', c.completed_cycles,
            'is_redeemed',      c.is_redeemed,
            'last_stamped_at',  c.last_stamped_at,
            'created_at',       c.created_at
          )
          order by c.current_stamps desc, c.last_stamped_at desc nulls last, c.created_at asc
        ),
        '[]'::jsonb
      )
      from public.user_loyalty_cards c
      where c.program_id = v_program.id
        and coalesce(c.current_stamps, 0) > 0
        and coalesce(c.is_redeemed, false) = false
    )
  );
end;
$$;

grant execute on function public.get_loyalty_redemption_report_by_token(text, date) to anon;
