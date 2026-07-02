// api/og/invites/[id].js — Open Graph card for /invites/{token}
//
// Collaborator invite shares look like https://www.troddr.com/invites/{uuid},
// where the uuid is the invite_token from trip_collaborators. Crawlers get the
// same public-facing card treatment as an itinerary share; humans are bounced
// to /app to open/download the app.
//
// The token is capability-gated: get_trip_invite_preview (SECURITY DEFINER)
// only returns a trip for a real invite token, so we never leak a private trip.

import {
  BASE_URL, isBot, lastPathSegment, sbRpc,
  formatTripDateRange, renderOgPage,
} from '../_lib/og.js';

export const config = { runtime: 'edge' };

const INVITE_SHARE_IMAGE_VERSION = '20260701-share-match-v2';

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
      title: 'My TRODDR Itinerary',
      ogTitle: 'My itinerary on TRODDR',
      description: 'Plan and share your trip on TRODDR.',
      imageUrl: `${BASE_URL}/api/og/invite-image?token=${encodeURIComponent(token)}&v=${INVITE_SHARE_IMAGE_VERSION}`,
      canonicalUrl,
      type: 'website',
      imageTitle: 'My itinerary',
      imageSubtitle: 'Plan your trip on TRODDR',
      imageWidth: 1080,
      imageHeight: 1500,
    });
  }

  const tripName = invite.trip_title || invite.trip_destination || 'this trip';
  const destination = invite.trip_destination || tripName;
  const dateRange = formatTripDateRange(invite.trip_start_date, invite.trip_end_date);

  // iMessage shows og:title as the caption below the rich preview. Keep the
  // invite language here while the og:image keeps the share-link visual style.
  const ogTitle = `Join me on TRODDR to plan "${tripName}" together:`;

  const description =
    [destination, dateRange].filter(Boolean).join(' · ') ||
    `My trip to ${destination}, planned on TRODDR.`;

  const imageUrl = `${BASE_URL}/api/og/invite-image?token=${encodeURIComponent(token)}&v=${INVITE_SHARE_IMAGE_VERSION}`;

  return renderOgPage({
    title: `Join ${tripName} on TRODDR`,
    ogTitle,
    description,
    imageUrl,
    canonicalUrl,
    type: 'website',
    imageTitle: `I'm going to ${destination}`,
    imageSubtitle: dateRange || 'My itinerary',
    imageWidth: 1080,
    imageHeight: 1500,
  });
}
