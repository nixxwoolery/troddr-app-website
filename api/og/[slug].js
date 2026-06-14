// api/og/[slug].js — Open Graph card for /listings/{slug} and /listings/{id}
//
// The map screen shares /listings/{uuid}; every other listing share uses
// /listings/{slug}. We resolve BOTH.

import {
  BASE_URL, isBot, isUuid, lastPathSegment, sbSelect,
  firstImage, renderOgPage, serveHumanPage,
} from './_lib/og.js';

export const config = { runtime: 'edge' };

async function fetchPlace(idOrSlug) {
  const column = isUuid(idOrSlug) ? 'id' : 'slug';
  const rows = await sbSelect(
    `places?${column}=eq.${encodeURIComponent(idOrSlug)}&select=*&limit=1`
  );
  return rows[0] || null;
}

export default async function handler(request) {
  const url = new URL(request.url);
  const slug = lastPathSegment(url.pathname);
  const debug = url.searchParams.get('debug') === '1';

  // Humans → the real listings page (URL bar unchanged).
  if (!isBot(request.headers.get('user-agent')) && !debug) {
    return serveHumanPage(url.origin, `/listings.html?slug=${encodeURIComponent(slug)}`);
  }

  const place = await fetchPlace(slug);

  const name =
    place?.name || slug.replace(/-/g, ' ').replace(/\b\w/g, (s) => s.toUpperCase());
  const location = [place?.town, place?.parish].filter(Boolean).join(', ');
  const title = `${name}${location ? ` in ${location}` : ''} — TRODDR`;
  const description = place?.description
    ? place.description.slice(0, 200)
    : `Check out ${name}${location ? ` in ${location}` : ''} on TRODDR.`;
  const imageUrl = firstImage(place?.image);
  // Canonical always points at the slug form when we have it.
  const canonicalUrl = `${BASE_URL}/listings/${encodeURIComponent(place?.slug || slug)}`;

  if (debug) {
    return new Response(
      JSON.stringify({ slug, found: !!place, name, location, imageUrl, fields: place ? Object.keys(place) : [] }, null, 2),
      { headers: { 'Content-Type': 'application/json' } }
    );
  }

  return renderOgPage({
    title,
    description,
    imageUrl,
    canonicalUrl,
    type: 'website',
    imageTitle: name,
    imageSubtitle: location || 'Discover Jamaica',
  });
}
