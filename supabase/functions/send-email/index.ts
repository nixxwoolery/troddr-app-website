// =============================================================
// send-email: shared Edge Function that sends transactional emails
// via Resend. Called by Postgres triggers (via supabase_functions.
// http_request) and by other Edge Functions (e.g. weekly-digest).
//
// Required secrets:
//   RESEND_API_KEY   re_xxx  Resend API key
//   FROM_EMAIL       defaults to "TRODDR <hello@troddr.com>"
//   ADMIN_EMAIL      defaults to hello@troddr.com (receives partner messages)
// =============================================================
import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';

const RESEND_API_KEY = Deno.env.get('RESEND_API_KEY');
const FROM_EMAIL     = Deno.env.get('FROM_EMAIL')  ?? 'TRODDR <hello@troddr.com>';
const ADMIN_EMAIL    = Deno.env.get('ADMIN_EMAIL') ?? 'hello@troddr.com';

const cors = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

interface SendArgs {
  to:       string | string[];
  subject:  string;
  html:     string;
  text?:    string;
  reply_to?: string;
}

async function sendViaResend(args: SendArgs): Promise<{ ok: boolean; id?: string; error?: string }> {
  if (!RESEND_API_KEY) return { ok: false, error: 'RESEND_API_KEY not set' };
  const res = await fetch('https://api.resend.com/emails', {
    method:  'POST',
    headers: {
      'Authorization': `Bearer ${RESEND_API_KEY}`,
      'Content-Type':  'application/json',
    },
    body: JSON.stringify({
      from:     FROM_EMAIL,
      to:       Array.isArray(args.to) ? args.to : [args.to],
      subject:  args.subject,
      html:     args.html,
      text:     args.text,
      reply_to: args.reply_to,
    }),
  });
  if (!res.ok) {
    return { ok: false, error: `Resend ${res.status}: ${(await res.text()).slice(0, 200)}` };
  }
  const data = await res.json();
  return { ok: true, id: data?.id };
}

// ---------- Email templates ----------
function wrap(title: string, body: string): string {
  return `
    <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 560px; margin: 0 auto; padding: 24px;">
      <div style="font-size: 26px; font-weight: 700; color: #0077CC; letter-spacing: -1px; margin-bottom: 20px;">troddr</div>
      <h1 style="font-size: 20px; color: #111; margin: 0 0 16px;">${title}</h1>
      <div style="font-size: 14px; line-height: 1.6; color: #333;">${body}</div>
      <hr style="border: none; border-top: 1px solid #e8e8e8; margin: 28px 0 16px;">
      <p style="font-size: 12px; color: #999;">TRODDR · Made with care in Jamaica</p>
    </div>`;
}

function tplPartnerMessage(p: any) {
  return {
    to:       ADMIN_EMAIL,
    subject:  `[Partner Message] ${p.subject || '(no subject)'}`,
    reply_to: p.partner_email || undefined,
    html:     wrap('New partner message', `
      <p><strong>From:</strong> ${escapeHtml(p.context || 'Unknown partner')}</p>
      ${p.subject ? `<p><strong>Subject:</strong> ${escapeHtml(p.subject)}</p>` : ''}
      <p><strong>Sent from:</strong> ${escapeHtml(p.source_page || '/')}</p>
      <div style="background: #f8f9fa; padding: 16px; border-radius: 8px; margin-top: 12px; white-space: pre-wrap;">${escapeHtml(p.message)}</div>
      <p style="margin-top: 18px;"><a href="https://troddr.com/admin/review" style="color: #0077CC;">Open review queue</a></p>`),
  };
}

function tplSubmissionApproved(p: any) {
  return {
    to:      p.partner_email,
    subject: `Your event "${p.event_name}" is live on TRODDR`,
    html:    wrap('Your event is now live', `
      <p>Good news. Your submission for <strong>${escapeHtml(p.event_name)}</strong> has been approved and is live on TRODDR.</p>
      ${p.event_url ? `<p><a href="${p.event_url}" style="color: #0077CC;">View your event page</a></p>` : ''}
      ${p.dashboard_url ? `<p>Track its performance on your dashboard: <a href="${p.dashboard_url}" style="color: #0077CC;">${p.dashboard_url}</a></p>` : ''}`),
  };
}

function tplSubmissionRejected(p: any) {
  return {
    to:      p.partner_email,
    subject: `Update on your event "${p.event_name}" submission`,
    html:    wrap('Your event submission needs another look', `
      <p>Thanks for submitting <strong>${escapeHtml(p.event_name)}</strong>. We weren't able to publish it as submitted.</p>
      ${p.review_note ? `<p><strong>Note from the team:</strong></p><div style="background: #f8f9fa; padding: 16px; border-radius: 8px; white-space: pre-wrap;">${escapeHtml(p.review_note)}</div>` : ''}
      <p>Reply to this email if you'd like to discuss, or open the dashboard to revise and resubmit.</p>`),
  };
}

function tplSpecialApproved(p: any) {
  return {
    to:      p.partner_email,
    subject: `Your special "${p.title}" is live`,
    html:    wrap('Your special is now live', `
      <p>Your special <strong>${escapeHtml(p.title)}</strong> for <strong>${escapeHtml(p.place_name)}</strong> is approved and visible in the TRODDR app.</p>
      ${p.dashboard_url ? `<p>Track its performance: <a href="${p.dashboard_url}" style="color: #0077CC;">${p.dashboard_url}</a></p>` : ''}`),
  };
}

function tplSpecialRejected(p: any) {
  return {
    to:      p.partner_email,
    subject: `Update on your special "${p.title}"`,
    html:    wrap('Your special needs another look', `
      <p>Thanks for submitting <strong>${escapeHtml(p.title)}</strong>. We weren't able to publish it as submitted.</p>
      ${p.review_note ? `<p><strong>Note from the team:</strong></p><div style="background: #f8f9fa; padding: 16px; border-radius: 8px; white-space: pre-wrap;">${escapeHtml(p.review_note)}</div>` : ''}
      <p>Open the dashboard to revise and resubmit, or reply to this email to discuss.</p>`),
  };
}

function escapeHtml(s: any): string {
  if (s == null) return '';
  return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
}

const TEMPLATES: Record<string, (p: any) => SendArgs> = {
  partner_message:     tplPartnerMessage,
  submission_approved: tplSubmissionApproved,
  submission_rejected: tplSubmissionRejected,
  special_approved:    tplSpecialApproved,
  special_rejected:    tplSpecialRejected,
};

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  try {
    const body = await req.json();
    const template = (body?.template ?? '').toString();
    const params   = body?.params ?? {};

    if (template && TEMPLATES[template]) {
      const args   = TEMPLATES[template](params);
      if (!args.to) return new Response(JSON.stringify({ ok: false, error: 'No recipient' }),
        { status: 400, headers: { ...cors, 'Content-Type': 'application/json' } });
      const result = await sendViaResend(args);
      return new Response(JSON.stringify(result), {
        status: result.ok ? 200 : 500,
        headers: { ...cors, 'Content-Type': 'application/json' },
      });
    }

    // Direct send (advanced usage)
    if (body?.to && body?.subject && (body?.html || body?.text)) {
      const result = await sendViaResend(body);
      return new Response(JSON.stringify(result), {
        status: result.ok ? 200 : 500,
        headers: { ...cors, 'Content-Type': 'application/json' },
      });
    }

    return new Response(JSON.stringify({ ok: false, error: 'Missing template or to/subject/html' }),
      { status: 400, headers: { ...cors, 'Content-Type': 'application/json' } });
  } catch (e: any) {
    console.error('[send-email] error', e);
    return new Response(JSON.stringify({ ok: false, error: String(e?.message ?? e) }),
      { status: 500, headers: { ...cors, 'Content-Type': 'application/json' } });
  }
});
