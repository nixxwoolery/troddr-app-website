-- Reuse existing suggested_places rows for the same unlisted place/location
-- instead of creating duplicate queue items. The app calls this RPC because
-- RLS correctly prevents clients from scanning everyone else's suggestions.

alter table public.suggested_places
  add column if not exists suggestion_count int not null default 1,
  add column if not exists want_to_go_count int not null default 0,
  add column if not exists been_count int not null default 0,
  add column if not exists notify_request_count int not null default 0,
  add column if not exists last_suggested_by uuid,
  add column if not exists last_suggested_at timestamptz;
create index if not exists suggested_places_lookup_idx
  on public.suggested_places (
    lower(regexp_replace(trim(coalesce(spot_name, '')), '\s+', ' ', 'g')),
    lower(regexp_replace(trim(coalesce(location, '')), '\s+', ' ', 'g')),
    lower(trim(coalesce(country, '')))
  );
create table if not exists public.suggested_place_users (
  suggested_place_id uuid not null references public.suggested_places(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  intent text check (intent in ('been', 'want_to_go')),
  user_rating text check (user_rating in ('loved', 'ok', 'not_for_me')),
  experience_note text,
  tried_item_name text,
  notify_when_added boolean not null default false,
  source_context text not null default 'search'
    check (source_context in ('search', 'taste_notes', 'plans', 'suggest_spot')),
  source_metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key (suggested_place_id, user_id)
);
create index if not exists suggested_place_users_user_idx
  on public.suggested_place_users (user_id, updated_at desc);
create index if not exists suggested_place_users_notify_idx
  on public.suggested_place_users (suggested_place_id)
  where notify_when_added;
insert into public.suggested_place_users (
  suggested_place_id,
  user_id,
  intent,
  user_rating,
  experience_note,
  tried_item_name,
  notify_when_added,
  source_context,
  source_metadata,
  created_at,
  updated_at
)
select
  sp.id,
  sp.user_id,
  sp.intent,
  sp.user_rating,
  sp.experience_note,
  sp.recommended,
  coalesce(sp.notify_when_added, false),
  coalesce(sp.source_context, 'search'),
  coalesce(sp.source_metadata, '{}'::jsonb),
  coalesce(sp.created_at, now()),
  coalesce(sp.updated_at, now())
from public.suggested_places sp
where sp.user_id is not null
  and exists (
    select 1
    from auth.users au
    where au.id = sp.user_id
  )
on conflict (suggested_place_id, user_id) do nothing;
with suggestion_totals as (
  select
    suggested_place_id,
    count(*)::int as suggestion_count,
    count(*) filter (where intent = 'want_to_go')::int as want_to_go_count,
    count(*) filter (where intent = 'been')::int as been_count,
    count(*) filter (where notify_when_added)::int as notify_request_count,
    max(updated_at) as last_suggested_at
  from public.suggested_place_users
  group by suggested_place_id
)
update public.suggested_places sp
   set suggestion_count = greatest(1, suggestion_totals.suggestion_count),
       want_to_go_count = suggestion_totals.want_to_go_count,
       been_count = suggestion_totals.been_count,
       notify_request_count = suggestion_totals.notify_request_count,
       last_suggested_at = coalesce(sp.last_suggested_at, suggestion_totals.last_suggested_at),
       last_suggested_by = coalesce(sp.last_suggested_by, sp.user_id),
       notify_when_added = coalesce(sp.notify_when_added, false)
         or suggestion_totals.notify_request_count > 0
  from suggestion_totals
 where sp.id = suggestion_totals.suggested_place_id;
alter table public.suggested_place_users enable row level security;
drop policy if exists "suggested_place_users_select_own" on public.suggested_place_users;
create policy "suggested_place_users_select_own"
  on public.suggested_place_users for select
  using (auth.uid() = user_id);
drop policy if exists "suggested_place_users_insert_own" on public.suggested_place_users;
create policy "suggested_place_users_insert_own"
  on public.suggested_place_users for insert
  with check (auth.uid() = user_id);
drop policy if exists "suggested_place_users_update_own" on public.suggested_place_users;
create policy "suggested_place_users_update_own"
  on public.suggested_place_users for update
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);
create or replace function public.upsert_suggested_place_user(
  p_suggested_place_id uuid,
  p_user_id uuid,
  p_intent text,
  p_user_rating text,
  p_experience_note text,
  p_tried_item_name text,
  p_notify_when_added boolean,
  p_source_context text,
  p_source_metadata jsonb
)
returns void
language sql
security definer
set search_path = public
as $$
  insert into public.suggested_place_users (
    suggested_place_id,
    user_id,
    intent,
    user_rating,
    experience_note,
    tried_item_name,
    notify_when_added,
    source_context,
    source_metadata,
    created_at,
    updated_at
  )
  values (
    p_suggested_place_id,
    p_user_id,
    p_intent,
    p_user_rating,
    nullif(trim(coalesce(p_experience_note, '')), ''),
    nullif(trim(coalesce(p_tried_item_name, '')), ''),
    p_notify_when_added,
    coalesce(p_source_context, 'search'),
    coalesce(p_source_metadata, '{}'::jsonb),
    now(),
    now()
  )
  on conflict (suggested_place_id, user_id)
  do update set
    intent = coalesce(excluded.intent, suggested_place_users.intent),
    user_rating = coalesce(excluded.user_rating, suggested_place_users.user_rating),
    experience_note = coalesce(excluded.experience_note, suggested_place_users.experience_note),
    tried_item_name = coalesce(excluded.tried_item_name, suggested_place_users.tried_item_name),
    notify_when_added = suggested_place_users.notify_when_added or excluded.notify_when_added,
    source_context = excluded.source_context,
    source_metadata = coalesce(suggested_place_users.source_metadata, '{}'::jsonb)
      || coalesce(excluded.source_metadata, '{}'::jsonb),
    updated_at = now();
$$;
create or replace function public.suggest_or_update_place(
  p_spot_name text,
  p_location text,
  p_country text default 'Jamaica',
  p_external_link text default null,
  p_intent text default null,
  p_user_rating text default null,
  p_experience_note text default null,
  p_tried_item_name text default null,
  p_notify_when_added boolean default false,
  p_source_context text default 'search',
  p_source_metadata jsonb default '{}'::jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_user_id uuid := auth.uid();
  v_existing_id uuid;
  v_user_already_attached boolean := false;
  v_user_already_requested_notify boolean := false;
  v_name_key text := lower(regexp_replace(trim(coalesce(p_spot_name, '')), '\s+', ' ', 'g'));
  v_location_key text := lower(regexp_replace(trim(coalesce(p_location, '')), '\s+', ' ', 'g'));
  v_country_key text := lower(trim(coalesce(nullif(p_country, ''), 'Jamaica')));
  v_description text;
begin
  if v_user_id is null then
    raise exception 'Authentication required';
  end if;

  if v_name_key = '' or v_location_key = '' then
    raise exception 'Place name and location are required';
  end if;

  if p_intent is not null and p_intent not in ('been', 'want_to_go') then
    raise exception 'Invalid intent';
  end if;

  if p_user_rating is not null and p_user_rating not in ('loved', 'ok', 'not_for_me') then
    raise exception 'Invalid user_rating';
  end if;

  if p_source_context is not null and p_source_context not in ('search', 'taste_notes', 'plans', 'suggest_spot') then
    raise exception 'Invalid source_context';
  end if;

  v_description := array_to_string(
    array_remove(array[
      case when p_intent is not null then 'Intent: ' || p_intent end,
      case when p_user_rating is not null then 'Rating: ' || p_user_rating end,
      case when nullif(trim(coalesce(p_experience_note, '')), '') is not null
        then 'Experience: ' || trim(p_experience_note)
      end,
      case when p_notify_when_added then 'Alert requested when added to TRODDR.' end,
      'Source: ' || coalesce(p_source_context, 'search')
    ], null),
    E'\n'
  );

  select id
    into v_existing_id
  from public.suggested_places
  where lower(regexp_replace(trim(coalesce(spot_name, '')), '\s+', ' ', 'g')) = v_name_key
    and lower(regexp_replace(trim(coalesce(location, '')), '\s+', ' ', 'g')) = v_location_key
    and lower(trim(coalesce(country, ''))) = v_country_key
  order by created_at asc
  limit 1
  for update;

  if v_existing_id is not null then
    select true, notify_when_added
      into v_user_already_attached, v_user_already_requested_notify
    from public.suggested_place_users
    where suggested_place_id = v_existing_id
      and user_id = v_user_id;

    update public.suggested_places
       set suggestion_count = greatest(1, coalesce(suggestion_count, 1))
             + case when coalesce(v_user_already_attached, false) then 0 else 1 end,
           want_to_go_count = coalesce(want_to_go_count, 0)
             + case
                 when not coalesce(v_user_already_attached, false)
                   and p_intent = 'want_to_go' then 1
                 else 0
               end,
           been_count = coalesce(been_count, 0)
             + case
                 when not coalesce(v_user_already_attached, false)
                   and p_intent = 'been' then 1
                 else 0
               end,
           notify_request_count = coalesce(notify_request_count, 0)
             + case
                 when p_notify_when_added
                   and not coalesce(v_user_already_requested_notify, false) then 1
                 else 0
               end,
           notify_when_added = coalesce(notify_when_added, false) or p_notify_when_added,
           intent = coalesce(p_intent, intent),
           user_rating = coalesce(p_user_rating, user_rating),
           experience_note = coalesce(nullif(trim(coalesce(p_experience_note, '')), ''), experience_note),
           source_context = coalesce(p_source_context, source_context, 'search'),
           source_metadata = coalesce(source_metadata, '{}'::jsonb)
             || coalesce(p_source_metadata, '{}'::jsonb)
             || jsonb_build_object(
                  'last_suggested_by', v_user_id,
                  'last_suggested_at', now()
                ),
           recommended = coalesce(nullif(trim(coalesce(p_tried_item_name, '')), ''), recommended),
           contact_info = coalesce(nullif(trim(coalesce(p_external_link, '')), ''), contact_info),
           description = coalesce(nullif(trim(v_description), ''), description),
           last_suggested_by = v_user_id,
           last_suggested_at = now(),
           updated_at = now()
     where id = v_existing_id;

    perform public.upsert_suggested_place_user(
      v_existing_id,
      v_user_id,
      p_intent,
      p_user_rating,
      p_experience_note,
      p_tried_item_name,
      p_notify_when_added,
      p_source_context,
      p_source_metadata
    );

    return v_existing_id;
  end if;

  insert into public.suggested_places (
    spot_name,
    category,
    location,
    country,
    recommended,
    description,
    contact_info,
    user_id,
    intent,
    user_rating,
    experience_note,
    source_context,
    source_metadata,
    notify_when_added,
    suggestion_count,
    want_to_go_count,
    been_count,
    notify_request_count,
    last_suggested_by,
    last_suggested_at,
    created_at,
    updated_at
  )
  values (
    trim(p_spot_name),
    null,
    trim(p_location),
    coalesce(nullif(trim(p_country), ''), 'Jamaica'),
    nullif(trim(coalesce(p_tried_item_name, '')), ''),
    nullif(trim(v_description), ''),
    nullif(trim(coalesce(p_external_link, '')), ''),
    v_user_id,
    p_intent,
    p_user_rating,
    nullif(trim(coalesce(p_experience_note, '')), ''),
    coalesce(p_source_context, 'search'),
    coalesce(p_source_metadata, '{}'::jsonb),
    p_notify_when_added,
    1,
    case when p_intent = 'want_to_go' then 1 else 0 end,
    case when p_intent = 'been' then 1 else 0 end,
    case when p_notify_when_added then 1 else 0 end,
    v_user_id,
    now(),
    now(),
    now()
  )
  returning id into v_existing_id;

  perform public.upsert_suggested_place_user(
    v_existing_id,
    v_user_id,
    p_intent,
    p_user_rating,
    p_experience_note,
    p_tried_item_name,
    p_notify_when_added,
    p_source_context,
    p_source_metadata
  );

  return v_existing_id;
end;
$$;
grant execute on function public.suggest_or_update_place(
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  text,
  boolean,
  text,
  jsonb
) to authenticated;
