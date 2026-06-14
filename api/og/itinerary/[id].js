// api/og/itinerary/[id].js — Open Graph card for /itinerary/{id}?token={token}
//
// TOKEN-GATED. Shares look like /itinerary/{uuid}?token={shareToken}. The
// itinerary id is in the path; the *share token* is in the ?token= query and
// is the only thing that authorizes exposing trip details. We validate it
// against get_shared_itinerary (a security-definer RPC that only returns
// shared trips). On a missing/invalid token we return a generic branded card
// and never leak a private itinerary.

import {
  BASE_URL, isBot, lastPathSegment, sbRpc,
  firstImage, renderOgPage, serveHumanPage,
} from '../_lib/og.js';

export const config = { runtime: 'edge' };

// Validate the share token, trying the dash/dashless variants the app uses.
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
      month: 'short',
      day: 'numeric',
    });
  } catch {
    return '';
  }
};

export default async function handler(request) {
  const url = new URL(request.url);
  const id = lastPathSegment(url.pathname); // itinerary id (path)
  const token = url.searchParams.get('token') || ''; // share token (authorizes)
  const debug = url.searchParams.get('debug') === '1';

  // Humans → the real itinerary page (keeps both id + token).
  if (!isBot(request.headers.get('user-agent')) && !debug) {
    const q = `tripId=${encodeURIComponent(id)}${token ? `&token=${encodeURIComponent(token)}` : ''}`;
    return serveHumanPage(url.origin, `/itinerary.html?${q}`);
  }

  const itinerary = await fetchSharedItinerary(token);

  const canonicalUrl = `${BASE_URL}/itinerary/${encodeURIComponent(id)}${
    token ? `?token=${encodeURIComponent(token)}` : ''
  }`;

  if (debug) {
    return new Response(
      JSON.stringify({ id, hasToken: !!token, found: !!itinerary, destination: itinerary?.destination, stops: itinerary?.items?.length || 0 }, null, 2),
      { headers: { 'Content-Type': 'application/json' } }
    );
  }

  // No valid token → generic, non-leaking card.
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
    .filter(Boolean)
    .join(' · ');

  const title = `Trip to ${destination} — TRODDR`;
  const description = subtitle || `A trip to ${destination}, planned on TRODDR.`;
  const imageUrl = firstImage(
    itinerary.items?.find((i) => i?.image)?.image,
    itinerary.cover_image,
    itinerary.image
  );

  return renderOgPage({
    title,
    description,
    imageUrl,
    canonicalUrl,
    type: 'website',
    imageTitle: `Trip to ${destination}`,
    imageSubtitle: subtitle || 'Planned on TRODDR',
  });
}
