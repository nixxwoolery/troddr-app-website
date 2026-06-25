-- Add per-event vendor filter labels used by the app to group/filter vendors.

alter table public.event_vendors
  add column if not exists filter_tags text[] not null default '{}';

drop function if exists public.update_event_vendor(
  text, uuid, text, text, text, text, boolean);

create or replace function public.update_event_vendor(
  p_token              text,
  p_event_vendor_id    uuid,
  p_vendor_name        text default null,
  p_booth_number       text default null,
  p_vendor_type        text default null,
  p_vendor_description text default null,
  p_is_featured        boolean default null,
  p_filter_tags        text[] default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id  uuid;
  v_vendor_id uuid;
begin
  select id into v_event_id
    from public.events
   where partner_access_token = p_token;

  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  select vendor_id into v_vendor_id
    from public.event_vendors
   where id = p_event_vendor_id and event_id = v_event_id;

  if v_vendor_id is null then
    return jsonb_build_object('ok', false, 'error', 'vendor_not_found_for_event');
  end if;

  update public.event_vendors
     set booth_number = coalesce(p_booth_number, booth_number),
         is_featured  = coalesce(p_is_featured,  is_featured),
         filter_tags  = coalesce(p_filter_tags,  filter_tags),
         updated_at   = now()
   where id = p_event_vendor_id;

  if p_vendor_name is not null or p_vendor_type is not null or p_vendor_description is not null then
    update public.vendors
       set name        = coalesce(p_vendor_name,        name),
           vendor_type = coalesce(p_vendor_type,        vendor_type),
           description = coalesce(p_vendor_description, description),
           updated_at  = now()
     where id = v_vendor_id;
  end if;

  return jsonb_build_object('ok', true, 'event_vendor_id', p_event_vendor_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;

grant execute on function public.update_event_vendor(
  text, uuid, text, text, text, text, boolean, text[]
) to anon, authenticated;

drop function if exists public.upsert_event_vendor(
  text, uuid, uuid, text, text, text, text, boolean, text);

create or replace function public.upsert_event_vendor(
  p_token              text,
  p_event_vendor_id    uuid    default null,
  p_vendor_id          uuid    default null,
  p_vendor_name        text    default null,
  p_booth_number       text    default null,
  p_vendor_type        text    default null,
  p_vendor_description text    default null,
  p_is_featured        boolean default null,
  p_zone               text    default null,
  p_filter_tags        text[]  default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id        uuid;
  v_vendor_id       uuid;
  v_event_vendor_id uuid;
begin
  select id into v_event_id
    from public.events
   where partner_access_token = p_token;

  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  if p_event_vendor_id is not null then
    select vendor_id into v_vendor_id
      from public.event_vendors
     where id = p_event_vendor_id and event_id = v_event_id;

    if v_vendor_id is null then
      return jsonb_build_object('ok', false, 'error', 'vendor_not_found_for_event');
    end if;

    update public.event_vendors
       set booth_number = coalesce(p_booth_number, booth_number),
           is_featured  = coalesce(p_is_featured,  is_featured),
           zone         = coalesce(p_zone,         zone),
           filter_tags  = coalesce(p_filter_tags,  filter_tags),
           updated_at   = now()
     where id = p_event_vendor_id;

    if p_vendor_name is not null or p_vendor_type is not null or p_vendor_description is not null then
      update public.vendors
         set name        = coalesce(p_vendor_name,        name),
             vendor_type = coalesce(p_vendor_type,        vendor_type),
             description = coalesce(p_vendor_description, description),
             updated_at  = now()
       where id = v_vendor_id;
    end if;

    return jsonb_build_object('ok', true, 'event_vendor_id', p_event_vendor_id);
  end if;

  v_vendor_id := p_vendor_id;

  if v_vendor_id is null then
    if coalesce(trim(p_vendor_name), '') = '' then
      return jsonb_build_object('ok', false, 'error', 'vendor_name_required');
    end if;

    select id into v_vendor_id
      from public.vendors
     where lower(btrim(name)) = lower(btrim(p_vendor_name))
     limit 1;

    if v_vendor_id is null then
      insert into public.vendors (name, vendor_type, description)
      values (trim(p_vendor_name), p_vendor_type, p_vendor_description)
      returning id into v_vendor_id;
    end if;
  else
    if not exists (select 1 from public.vendors where id = v_vendor_id) then
      return jsonb_build_object('ok', false, 'error', 'vendor_not_found');
    end if;
  end if;

  select id into v_event_vendor_id
    from public.event_vendors
   where event_id = v_event_id and vendor_id = v_vendor_id;

  if v_event_vendor_id is not null then
    update public.event_vendors
       set booth_number = coalesce(p_booth_number, booth_number),
           is_featured  = coalesce(p_is_featured,  is_featured),
           zone         = coalesce(p_zone,         zone),
           filter_tags  = coalesce(p_filter_tags,  filter_tags),
           updated_at   = now()
     where id = v_event_vendor_id;
    return jsonb_build_object('ok', true, 'event_vendor_id', v_event_vendor_id, 'already_linked', true);
  end if;

  insert into public.event_vendors (event_id, vendor_id, booth_number, is_featured, zone, filter_tags)
  values (v_event_id, v_vendor_id, p_booth_number, coalesce(p_is_featured, false), p_zone, coalesce(p_filter_tags, '{}'))
  returning id into v_event_vendor_id;

  return jsonb_build_object('ok', true, 'event_vendor_id', v_event_vendor_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;

grant execute on function public.upsert_event_vendor(
  text, uuid, uuid, text, text, text, text, boolean, text, text[]
) to anon, authenticated;
