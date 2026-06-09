-- ============================================================
-- event-vendors : RPC for editing a vendor entry on an event,
-- called from the partner-event dashboard's vendor edit modal.
-- ============================================================

create or replace function public.update_event_vendor(
  p_token              text,
  p_event_vendor_id    uuid,
  p_vendor_name        text default null,
  p_booth_number       text default null,
  p_vendor_type        text default null,
  p_vendor_description text default null,
  p_is_featured        boolean default null
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
  -- 1. Resolve token → event
  select id into v_event_id
    from public.events
   where partner_access_token = p_token;

  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  -- 2. Confirm this event_vendor row belongs to that event
  select vendor_id into v_vendor_id
    from public.event_vendors
   where id = p_event_vendor_id and event_id = v_event_id;

  if v_vendor_id is null then
    return jsonb_build_object('ok', false, 'error', 'vendor_not_found_for_event');
  end if;

  -- 3. Update event-level metadata (booth, featured)
  update public.event_vendors
     set booth_number  = coalesce(p_booth_number,  booth_number),
         is_featured   = coalesce(p_is_featured,   is_featured),
         updated_at    = now()
   where id = p_event_vendor_id;

  -- 4. Update vendor-level fields (name, type, description) on the vendors row.
  --    Only update the columns the partner actually changed.
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
  text, uuid, text, text, text, text, boolean
) to anon, authenticated;

comment on function public.update_event_vendor is
  'Lets a partner update one vendor row on their event via the partner-event dashboard edit modal. Updates event_vendors.booth_number/is_featured and (optionally) the vendor''s own name/vendor_type/description. Token-gated to the owning event.';
