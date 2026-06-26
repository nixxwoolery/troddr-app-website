-- Bands editor backend.
--
-- partner-event.html (saveBand/deleteBand) calls upsert_event_band /
-- delete_event_band, which never existed on remote, so every band save/delete
-- failed. Bands are read from public.mas_bands (season_id = event_id) via
-- get_partner_event_extras_by_token, but had no write path.
--
-- This adds the missing write RPCs. It also adds the two columns the editor
-- form sends but mas_bands lacked (launch_date, is_featured). The read function
-- (get_partner_event_extras_by_token) is extended to expose the new band fields
-- in the following passes migration (20260626140000), which redefines it.

alter table public.mas_bands add column if not exists launch_date date;
alter table public.mas_bands add column if not exists is_featured boolean not null default false;

create or replace function public.upsert_event_band(
  p_token                 text,
  p_id                    uuid    default null,
  p_name                  text    default null,
  p_tagline               text    default null,
  p_website_url           text    default null,
  p_instagram             text    default null,
  p_logo_url              text    default null,
  p_registration_deadline text    default null,
  p_launch_date           text    default null,
  p_is_featured           boolean default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
  v_id       uuid;
  v_name     text := nullif(btrim(p_name), '');
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;

  if p_id is null then
    if v_name is null then return jsonb_build_object('ok', false, 'error', 'name_required'); end if;

    insert into public.mas_bands (
      season_id, name, slug, tagline, logo_url, website_url, ig_handle,
      registration_deadline, launch_date, is_featured
    )
    values (
      v_event_id,
      v_name,
      regexp_replace(
        lower(v_name) || '-' || substr(encode(extensions.gen_random_bytes(3), 'hex'), 1, 6),
        '[^a-z0-9-]+', '-', 'g'),
      nullif(btrim(p_tagline), ''),
      nullif(btrim(p_logo_url), ''),
      nullif(btrim(p_website_url), ''),
      nullif(btrim(p_instagram), ''),
      nullif(btrim(p_registration_deadline), '')::date,
      nullif(btrim(p_launch_date), '')::date,
      coalesce(p_is_featured, false)
    )
    returning id into v_id;
  else
    update public.mas_bands
       set name                  = coalesce(v_name, name),
           tagline               = case when p_tagline is not null then nullif(btrim(p_tagline), '') else tagline end,
           logo_url              = case when p_logo_url is not null then nullif(btrim(p_logo_url), '') else logo_url end,
           website_url           = case when p_website_url is not null then nullif(btrim(p_website_url), '') else website_url end,
           ig_handle             = case when p_instagram is not null then nullif(btrim(p_instagram), '') else ig_handle end,
           registration_deadline = case when p_registration_deadline is not null then nullif(btrim(p_registration_deadline), '')::date else registration_deadline end,
           launch_date           = case when p_launch_date is not null then nullif(btrim(p_launch_date), '')::date else launch_date end,
           is_featured           = coalesce(p_is_featured, is_featured),
           updated_at            = now()
     where id = p_id and season_id = v_event_id
     returning id into v_id;
    if v_id is null then return jsonb_build_object('ok', false, 'error', 'band_not_on_event'); end if;
  end if;

  return jsonb_build_object('ok', true, 'id', v_id);
exception when others then
  return jsonb_build_object('ok', false, 'error', SQLERRM);
end;
$$;

grant execute on function public.upsert_event_band(
  text, uuid, text, text, text, text, text, text, text, boolean
) to anon, authenticated;

create or replace function public.delete_event_band(p_token text, p_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare v_event_id uuid;
begin
  v_event_id := _partner_event_id_from_token(p_token);
  if v_event_id is null then return jsonb_build_object('ok', false, 'error', 'invalid_token'); end if;
  delete from public.mas_bands where id = p_id and season_id = v_event_id;
  return jsonb_build_object('ok', true);
end;
$$;

grant execute on function public.delete_event_band(text, uuid) to anon, authenticated;

notify pgrst, 'reload schema';
