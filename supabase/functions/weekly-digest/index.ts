// =============================================================
// weekly-digest: builds a weekly summary email for every place
// partner with an email on file and sends it via send-email.
//
// Schedule it weekly via Supabase Dashboard → Edge Functions →
// Cron, or trigger manually for testing.
// =============================================================
import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

const SUPABASE_URL     = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const SEND_EMAIL_URL   = `${SUPABASE_URL}/functions/v1/send-email`;
const DASHBOARD_BASE   = Deno.env.get('DASHBOARD_BASE_URL') ?? 'https://troddr.com';

const supa = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

const cors = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function escapeHtml(s: any): string {
  if (s == null) return '';
  return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
}

interface PlaceMetrics {
  new_members:        number;
  new_visits:         number;
  total_members:      number;
  new_feedback:       number;
  avg_rating:         number | null;
  new_specials_views: number;
}

async function gatherPlaceMetrics(placeId: string): Promise<PlaceMetrics> {
  const since = new Date(Date.now() - 7 * 86400000).toISOString();

  // New loyalty members in last 7d (joined this week)
  const newMembers = await supa
    .from('user_loyalty_cards')
    .select('id', { count: 'exact', head: true })
    .gte('created_at', since)
    .in('program_id',
      // place's active loyalty programs
      (await supa.from('loyalty_programs').select('id').eq('place_id', placeId).eq('is_active', true)).data?.map(r => r.id) ?? ['00000000-0000-0000-0000-000000000000']);

  // New visits (stamps) in last 7d
  const newVisits = await supa
    .from('loyalty_visits')
    .select('id', { count: 'exact', head: true })
    .eq('place_id', placeId)
    .gte('stamped_at', since);

  // Total members (all-time)
  const totalMembers = await supa
    .from('user_loyalty_cards')
    .select('id', { count: 'exact', head: true })
    .in('program_id',
      (await supa.from('loyalty_programs').select('id').eq('place_id', placeId)).data?.map(r => r.id) ?? ['00000000-0000-0000-0000-000000000000']);

  // New feedback in last 7d
  const newFeedback = await supa
    .from('visited_feedback')
    .select('rating_taste, rating_service, rating_value, rating_vibe', { count: 'exact' })
    .eq('place_id', placeId)
    .gte('created_at', since);

  // Average rating across all of this week's feedback dimensions
  let avgRating: number | null = null;
  if (newFeedback.data && newFeedback.data.length) {
    const allVals: number[] = [];
    for (const row of newFeedback.data) {
      for (const v of Object.values(row)) if (typeof v === 'number') allVals.push(v);
    }
    if (allVals.length) {
      avgRating = Math.round((allVals.reduce((a, b) => a + b, 0) / allVals.length) * 10) / 10;
    }
  }

  return {
    new_members:   newMembers.count ?? 0,
    new_visits:    newVisits.count ?? 0,
    total_members: totalMembers.count ?? 0,
    new_feedback:  newFeedback.count ?? 0,
    avg_rating:    avgRating,
    new_specials_views: 0, // placeholder
  };
}

function buildDigestEmail(place: any, m: PlaceMetrics): { subject: string; html: string } {
  const dashUrl = `${DASHBOARD_BASE}/partner/loyalty?token=${place.partner_access_token}`;
  const stat = (n: number, label: string) => `
    <td style="padding: 14px 12px; background: #f8f9fa; border-radius: 10px; vertical-align: top; width: 50%;">
      <div style="font-size: 26px; font-weight: 800; color: #0077CC; line-height: 1;">${n}</div>
      <div style="font-size: 11px; font-weight: 700; letter-spacing: 0.06em; text-transform: uppercase; color: #666; margin-top: 6px;">${label}</div>
    </td>`;

  const html = `
    <div style="font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; max-width: 560px; margin: 0 auto; padding: 24px;">
      <div style="font-size: 26px; font-weight: 700; color: #0077CC; letter-spacing: -1px; margin-bottom: 6px;">troddr</div>
      <div style="font-size: 12px; color: #999; letter-spacing: 0.08em; text-transform: uppercase; margin-bottom: 18px;">Weekly summary</div>
      <h1 style="font-size: 22px; color: #111; margin: 0 0 6px;">${escapeHtml(place.name)}</h1>
      <p style="font-size: 13px; color: #666; margin: 0 0 22px;">Here's what happened on TRODDR for you last week.</p>

      <table style="width: 100%; border-collapse: separate; border-spacing: 8px;">
        <tr>${stat(m.new_members, 'New members')}${stat(m.new_visits, 'Loyalty visits')}</tr>
        <tr>${stat(m.new_feedback, 'New reviews')}${stat(m.avg_rating ?? 0, 'Avg rating this week')}</tr>
      </table>

      <p style="font-size: 14px; line-height: 1.6; color: #333; margin-top: 22px;">
        Total members all-time: <strong>${m.total_members}</strong>.
      </p>

      <p style="margin: 24px 0;">
        <a href="${dashUrl}" style="display: inline-block; background: #0077CC; color: white; padding: 10px 20px; border-radius: 8px; font-size: 14px; font-weight: 600; text-decoration: none;">Open your dashboard</a>
      </p>

      <hr style="border: none; border-top: 1px solid #e8e8e8; margin: 28px 0 14px;">
      <p style="font-size: 11px; color: #999;">
        You're receiving this because you have a partner account on TRODDR.
        Reply to this email to opt out or change frequency.
      </p>
    </div>
  `;

  return {
    subject: `Your week on TRODDR: ${m.new_members} new members, ${m.new_visits} visits`,
    html,
  };
}

async function sendDigest(email: string, place: any, m: PlaceMetrics) {
  const tpl = buildDigestEmail(place, m);
  await fetch(SEND_EMAIL_URL, {
    method:  'POST',
    headers: {
      'Authorization': `Bearer ${SERVICE_ROLE_KEY}`,
      'Content-Type':  'application/json',
    },
    body: JSON.stringify({
      to:      email,
      subject: tpl.subject,
      html:    tpl.html,
    }),
  });
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });

  try {
    // Only places with an email on file get a digest (opt-in via email presence).
    const { data: places, error } = await supa
      .from('places')
      .select('id, name, slug, partner_access_token, bookings_email, booking_contact_email')
      .or('bookings_email.not.is.null,booking_contact_email.not.is.null');

    if (error) throw error;

    let sent = 0;
    const errors: string[] = [];
    for (const place of (places ?? [])) {
      const email = place.bookings_email || place.booking_contact_email;
      if (!email) continue;
      try {
        const m = await gatherPlaceMetrics(place.id);
        // Skip places that had zero activity this week
        if (m.new_members === 0 && m.new_visits === 0 && m.new_feedback === 0) continue;
        await sendDigest(email, place, m);
        sent++;
      } catch (e: any) {
        errors.push(`${place.name}: ${e?.message ?? e}`);
      }
    }

    return new Response(JSON.stringify({ ok: true, sent, skipped_or_failed: errors.length, errors }), {
      headers: { ...cors, 'Content-Type': 'application/json' },
    });
  } catch (e: any) {
    console.error('[weekly-digest] error', e);
    return new Response(JSON.stringify({ ok: false, error: String(e?.message ?? e) }), {
      status: 500,
      headers: { ...cors, 'Content-Type': 'application/json' },
    });
  }
});
