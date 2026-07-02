-- Event ticket analytics for the partner event dashboard.
-- Works before native ticketing exists: reports tracked ticket clicks,
-- configured provider sources, UTM attribution, and nullable sales/revenue
-- placeholders for future imports or provider integrations.

create or replace function public.get_partner_event_ticket_analytics(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event events%rowtype;
begin
  select *
    into v_event
    from public.events
   where partner_access_token = p_token;

  if v_event.id is null then
    return jsonb_build_object('ok', false, 'error', 'event_not_found');
  end if;

  return jsonb_build_object(
    'ok', true,
    'currency', coalesce(nullif(v_event.currency, ''), 'JMD'),
    'ticket_clicks', (
      select count(*)::int
        from public.event_analytics_events e
       where e.event_id = v_event.id
         and e.event_name = 'ticket_click'
    ),
    'unique_clickers', (
      select count(distinct coalesce(e.user_id::text, e.anon_device_id))::int
        from public.event_analytics_events e
       where e.event_id = v_event.id
         and e.event_name = 'ticket_click'
         and coalesce(e.user_id::text, e.anon_device_id) is not null
    ),
    'estimated_sales', null,
    'estimated_revenue', null,
    'sales_source', 'not_connected',
    'revenue_source', 'not_connected',
    'providers', coalesce((
      with configured as (
        select 'Primary ticket link'::text as provider,
               v_event.ticket_url as ticket_url
         where nullif(trim(coalesce(v_event.ticket_url, '')), '') is not null
        union all
        select coalesce(nullif(trim(provider_type), ''), nullif(trim(name), ''), 'Ticket link') as provider,
               ticket_url
          from public.ticket_locations
         where event_id = v_event.id
           and coalesce(is_active, true)
           and nullif(trim(coalesce(ticket_url, '')), '') is not null
      )
      select jsonb_agg(
        jsonb_build_object(
          'provider', c.provider,
          'url', c.ticket_url,
          'clicks', (
            select count(*)::int
              from public.event_analytics_events e
             where e.event_id = v_event.id
               and e.event_name = 'ticket_click'
               and (
                 e.target_url = c.ticket_url
                 or e.metadata ->> 'ticket_url' = c.ticket_url
                 or e.metadata ->> 'provider' = c.provider
               )
          )
        )
        order by c.provider
      )
      from configured c
    ), '[]'::jsonb),
    'campaigns', coalesce((
      select jsonb_agg(
        jsonb_build_object(
          'source', source,
          'campaign', campaign,
          'clicks', clicks
        )
        order by clicks desc, source, campaign
      )
      from (
        select
          coalesce(nullif(e.metadata ->> 'utm_source', ''), nullif(e.metadata ->> 'source', ''), 'Direct / unknown') as source,
          nullif(e.metadata ->> 'utm_campaign', '') as campaign,
          count(*)::int as clicks
        from public.event_analytics_events e
        where e.event_id = v_event.id
          and e.event_name = 'ticket_click'
        group by 1, 2
      ) c
    ), '[]'::jsonb)
  );
end;
$$;

grant execute on function public.get_partner_event_ticket_analytics(text) to anon, authenticated;

comment on function public.get_partner_event_ticket_analytics(text) is
  'Partner dashboard ticket analytics: ticket_click totals, provider source clicks, UTM attribution, and nullable sales/revenue placeholders for future integrations.';
