// ═══════════════════════════════════════════════════════════════
// TRODDR — notify-partner-booking Edge Function
//
// Fires on INSERT to public.bookings. Routes by booking_type to send the
// partner an email with a confirm/decline/counter link, then emails
// hello@troddr.com for internal visibility.
//
// v1 handles booking_type = 'day_pass' only. When restaurant/stay/activity
// types come online, branch on booking_type to vary email copy and the
// destination URL.
//
// Deploy:  supabase functions deploy notify-partner-booking
//
// Database Webhook setup:
//   Dashboard → Database → Webhooks → Create new webhook
//   Table:   bookings
//   Events:  INSERT
//   URL:     https://rprpwudhplodaqmmwqkf.supabase.co/functions/v1/notify-partner-booking
//   Method:  POST
//
// Required secrets (Dashboard → Edge Functions → Secrets):
//   RESEND_API_KEY            — Resend account API key
//   SUPABASE_URL              — auto-injected
//   SUPABASE_SERVICE_ROLE_KEY — auto-injected
// ═══════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const TRODDR_EMAIL = 'hello@troddr.com';
const FROM_EMAIL   = 'TRODDR Bookings <bookings@troddr.com>';

// One URL per booking_type. Add entries as new types come online.
const PARTNER_URLS: Record<string, string> = {
  day_pass: 'https://www.troddr.com/day-pass-booking',
};

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// @ts-ignore — Deno runtime
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const payload = await req.json();
    const booking = payload.record;
    if (!booking) throw new Error('No record in webhook payload');

    // Only act on fresh requests. Status changes are handled by
    // notify-booking-status (in the app repo).
    if (booking.status !== 'pending') {
      return ok({ skipped: true, reason: `status=${booking.status}` });
    }

    // v1 guard: only day_pass bookings get partner emails. Other types
    // will need their own branding/copy + a partner page route before
    // this fires for them.
    const partnerUrl = PARTNER_URLS[booking.booking_type];
    if (!partnerUrl) {
      return ok({ skipped: true, reason: `unsupported booking_type=${booking.booking_type}` });
    }

    // @ts-ignore
    const supaUrl = Deno.env.get('SUPABASE_URL')!;
    // @ts-ignore
    const supaKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
    const supa = createClient(supaUrl, supaKey);

    const { data: place, error: placeErr } = await supa
      .from('places')
      .select('id, slug, name, address, town, parish, image, bookings_email, day_pass_price, day_pass_hours, day_pass_notes')
      .eq('id', booking.place_id)
      .single();

    if (placeErr || !place) throw new Error(`Place not found: ${booking.place_id}`);
    if (!place.bookings_email) {
      await sendInternalMissingInbox(booking, place);
      return ok({ skipped: true, reason: 'no_bookings_email' });
    }

    // @ts-ignore
    const resendKey = Deno.env.get('RESEND_API_KEY');
    if (!resendKey) throw new Error('RESEND_API_KEY not set');

    const link = `${partnerUrl}?token=${booking.token}`;

    // ── EMAIL 1: Partner ─────────────────────────────────────
    await sendEmail(resendKey, {
      from: FROM_EMAIL,
      to: place.bookings_email,
      reply_to: booking.guest_email,
      subject: `New day pass request — ${place.name} (${fmtDate(booking.visit_date)})`,
      html: partnerHtml({ booking, place, link }),
    });

    // ── EMAIL 2: Internal ────────────────────────────────────
    await sendEmail(resendKey, {
      from: FROM_EMAIL,
      to: TRODDR_EMAIL,
      subject: `[TRODDR] ${booking.booking_type} request → ${place.name}`,
      html: internalHtml({ booking, place, link }),
    });

    return ok({ success: true });
  } catch (err) {
    console.error('notify-partner-booking error:', err);
    return new Response(
      JSON.stringify({ error: err instanceof Error ? err.message : String(err) }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 },
    );
  }
});

// ── Helpers ─────────────────────────────────────────────────────
function ok(body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    status: 200,
  });
}

function fmtDate(d?: string) {
  if (!d) return '—';
  return new Date(d + 'T00:00:00').toLocaleDateString('en-US', {
    weekday: 'short', month: 'long', day: 'numeric', year: 'numeric',
  });
}

function esc(s: unknown): string {
  return String(s ?? '')
    .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

function partySummary(n: number) {
  return n === 1 ? '1 guest' : `${n} guests`;
}

async function sendEmail(apiKey: string, opts: {
  from: string; to: string; subject: string; html: string; reply_to?: string;
}) {
  const res = await fetch('https://api.resend.com/emails', {
    method: 'POST',
    headers: { 'Authorization': `Bearer ${apiKey}`, 'Content-Type': 'application/json' },
    body: JSON.stringify(opts),
  });
  if (!res.ok) throw new Error(`Resend ${res.status}: ${await res.text()}`);
  return res.json();
}

async function sendInternalMissingInbox(booking: any, place: any) {
  // @ts-ignore
  const resendKey = Deno.env.get('RESEND_API_KEY');
  if (!resendKey) return;
  await sendEmail(resendKey, {
    from: FROM_EMAIL,
    to: TRODDR_EMAIL,
    subject: `[TRODDR] ⚠️ ${booking.booking_type} request but no bookings_email — ${place.name}`,
    html: `
      <p>A user requested a ${esc(booking.booking_type)} at <strong>${esc(place.name)}</strong> but the property has no <code>bookings_email</code> set.</p>
      <p>Guest: ${esc(booking.guest_name)} (${esc(booking.guest_email)})</p>
      <p>Date: ${esc(fmtDate(booking.visit_date))}, ${esc(partySummary(booking.party_size))}</p>
      <p>You'll need to reach out manually, or add a bookings_email and resend the webhook.</p>
      <p>Booking token: <code>${esc(booking.token)}</code></p>
    `,
  });
}

// ── Email templates ─────────────────────────────────────────────
function partnerHtml({ booking, place, link }: any) {
  const placeLoc = [place.town, place.parish].filter(Boolean).join(', ') || place.address || '';
  const guestContact = [booking.guest_email, booking.guest_phone].filter(Boolean).join(' · ');

  return `
  <div style="font-family: 'Helvetica Neue', Arial, sans-serif; max-width: 560px; margin: 0 auto; color: #111;">
    <div style="background: #0077CC; padding: 28px 36px; border-radius: 12px 12px 0 0;">
      <p style="color: #fff; font-size: 24px; font-weight: 700; margin: 0; letter-spacing: -0.5px;">troddr</p>
      <p style="color: rgba(255,255,255,0.8); font-size: 12px; font-weight: 600; letter-spacing: 0.1em; text-transform: uppercase; margin: 6px 0 0;">Day Pass Request</p>
    </div>

    <div style="background: #fff; padding: 36px; border: 1px solid #e8e8e8; border-top: none; border-radius: 0 0 12px 12px;">
      <h2 style="font-size: 22px; font-weight: 700; margin: 0 0 8px; color: #111;">
        New day pass request
      </h2>
      <p style="font-size: 15px; color: #555; margin: 0 0 24px; line-height: 1.6;">
        A TRODDR user wants to book a day pass at <strong>${esc(place.name)}</strong>.
        ${placeLoc ? `<br><span style="font-size:13px; color:#888;">${esc(placeLoc)}</span>` : ''}
      </p>

      <table style="width: 100%; border-collapse: collapse; font-size: 14px; margin-bottom: 28px; background: #f8f9fa; border-radius: 10px; overflow: hidden;">
        <tr><td style="padding: 12px 16px; color: #666; width: 130px; border-bottom: 1px solid #e8e8e8;">Date</td>
            <td style="padding: 12px 16px; font-weight: 600; border-bottom: 1px solid #e8e8e8;">${esc(fmtDate(booking.visit_date))}</td></tr>
        <tr><td style="padding: 12px 16px; color: #666; border-bottom: 1px solid #e8e8e8;">Time</td>
            <td style="padding: 12px 16px; border-bottom: 1px solid #e8e8e8;">${esc(booking.visit_time || 'Any time')}</td></tr>
        <tr><td style="padding: 12px 16px; color: #666; border-bottom: 1px solid #e8e8e8;">Party</td>
            <td style="padding: 12px 16px; border-bottom: 1px solid #e8e8e8;">${esc(partySummary(booking.party_size))}</td></tr>
        <tr><td style="padding: 12px 16px; color: #666; border-bottom: 1px solid #e8e8e8;">Guest</td>
            <td style="padding: 12px 16px; border-bottom: 1px solid #e8e8e8;">${esc(booking.guest_name)}</td></tr>
        <tr><td style="padding: 12px 16px; color: #666;">Contact</td>
            <td style="padding: 12px 16px;">${esc(guestContact)}</td></tr>
        ${booking.notes ? `<tr><td colspan="2" style="padding: 12px 16px; border-top: 1px solid #e8e8e8;">
          <div style="font-size: 12px; color: #666; margin-bottom: 4px;">Notes from guest</div>
          <div style="font-style: italic; color: #333;">"${esc(booking.notes)}"</div>
        </td></tr>` : ''}
      </table>

      <a href="${esc(link)}"
         style="display: block; background: #0077CC; color: #fff; text-decoration: none;
                padding: 16px 24px; border-radius: 8px; font-size: 15px; font-weight: 600;
                text-align: center; margin-bottom: 14px;">
        Confirm, Decline, or Suggest a Different Time →
      </a>
      <p style="font-size: 12px; color: #999; margin: 0 0 24px; text-align: center;">
        Or paste this link into your browser:<br>
        <span style="color: #666; word-break: break-all;">${esc(link)}</span>
      </p>

      <div style="border-top: 1px solid #e8e8e8; padding-top: 18px;">
        <p style="font-size: 12px; color: #888; margin: 0; line-height: 1.6;">
          <strong>How it works:</strong> click the link to respond. The guest gets a push notification.
          Payment is collected at the property on arrival — TRODDR doesn't process payment.
        </p>
        <p style="font-size: 12px; color: #888; margin: 14px 0 0;">
          Reply directly to this email to contact the guest, or reach TRODDR at
          <a href="mailto:${TRODDR_EMAIL}" style="color: #0077CC;">${TRODDR_EMAIL}</a>.
        </p>
      </div>
    </div>

    <p style="font-size: 12px; color: #bbb; text-align: center; margin-top: 20px;">
      © 2026 TRODDR · Made with ❤️ in Jamaica
    </p>
  </div>`;
}

function internalHtml({ booking, place, link }: any) {
  return `
  <div style="font-family: 'Helvetica Neue', Arial, sans-serif; max-width: 560px; margin: 0 auto; color: #111;">
    <h2 style="font-size: 18px; font-weight: 700; margin-bottom: 16px;">🛎️ New ${esc(booking.booking_type)} request</h2>
    <table style="width: 100%; border-collapse: collapse; font-size: 14px;">
      <tr><td style="padding: 8px 0; color: #666; width: 130px;">Place</td>
          <td style="padding: 8px 0; font-weight: 600;">${esc(place.name)}</td></tr>
      <tr><td style="padding: 8px 0; color: #666;">Partner inbox</td>
          <td style="padding: 8px 0;">${esc(place.bookings_email)}</td></tr>
      <tr><td style="padding: 8px 0; color: #666;">Date</td>
          <td style="padding: 8px 0;">${esc(fmtDate(booking.visit_date))} ${booking.visit_time ? `· ${esc(booking.visit_time)}` : ''}${booking.checkout_date ? ` → ${esc(fmtDate(booking.checkout_date))}` : ''}</td></tr>
      <tr><td style="padding: 8px 0; color: #666;">Party</td>
          <td style="padding: 8px 0;">${esc(partySummary(booking.party_size))}</td></tr>
      <tr><td style="padding: 8px 0; color: #666;">Guest</td>
          <td style="padding: 8px 0;">${esc(booking.guest_name)} · ${esc(booking.guest_email)}</td></tr>
      <tr><td style="padding: 8px 0; color: #666;">Partner link</td>
          <td style="padding: 8px 0;"><a href="${esc(link)}" style="color:#0077CC;">${esc(link)}</a></td></tr>
    </table>
    <p style="font-size: 12px; color: #bbb; margin-top: 18px;">
      Booking ID: ${esc(booking.id)}
    </p>
  </div>`;
}
