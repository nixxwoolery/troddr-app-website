-- Create the public Storage bucket used by partner dashboard uploads
-- including event hero images, sponsor logos, and lineup artist photos.

insert into storage.buckets (id, name, public)
values ('partner-intake-assets', 'partner-intake-assets', true)
on conflict (id) do update set public = true;

drop policy if exists "anon can upload to partner-intake-assets" on storage.objects;
create policy "anon can upload to partner-intake-assets"
on storage.objects for insert to anon
with check (bucket_id = 'partner-intake-assets');

drop policy if exists "anon can read partner-intake-assets" on storage.objects;
create policy "anon can read partner-intake-assets"
on storage.objects for select to anon
using (bucket_id = 'partner-intake-assets');
