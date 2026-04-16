// ═══════════════════════════════════════════════════════════════
// TRODDR — notify-partner-submission Edge Function
// Sends two emails on every INSERT or UPDATE to event_partner_submissions:
//   1. To the partner — their edit link
//   2. To you (hello@troddr.com) — new submission alert
//
// Deploy:  supabase functions deploy notify-partner-submission
//
// Then set up a Database Webhook in Supabase:
//   Dashboard → Database → Webhooks → Create new webhook
//   Table:   event_partner_submissions
//   Events:  INSERT, UPDATE
//   URL:     https://rprpwudhplodaqmmwqkf.supabase.co/functions/v1/notify-partner-submission
//   Method:  POST
//
// Required environment variable (set in Dashboard → Edge Functions → Secrets):
//   RESEND_API_KEY  — get a free key at resend.com
//
// ═══════════════════════════════════════════════════════════════

const TRODDR_EMAIL       = 'hello@troddr.com';
const FORM_BASE_URL = 'https://troddr.com/event-onboarding';// update to your actual URL
const FROM_EMAIL         = 'TRODDR <partners@troddr.com>';      // must be a verified Resend sender

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

// @ts-ignore
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });

  try {
    const payload = await req.json();

    // Supabase webhooks send { type, table, record, old_record }
    const record = payload.record;
    if (!record) throw new Error('No record in payload');

    // Only notify on actual submissions — skip drafts that haven't been submitted yet
    if (record.status !== 'submitted') {
      return new Response(JSON.stringify({ skipped: true, status: record.status }), { status: 200 });
    }

    const isUpdate  = payload.type === 'UPDATE';
    const editLink  = `${FORM_BASE_URL}?token=${record.token}`;
    const eventName = record.event_name || 'Your Event';
    const contactName = record.contact_name || 'there';
    const contactEmail = record.contact_email;

    // @ts-ignore
    const resendKey = Deno.env.get('RESEND_API_KEY');
    if (!resendKey) throw new Error('RESEND_API_KEY not set');

    // ── EMAIL 1: To the partner ───────────────────────────────
    if (contactEmail) {
      const partnerSubject = isUpdate
        ? `Your TRODDR submission has been updated — ${eventName}`
        : `Your TRODDR Partner Intake is received — ${eventName}`;

      const partnerHtml = `
        <div style="font-family: 'Helvetica Neue', Arial, sans-serif; max-width: 560px; margin: 0 auto; color: #111;">
          <div style="background: #0077CC; padding: 32px 40px; border-radius: 12px 12px 0 0;">
            <p style="color: #fff; font-size: 24px; font-weight: 700; margin: 0; letter-spacing: -0.5px;">troddr</p>
          </div>
          <div style="background: #fff; padding: 40px; border: 1px solid #e8e8e8; border-top: none; border-radius: 0 0 12px 12px;">
            <h2 style="font-size: 22px; font-weight: 700; margin: 0 0 12px; color: #111;">
              ${isUpdate ? 'Submission Updated' : 'Brief Received'} 🎉
            </h2>
            <p style="font-size: 15px; color: #555; line-height: 1.6; margin: 0 0 24px;">
              Hi ${contactName}, ${isUpdate
                ? `your updates to <strong>${eventName}</strong> have been saved.`
                : `we've received your partner brief for <strong>${eventName}</strong>. The TRODDR team will review it and be in touch within 2–3 business days.`
              }
            </p>

            <div style="background: #f8f9fa; border: 1px solid #e8e8e8; border-radius: 10px; padding: 24px; margin-bottom: 28px;">
              <p style="font-size: 11px; font-weight: 700; text-transform: uppercase; letter-spacing: 0.08em; color: #0077CC; margin: 0 0 10px;">
                Your Edit Link
              </p>
              <p style="font-size: 13px; color: #555; margin: 0 0 14px; line-height: 1.5;">
                Use this link to return and update your submission at any time — add performers once the schedule is confirmed, update sponsors, or add On the Radar promotions.
              </p>
              <a href="${editLink}"
                 style="display: inline-block; background: #0077CC; color: #fff; text-decoration: none;
                        padding: 13px 24px; border-radius: 8px; font-size: 14px; font-weight: 600;">
                Return to My Submission →
              </a>
              <p style="font-size: 11px; color: #999; margin: 14px 0 0;">
                Or copy this link: ${editLink}
              </p>
            </div>

            <p style="font-size: 13px; color: #888; margin: 0;">
              Questions? Reply to this email or reach us at <a href="mailto:${TRODDR_EMAIL}" style="color: #0077CC;">${TRODDR_EMAIL}</a>
            </p>
          </div>
          <p style="font-size: 12px; color: #bbb; text-align: center; margin-top: 20px;">
            © 2026 TRODDR · Made with ❤️ in Jamaica
          </p>
        </div>`;

      await sendEmail(resendKey, {
        from:    FROM_EMAIL,
        to:      contactEmail,
        subject: partnerSubject,
        html:    partnerHtml,
      });
    }

    // ── EMAIL 2: To you ───────────────────────────────────────
    const adminSubject = isUpdate
      ? `[TRODDR] Submission updated: ${eventName}`
      : `[TRODDR] New partner submission: ${eventName}`;

    const adminHtml = `
      <div style="font-family: 'Helvetica Neue', Arial, sans-serif; max-width: 560px; margin: 0 auto; color: #111;">
        <h2 style="font-size: 20px; font-weight: 700; margin-bottom: 16px;">
          ${isUpdate ? '✏️ Submission Updated' : '🆕 New Partner Submission'}
        </h2>
        <table style="width: 100%; border-collapse: collapse; font-size: 14px;">
          <tr><td style="padding: 10px 0; border-bottom: 1px solid #eee; color: #666; width: 140px;">Event</td>
              <td style="padding: 10px 0; border-bottom: 1px solid #eee; font-weight: 600;">${eventName}</td></tr>
          <tr><td style="padding: 10px 0; border-bottom: 1px solid #eee; color: #666;">Type</td>
              <td style="padding: 10px 0; border-bottom: 1px solid #eee;">${record.event_type || '—'}</td></tr>
          <tr><td style="padding: 10px 0; border-bottom: 1px solid #eee; color: #666;">Organizer</td>
              <td style="padding: 10px 0; border-bottom: 1px solid #eee;">${record.organizer_name || '—'}</td></tr>
          <tr><td style="padding: 10px 0; border-bottom: 1px solid #eee; color: #666;">Contact</td>
              <td style="padding: 10px 0; border-bottom: 1px solid #eee;">${record.contact_name || '—'} · ${record.contact_email || '—'}</td></tr>
          <tr><td style="padding: 10px 0; border-bottom: 1px solid #eee; color: #666;">Dates</td>
              <td style="padding: 10px 0; border-bottom: 1px solid #eee;">${record.event_start_date || '—'} → ${record.event_end_date || '—'}</td></tr>
          <tr><td style="padding: 10px 0; border-bottom: 1px solid #eee; color: #666;">Venue</td>
              <td style="padding: 10px 0; border-bottom: 1px solid #eee;">${record.venue_name || '—'}</td></tr>
          <tr><td style="padding: 10px 0; border-bottom: 1px solid #eee; color: #666;">Performers</td>
              <td style="padding: 10px 0; border-bottom: 1px solid #eee;">${Array.isArray(record.performers) ? record.performers.length : 0}</td></tr>
          <tr><td style="padding: 10px 0; border-bottom: 1px solid #eee; color: #666;">Vendors</td>
              <td style="padding: 10px 0; border-bottom: 1px solid #eee;">${Array.isArray(record.vendors) ? record.vendors.length : 0}</td></tr>
          <tr><td style="padding: 10px 0; border-bottom: 1px solid #eee; color: #666;">Sponsors</td>
              <td style="padding: 10px 0; border-bottom: 1px solid #eee;">${Array.isArray(record.sponsors) ? record.sponsors.length : 0}</td></tr>
          <tr><td style="padding: 10px 0; color: #666;">Submitted</td>
              <td style="padding: 10px 0;">${new Date(record.submitted_at || record.created_at).toLocaleString('en-JM', { timeZone: 'America/Jamaica' })}</td></tr>
        </table>

        <div style="margin-top: 28px;">
          <a href="https://supabase.com/dashboard/project/rprpwudhplodaqmmwqkf/editor"
             style="display: inline-block; background: #0077CC; color: #fff; text-decoration: none;
                    padding: 12px 22px; border-radius: 8px; font-size: 14px; font-weight: 600; margin-right: 12px;">
            View in Supabase →
          </a>
        </div>

        <p style="font-size: 12px; color: #bbb; margin-top: 24px;">
          Submission ID: ${record.id}<br>
          Token: ${record.token}
        </p>
      </div>`;

    await sendEmail(resendKey, {
      from:    FROM_EMAIL,
      to:      TRODDR_EMAIL,
      subject: adminSubject,
      html:    adminHtml,
    });

    return new Response(JSON.stringify({ success: true }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
      status: 200,
    });

  } catch (err) {
    console.error('notify-partner-submission error:', err);
    return new Response(
      JSON.stringify({ error: err instanceof Error ? err.message : String(err) }),
      { headers: { ...corsHeaders, 'Content-Type': 'application/json' }, status: 400 }
    );
  }
});

// ── Resend API call ───────────────────────────────────────────
async function sendEmail(apiKey: string, opts: {
  from: string;
  to: string;
  subject: string;
  html: string;
}) {
  const res = await fetch('https://api.resend.com/emails', {
    method:  'POST',
    headers: {
      'Authorization': `Bearer ${apiKey}`,
      'Content-Type':  'application/json',
    },
    body: JSON.stringify(opts),
  });

  if (!res.ok) {
    const body = await res.text();
    throw new Error(`Resend error ${res.status}: ${body}`);
  }
  return res.json();
}