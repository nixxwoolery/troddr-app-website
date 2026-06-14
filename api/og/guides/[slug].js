// api/og/guides/[slug].js — Open Graph card for /guides/{slug}

import {
  BASE_URL, isBot, lastPathSegment, sbSelect,
  firstImage, renderOgPage, serveHumanPage,
} from '../_lib/og.js';

export const config = { runtime: 'edge' };

async function fetchGuide(slug) {
  const rows = await sbSelect(
    `guides?slug=eq.${encodeURIComponent(slug)}&select=*&limit=1`
  );
  return rows[0] || null;
}

export default async function handler(request) {
  const url = new URL(request.url);
  const slug = lastPathSegment(url.pathname);
  const debug = url.searchParams.get('debug') === '1';

  if (!isBot(request.headers.get('user-agent')) && !debug) {
    return serveHumanPage(url.origin, `/guides.html?slug=${encodeURIComponent(slug)}`);
  }

  const guide = await fetchGuide(slug);

  const name =
    guide?.title || slug.replace(/-/g, ' ').replace(/\b\w/g, (s) => s.toUpperCase());
  const location = guide?.location || guide?.destination || guide?.country || '';
  const title = `${name}${location ? ` — ${location}` : ''} — TRODDR Guide`;
  const description = guide?.description
    ? guide.description.slice(0, 200)
    : `Explore ${name} on TRODDR — your guide to the best of Jamaica.`;
  const imageUrl = firstImage(guide?.image_url, guide?.image, guide?.cover_image);
  const canonicalUrl = `${BASE_URL}/guides/${encodeURIComponent(guide?.slug || slug)}`;

  if (debug) {
    return new Response(
      JSON.stringify({ slug, found: !!guide, name, location, imageUrl, fields: guide ? Object.keys(guide) : [] }, null, 2),
      { headers: { 'Content-Type': 'application/json' } }
    );
  }

  return renderOgPage({
    title,
    description,
    imageUrl,
    canonicalUrl,
    type: 'article',
    imageTitle: name,
    imageSubtitle: location || 'TRODDR Guide',
  });
}
