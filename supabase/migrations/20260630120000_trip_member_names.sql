-- get_trip_member_names: resolve display names for the people who appear in a
-- trip's activity feed.
--
-- Why this exists: public."user" has RLS that only lets you read your OWN row
-- ("Allow users to manage their own profiles"), so the activity strip could
-- never resolve a collaborator's name and fell back to "A collaborator …" for
-- everyone but the viewer. This SECURITY DEFINER RPC reads names on the
-- caller's behalf, but is locked down three ways:
--   1. caller must have access to the trip (has_trip_access),
--   2. only the ids the caller asks for are considered, and
--   3. only ids that are ACTUAL members of that trip (owner or accepted
--      collaborator) are returned — so it can't be used to deanonymize
--      arbitrary user ids.
-- It never exposes email/phone beyond a single human-readable label.

create or replace function public.get_trip_member_names(_trip_id uuid, _ids uuid[])
returns table (id uuid, display_name text)
language sql
stable
security definer
set search_path to 'public'
as $$
  select u.id,
         coalesce(nullif(btrim(u.username), ''), nullif(btrim(u.email), '')) as display_name
  from public."user" u
  where public.has_trip_access(_trip_id)
    and u.id = any(_ids)
    and (
      exists (
        select 1 from public.itineraries i
        where i.id = _trip_id and i.user_id = u.id
      )
      or exists (
        select 1 from public.trip_collaborators c
        where c.trip_id = _trip_id
          and c.invitee_id = u.id
          and c.status = 'accepted'
      )
    );
$$;
alter function public.get_trip_member_names(uuid, uuid[]) owner to postgres;
grant execute on function public.get_trip_member_names(uuid, uuid[]) to authenticated;
grant execute on function public.get_trip_member_names(uuid, uuid[]) to service_role;
