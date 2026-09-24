-- Order analytics for the partner event dashboard's Order Queue.
-- get_order_queue_by_token() only returns live/recent (last 4h) orders, which
-- is fine for the live queue but not enough to summarize a whole event's
-- ordering activity. This is a separate, read-only rollup over every order
-- ever placed for the event: revenue, fulfillment time, top items, and a
-- per-vendor breakdown.

create or replace function public.get_order_analytics_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event uuid := public._event_id_from_partner_token(p_token);
begin
  if v_event is null then
    return jsonb_build_object('ok', false, 'error', 'invalid_token');
  end if;

  return jsonb_build_object(
    'ok', true,
    'summary', (
      select jsonb_build_object(
        'total_orders', count(*) filter (where o.status <> 'cancelled'),
        'collected_orders', count(*) filter (where o.status = 'collected'),
        'cancelled_orders', count(*) filter (where o.status = 'cancelled'),
        'total_revenue', coalesce(sum(coalesce(o.amount_paid, o.subtotal)) filter (where o.status <> 'cancelled'), 0),
        'avg_order_value', round(coalesce(avg(coalesce(o.amount_paid, o.subtotal)) filter (where o.status <> 'cancelled'), 0), 2),
        'avg_fulfillment_minutes', round(coalesce(avg(extract(epoch from (o.collected_at - o.created_at)) / 60) filter (where o.collected_at is not null), 0)::numeric, 1),
        'currency', coalesce((select o2.currency from public.event_orders o2 where o2.event_id = v_event and o2.currency is not null limit 1), 'JMD')
      )
      from public.event_orders o
      where o.event_id = v_event
    ),
    'top_items', coalesce((
      select jsonb_agg(jsonb_build_object('name', x.name, 'quantity', x.qty, 'revenue', x.revenue) order by x.qty desc)
      from (
        select i.item_name as name,
               sum(i.quantity)::int as qty,
               sum(coalesce(i.unit_price, 0) * i.quantity) as revenue
        from public.event_order_items i
        join public.event_orders o on o.id = i.order_id
        where o.event_id = v_event
          and o.status <> 'cancelled'
          and not i.is_unavailable
        group by i.item_name
        order by sum(i.quantity) desc
        limit 8
      ) x
    ), '[]'::jsonb),
    'vendors', coalesce((
      select jsonb_agg(jsonb_build_object('name', x.name, 'orders', x.orders, 'items_sold', x.items_sold, 'revenue', x.revenue) order by x.revenue desc)
      from (
        select coalesce(ev.display_name, v.name, 'Unknown vendor') as name,
               count(distinct i.order_id)::int as orders,
               sum(i.quantity)::int as items_sold,
               sum(coalesce(i.unit_price, 0) * i.quantity) as revenue
        from public.event_order_items i
        join public.event_orders o on o.id = i.order_id
        left join public.event_vendors ev on ev.id = i.event_vendor_id
        left join public.vendors v on v.id = ev.vendor_id
        where o.event_id = v_event
          and o.status <> 'cancelled'
          and not i.is_unavailable
        group by coalesce(ev.display_name, v.name, 'Unknown vendor')
        order by revenue desc
      ) x
    ), '[]'::jsonb),
    'hourly', coalesce((
      select jsonb_agg(jsonb_build_object('hour', x.h, 'orders', x.c) order by x.h)
      from (
        select extract(hour from o.created_at at time zone 'America/Jamaica')::int as h,
               count(*)::int as c
        from public.event_orders o
        where o.event_id = v_event
          and o.status <> 'cancelled'
        group by 1
      ) x
    ), '[]'::jsonb)
  );
end;
$$;

grant execute on function public.get_order_analytics_by_token(text) to anon, authenticated;

comment on function public.get_order_analytics_by_token(text) is
  'Partner Order Queue analytics: full-event revenue, avg order value, avg fulfillment time, top items, and per-vendor breakdown (unlike get_order_queue_by_token, not limited to the last 4 hours).';
