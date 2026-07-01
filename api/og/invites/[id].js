// api/og/invites/[id].js — Open Graph card for /invites/{token}
//
// Collaborator invite shares look like https://www.troddr.com/invites/{uuid},
// where the uuid is the invite_token from trip_collaborators. Crawlers get a
// rich card (trip name, destination, dates, inviter) so the invite unfurls like
// an itinerary share; humans are bounced to /app to open/download the app.
//
// The token is capability-gated: get_trip_invite_preview (SECURITY DEFINER)
// only returns a trip for a real invite token, so we never leak a private trip.

import {
  BASE_URL, isBot, lastPathSegment, sbRpc,
  formatTripDateRange, renderOgPage,
} from '../_lib/og.js';

export const config = { runtime: 'edge' };

const INVITE_SHARE_IMAGE_VERSION = '20260630-v1';

// get_trip_invite_preview returns a TABLE (one row) → PostgREST array.
function firstRow(data) {
  if (Array.isArray(data)) return data[0] || null;
  return data || null;
}

export default async function handler(request) {
  const url = new URL(request.url);
  const token = lastPathSegment(url.pathname); // invite token (path)
  const debug = url.searchParams.get('debug') === '1';

  // vercel.json already redirects humans to /app; this mirrors it if reached.
  if (!isBot(request.headers.get('user-agent')) && !debug) {
    return Response.redirect(
      `${url.origin}/app?redirect=/invites/${encodeURIComponent(token)}`,
      302
    );
  }

  const invite = firstRow(await sbRpc('get_trip_invite_preview', { _token: token }));

  const canonicalUrl = `${BASE_URL}/invites/${encodeURIComponent(token)}`;

  if (debug) {
    return new Response(
      JSON.stringify({ token, found: !!invite?.trip_id, invite }, null, 2),
      { headers: { 'Content-Type': 'application/json' } }
    );
  }

  // No valid invite → generic, non-leaking card.
  if (!invite?.trip_id) {
    return renderOgPage({
      title: 'You’re invited on TRODDR',
      ogTitle: 'You’re invited to plan a trip on TRODDR',
      description: 'Open the invite in TRODDR to plan the trip together.',
      imageUrl: `${BASE_URL}/api/og/invite-image?token=${encodeURIComponent(token)}&v=${INVITE_SHARE_IMAGE_VERSION}`,
      canonicalUrl,
      type: 'website',
      imageTitle: 'You’re invited',
      imageSubtitle: 'Plan the trip together on TRODDR',
      imageWidth: 1080,
      imageHeight: 1500,
    });
  }

  const tripName = invite.trip_title || invite.trip_destination || 'a trip';
  const destination = invite.trip_destination || tripName;
  const inviter = invite.inviter_name;
  const dateRange = formatTripDateRange(invite.trip_start_date, invite.trip_end_date);

  // iMessage shows only og:title, so stack the invite pitch into the title so it
  // all lands in the card caption:
  //   nixx invited you to plan "Shadae's Trip"
  //   Ocho Rios · July 9 – 13
  const line1 = inviter
    ? `${inviter} invited you to plan “${tripName}”`
    : `You’re invited to plan “${tripName}”`;
  const line2 = [destination, dateRange].filter(Boolean).join(' · ');
  const ogTitle = [line1, line2].filter(Boolean).join('\n');

  const description =
    [destination, dateRange].filter(Boolean).join(' · ') ||
    `Join ${inviter || 'the trip'} on TRODDR to plan together.`;

  const imageUrl = `${BASE_URL}/api/og/invite-image?token=${encodeURIComponent(token)}&v=${INVITE_SHARE_IMAGE_VERSION}`;

  return renderOgPage({
    title: `Join ${tripName} on TRODDR`,
    ogTitle,
    description,
    imageUrl,
    canonicalUrl,
    type: 'website',
    imageTitle: line1,
    imageSubtitle: line2 || 'Plan the trip together',
    imageWidth: 1080,
    imageHeight: 1500,
  });
}
