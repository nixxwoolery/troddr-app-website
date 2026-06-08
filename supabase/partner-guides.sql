-- ============================================================
-- partner-guides : RPC for the "Featured in Guides" section of
-- the partner-listing dashboard.
-- Reuses places.partner_access_token (same token as other partner pages).
-- ============================================================

create or replace function public.get_partner_guides_by_token(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place_slug text;
begin
  select slug
    into v_place_slug
    from public.places
   where partner_access_token = p_token;

  if v_place_slug is null then
    return null;
  end if;

  return (
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'slug',         g.slug,
          'title',        g.title,
          'image_url',    g.image_url,
          'description',  g.description,
          'location',     g.location,
          'category',     g.category,
          'country',      g.country,
          'type',         g.type,
          'custom_blurb', gs.custom_blurb,
          'section',      gs.section,
          'sort_order',   gs."order"
        )
        order by g.title
      ),
      '[]'::jsonb
    )
    from public.guide_spots gs
    join public.guides g on g.slug = gs.guide_slug
    where gs.place_slug = v_place_slug
  );
end;
$$;

grant execute on function public.get_partner_guides_by_token(text) to anon, authenticated;

comment on function public.get_partner_guides_by_token(text) is
  'Returns the guides this place is featured in, used by the partner-listing "Featured in Guides" section. Reads guide_spots joined to guides for the place tied to the given token.';
