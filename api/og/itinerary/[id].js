// api/og/itinerary/[id].js — Open Graph card for /itinerary/{id}?token={token}
//
// TOKEN-GATED. Shares look like /itinerary/{uuid}?token={shareToken}. The
// itinerary id is in the path; the share token is in the ?token= query. We
// validate against get_shared_itinerary (a security-definer RPC that only
// returns *shared* trips). If the token is absent/invalid we fall back to
// get_shared_itinerary_by_id using the path id — also shared-only, so it never
// leaks a private trip — which makes the card resilient if a client strips the
// query string. Only when neither resolves do we show a generic card.

import {
  BASE_URL, isBot, isUuid, lastPathSegment, sbRpc,
  firstImage, formatTripDateRange, renderOgPage, serveHumanPage,
} from '../_lib/og.js';

export const config = { runtime: 'edge' };

function looksShared(data) {
  return data && (data.title || data.items) ? data : null;
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

// Shared-only lookup by itinerary id (same RPC the public trip page falls back
// to). Returns null for private/unshared trips, so it cannot leak.
async function fetchById(id) {
  if (!isUuid(id)) return null;
  return looksShared(await sbRpc('get_shared_itinerary_by_id', { _itinerary_id: id }));
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

  const itinerary = (await fetchByToken(token)) || (await fetchById(id));

  const canonicalUrl = `${BASE_URL}/itinerary/${encodeURIComponent(id)}${
    token ? `?token=${encodeURIComponent(token)}` : ''
  }`;

  if (debug) {
    return new Response(
      JSON.stringify({ id, hasToken: !!token, found: !!itinerary, destination: itinerary?.destination, stops: itinerary?.items?.length || 0, imageUrl: firstImage(itinerary?.items?.find((i) => i?.image)?.image) }, null, 2),
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

  const destination = itinerary.destination || 'Jamaica';
  const stops = Array.isArray(itinerary.items) ? itinerary.items.length : 0;
  const dateRange = formatTripDateRange(itinerary.start_date, itinerary.end_date);
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

  // Use a photo from one of the trip's stops; branded card only if none has one.
  const imageUrl = firstImage(
    itinerary.items?.find((i) => i?.image)?.image,
    itinerary.cover_image,
    itinerary.image
  );

  return renderOgPage({
    title: `My trip to ${destination}`,
    ogTitle,
    description,
    imageUrl,
    canonicalUrl,
    type: 'website',
    imageTitle: `I'm going to ${destination}`,
    imageSubtitle: [dateRange, stopsLabel].filter(Boolean).join(' · ') || 'My itinerary',
  });
}
