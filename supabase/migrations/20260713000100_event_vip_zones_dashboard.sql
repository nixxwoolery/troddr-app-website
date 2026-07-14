-- Let an event partner label existing vendor zones as VIP-only.
-- events.vip_zones already exists; this migration only exposes a scoped,
-- token-gated update path for the partner dashboard.

create or replace function public.update_partner_event_vip_zones(
  p_token text,
  p_vip_zones text[] default '{}'::text[]
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
  v_reconciled text[];
begin
  select id into v_event_id
    from public.events
   where partner_access_token = p_token;

  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;

  -- Keep the exact strings stored on event_vendors. Entries for renamed or
  -- deleted zones are intentionally omitted, which reconciles stale state.
  select coalesce(array_agg(requested_zone order by first_position), '{}'::text[])
    into v_reconciled
    from (
      select requested.requested_zone, min(requested.position) as first_position
        from unnest(coalesce(p_vip_zones, '{}'::text[]))
             with ordinality as requested(requested_zone, position)
       where exists (
         select 1
           from public.event_vendors vendor
          where vendor.event_id = v_event_id
            and nullif(btrim(vendor.zone), '') is not null
            and vendor.zone = requested.requested_zone
       )
       group by requested.requested_zone
    ) current_zones;

  update public.events
     set vip_zones = v_reconciled,
         updated_at = now()
   where id = v_event_id;

  return jsonb_build_object(
    'ok', true,
    'vip_zones', to_jsonb(v_reconciled),
    'message', 'VIP-only food courts updated successfully.'
  );
end;
$$;

grant execute on function public.update_partner_event_vip_zones(text, text[])
  to anon, authenticated, service_role;

notify pgrst, 'reload schema';
