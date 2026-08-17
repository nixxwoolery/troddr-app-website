-- Let an event partner set, replace, or clear the app's full-screen announcement image.
-- The event is resolved exclusively through its existing partner access token.

alter table public.events
  add column if not exists announcement_image_url text;

create or replace function public.update_partner_event_announcement_image(
  p_token text,
  p_announcement_image_url text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id uuid;
begin
  select id into v_event_id
    from public.events
   where partner_access_token = p_token;

  if v_event_id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;

  update public.events
     set announcement_image_url = nullif(btrim(p_announcement_image_url), ''),
         updated_at = now()
   where id = v_event_id;

  return jsonb_build_object('ok', true, 'updated_count', 1);
end;
$$;

grant execute on function public.update_partner_event_announcement_image(text, text)
  to anon, authenticated, service_role;

notify pgrst, 'reload schema';
