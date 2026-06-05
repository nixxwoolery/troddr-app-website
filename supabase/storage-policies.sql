-- ============================================================
-- Storage policies for partner-intake-assets bucket.
-- Allows anon to upload (so the partner dashboard works without
-- requiring login) and read.
-- ============================================================

-- Make sure the bucket exists and is publicly readable
insert into storage.buckets (id, name, public)
values ('partner-intake-assets', 'partner-intake-assets', true)
on conflict (id) do update set public = true;

-- Allow anon to upload
drop policy if exists "anon can upload to partner-intake-assets" on storage.objects;
create policy "anon can upload to partner-intake-assets"
on storage.objects for insert to anon
with check (bucket_id = 'partner-intake-assets');

-- Allow anon to read (since bucket is public, but be explicit)
drop policy if exists "anon can read partner-intake-assets" on storage.objects;
create policy "anon can read partner-intake-assets"
on storage.objects for select to anon
using (bucket_id = 'partner-intake-assets');
