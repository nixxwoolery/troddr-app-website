-- Private editorial photos. All access is through admin-content-media, which
-- checks the existing admin token and chooses the object path on the server.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('content-media','content-media',false,5000000,array['image/jpeg'])
on conflict(id) do update set public=false, file_size_limit=excluded.file_size_limit, allowed_mime_types=excluded.allowed_mime_types;

create table if not exists public.admin_content_media (
  id uuid primary key,
  draft_id uuid not null,
  country text not null,
  purpose text not null check(purpose in ('guide','post','photo_story','place_profile','place_update','instagram')),
  path text unique not null,
  created_at timestamptz not null default now()
);
alter table public.admin_content_media enable row level security;
revoke all on public.admin_content_media from anon,authenticated;
-- No public storage policies are added. Service-role access stays in the function.
grant select,insert,delete on public.admin_content_media to service_role;
-- A restrictive guard also blocks any older broad storage policies from exposing
-- this bucket to browser roles. Signed URLs and the service role still work.
drop policy if exists content_media_private_guard on storage.objects;
create policy content_media_private_guard on storage.objects as restrictive
for all to anon, authenticated
using(bucket_id <> 'content-media') with check(bucket_id <> 'content-media');

-- Uploaded objects must be registered to this exact draft, country and purpose.
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
    if length(coalesce(v_photo->>'caption','')) > 300 then raise exception 'Photo caption too long'; end if;
    if v_photo->>'bucket' is distinct from 'content-media' or not exists (
      select 1 from public.admin_content_media m
      where m.path = v_photo->>'path'
      and m.draft_id = (p_draft->>'id')::uuid
      and (p_draft->>'contentPurpose' = 'instagram' or m.country = p_draft->>'country')
      and m.purpose = coalesce(p_draft->>'contentPurpose', p_draft->>'kind')
    ) then raise exception 'Upload each photo to this draft and country before saving'; end if;
    if v_photo ? 'src' then raise exception 'Store photo paths, not image data or signed URLs'; end if;
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

