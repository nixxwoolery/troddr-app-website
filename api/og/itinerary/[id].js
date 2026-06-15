// api/og/itinerary/[id].js — Open Graph card for /itinerary/{id}?token={token}
//
// TOKEN-GATED. Shares look like /itinerary/{uuid}?token={shareToken}. The
// itinerary id is in the path; the share token is in the ?token= query. We
// validate against get_shared_itinerary (a security-definer RPC that only
// returns *shared* trips); with no valid token we show a generic card and never
// leak a private trip.
//
// NOTE: the vercel.json route MUST name the path param :id (not :token) — a
// :token path param collides with the ?token= query and Vercel overwrites the
// real share token with the itinerary id, breaking validation.

import {
  BASE_URL, isBot, lastPathSegment, sbRpc,
  firstImage, formatTripDateRange, renderOgPage, serveHumanPage,
} from '../_lib/og.js';

export const config = { runtime: 'edge' };

const ITINERARY_SHARE_IMAGE_VERSION = '20260615-portrait-v3';

// get_shared_itinerary returns { itinerary: {...}, places: [...] } for a valid
// share token, or null otherwise.
function looksShared(data) {
  return data && (data.itinerary || data.title) ? data : null;
}

// Validate the share token, trying the dash/dashless variants the app uses.
async function fetchByToken(token) {
  if (!token) return null;
  const tryToken = async (t) => looksShared(await sbRpc('get_shared_itinerary', { _token: t }));

  let result = await tryToken(token);
  if (result) return result;
  if (token.includes('-')) {
    result = await tryToken(token.replace(/-/g, ''));
    if (result) return result;
  }
  if (/^[0-9a-fA-F]{32}$/.test(token)) {
    const dashed = token.replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/, '$1-$2-$3-$4-$5');
    result = await tryToken(dashed);
    if (result) return result;
  }
  return null;
}

export default async function handler(request) {
  const url = new URL(request.url);
  const id = lastPathSegment(url.pathname); // itinerary id (path)
  const token = url.searchParams.get('token') || ''; // share token (authorizes)
  const debug = url.searchParams.get('debug') === '1';

  if (!isBot(request.headers.get('user-agent')) && !debug) {
    const q = `tripId=${encodeURIComponent(id)}${token ? `&token=${encodeURIComponent(token)}` : ''}`;
    return serveHumanPage(url.origin, `/itinerary.html?${q}`);
  }

  const itinerary = await fetchByToken(token);

  const canonicalUrl = `${BASE_URL}/itinerary/${encodeURIComponent(id)}${
    token ? `?token=${encodeURIComponent(token)}` : ''
  }`;

  // Normalize the RPC shape: { itinerary: {...}, places: [...] }.
  const trip = itinerary?.itinerary || itinerary || {};
  const places = itinerary?.places || itinerary?.items || [];

  if (debug) {
    return new Response(
      JSON.stringify({ id, hasToken: !!token, found: !!itinerary, destination: trip.destination, stops: places.length, imageUrl: firstImage(...places.map((p) => p?.image)) }, null, 2),
      { headers: { 'Content-Type': 'application/json' } }
    );
  }

  // No shared trip resolved → generic, non-leaking card.
  if (!itinerary) {
    return renderOgPage({
      title: 'My TRODDR Itinerary',
      ogTitle: 'My itinerary on TRODDR',
      description: 'Plan and share your trip on TRODDR.',
      imageUrl: null,
      canonicalUrl,
      type: 'website',
      imageTitle: 'My itinerary',
      imageSubtitle: 'Plan your trip on TRODDR',
    });
  }

  const destination = trip.destination || 'Jamaica';
  const stops = places.length;
  const dateRange = formatTripDateRange(trip.start_date, trip.end_date);
  const stopsLabel = stops ? `${stops} ${stops === 1 ? 'stop' : 'stops'}` : '';

  // iMessage shows only og:title — stack the trip pitch so it all lands in the
  // card caption: "I'm going to St. Ann, July 18 – 19" / "Here's my itinerary".
  const ogTitle = [
    `I'm going to ${destination}${dateRange ? `, ${dateRange}` : ''}`,
    "Here's my itinerary",
  ].join('\n');
  const description =
    [dateRange, stopsLabel].filter(Boolean).join(' · ') ||
    `My trip to ${destination}, planned on TRODDR.`;

  // og:image is the generated collage (hero photo + destination + dates +
  // stops + thumbnails + footer) so the single tappable card looks like the
  // in-app trip card. It re-validates the token server-side before rendering.
  const imageUrl = `${BASE_URL}/api/og/itinerary-image?id=${encodeURIComponent(id)}&token=${encodeURIComponent(token)}&v=${ITINERARY_SHARE_IMAGE_VERSION}`;

  return renderOgPage({
    title: `My trip to ${destination}`,
    ogTitle,
    description,
    imageUrl,
    canonicalUrl,
    type: 'website',
    imageTitle: `I'm going to ${destination}`,
    imageSubtitle: [dateRange, stopsLabel].filter(Boolean).join(' · ') || 'My itinerary',
    imageWidth: 1080,
    imageHeight: 1500,
  });
}
