-- ============================================================
-- Partner Messages
-- Inbox for partners to send feedback/questions/issues to TRODDR.
-- ============================================================

create table if not exists public.partner_messages (
  id              uuid primary key default gen_random_uuid(),
  partner_id      uuid references public.partners(id) on delete set null,
  place_id        uuid references public.places(id) on delete set null,
  event_id        uuid references public.events(id) on delete set null,
  source_page     text,           -- which dashboard page they were on
  subject         text,
  message         text not null,
  status          text not null default 'new'
                  check (status in ('new', 'in_progress', 'resolved')),
  created_at      timestamptz not null default now(),
  resolved_at     timestamptz
);

create index if not exists partner_messages_status_idx     on public.partner_messages(status);
create index if not exists partner_messages_created_at_idx on public.partner_messages(created_at desc);
create index if not exists partner_messages_partner_idx    on public.partner_messages(partner_id);

-- Lock it down. Only the RPC can write.
alter table public.partner_messages enable row level security;

-- ============================================================
-- RPC: send_partner_message
-- Called by every partner page's "Send a message" modal.
-- Resolves the token (place or event), then writes the message.
-- ============================================================
create or replace function public.send_partner_message(
  p_token       text,
  p_subject     text,
  p_message     text,
  p_source_page text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_place      places%rowtype;
  v_event      events%rowtype;
  v_partner_id uuid;
  v_msg_id     uuid;
begin
  if p_message is null or length(trim(p_message)) = 0 then
    return jsonb_build_object('ok', false, 'error', 'Message is required');
  end if;
  if length(p_message) > 5000 then
    return jsonb_build_object('ok', false, 'error', 'Message is too long (5000 char max)');
  end if;

  -- Resolve token to a place or event
  select * into v_place from public.places where partner_access_token = p_token;
  if v_place.id is null then
    select * into v_event from public.events where partner_access_token = p_token;
  end if;

  if v_place.id is null and v_event.id is null then
    return jsonb_build_object('ok', false, 'error', 'Invalid or revoked token');
  end if;

  v_partner_id := coalesce(v_place.partner_id, v_event.partner_id);

  insert into public.partner_messages (
    partner_id, place_id, event_id,
    source_page, subject, message
  )
  values (
    v_partner_id,
    v_place.id,
    v_event.id,
    nullif(trim(coalesce(p_source_page, '')), ''),
    nullif(trim(coalesce(p_subject, '')), ''),
    trim(p_message)
  )
  returning id into v_msg_id;

  return jsonb_build_object('ok', true, 'id', v_msg_id);
end;
$$;

grant execute on function public.send_partner_message(text, text, text, text) to anon;
