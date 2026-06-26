-- Create the public Storage bucket used by the partner event floor-plan editor.

insert into storage.buckets (id, name, public)
values ('event-floorplans', 'event-floorplans', true)
on conflict (id) do update set public = true;

drop policy if exists "event-floorplans public read" on storage.objects;
create policy "event-floorplans public read"
on storage.objects for select
using (bucket_id = 'event-floorplans');

drop policy if exists "event-floorplans authenticated insert" on storage.objects;
create policy "event-floorplans authenticated insert"
on storage.objects for insert
to anon, authenticated
with check (bucket_id = 'event-floorplans');

drop policy if exists "event-floorplans authenticated update" on storage.objects;
create policy "event-floorplans authenticated update"
on storage.objects for update
to anon, authenticated
using (bucket_id = 'event-floorplans')
with check (bucket_id = 'event-floorplans');
