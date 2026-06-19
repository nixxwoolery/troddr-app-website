-- ============================================================
-- Special menus (partner dashboard)
-- ------------------------------------------------------------
-- Read/write the specials.menu_items jsonb column from the
-- partner-specials dashboard. Kept as standalone RPCs ON PURPOSE:
-- submit_partner_special / update_partner_special are defined in
-- multiple files (specials-submission, specials-reservations,
-- billing-specials) and threading a new param through all of them
-- risks signature drift, so the menu gets its own dedicated pair.
--
-- The dashboard already calls submit_/update_partner_special to save
-- the special; it then calls set_special_menu_by_token with the
-- returned/edited id to persist the menu. get_special_menu_by_token
-- pre-fills the editor when editing an existing special.
--
-- menu_items shape (jsonb object):
--   {
--     "pricing":    [ { "label", "price", "description" } ],
--     "sections":   [ { "title", "items": [ { "name", "price", "description" } ] } ],
--     "disclaimer": "..."
--   }
--
-- Both functions validate ownership via the place partner token, the
-- same model the other specials RPCs use. Token -> place; the special
-- must belong to that place.
-- ============================================================

create or replace function public.get_special_menu_by_token(
  p_token      text,
  p_special_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place   places%rowtype;
  v_special specials%rowtype;
begin
  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;

  select * into v_special from public.specials where id = p_special_id;
  if v_special.id is null then
    return jsonb_build_object('ok', false, 'error', 'Special not found');
  end if;
  if v_special.place_id is distinct from v_place.id then
    return jsonb_build_object('ok', false, 'error', 'You do not own this special');
  end if;

  return jsonb_build_object('ok', true, 'menu_items', v_special.menu_items);
end;
$$;

create or replace function public.set_special_menu_by_token(
  p_token      text,
  p_special_id uuid,
  p_menu_items jsonb default null,
  p_clear      boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place   places%rowtype;
  v_special specials%rowtype;
begin
  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;

  select * into v_special from public.specials where id = p_special_id;
  if v_special.id is null then
    return jsonb_build_object('ok', false, 'error', 'Special not found');
  end if;
  if v_special.place_id is distinct from v_place.id then
    return jsonb_build_object('ok', false, 'error', 'You do not own this special');
  end if;

  -- Menu, when present, must be a JSON object ({pricing, sections, disclaimer}).
  if not p_clear and p_menu_items is not null and jsonb_typeof(p_menu_items) <> 'object' then
    return jsonb_build_object('ok', false, 'error', 'Menu must be a JSON object');
  end if;

  update public.specials
     set menu_items = case when p_clear then null else p_menu_items end
   where id = p_special_id;

  return jsonb_build_object('ok', true, 'id', p_special_id);
end;
$$;

grant execute on function public.get_special_menu_by_token(text, uuid) to anon;
grant execute on function public.set_special_menu_by_token(text, uuid, jsonb, boolean) to anon;
