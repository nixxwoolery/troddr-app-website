// api/og/invites/[id].js — Open Graph card for /invites/{token}
//
// The /invites/{token} URL is overloaded: the same shape backs a PLACE invite
// (dinner/drinks/coffee…), an EVENT invite, a multi-place POLL, and a trip
// COLLABORATOR invite. Each token type has its own SECURITY DEFINER preview
// RPC, all capability-gated, so we never leak a private plan.
//
// We probe in the app's order — place → event → trip — and render a card that
// matches what the link actually is. (Poll tokens reuse the parent place_invite
// row, so they resolve through get_place_invite_preview to the first option's
// place, which is a fine preview.) Anything unrecognised gets a generic,
// non-leaking card. Humans are bounced to /app by vercel.json (mirrored here).

import {
  BASE_URL, isBot, lastPathSegment, sbRpc, firstImage,
  formatTripDateRange, renderOgPage,
} from '../_lib/og.js';

export const config = { runtime: 'edge' };

const INVITE_SHARE_IMAGE_VERSION = '20260701-share-match-v2';

// The occasion key → the phrase that slots into "invited you to ___ at Place".
const OCCASION_PHRASE = {
  breakfast: 'breakfast',
  brunch: 'brunch',
  lunch: 'lunch',
  dinner: 'dinner',
  drinks: 'drinks',
  coffee: 'coffee',
  hangout: 'a hangout',
  getaway: 'a getaway',
};

// RPCs that return a TABLE (one row) → PostgREST array.
function firstRow(data) {
  if (Array.isArray(data)) return data[0] || null;
  return data || null;
}

function cap(s) {
  return s ? s.charAt(0).toUpperCase() + s.slice(1) : s;
}

// place_image / event_image arrive as a Postgres array TEXT literal — e.g.
// "{https://a.jpg,https://b.jpg}" — because the RPC declares the column as
// text. firstImage only understands real arrays / JSON strings, so unwrap the
// {…} form into elements first. Falls through to firstImage for anything else.
function coerceImage(field) {
  if (typeof field === 'string') {
    const s = field.trim();
    if (s.startsWith('{') && s.endsWith('}')) {
      const inner = s.slice(1, -1);
      if (!inner) return null;
      const parts = inner.split(',').map((p) => p.replace(/^"+|"+$/g, '').trim());
      return firstImage(parts);
    }
  }
  return firstImage(field);
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

  const canonicalUrl = `${BASE_URL}/invites/${encodeURIComponent(token)}`;

  // Probe each invite type in the app's order.
  const place = firstRow(await sbRpc('get_place_invite_preview', { _token: token }));
  const event = place?.place_id
    ? null
    : firstRow(await sbRpc('get_event_invite_preview', { _token: token }));
  const trip = place?.place_id || event?.event_id
    ? null
    : firstRow(await sbRpc('get_trip_invite_preview', { _token: token }));

  if (debug) {
    return new Response(
      JSON.stringify(
        {
          token,
          kind: place?.place_id ? 'place' : event?.event_id ? 'event' : trip?.trip_id ? 'trip' : 'none',
          place, event, trip,
        },
        null,
        2
      ),
      { headers: { 'Content-Type': 'application/json' } }
    );
  }

  // ── PLACE invite (the common case: dinner/drinks/coffee at a restaurant) ──
  if (place?.place_id) {
    const host = (place.host_name || '').trim();
    const placeName = place.place_name || 'a spot';
    const phrase = OCCASION_PHRASE[String(place.occasion || '').toLowerCase()] || 'a meet-up';
    const where = [place.place_town, place.place_parish].filter(Boolean)[0] || '';
    const when = (place.when_label || '').trim();

    const ogTitle = host
      ? `${host} invited you to ${phrase} at ${placeName}`
      : `You're invited to ${phrase} at ${placeName}`;
    const description = [where, when].filter(Boolean).join(' · ') || 'Tap to RSVP on TRODDR.';

    return renderOgPage({
      title: `${cap(phrase)} at ${placeName} · TRODDR`,
      ogTitle,
      description,
      imageUrl: coerceImage(place.place_image),
      canonicalUrl,
      type: 'website',
      imageTitle: placeName,
      imageSubtitle: [cap(phrase), when].filter(Boolean).join(' · '),
    });
  }

  // ── EVENT invite ──────────────────────────────────────────────────────────
  if (event?.event_id) {
    const host = (event.host_name || '').trim();
    const eventTitle = event.event_title || 'an event';
    const venue = event.event_venue || [event.event_town, event.event_parish].filter(Boolean)[0] || '';
    const when = formatTripDateRange(event.start_date, event.start_date) || '';

    const ogTitle = host
      ? `${host} invited you to ${eventTitle}`
      : `You're invited to ${eventTitle}`;
    const description = [venue, when].filter(Boolean).join(' · ') || 'Tap to RSVP on TRODDR.';

    return renderOgPage({
      title: `${eventTitle} · TRODDR`,
      ogTitle,
      description,
      imageUrl: coerceImage(event.event_image),
      canonicalUrl,
      type: 'website',
      imageTitle: eventTitle,
      imageSubtitle: [venue, when].filter(Boolean).join(' · '),
    });
  }

  // ── TRIP collaborator invite (original behaviour) ─────────────────────────
  if (trip?.trip_id) {
    const tripName = trip.trip_title || trip.trip_destination || 'this trip';
    const destination = trip.trip_destination || tripName;
    const dateRange = formatTripDateRange(trip.trip_start_date, trip.trip_end_date);

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

  // ── Nothing matched → generic, non-leaking card ───────────────────────────
  return renderOgPage({
    title: 'You’re invited on TRODDR',
    ogTitle: 'You’re invited on TRODDR',
    description: 'Tap to see the plan and RSVP on TRODDR.',
    canonicalUrl,
    type: 'website',
    imageTitle: 'You’re invited',
    imageSubtitle: 'See the plan on TRODDR',
  });
}
