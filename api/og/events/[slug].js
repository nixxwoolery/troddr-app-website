// api/og/events/[slug].js — Open Graph card for /events/{slug}
//
// This route had a vercel.json rewrite but no function, so event shares
// unfurled as bare text. This is the missing handler.

import {
  BASE_URL, isBot, lastPathSegment, sbSelect,
  firstImage, renderOgPage,
} from '../_lib/og.js';

export const config = { runtime: 'edge' };

async function fetchEvent(slug) {
  const rows = await sbSelect(
    `events?slug=eq.${encodeURIComponent(slug)}&select=*&limit=1`
  );
  return rows[0] || null;
}

// "2026-07-18" → "Saturday, July 18". Noon avoids any TZ date rollback.
function formatEventDate(startDate) {
  if (!startDate) return '';
  try {
    return new Date(`${startDate}T12:00:00`).toLocaleDateString('en-US', {
      weekday: 'long',
      month: 'long',
      day: 'numeric',
    });
  } catch {
    return '';
  }
}

export default async function handler(request) {
  const url = new URL(request.url);
  const slug = lastPathSegment(url.pathname);
  const debug = url.searchParams.get('debug') === '1';

  // vercel.json already redirects humans to /app; this mirrors it if reached.
  if (!isBot(request.headers.get('user-agent')) && !debug) {
    return Response.redirect(`${url.origin}/app?redirect=/events/${encodeURIComponent(slug)}`, 302);
  }

  const event = await fetchEvent(slug);

  const name =
    event?.title || event?.name ||
    slug.replace(/-/g, ' ').replace(/\b\w/g, (s) => s.toUpperCase());
  const venue = event?.venue_name || event?.venue || event?.location || '';
  const dateLabel = formatEventDate(event?.start_date);
  const venueDate = [venue, dateLabel].filter(Boolean).join(' · ');

  // iMessage (and several other clients) show ONLY og:title + the domain in the
  // unfurl caption — never og:description. So stack the name, venue and date
  // into og:title so all three render in the card's bottom section:
  //   A taste of Reggae Sumfest
  //   Plantation Cove
  //   Saturday, July 18
  const ogTitle = [name, venue, dateLabel].filter(Boolean).join('\n');
  // Secondary line for clients that DO show a description (FB, Slack, Twitter).
  const description =
    (event?.description ? event.description.slice(0, 200) : venueDate) ||
    `Check out ${name} on TRODDR.`;
  const imageUrl = firstImage(event?.featured_image_url, event?.image_urls, event?.image);
  const canonicalUrl = `${BASE_URL}/events/${encodeURIComponent(event?.slug || slug)}`;

  if (debug) {
    return new Response(
      JSON.stringify({ slug, found: !!event, name, venue, dateLabel, ogTitle, imageUrl, fields: event ? Object.keys(event) : [] }, null, 2),
      { headers: { 'Content-Type': 'application/json' } }
    );
  }

  return renderOgPage({
    title: name,
    ogTitle,
    description,
    imageUrl,
    canonicalUrl,
    type: 'website',
    imageTitle: name,
    imageSubtitle: venueDate || 'TRODDR Event',
  });
}
