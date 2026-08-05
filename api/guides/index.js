import { BASE_URL, escapeHtml } from '../og/_lib/og.js';
import { cleanImage, fetchGuides, footer, nav, pageHead } from './_lib/page.js';

export const config = { runtime: 'edge' };

export default async function handler() {
  const guides = await fetchGuides();
  const title = 'Jamaica Travel Guides Curated by Locals | TRODDR';
  const description = 'Explore locally curated Jamaica guides for weekend trips, restaurants, date nights, wellness escapes and things to do across the island.';
  const cards = guides.map((guide) => {
    const image = cleanImage(guide.image_url);
    const summary = String(guide.description || '').replace(/\s+/g, ' ').slice(0, 150);
    return `<a class="card" href="/guides/${encodeURIComponent(guide.slug)}">${image ? `<img src="${escapeHtml(image)}" alt="" loading="lazy">` : '<span class="card-art"></span>'}<div class="card-body"><small>${escapeHtml(guide.location || guide.type || 'Jamaica')}</small><h2>${escapeHtml(guide.title)}</h2><p>${escapeHtml(summary)}${summary.length === 150 ? '…' : ''}</p></div></a>`;
  }).join('');
  const schema = { '@context': 'https://schema.org', '@type': 'CollectionPage', name: title, description, url: `${BASE_URL}/guides`, hasPart: guides.map((g) => ({ '@type': 'Article', headline: g.title, url: `${BASE_URL}/guides/${g.slug}` })) };
  const html = `${pageHead({ title, description, canonical: `${BASE_URL}/guides`, type: 'website', schema })}<body>${nav()}<main class="shell"><section class="hub-head"><span class="eyebrow">Curated by locals</span><h1>Jamaica, one good guide at a time.</h1><p>Weekend escapes, food trails and local favourites selected by people who know the island. Preview each collection here, then open the complete guide in TRODDR.</p></section><section class="cards">${cards || '<p>New guides are on the way.</p>'}</section></main>${footer()}`;
  return new Response(html, { headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'public, s-maxage=1800, stale-while-revalidate=86400' } });
}
