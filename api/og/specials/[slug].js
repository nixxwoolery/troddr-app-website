// api/og/specials/[slug].js — Open Graph card for /specials/{special_slug}

import {
  BASE_URL, isBot, lastPathSegment, sbSelect,
  firstImage, renderOgPage, serveHumanPage,
} from '../_lib/og.js';

export const config = { runtime: 'edge' };

async function fetchSpecial(slug) {
  // Specials are looked up by special_slug; fall back to slug for safety.
  let rows = await sbSelect(
    `specials?special_slug=eq.${encodeURIComponent(slug)}&select=*&limit=1`
  );
  if (rows[0]) return rows[0];
  rows = await sbSelect(`specials?slug=eq.${encodeURIComponent(slug)}&select=*&limit=1`);
  return rows[0] || null;
}

export default async function handler(request) {
  const url = new URL(request.url);
  const slug = lastPathSegment(url.pathname);
  const debug = url.searchParams.get('debug') === '1';

  if (!isBot(request.headers.get('user-agent')) && !debug) {
    return serveHumanPage(url.origin, `/specials.html?special_slug=${encodeURIComponent(slug)}`);
  }

  const special = await fetchSpecial(slug);

  const name =
    special?.title || special?.name ||
    slug.replace(/-/g, ' ').replace(/\b\w/g, (s) => s.toUpperCase());
  const placeName = special?.place_name || special?.restaurant_name || '';
  const title = `${name}${placeName ? ` at ${placeName}` : ''} — TRODDR`;
  const description = special?.description
    ? special.description.slice(0, 200)
    : `Check out this special${placeName ? ` at ${placeName}` : ''} on TRODDR.`;
  const imageUrl = firstImage(special?.image_urls, special?.image, special?.image_url, special?.cover_image);
  const canonicalUrl = `${BASE_URL}/specials/${encodeURIComponent(special?.special_slug || slug)}`;

  if (debug) {
    return new Response(
      JSON.stringify({ slug, found: !!special, name, placeName, imageUrl, fields: special ? Object.keys(special) : [] }, null, 2),
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
    imageSubtitle: placeName || 'TRODDR Special',
  });
}
