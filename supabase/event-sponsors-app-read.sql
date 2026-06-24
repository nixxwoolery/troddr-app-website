-- ============================================================
-- Event sponsors app-read access
-- ============================================================
-- The partner dashboard writes sponsor details to public.sponsors and links
-- them to an event through public.event_sponsors. The attendee app needs read
-- access to both active rows.

grant select on public.sponsors to anon, authenticated;
grant select on public.event_sponsors to anon, authenticated;

do $$
begin
  if not exists (
    select 1
      from pg_policies
     where schemaname = 'public'
       and tablename = 'sponsors'
       and policyname = 'active sponsors are publicly readable'
  ) then
    create policy "active sponsors are publicly readable"
      on public.sponsors
      for select
      to anon, authenticated
      using (coalesce(is_active, true) = true);
  end if;

  if not exists (
    select 1
      from pg_policies
     where schemaname = 'public'
       and tablename = 'event_sponsors'
       and policyname = 'active event sponsors are publicly readable'
  ) then
    create policy "active event sponsors are publicly readable"
      on public.event_sponsors
      for select
      to anon, authenticated
      using (coalesce(is_active, true) = true);
  end if;
end $$;

create or replace function public.get_event_sponsors_by_slug(p_event_slug text)
returns jsonb
language sql
security definer
set search_path = public
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id',                 s.id,
        'sponsor_id',         s.id,
        'event_sponsor_id',   es.id,
        'name',               s.name,
        'slug',               s.slug,
        'logo_url',           s.logo_url,
        'logo_variant',       s.logo_variant,
        'website',            s.website,
        'description',        coalesce(es.custom_tagline, s.description),
        'instagram',          s.instagram,
        'brand_color',        s.brand_color,
        'tier',               es.tier,
        'tier_label',         es.display_tier_label,
        'display_tier_label', es.display_tier_label,
        'is_featured',        es.is_featured
      )
      order by es.display_order nulls last, es.tier, s.name
    ),
    '[]'::jsonb
  )
  from public.events e
  join public.event_sponsors es on es.event_id = e.id
  join public.sponsors s on s.id = es.sponsor_id
  where e.slug = p_event_slug
    and coalesce(es.is_active, true) = true
    and coalesce(s.is_active, true) = true;
$$;

grant execute on function public.get_event_sponsors_by_slug(text) to anon, authenticated;
