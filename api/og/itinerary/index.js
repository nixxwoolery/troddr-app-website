// api/og/itinerary/index.js — Open Graph card for /itinerary and
// /itinerary?tripId=…&token=…  (query-string form). Token-gated exactly like
// the path form in [id].js, with the same shared-only by-id fallback.

import {
  BASE_URL, isBot, sbRpc, firstImage, formatTripDateRange,
  renderOgPage, serveHumanPage,
} from '../_lib/og.js';

export const config = { runtime: 'edge' };

const looksShared = (data) => (data && (data.title || data.items) ? data : null);

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
  const tripId = url.searchParams.get('tripId') || '';
  const token = url.searchParams.get('token') || tripId;
  const debug = url.searchParams.get('debug') === '1';

  if (!isBot(request.headers.get('user-agent')) && !debug) {
    const q = [tripId && `tripId=${encodeURIComponent(tripId)}`, token && token !== tripId && `token=${encodeURIComponent(token)}`]
      .filter(Boolean).join('&');
    return serveHumanPage(url.origin, `/itinerary.html${q ? `?${q}` : ''}`);
  }

  const itinerary = await fetchByToken(token);
  const canonicalUrl = `${BASE_URL}/itinerary${tripId ? `?tripId=${encodeURIComponent(tripId)}` : ''}`;

  if (debug) {
    return new Response(
      JSON.stringify({ tripId, hasToken: !!token, found: !!itinerary, destination: itinerary?.destination, stops: itinerary?.items?.length || 0 }, null, 2),
      { headers: { 'Content-Type': 'application/json' } }
    );
  }

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

  const ogTitle = [
    `I'm going to ${destination}${dateRange ? `, ${dateRange}` : ''}`,
    "Here's my itinerary",
  ].join('\n');

  return renderOgPage({
    title: `My trip to ${destination}`,
    ogTitle,
    description: [dateRange, stopsLabel].filter(Boolean).join(' · ') || `My trip to ${destination}, planned on TRODDR.`,
    imageUrl: firstImage(itinerary.items?.find((i) => i?.image)?.image, itinerary.cover_image, itinerary.image),
    canonicalUrl,
    type: 'website',
    imageTitle: `I'm going to ${destination}`,
    imageSubtitle: [dateRange, stopsLabel].filter(Boolean).join(' · ') || 'My itinerary',
  });
}
