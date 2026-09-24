-- Sort the live Order Queue (partner-event-orders.html) by the order it was
-- RECEIVED (created_at), not by pickup_time. Pickup urgency stays visible on
-- each card via the existing "overdue" flag/pickup time display - it's just
-- no longer what determines queue position. This matches how a kitchen
-- display normally works: staff work top-down in arrival order so nothing
-- gets skipped, and the overdue flag tells them when something's slipping.
--
-- Only the ORDER BY changes; the returned shape is identical to the current
-- get_order_queue_by_token().

create or replace function public.get_order_queue_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_event uuid := public._event_id_from_partner_token(p_token);
begin
  if v_event is null then return null; end if;
  return jsonb_build_object(
    'event', (select jsonb_build_object('id', id, 'title', title, 'slug', slug) from public.events where id = v_event),
    'config', (select jsonb_build_object('enabled', enabled, 'pickup_counter_name', pickup_counter_name, 'paused', paused)
                 from public.event_order_config where event_id = v_event),
    'ordering_vendors', coalesce((select jsonb_agg(jsonb_build_object(
      'id',ev.id,'name',coalesce(ev.display_name,v.name),'ordering_enabled',ev.ordering_enabled,
      'menu_count',(select count(*) from public.vendor_menu_items mi where mi.event_vendor_id=ev.id))
      order by coalesce(ev.display_name,v.name))
      from public.event_vendors ev join public.vendors v on v.id=ev.vendor_id where ev.event_id=v_event),'[]'::jsonb),
    'orders', coalesce((
      select jsonb_agg(o.o order by o.sort_rank, o.created_at)
      from (
        select jsonb_build_object(
                 'id', eo.id, 'code', eo.code, 'status', eo.status,
                 'customer_name', eo.customer_name, 'customer_phone', eo.customer_phone,
                 'pickup_time', eo.pickup_time, 'note', eo.note,
                 'payment_confirmed_at', eo.payment_confirmed_at, 'amount_paid', eo.amount_paid, 'subtotal', eo.subtotal, 'currency', eo.currency,
                 'attention_reason', eo.attention_reason,
                 'created_at', eo.created_at, 'ready_at', eo.ready_at,
                 'items', coalesce((
                   select jsonb_agg(jsonb_build_object(
                            'vendor_key', coalesce(i.event_vendor_id::text, i.vendor_name), 'runner_placed_at', i.runner_placed_at, 'runner_collected_at', i.runner_collected_at, 'options', i.options, 'id', i.id, 'vendor_name', i.vendor_name, 'item_name', i.item_name,
                            'quantity', i.quantity, 'unit_price', i.unit_price,
                            'price_label', i.price_label, 'note', i.note,
                            'is_unavailable', i.is_unavailable, 'menu_item_id', i.menu_item_id)
                            order by i.created_at)
                   from public.event_order_items i where i.order_id = eo.id), '[]'::jsonb)
               ) as o,
               case eo.status when 'ready' then 0 when 'preparing' then 1 when 'received' then 2 else 3 end as sort_rank,
               eo.created_at
        from public.event_orders eo
        where eo.event_id = v_event
          and (eo.status in ('received','preparing','ready')
               or eo.updated_at > now() - interval '4 hours')
      ) o
    ), '[]'::jsonb)
  );
end;
$function$;

grant execute on function public.get_order_queue_by_token(text) to anon;
