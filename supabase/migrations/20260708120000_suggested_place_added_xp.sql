-- Reward each user who suggested a place once TRODDR matches that suggestion
-- to a curated place. The XP ledger's unique action/source index keeps this
-- idempotent if a match is changed and later restored.

create or replace function public.award_suggested_place_added_xp()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.matched_place_id is null
    or (
      tg_op = 'UPDATE'
      and old.matched_place_id is not distinct from new.matched_place_id
    )
  then
    return new;
  end if;

  insert into public.xp_transactions (
    user_id,
    transaction_type,
    source_type,
    source_id,
    xp_amount,
    metadata,
    action_key
  )
  select
    recipient.user_id,
    'earn',
    'suggested_place',
    new.id::text,
    15,
    jsonb_build_object(
      'suggested_place_id', new.id,
      'place_id', new.matched_place_id,
      'spot_name', new.spot_name,
      'awarded_from', 'suggested_place_match'
    ),
    'suggested_place_added'
  from (
    select spu.user_id
    from public.suggested_place_users spu
    where spu.suggested_place_id = new.id

    union

    select new.user_id
    where new.user_id is not null
  ) recipient
  on conflict do nothing;

  return new;
end;
$$;
drop trigger if exists trg_award_suggested_place_added_xp
  on public.suggested_places;
create trigger trg_award_suggested_place_added_xp
after insert or update of matched_place_id
on public.suggested_places
for each row
execute function public.award_suggested_place_added_xp();
