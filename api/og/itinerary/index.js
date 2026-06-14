// api/og/itinerary/index.js — Open Graph card for /itinerary and
// /itinerary?tripId=…&token=…  (query-string form). Token-gated exactly like
// the path form in [id].js: a valid share token is required to expose any
// trip details, otherwise we return a generic, non-leaking card.

import {
  BASE_URL, isBot, sbRpc, firstImage, renderOgPage, serveHumanPage,
} from '../_lib/og.js';

export const config = { runtime: 'edge' };

async function fetchSharedItinerary(token) {
  if (!token) return null;
  const tryToken = async (t) => {
    const data = await sbRpc('get_shared_itinerary', { _token: t });
    return data && (data.title || data.items) ? data : null;
  };
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

const fmtDay = (iso) => {
  if (!iso) return '';
  try {
    return new Date(`${String(iso).slice(0, 10)}T12:00:00`).toLocaleDateString('en-US', {
      month: 'short', day: 'numeric',
    });
  } catch {
    return '';
  }
};

export default async function handler(request) {
  const url = new URL(request.url);
  const tripId = url.searchParams.get('tripId') || '';
  // Token may arrive as ?token= (share token) or, historically, in ?tripId=.
  const token = url.searchParams.get('token') || tripId;
  const debug = url.searchParams.get('debug') === '1';

  if (!isBot(request.headers.get('user-agent')) && !debug) {
    const q = [tripId && `tripId=${encodeURIComponent(tripId)}`, token && token !== tripId && `token=${encodeURIComponent(token)}`]
      .filter(Boolean).join('&');
    return serveHumanPage(url.origin, `/itinerary.html${q ? `?${q}` : ''}`);
  }

  const itinerary = await fetchSharedItinerary(token);
  const canonicalUrl = `${BASE_URL}/itinerary${tripId ? `?tripId=${encodeURIComponent(tripId)}` : ''}`;

  if (debug) {
    return new Response(
      JSON.stringify({ tripId, hasToken: !!token, found: !!itinerary, destination: itinerary?.destination, stops: itinerary?.items?.length || 0 }, null, 2),
      { headers: { 'Content-Type': 'application/json' } }
    );
  }

  if (!itinerary) {
    return renderOgPage({
      title: 'A Trip on TRODDR',
      description: 'Plan and share your Caribbean trip on TRODDR.',
      imageUrl: null,
      canonicalUrl,
      type: 'website',
      imageTitle: 'A Trip on TRODDR',
      imageSubtitle: 'Plan your Caribbean trip',
    });
  }

  const destination = itinerary.destination || 'Jamaica';
  const stops = Array.isArray(itinerary.items) ? itinerary.items.length : 0;
  const dateRange =
    itinerary.start_date && itinerary.end_date
      ? `${fmtDay(itinerary.start_date)} – ${fmtDay(itinerary.end_date)}`
      : '';
  const subtitle = [dateRange, stops ? `${stops} ${stops === 1 ? 'stop' : 'stops'}` : '']
    .filter(Boolean).join(' · ');

  return renderOgPage({
    title: `Trip to ${destination} — TRODDR`,
    description: subtitle || `A trip to ${destination}, planned on TRODDR.`,
    imageUrl: firstImage(itinerary.items?.find((i) => i?.image)?.image, itinerary.cover_image, itinerary.image),
    canonicalUrl,
    type: 'website',
    imageTitle: `Trip to ${destination}`,
    imageSubtitle: subtitle || 'Planned on TRODDR',
  });
}
