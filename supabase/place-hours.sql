-- ============================================================
-- Operating hours for places:
--   1. opening_hours_struct (jsonb)  – regular weekly hours
--   2. kitchen_hours_struct (jsonb)  – kitchen-specific hours
--   3. place_special_hours (table)   – date-specific closures /
--                                       early closes / late opens
--
-- We keep the legacy text columns opening_hours / kitchen_hours
-- in sync via the RPC so the app keeps working unchanged.
-- ============================================================

-- 1. Structured columns
alter table public.places
  add column if not exists opening_hours_struct jsonb,
  add column if not exists kitchen_hours_struct jsonb;

-- 2. Special hours table (holidays, weather closures, early closes…)
create table if not exists public.place_special_hours (
  id            uuid primary key default gen_random_uuid(),
  place_id      uuid not null references public.places(id) on delete cascade,
  date          date not null,
  is_closed     boolean not null default true,
  open_time     time,
  close_time    time,
  kitchen_open  time,
  kitchen_close time,
  reason        text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create unique index if not exists place_special_hours_unique
  on public.place_special_hours(place_id, date);
create index if not exists place_special_hours_date_idx
  on public.place_special_hours(date);

-- ============================================================
-- Helper: render the struct into a human readable text
-- string for the legacy opening_hours column.
--
-- Input shape:
-- {
--   "mon": { "open": "11:00", "close": "21:00" },
--   "tue": { "open": "11:00", "close": "21:00" },
--   "wed": { "closed": true },
--   ...
-- }
-- ============================================================
create or replace function public._format_hours_text(p_hours jsonb)
returns text
language plpgsql
immutable
as $$
declare
  v_days   text[] := array['mon','tue','wed','thu','fri','sat','sun'];
  v_labels text[] := array['Mon','Tue','Wed','Thu','Fri','Sat','Sun'];
  v_lines  text[] := '{}';
  v_day    text;
  v_entry  jsonb;
  v_open   text;
  v_close  text;
  v_i      int;
begin
  if p_hours is null or p_hours = '{}'::jsonb then
    return null;
  end if;
  for v_i in 1 .. array_length(v_days, 1) loop
    v_day   := v_days[v_i];
    v_entry := p_hours -> v_day;
    if v_entry is null then
      continue;
    end if;
    if (v_entry ->> 'closed')::boolean is true then
      v_lines := v_lines || (v_labels[v_i] || ' Closed');
    else
      v_open  := v_entry ->> 'open';
      v_close := v_entry ->> 'close';
      if v_open is not null and v_close is not null then
        v_lines := v_lines || (v_labels[v_i] || ' ' || v_open || '–' || v_close);
      end if;
    end if;
  end loop;
  if array_length(v_lines, 1) is null then return null; end if;
  return array_to_string(v_lines, '; ');
end;
$$;

-- ============================================================
-- RPC: update_partner_hours
-- Replaces both the struct AND the legacy text representation.
-- ============================================================
create or replace function public.update_partner_hours(
  p_token                 text,
  p_opening_hours_struct  jsonb default null,
  p_kitchen_hours_struct  jsonb default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place places%rowtype;
begin
  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;

  update public.places set
    opening_hours_struct = coalesce(p_opening_hours_struct, opening_hours_struct),
    kitchen_hours_struct = coalesce(p_kitchen_hours_struct, kitchen_hours_struct),
    opening_hours        = case
                              when p_opening_hours_struct is not null
                                then public._format_hours_text(p_opening_hours_struct)
                              else opening_hours
                           end,
    kitchen_hours        = case
                              when p_kitchen_hours_struct is not null
                                then public._format_hours_text(p_kitchen_hours_struct)
                              else kitchen_hours
                           end
  where id = v_place.id;

  return jsonb_build_object('ok', true, 'message', 'Hours updated.');
end;
$$;

-- ============================================================
-- RPC: list / upsert / delete special hours
-- ============================================================
create or replace function public.list_partner_closures(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place places%rowtype;
begin
  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;

  return jsonb_build_object(
    'ok', true,
    'closures', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',            id,
        'date',          date,
        'is_closed',     is_closed,
        'open_time',     open_time,
        'close_time',    close_time,
        'kitchen_open',  kitchen_open,
        'kitchen_close', kitchen_close,
        'reason',        reason
      ) order by date), '[]'::jsonb)
      from public.place_special_hours
      where place_id = v_place.id
        and date >= current_date - interval '7 days'
    )
  );
end;
$$;

create or replace function public.upsert_partner_closure(
  p_token         text,
  p_date          date,
  p_is_closed     boolean default true,
  p_open_time     time default null,
  p_close_time    time default null,
  p_kitchen_open  time default null,
  p_kitchen_close time default null,
  p_reason        text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place places%rowtype;
  v_id    uuid;
begin
  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;
  if p_date is null then
    return jsonb_build_object('ok', false, 'error', 'Pick a date for this closure');
  end if;
  if p_is_closed = false and (p_open_time is null or p_close_time is null) then
    return jsonb_build_object('ok', false, 'error',
      'For a non-closed day, please give open and close times');
  end if;

  insert into public.place_special_hours (
    place_id, date, is_closed, open_time, close_time,
    kitchen_open, kitchen_close, reason
  ) values (
    v_place.id, p_date, p_is_closed, p_open_time, p_close_time,
    p_kitchen_open, p_kitchen_close, nullif(trim(coalesce(p_reason, '')), '')
  )
  on conflict (place_id, date) do update set
    is_closed     = excluded.is_closed,
    open_time     = excluded.open_time,
    close_time    = excluded.close_time,
    kitchen_open  = excluded.kitchen_open,
    kitchen_close = excluded.kitchen_close,
    reason        = excluded.reason,
    updated_at    = now()
  returning id into v_id;

  return jsonb_build_object('ok', true, 'id', v_id);
end;
$$;

create or replace function public.delete_partner_closure(
  p_token      text,
  p_closure_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place places%rowtype;
begin
  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;

  delete from public.place_special_hours
   where id = p_closure_id and place_id = v_place.id;

  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.update_partner_hours(text, jsonb, jsonb)             to anon;
grant execute on function public.list_partner_closures(text)                          to anon;
grant execute on function public.upsert_partner_closure(text, date, boolean, time, time, time, time, text) to anon;
grant execute on function public.delete_partner_closure(text, uuid)                   to anon;
grant execute on function public._format_hours_text(jsonb)                            to anon;
