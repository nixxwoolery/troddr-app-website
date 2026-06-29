-- Keep partner dashboard uploads working for both public token links and
-- authenticated sessions, and raise the bucket limit to match video uploads.

insert into storage.buckets (id, name, public, file_size_limit)
values ('partner-intake-assets', 'partner-intake-assets', true, 104857600)
on conflict (id) do update
set public = true,
    file_size_limit = 104857600;

drop policy if exists "anon can upload to partner-intake-assets" on storage.objects;
create policy "anon can upload to partner-intake-assets"
on storage.objects for insert to anon, authenticated
with check (bucket_id = 'partner-intake-assets');

drop policy if exists "anon can read partner-intake-assets" on storage.objects;
create policy "anon can read partner-intake-assets"
on storage.objects for select to anon, authenticated
using (bucket_id = 'partner-intake-assets');
