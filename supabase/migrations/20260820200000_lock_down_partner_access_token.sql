-- Column-level lockdown of partner_access_token.
--
-- `places` and `events` each have a permissive RLS SELECT policy (read all rows
-- where is_active/published) plus a table-level SELECT grant to anon. RLS filters
-- ROWS, not COLUMNS, so partner_access_token — a bearer credential for the partner
-- dashboard (/partner/*) — was world-readable with the public anon key:
--   GET /rest/v1/places?select=name,partner_access_token
-- Verified: 348 place tokens + 5 event tokens exposed to the anon role.
--
-- Fix: drop the blanket table-level SELECT and re-grant SELECT on every column
-- EXCEPT partner_access_token. PostgREST `select=*` returns only granted columns,
-- so normal reads are unaffected; only reading the token is now denied.

do $$
declare v_cols text;
begin
  -- places
  select string_agg(quote_ident(column_name), ', ')
    into v_cols
  from information_schema.columns
  where table_schema = 'public' and table_name = 'places'
    and column_name <> 'partner_access_token';
  revoke select on public.places from anon, authenticated;
  execute format('grant select (%s) on public.places to anon, authenticated', v_cols);

  -- events
  select string_agg(quote_ident(column_name), ', ')
    into v_cols
  from information_schema.columns
  where table_schema = 'public' and table_name = 'events'
    and column_name <> 'partner_access_token';
  revoke select on public.events from anon, authenticated;
  execute format('grant select (%s) on public.events to anon, authenticated', v_cols);
end $$;

-- fuzzy_search_places was SECURITY INVOKER doing `select *`, which both leaked the
-- token and would now fail for anon (no privilege on the column). Recreate as
-- SECURITY DEFINER with the token nulled out, preserving the SETOF places shape.
-- DEFINER bypasses RLS, so re-assert the same visibility the RLS policy enforced
-- (is_active) to avoid surfacing unpublished places in search.
create or replace function public.fuzzy_search_places(q text)
returns setof public.places
language sql
security definer
set search_path = public, extensions
as $$
  select (jsonb_populate_record(null::public.places,
            to_jsonb(p) - 'partner_access_token')).*
  from public.places p
  where p.is_active is true
    and (
      similarity(name, q) > 0.2
      or similarity(town, q) > 0.2
      or similarity(parish, q) > 0.2
      or similarity(category, q) > 0.2
      or similarity(cuisine, q) > 0.2
      or similarity(recommended_dishes, q) > 0.2
      or recommended_dishes ilike '%' || q || '%'
    )
  order by
    greatest(
      similarity(name, q),
      similarity(town, q),
      similarity(parish, q),
      similarity(recommended_dishes, q),
      similarity(cuisine, q)
    ) desc
  limit 50;
$$;
