-- ============================================================
-- Admin Review System
-- Internal TRODDR admin tool for approving partner submissions,
-- specials, messages, and event updates.
--
-- Auth: admin_tokens table holds the bearer tokens. Add a row
-- per admin user. Tokens go in the ?token= URL parameter on
-- the admin dashboard.
-- ============================================================

create table if not exists public.admin_tokens (
  id         uuid primary key default gen_random_uuid(),
  token      text not null unique default encode(gen_random_bytes(24), 'hex'),
  label      text,
  is_active  boolean not null default true,
  created_at timestamptz not null default now()
);

alter table public.admin_tokens enable row level security;
-- No policies: only RPCs (security definer) can touch this.

-- Convenience helper
create or replace function public._is_admin(p_token text)
returns boolean
language sql
security definer
set search_path = public
as $$
  select exists(
    select 1 from public.admin_tokens
     where token = p_token and is_active = true
  );
$$;

-- ============================================================
-- get_admin_review_queue(p_admin_token)
-- One round-trip that powers the whole admin dashboard.
-- ============================================================
create or replace function public.get_admin_review_queue(p_admin_token text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._is_admin(p_admin_token) then
    return null;
  end if;

  return jsonb_build_object(

    'counts', jsonb_build_object(
      'pending_submissions',
        (select count(*) from public.event_partner_submissions
          where status in ('submitted','reviewing')),
      'pending_specials',
        (select count(*) from public.specials
          where submission_status = 'pending'),
      'new_messages',
        (select count(*) from public.partner_messages
          where status = 'new'),
      'recent_event_updates_7d',
        (select count(*) from public.event_updates
          where created_at >= now() - interval '7 days')
    ),

    'pending_submissions', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',                s.id,
        'event_name',        s.event_name,
        'event_type',        s.event_type,
        'organizer_name',    s.organizer_name,
        'contact_email',     s.contact_email,
        'contact_phone',     s.contact_phone,
        'event_start_date',  s.event_start_date,
        'event_end_date',    s.event_end_date,
        'venue_name',        s.venue_name,
        'venue_address',     s.venue_address,
        'event_description', s.event_description,
        'website',           s.website,
        'instagram',         s.instagram,
        'hero_url',          s.hero_url,
        'logo_url',          s.logo_url,
        'gallery_urls',      s.gallery_urls,
        'tickets_url',       s.tickets_url,
        'status',            s.status,
        'event_id',          s.event_id,
        'created_at',        s.created_at,
        'updated_at',        s.updated_at
      ) order by s.created_at desc), '[]'::jsonb)
      from public.event_partner_submissions s
      where s.status in ('submitted','reviewing','draft')
    ),

    'pending_specials', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',                  sp.id,
        'title',               sp.title,
        'description',         sp.description,
        'special_type',        sp.special_type,
        'start_date',          sp.start_date,
        'end_date',            sp.end_date,
        'start_time',          sp.start_time,
        'end_time',            sp.end_time,
        'image_url',           (case when sp.image_urls is not null and array_length(sp.image_urls, 1) > 0
                                     then sp.image_urls[1] else null end),
        'discount_percentage', sp.discount_percentage,
        'discount_amount',     sp.discount_amount,
        'price_amount',        sp.price_amount,
        'currency',            sp.currency,
        'event_category',      sp.event_category,
        'event_tags',          sp.event_tags,
        'submitted_at',        sp.submitted_at,
        'submitted_via',       sp.submitted_via,
        'submission_status',   sp.submission_status,
        'review_note',         sp.review_note,
        'place', (
          select jsonb_build_object(
            'id',   p.id,
            'name', p.name,
            'slug', p.slug,
            'town', p.town,
            'parish', p.parish,
            'partner_email', p.bookings_email
          )
          from public.places p
          where p.id = sp.place_id
        )
      ) order by sp.submitted_at desc nulls last, sp.created_at desc), '[]'::jsonb)
      from public.specials sp
      where sp.submission_status in ('pending', 'draft')
    ),

    'new_messages', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',          m.id,
        'subject',     m.subject,
        'message',     m.message,
        'status',      m.status,
        'source_page', m.source_page,
        'created_at',  m.created_at,
        'partner', (
          select jsonb_build_object('id', p.id, 'name', p.name)
          from public.partners p where p.id = m.partner_id
        ),
        'place', (
          select jsonb_build_object('id', pl.id, 'name', pl.name, 'slug', pl.slug)
          from public.places pl where pl.id = m.place_id
        ),
        'event', (
          select jsonb_build_object('id', ev.id, 'title', ev.title, 'slug', ev.slug)
          from public.events ev where ev.id = m.event_id
        )
      ) order by
          case m.status when 'new' then 0 when 'in_progress' then 1 else 2 end,
          m.created_at desc), '[]'::jsonb)
      from public.partner_messages m
      where m.status in ('new', 'in_progress')
      limit 50
    ),

    'recent_event_updates', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id',          u.id,
        'title',       u.title,
        'message',     u.message,
        'created_at',  u.created_at,
        'event', (
          select jsonb_build_object('id', e.id, 'title', e.title, 'slug', e.slug)
          from public.events e where e.id = u.event_id
        )
      ) order by u.created_at desc), '[]'::jsonb)
      from public.event_updates u
      where u.created_at >= now() - interval '30 days'
      limit 50
    )

  );
end;
$$;

-- ============================================================
-- Admin actions
-- ============================================================

-- Approve / reject an event submission
create or replace function public.admin_set_submission_status(
  p_admin_token  text,
  p_submission_id uuid,
  p_status       text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_event_id   uuid;
  v_event_slug text;
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  if p_status not in ('draft','submitted','reviewing','approved','archived') then
    return jsonb_build_object('ok', false, 'error', 'Invalid status');
  end if;

  update public.event_partner_submissions
     set status = p_status,
         updated_at = now()
   where id = p_submission_id
   returning event_id into v_event_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Submission not found');
  end if;

  if v_event_id is not null then
    select slug into v_event_slug from public.events where id = v_event_id;
  end if;

  return jsonb_build_object(
    'ok', true,
    'status', p_status,
    'event_id', v_event_id,
    'event_slug', v_event_slug
  );
end;
$$;

-- Approve / reject a special (with optional review note)
create or replace function public.admin_set_special_status(
  p_admin_token text,
  p_special_id  uuid,
  p_status      text,
  p_review_note text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  if p_status not in ('draft','pending','approved','rejected') then
    return jsonb_build_object('ok', false, 'error', 'Invalid status');
  end if;

  update public.specials
     set submission_status = p_status,
         active = case
                    when p_status = 'approved' then true
                    when p_status = 'rejected' then false
                    else active
                  end,
         review_note  = case when p_review_note is null then review_note else p_review_note end,
         reviewed_at  = now(),
         reviewed_by  = 'admin'
   where id = p_special_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Special not found');
  end if;

  return jsonb_build_object('ok', true, 'status', p_status);
end;
$$;

-- Mark a partner message
create or replace function public.admin_set_message_status(
  p_admin_token text,
  p_message_id  uuid,
  p_status      text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  if not public._is_admin(p_admin_token) then
    return jsonb_build_object('ok', false, 'error', 'Not authorized');
  end if;
  if p_status not in ('new','in_progress','resolved') then
    return jsonb_build_object('ok', false, 'error', 'Invalid status');
  end if;

  update public.partner_messages
     set status = p_status,
         resolved_at = case when p_status = 'resolved' then now() else resolved_at end
   where id = p_message_id;

  if not found then
    return jsonb_build_object('ok', false, 'error', 'Message not found');
  end if;

  return jsonb_build_object('ok', true, 'status', p_status);
end;
$$;

-- Grants
grant execute on function public.get_admin_review_queue(text) to anon;
grant execute on function public.admin_set_submission_status(text, uuid, text) to anon;
grant execute on function public.admin_set_special_status(text, uuid, text, text) to anon;
grant execute on function public.admin_set_message_status(text, uuid, text) to anon;

-- ============================================================
-- Create the first admin token. Run once, then save it somewhere safe.
-- ============================================================
-- insert into public.admin_tokens (label) values ('initial admin')
-- returning token;
