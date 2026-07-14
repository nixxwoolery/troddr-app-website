-- Let the app send the unlisted place category alongside the richer feedback
-- metadata without duplicating the existing dedupe RPC body.

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
  p_source_metadata jsonb default '{}'::jsonb,
  p_category text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_suggested_place_id uuid;
  v_category text := lower(trim(coalesce(p_category, '')));
begin
  if v_category <> '' and v_category not in ('eat', 'stay', 'play') then
    raise exception 'Invalid category';
  end if;

  v_suggested_place_id := public.suggest_or_update_place(
    p_spot_name,
    p_location,
    p_country,
    p_external_link,
    p_intent,
    p_user_rating,
    p_experience_note,
    p_tried_item_name,
    p_notify_when_added,
    p_source_context,
    p_source_metadata
  );

  if v_category <> '' then
    update public.suggested_places
       set category = v_category,
           source_metadata = coalesce(source_metadata, '{}'::jsonb)
             || jsonb_build_object('suggested_category', v_category),
           updated_at = now()
     where id = v_suggested_place_id;
  end if;

  return v_suggested_place_id;
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
  jsonb,
  text
) to authenticated;
