-- Private editorial drafts. Uses the same token verification as the admin console.
create table if not exists public.admin_content_drafts (
  id uuid primary key default gen_random_uuid(),
  document jsonb not null,
  updated_at timestamptz not null default now(),
  constraint content_draft_size check (octet_length(document::text) <= 8500000)
);
alter table public.admin_content_drafts enable row level security;
revoke all on public.admin_content_drafts from anon, authenticated;

create or replace function public.admin_list_content_drafts(p_admin_token text)
returns jsonb language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin(p_admin_token) then raise exception 'Admin access required'; end if;
  return (select coalesce(jsonb_agg(document || jsonb_build_object('id', id, 'updated_at', updated_at) order by updated_at desc), '[]'::jsonb) from public.admin_content_drafts);
end;
$$;

create or replace function public.admin_save_content_draft(p_admin_token text, p_draft jsonb)
returns jsonb language plpgsql security definer set search_path = public as $$
declare
  v_id uuid;
  v_photo jsonb;
  v_result jsonb;
  v_updated timestamptz;
begin
  if not public._is_admin(p_admin_token) then raise exception 'Admin access required'; end if;
  if p_draft is null or jsonb_typeof(p_draft) <> 'object' then raise exception 'Invalid draft'; end if;
  if coalesce(p_draft->>'kind', '') not in ('post', 'guide') then raise exception 'Choose a post or guide'; end if;
  if length(trim(coalesce(p_draft->>'title', ''))) not between 1 and 180 then raise exception 'Title must be 1–180 characters'; end if;
  if length(coalesce(p_draft->>'body', '')) > 60000 or length(coalesce(p_draft->>'intro', '')) > 1000 then raise exception 'Draft text is too long'; end if;
  if jsonb_typeof(p_draft->'photos') is distinct from 'array' or jsonb_typeof(p_draft->'stops') is distinct from 'array' then raise exception 'Invalid photos or guide stops'; end if;
  if jsonb_array_length(p_draft->'photos') > 10 then raise exception 'Maximum 10 photos'; end if;
  for v_photo in select value from jsonb_array_elements(p_draft->'photos') loop
    if coalesce(v_photo->>'src','') !~ '^data:image/jpeg;base64,[A-Za-z0-9+/]+={0,2}$' or length(coalesce(v_photo->>'caption','')) > 300 then raise exception 'Invalid photo'; end if;
  end loop;
  if length(trim(coalesce(p_draft->>'country', ''))) not between 1 and 120 then raise exception 'Choose a country for this draft'; end if;
  if p_draft->>'kind' = 'guide' then
    if jsonb_typeof(p_draft->'guidePlaces') is distinct from 'array' then raise exception 'Invalid guide places'; end if;
    if exists (
      select 1 from jsonb_array_elements(p_draft->'guidePlaces') as selected(value)
      left join public.places p on p.slug = selected.value->>'slug'
      where p.slug is null or p.country is distinct from p_draft->>'country'
    ) then raise exception 'All guide places must belong to the guide country'; end if;
  end if;
  v_id := (p_draft->>'id')::uuid;
  if v_id is null then raise exception 'Draft ID required'; end if;
  -- Optimistic concurrency: do not overwrite work saved in another tab.
  select updated_at into v_updated from public.admin_content_drafts where id = v_id for update;
  if found and (p_draft->>'updated_at')::timestamptz is distinct from v_updated then
    raise exception 'This draft changed in another tab. Reload the library before editing again.';
  end if;
  insert into public.admin_content_drafts(id, document, updated_at)
    values(v_id, p_draft - 'updated_at' - 'id', clock_timestamp())
    on conflict(id) do update set document = excluded.document, updated_at = excluded.updated_at
    returning document || jsonb_build_object('id', id, 'updated_at', updated_at) into v_result;
  return v_result;
end;
$$;

create or replace function public.admin_delete_content_draft(p_admin_token text, p_id uuid)
returns boolean language plpgsql security definer set search_path = public as $$
begin
  if not public._is_admin(p_admin_token) then raise exception 'Admin access required'; end if;
  delete from public.admin_content_drafts where id = p_id;
  return true;
end;
$$;
revoke all on function public.admin_list_content_drafts(text) from public;
revoke all on function public.admin_save_content_draft(text,jsonb) from public;
revoke all on function public.admin_delete_content_draft(text,uuid) from public;
grant execute on function public.admin_list_content_drafts(text) to anon, authenticated;
grant execute on function public.admin_save_content_draft(text,jsonb) to anon, authenticated;
grant execute on function public.admin_delete_content_draft(text,uuid) to anon, authenticated;
