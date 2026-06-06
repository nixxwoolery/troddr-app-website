-- ============================================================
-- Email triggers: fire transactional emails via the send-email
-- Edge Function on key partner-side events.
--
-- Requires: pg_net extension. Edge Function send-email deployed.
-- Set the function URL + service role token in app_settings below.
-- ============================================================

create extension if not exists pg_net;

-- Holds the Edge Function URL + auth header.
-- Update these once after deploying. If you change the project URL
-- or rotate the service role key, update here.
create table if not exists public.app_settings (
  key   text primary key,
  value text not null
);

-- Run these once (replace SERVICE_ROLE_JWT with your actual key):
--   insert into public.app_settings (key, value) values
--     ('send_email_url',      'https://rprpwudhplodaqmmwqkf.supabase.co/functions/v1/send-email')
--     on conflict (key) do update set value = excluded.value;
--   insert into public.app_settings (key, value) values
--     ('service_role_jwt',    'eyJ...your_service_role_jwt...')
--     on conflict (key) do update set value = excluded.value;
--   insert into public.app_settings (key, value) values
--     ('dashboard_base_url',  'https://troddr.com')
--     on conflict (key) do update set value = excluded.value;

-- Helper to POST to send-email
create or replace function public._send_email(p_template text, p_params jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_url   text;
  v_token text;
begin
  select value into v_url   from public.app_settings where key = 'send_email_url';
  select value into v_token from public.app_settings where key = 'service_role_jwt';
  if v_url is null or v_token is null then
    return;  -- not configured yet; silently skip
  end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
      'Content-Type',  'application/json',
      'Authorization', 'Bearer ' || v_token
    ),
    body    := jsonb_build_object(
      'template', p_template,
      'params',   p_params
    )
  );
exception when others then
  -- Swallow errors so a missing/down email service never breaks the underlying write.
  null;
end;
$$;

-- ============================================================
-- TRIGGER 1: new partner_messages → email TRODDR admin
-- ============================================================
create or replace function public.tg_partner_message_email()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_context text;
begin
  -- Build a human-readable "from" line from partner / place / event
  select coalesce(
    (select p.name from public.partners p where p.id = NEW.partner_id),
    (select pl.name from public.places   pl where pl.id = NEW.place_id),
    (select ev.title from public.events  ev where ev.id = NEW.event_id),
    'Unknown partner'
  ) into v_context;

  perform public._send_email('partner_message', jsonb_build_object(
    'subject',     NEW.subject,
    'message',     NEW.message,
    'source_page', NEW.source_page,
    'context',     v_context
  ));
  return NEW;
end;
$$;

drop trigger if exists trg_partner_message_email on public.partner_messages;
create trigger trg_partner_message_email
  after insert on public.partner_messages
  for each row
  execute function public.tg_partner_message_email();

-- ============================================================
-- TRIGGER 2: event_partner_submissions status change → email partner
-- ============================================================
create or replace function public.tg_submission_email()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dashboard_base text;
  v_event_slug     text;
  v_event_token    text;
begin
  if NEW.status is distinct from OLD.status then
    if NEW.contact_email is null or NEW.contact_email = '' then
      return NEW;
    end if;

    select value into v_dashboard_base from public.app_settings where key = 'dashboard_base_url';
    if NEW.event_id is not null then
      select slug, partner_access_token into v_event_slug, v_event_token
        from public.events where id = NEW.event_id;
    end if;

    if NEW.status = 'approved' then
      perform public._send_email('submission_approved', jsonb_build_object(
        'partner_email', NEW.contact_email,
        'event_name',    NEW.event_name,
        'event_url',     case when v_event_slug is not null
                              then coalesce(v_dashboard_base, '') || '/events/' || v_event_slug
                              else null end,
        'dashboard_url', case when v_event_token is not null
                              then coalesce(v_dashboard_base, '') || '/partner/event?token=' || v_event_token
                              else null end
      ));
    elsif NEW.status = 'archived' then
      perform public._send_email('submission_rejected', jsonb_build_object(
        'partner_email', NEW.contact_email,
        'event_name',    NEW.event_name,
        'review_note',   null
      ));
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_submission_email on public.event_partner_submissions;
create trigger trg_submission_email
  after update of status on public.event_partner_submissions
  for each row
  execute function public.tg_submission_email();

-- ============================================================
-- TRIGGER 3: specials submission_status change → email partner
-- ============================================================
create or replace function public.tg_special_email()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_dashboard_base text;
  v_partner_email  text;
  v_place_name     text;
  v_place_token    text;
begin
  if NEW.submission_status is distinct from OLD.submission_status then
    select bookings_email, name, partner_access_token
      into v_partner_email, v_place_name, v_place_token
      from public.places where id = NEW.place_id;
    if v_partner_email is null or v_partner_email = '' then
      return NEW;  -- no email on file
    end if;

    select value into v_dashboard_base from public.app_settings where key = 'dashboard_base_url';

    if NEW.submission_status = 'approved' then
      perform public._send_email('special_approved', jsonb_build_object(
        'partner_email', v_partner_email,
        'title',         NEW.title,
        'place_name',    v_place_name,
        'dashboard_url', case when v_place_token is not null
                              then coalesce(v_dashboard_base, '') || '/partner/specials?token=' || v_place_token
                              else null end
      ));
    elsif NEW.submission_status = 'rejected' then
      perform public._send_email('special_rejected', jsonb_build_object(
        'partner_email', v_partner_email,
        'title',         NEW.title,
        'place_name',    v_place_name,
        'review_note',   NEW.review_note
      ));
    end if;
  end if;
  return NEW;
end;
$$;

drop trigger if exists trg_special_email on public.specials;
create trigger trg_special_email
  after update of submission_status on public.specials
  for each row
  execute function public.tg_special_email();
