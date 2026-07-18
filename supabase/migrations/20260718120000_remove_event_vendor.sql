-- Allow an event partner to remove a vendor from their own event without
-- deleting the shared vendor-directory record.
create or replace function public.remove_event_vendor(
  p_token text,
  p_event_vendor_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
  v_vendor_name text;
begin
  select ev.event_id, coalesce(nullif(btrim(ev.display_name), ''), v.name)
    into v_event_id, v_vendor_name
    from public.event_vendors ev
    join public.events e on e.id = ev.event_id
    join public.vendors v on v.id = ev.vendor_id
   where ev.id = p_event_vendor_id
     and e.partner_access_token = p_token
   for update of ev;

  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'vendor_not_found_for_event');
  end if;

  -- Keep manually positioned floor-plan objects, but detach their vendor link
  -- so deleting a lineup entry never makes map artwork disappear.
  update public.events e
     set floor_plan_markers = coalesce((
       select jsonb_agg(
         case
           when marker.value->>'vendor_id' = p_event_vendor_id::text
             then jsonb_set(marker.value, '{vendor_id}', 'null'::jsonb, true)
           else marker.value
         end
         order by marker.ordinality
       )
       from jsonb_array_elements(coalesce(e.floor_plan_markers, '[]'::jsonb))
            with ordinality as marker(value, ordinality)
     ), '[]'::jsonb),
         updated_at = now()
   where e.id = v_event_id;

  -- Event menu items and legacy event map points cascade from this link.
  delete from public.event_vendors where id = p_event_vendor_id and event_id = v_event_id;

  return jsonb_build_object(
    'ok', true,
    'event_vendor_id', p_event_vendor_id,
    'vendor_name', v_vendor_name
  );
exception when others then
  return jsonb_build_object('ok', false, 'error', sqlerrm);
end;
$$;

grant execute on function public.remove_event_vendor(text, uuid) to anon, authenticated;

comment on function public.remove_event_vendor(text, uuid) is
  'Token-gated removal of a vendor from one event. Preserves the global vendor directory record and detaches floor-plan objects.';
