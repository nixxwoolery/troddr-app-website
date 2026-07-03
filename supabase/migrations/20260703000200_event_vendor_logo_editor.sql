-- Event vendor logo editor support.
-- Adds vendor logo URL support to the partner-event vendor modal RPC.

create or replace function public.get_partner_vendor_directory(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
begin
  select id into v_event_id
    from public.events
   where partner_access_token = p_token;

  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  return jsonb_build_object(
    'ok', true,
    'vendors', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'vendor_id',   v.id,
        'name',        v.name,
        'vendor_type', v.vendor_type,
        'description', v.description,
        'logo_url',    v.logo_url,
        'on_event', exists (
          select 1 from public.event_vendors ev
           where ev.event_id = v_event_id and ev.vendor_id = v.id
        )
      ) order by v.name), '[]'::jsonb)
      from public.vendors v
    )
  );
end;
$$;

grant execute on function public.get_partner_vendor_directory(text) to anon, authenticated;

drop function if exists public.upsert_event_vendor(
  text, uuid, uuid, text, text, text, text, boolean);
drop function if exists public.upsert_event_vendor(
  text, uuid, uuid, text, text, text, text, boolean, text);
drop function if exists public.upsert_event_vendor(
  text, uuid, uuid, text, text, text, text, boolean, text, text[]);

create or replace function public.upsert_event_vendor(
  p_token              text,
  p_event_vendor_id    uuid    default null,
  p_vendor_id          uuid    default null,
  p_vendor_name        text    default null,
  p_logo_url           text    default null,
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
  v_event_id         uuid;
  v_vendor_id        uuid;
  v_event_vendor_id  uuid;
  v_target_vendor_id uuid;
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

    if p_vendor_name is not null then
      select id into v_target_vendor_id
        from public.vendors
       where lower(btrim(name)) = lower(btrim(p_vendor_name))
         and id <> v_vendor_id
       limit 1;
    end if;

    if v_target_vendor_id is not null then
      if exists (
        select 1
          from public.event_vendors
         where event_id = v_event_id
           and vendor_id = v_target_vendor_id
           and id <> p_event_vendor_id
      ) then
        v_target_vendor_id := null;
      else
        v_vendor_id := v_target_vendor_id;
      end if;
    end if;

    update public.event_vendors
       set vendor_id    = coalesce(v_target_vendor_id, vendor_id),
           display_name = coalesce(nullif(btrim(p_vendor_name), ''), display_name),
           booth_number = coalesce(p_booth_number, booth_number),
           is_featured  = coalesce(p_is_featured,  is_featured),
           zone         = coalesce(p_zone,         zone),
           filter_tags  = coalesce(p_filter_tags,  filter_tags),
           updated_at   = now()
     where id = p_event_vendor_id;

    if v_target_vendor_id is not null then
      if p_vendor_type is not null or p_vendor_description is not null or p_logo_url is not null then
        update public.vendors
           set vendor_type = coalesce(p_vendor_type, vendor_type),
               description = coalesce(p_vendor_description, description),
               logo_url    = case when p_logo_url is not null then nullif(btrim(p_logo_url), '') else logo_url end,
               updated_at  = now()
         where id = v_vendor_id;
      end if;
    elsif p_vendor_type is not null or p_vendor_description is not null or p_logo_url is not null then
      update public.vendors
         set vendor_type = coalesce(p_vendor_type, vendor_type),
             description = coalesce(p_vendor_description, description),
             logo_url    = case when p_logo_url is not null then nullif(btrim(p_logo_url), '') else logo_url end,
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
      insert into public.vendors (name, vendor_type, description, logo_url)
      values (trim(p_vendor_name), p_vendor_type, p_vendor_description, nullif(btrim(p_logo_url), ''))
      returning id into v_vendor_id;
    elsif p_logo_url is not null or p_vendor_type is not null or p_vendor_description is not null then
      update public.vendors
         set vendor_type = coalesce(p_vendor_type, vendor_type),
             description = coalesce(p_vendor_description, description),
             logo_url    = case when p_logo_url is not null then nullif(btrim(p_logo_url), '') else logo_url end,
             updated_at  = now()
       where id = v_vendor_id;
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
           display_name = coalesce(nullif(btrim(p_vendor_name), ''), display_name),
           filter_tags  = coalesce(p_filter_tags,  filter_tags),
           updated_at   = now()
     where id = v_event_vendor_id;

    if p_logo_url is not null or p_vendor_type is not null or p_vendor_description is not null then
      update public.vendors
         set vendor_type = coalesce(p_vendor_type, vendor_type),
             description = coalesce(p_vendor_description, description),
             logo_url    = case when p_logo_url is not null then nullif(btrim(p_logo_url), '') else logo_url end,
             updated_at  = now()
       where id = v_vendor_id;
    end if;

    return jsonb_build_object('ok', true, 'event_vendor_id', v_event_vendor_id, 'already_linked', true);
  end if;

  insert into public.event_vendors (event_id, vendor_id, display_name, booth_number, is_featured, zone, filter_tags)
  values (v_event_id, v_vendor_id, nullif(btrim(p_vendor_name), ''), p_booth_number, coalesce(p_is_featured, false), p_zone, coalesce(p_filter_tags, '{}'))
  returning id into v_event_vendor_id;

  return jsonb_build_object('ok', true, 'event_vendor_id', v_event_vendor_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;

grant execute on function public.upsert_event_vendor(
  text, uuid, uuid, text, text, text, text, text, boolean, text, text[]
) to anon, authenticated;

notify pgrst, 'reload schema';
