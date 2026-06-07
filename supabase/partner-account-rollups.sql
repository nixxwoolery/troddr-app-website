-- ============================================================
-- Partner account rollups
-- Groups multiple places/events under one authenticated partner
-- dashboard account. Run after partners-migration.sql.
-- ============================================================

create or replace function public.assign_partner_account(
  p_partner_name text,
  p_contact_email text default null,
  p_place_slugs text[] default '{}',
  p_event_slugs text[] default '{}'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_partner_id uuid;
begin
  select id
    into v_partner_id
    from public.partners
   where lower(name) = lower(p_partner_name)
   limit 1;

  if v_partner_id is null then
    insert into public.partners (name, contact_email)
    values (p_partner_name, p_contact_email)
    returning id into v_partner_id;
  else
    update public.partners
       set contact_email = coalesce(p_contact_email, contact_email),
           updated_at = now()
     where id = v_partner_id;
  end if;

  update public.places
     set partner_id = v_partner_id
   where slug = any(p_place_slugs);

  update public.events
     set partner_id = v_partner_id
   where slug = any(p_event_slugs);

  return v_partner_id;
end;
$$;

-- Examples to run with the exact slugs from production.
-- select public.assign_partner_account(
--   'Bowl and Spoon',
--   null,
--   array['bowl-and-spoon-location-1', 'bowl-and-spoon-location-2', 'bowl-and-spoon-location-3'],
--   '{}'
-- );
--
-- select public.assign_partner_account(
--   'Rockhouse Hotel',
--   null,
--   array['skylark', 'miss-lilys', 'rockhouse-hotel', 'pushcart-restaurant', 'rockhouse-restaurant'],
--   '{}'
-- );
--
-- select public.assign_partner_account(
--   'Island Outpost',
--   null,
--   array['strawberry-hill-hotel', 'the-caves', 'goldeneye'],
--   '{}'
-- );

