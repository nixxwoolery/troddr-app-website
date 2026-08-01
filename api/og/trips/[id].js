// api/og/trips/[id].js — Open Graph card for /trips/{token}
//
// Trip COLLABORATOR invite shares. The uuid is the invite_token from
// trip_collaborators; get_trip_invite_preview (SECURITY DEFINER) validates it
// and returns the trip meta, so a private trip is never leaked.
//
// This is the dedicated home for trip shares. Place/event invites live at
// /invites/{token}. The /invites handler keeps a trip fallback so links shared
// under the old /invites/{trip_token} form still unfurl correctly.

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

  // vercel.json redirects humans to /app; mirror it if reached directly.
  if (!isBot(request.headers.get('user-agent')) && !debug) {
    return Response.redirect(
      `${url.origin}/app?redirect=/trips/${encodeURIComponent(token)}`,
      302
    );
  }

  const invite = firstRow(await sbRpc('get_trip_invite_preview', { _token: token }));
  const canonicalUrl = `${BASE_URL}/trips/${encodeURIComponent(token)}`;

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

  const ogTitle = `Join me on TRODDR to plan "${tripName}" together:`;
  const description =
    [destination, dateRange].filter(Boolean).join(' · ') ||
    `My trip to ${destination}, planned on TRODDR.`;

  return renderOgPage({
    title: `Join ${tripName} on TRODDR`,
    ogTitle,
    description,
    imageUrl: `${BASE_URL}/api/og/invite-image?token=${encodeURIComponent(token)}&v=${INVITE_SHARE_IMAGE_VERSION}`,
    canonicalUrl,
    type: 'website',
    imageTitle: `I'm going to ${destination}`,
    imageSubtitle: dateRange || 'My itinerary',
    imageWidth: 1080,
    imageHeight: 1500,
  });
}
