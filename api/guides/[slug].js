import { BASE_URL, escapeHtml, lastPathSegment, sbSelect } from '../og/_lib/og.js';
import { cleanImage, footer, nav, pageHead } from './_lib/page.js';

export const config = { runtime: 'edge' };

export default async function handler(request) {
  const slug = lastPathSegment(new URL(request.url).pathname);
  const guides = await sbSelect(`guides?slug=eq.${encodeURIComponent(slug)}&select=slug,title,description,image_url,location,category,type,is_itinerary_guide,country,best_for,created_at&limit=1`);
  const guide = guides[0];
  if (!guide) return new Response('Guide not found', { status: 404, headers: { 'Content-Type': 'text/plain; charset=utf-8', 'X-Robots-Tag': 'noindex' } });

  const places = await sbSelect(`view_guide_details?guide_slug=eq.${encodeURIComponent(slug)}&select=name,town,parish,category,ordering&order=ordering.asc&limit=3`);
  const canonical = `${BASE_URL}/guides/${encodeURIComponent(guide.slug)}`;
  const title = `${guide.title}${guide.location ? ` — ${guide.location}` : ' — Jamaica'} | TRODDR Guide`;
  const description = String(guide.description || `Explore ${guide.title}, a locally curated Jamaica guide from TRODDR.`).replace(/\s+/g, ' ').slice(0, 220);
  const image = cleanImage(guide.image_url);
  const preview = places.map((place) => `<div class="preview"><strong>${escapeHtml(place.name)}</strong><span>${escapeHtml([place.town, place.parish].filter(Boolean).join(', ') || 'Jamaica')}</span></div>`).join('');
  const tags = [guide.location, guide.type, guide.best_for].filter(Boolean).flatMap((v) => String(v).split(',')).map((v) => `<span class="pill">${escapeHtml(v.trim())}</span>`).join('');
  const appPath = `/app?redirect=${encodeURIComponent(`/guides/${guide.slug}`)}`;
  const schema = { '@context': 'https://schema.org', '@type': 'Article', headline: guide.title, description, image: image || undefined, datePublished: guide.created_at, author: { '@type': 'Organization', name: 'TRODDR', url: BASE_URL }, publisher: { '@type': 'Organization', name: 'TRODDR', url: BASE_URL }, mainEntityOfPage: canonical, about: [guide.location, guide.category, 'Jamaica travel'].filter(Boolean) };
  const html = `${pageHead({ title, description, canonical, image, schema })}<body>${nav()}<main><section class="hero"><div class="shell"><a class="crumb" href="/guides">← All Jamaica guides</a><div class="hero-grid"><div><span class="eyebrow">${escapeHtml(guide.type || 'TRODDR guide')}</span><h1>${escapeHtml(guide.title)}</h1><p class="lede">${escapeHtml(guide.description || description)}</p><div class="meta">${tags}</div></div>${image ? `<img class="cover" src="${escapeHtml(image)}" alt="${escapeHtml(guide.title)}">` : '<div class="cover cover-fallback">t</div>'}</div></div></section><section class="content"><div class="shell content-grid"><article><h2>A small preview</h2><p>Here are a few places from this locally curated collection. The complete guide—including every stop, details and planning tools—is available in TRODDR.</p><div class="preview-list">${preview || '<div class="preview"><strong>Locally selected stops</strong><span>Open TRODDR to see the complete collection.</span></div>'}</div><div class="more">More recommendations are waiting in the app</div></article><aside class="cta"><span class="eyebrow">Complete guide</span><h2>Take this guide with you.</h2><p>Save every stop, view it on the map and add places directly to your plans.</p><a class="button" href="${appPath}">Open this guide in TRODDR</a><div class="store-row"><a href="https://apps.apple.com/us/app/troddr/id6751852075">Download for iPhone</a><a href="https://play.google.com/store/apps/details?id=com.troddr.app">Download for Android</a></div></aside></div></section></main>${footer()}`;
  return new Response(html, { headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'public, s-maxage=1800, stale-while-revalidate=86400' } });
}
