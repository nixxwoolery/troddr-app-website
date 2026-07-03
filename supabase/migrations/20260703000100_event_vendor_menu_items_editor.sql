-- Event vendor menu item editor support.
-- Adds price_label to the event_vendors_with_menu view payload and exposes
-- a token-scoped RPC used by the partner-event vendor modal.

create or replace view public.event_vendors_with_menu as
 select e.id as event_id,
    e.slug as event_slug,
    e.title as event_title,
    e.town as event_town,
    e.parish as event_parish,
    e.start_date,
    e.end_date,
    e.currency as event_currency,
    v.id as vendor_id,
    v.name as vendor_name,
    v.description as vendor_description,
    v.vendor_type,
    v.logo_url,
    v.cover_image_url,
    v.instagram,
    v.website,
    v.place_id as vendor_place_id,
    p.id as place_id,
    p.slug as place_slug,
    p.name as place_name,
    p.image as place_image,
    p.category as place_category,
    ev.id as event_vendor_id,
    ev.booth_number,
    ev.is_featured as vendor_is_featured,
    mi.id as menu_item_id,
    mi.name as menu_item_name,
    mi.description as menu_item_description,
    mi.price,
    coalesce(mi.currency, e.currency) as currency,
    mi.category as menu_category,
    mi.tags,
    mi.is_special,
    mi.is_sold_out,
    mi.image_url as menu_image_url,
    mi.sort_order,
    mi.price_label
   from public.events e
     join public.event_vendors ev on ev.event_id = e.id
     join public.vendors v on v.id = ev.vendor_id
     left join public.places p on p.id = v.place_id
     left join public.vendor_menu_items mi on mi.event_vendor_id = ev.id;

drop function if exists public.set_event_vendor_menu_items(text, uuid, jsonb);

create or replace function public.set_event_vendor_menu_items(
  p_token           text,
  p_event_vendor_id uuid,
  p_items           jsonb default '[]'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
  v_keep_ids uuid[] := '{}';
  v_item jsonb;
  v_item_id uuid;
  v_saved_id uuid;
  v_idx integer := 0;
  v_name text;
  v_tags text[];
begin
  select e.id into v_event_id
    from public.events e
    join public.event_vendors ev on ev.event_id = e.id
   where e.partner_access_token = p_token
     and ev.id = p_event_vendor_id;

  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'vendor_not_found_for_event');
  end if;

  if jsonb_typeof(coalesce(p_items, '[]'::jsonb)) <> 'array' then
    return jsonb_build_object('ok', false, 'error', 'menu_items_must_be_array');
  end if;

  for v_item in select value from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
  loop
    v_name := nullif(btrim(v_item->>'name'), '');
    if v_name is null then
      return jsonb_build_object('ok', false, 'error', 'menu_item_name_required');
    end if;

    v_tags := coalesce(
      array(
        select nullif(btrim(value), '')
          from jsonb_array_elements_text(coalesce(v_item->'tags', '[]'::jsonb))
         where nullif(btrim(value), '') is not null
      ),
      '{}'::text[]
    );

    v_item_id := nullif(v_item->>'id', '')::uuid;
    if v_item_id is not null and exists (
      select 1 from public.vendor_menu_items
       where id = v_item_id and event_vendor_id = p_event_vendor_id
    ) then
      update public.vendor_menu_items
         set name        = v_name,
             description = nullif(btrim(v_item->>'description'), ''),
             price       = nullif(v_item->>'price', '')::numeric,
             currency    = coalesce(nullif(btrim(v_item->>'currency'), ''), 'JMD'),
             category    = nullif(btrim(v_item->>'category'), ''),
             is_special  = coalesce((v_item->>'is_special')::boolean, false),
             is_sold_out = coalesce((v_item->>'is_sold_out')::boolean, false),
             image_url   = nullif(btrim(v_item->>'image_url'), ''),
             sort_order  = coalesce(nullif(v_item->>'sort_order', '')::integer, v_idx),
             tags        = v_tags,
             price_label = nullif(btrim(v_item->>'price_label'), ''),
             updated_at  = now()
       where id = v_item_id
       returning id into v_saved_id;
    else
      insert into public.vendor_menu_items (
        event_vendor_id, name, description, price, currency, category,
        is_special, is_sold_out, image_url, sort_order, tags, price_label
      ) values (
        p_event_vendor_id,
        v_name,
        nullif(btrim(v_item->>'description'), ''),
        nullif(v_item->>'price', '')::numeric,
        coalesce(nullif(btrim(v_item->>'currency'), ''), 'JMD'),
        nullif(btrim(v_item->>'category'), ''),
        coalesce((v_item->>'is_special')::boolean, false),
        coalesce((v_item->>'is_sold_out')::boolean, false),
        nullif(btrim(v_item->>'image_url'), ''),
        coalesce(nullif(v_item->>'sort_order', '')::integer, v_idx),
        v_tags,
        nullif(btrim(v_item->>'price_label'), '')
      )
      returning id into v_saved_id;
    end if;

    v_keep_ids := array_append(v_keep_ids, v_saved_id);
    v_idx := v_idx + 1;
  end loop;

  delete from public.vendor_menu_items
   where event_vendor_id = p_event_vendor_id
     and not (id = any(v_keep_ids));

  return jsonb_build_object(
    'ok', true,
    'event_vendor_id', p_event_vendor_id,
    'menu_items', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'menu_item_id', id,
        'id',           id,
        'name',         name,
        'description',  description,
        'price',        price,
        'currency',     currency,
        'category',     category,
        'tags',         tags,
        'is_special',   is_special,
        'is_sold_out',  is_sold_out,
        'image_url',    image_url,
        'sort_order',   sort_order,
        'price_label',  price_label
      ) order by sort_order, name), '[]'::jsonb)
      from public.vendor_menu_items
      where event_vendor_id = p_event_vendor_id
    )
  );
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;

grant execute on function public.set_event_vendor_menu_items(text, uuid, jsonb) to anon, authenticated;

comment on function public.set_event_vendor_menu_items is
  'Replaces menu items for one event_vendor row via the partner-event dashboard. Token-gated to the owning event.';

notify pgrst, 'reload schema';
