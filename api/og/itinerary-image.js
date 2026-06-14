// api/og/itinerary-image.js
//
// Generated 1200×630 collage used as the og:image for a shared itinerary —
// mirrors the in-app trip card (hero photo, destination, dates, stops, stop
// names, thumbnails, "View this trip on troddr.com"). This is what makes the
// single tappable link-preview card look like the app's share card.
//
//   /api/og/itinerary-image?id={id}&token={shareToken}
//
// Token-gated via the shared-only RPC; renders a generic branded card if the
// token doesn't resolve (never leaks a private trip).

import { ImageResponse } from '@vercel/og';
import { fetchSharedItinerary, firstImage, formatTripDateRange } from './_lib/og.js';

export const config = { runtime: 'edge' };

const BLUE = '#0077cc';

const h = (type, props, ...children) => ({
  type,
  key: null,
  props: { ...(props || {}), children: children.length <= 1 ? children[0] : children },
});

// Some CDNs (e.g. Wix) serve AVIF, which Satori/resvg can't decode. Force a
// JPEG-friendly variant so the photo actually renders in the PNG.
function safeImg(url) {
  if (!url) return url;
  return url.replace(/enc_avif/g, 'enc_auto');
}

function buildCard({ destination, dateRange, stopsLabel, names, hero, thumbs }) {
  const metaText = [dateRange, stopsLabel].filter(Boolean).join('   ·   ');

  return h(
    'div',
    {
      style: {
        width: '1200px',
        height: '630px',
        display: 'flex',
        flexDirection: 'column',
        fontFamily: 'sans-serif',
      },
    },
    // Photo stack
    h(
      'div',
      { style: { display: 'flex', position: 'relative', width: '1200px', height: '566px' } },
      hero
        ? h('img', {
            src: safeImg(hero),
            width: 1200,
            height: 566,
            style: { position: 'absolute', top: 0, left: 0, width: '1200px', height: '566px', objectFit: 'cover' },
          })
        : h('div', { style: { display: 'flex', position: 'absolute', top: 0, left: 0, width: '1200px', height: '566px', backgroundColor: BLUE } }),
      // Legibility gradient
      h('div', {
        style: {
          display: 'flex',
          position: 'absolute',
          top: 0,
          left: 0,
          width: '1200px',
          height: '566px',
          backgroundImage: 'linear-gradient(to bottom, rgba(0,0,0,0.35) 0%, rgba(0,0,0,0) 35%, rgba(0,0,0,0.15) 60%, rgba(0,0,0,0.85) 100%)',
        },
      }),
      // Content
      h(
        'div',
        {
          style: {
            display: 'flex',
            flexDirection: 'column',
            justifyContent: 'space-between',
            position: 'absolute',
            top: 0,
            left: 0,
            width: '1200px',
            height: '566px',
            padding: '48px 56px',
          },
        },
        // Top bar
        h(
          'div',
          { style: { display: 'flex', alignItems: 'center', justifyContent: 'space-between' } },
          h('div', { style: { display: 'flex', color: '#fff', fontSize: '26px', fontWeight: 800, letterSpacing: '2px' } }, 'TRODDR'),
          h('div', {
            style: { display: 'flex', color: '#fff', fontSize: '22px', fontWeight: 700, backgroundColor: 'rgba(0,0,0,0.35)', borderRadius: '999px', padding: '8px 18px' },
          }, 'Trip itinerary')
        ),
        // Bottom block
        h(
          'div',
          { style: { display: 'flex', flexDirection: 'column' } },
          h('div', { style: { display: 'flex', color: '#fff', fontSize: '84px', fontWeight: 800, letterSpacing: '-1px', lineHeight: 1 } }, destination),
          metaText
            ? h('div', { style: { display: 'flex', color: '#fff', fontSize: '30px', fontWeight: 600, marginTop: '16px' } }, metaText)
            : null,
          names
            ? h('div', { style: { display: 'flex', color: 'rgba(255,255,255,0.9)', fontSize: '26px', marginTop: '12px' } }, names)
            : null,
          thumbs.length > 0
            ? h(
                'div',
                { style: { display: 'flex', marginTop: '20px' } },
                ...thumbs.map((u) =>
                  h('img', {
                    src: safeImg(u),
                    width: 84,
                    height: 84,
                    style: { width: '84px', height: '84px', borderRadius: '12px', objectFit: 'cover', marginRight: '12px' },
                  })
                )
              )
            : null
        )
      )
    ),
    // Footer bar
    h(
      'div',
      { style: { display: 'flex', width: '1200px', height: '64px', backgroundColor: BLUE, alignItems: 'center', justifyContent: 'center' } },
      h('div', { style: { display: 'flex', color: '#fff', fontSize: '28px', fontWeight: 600 } }, 'View this trip on '),
      h('div', { style: { display: 'flex', color: '#fff', fontSize: '28px', fontWeight: 800, marginLeft: '8px' } }, 'troddr.com')
    )
  );
}

function fieldsFrom(payload) {
  const trip = payload?.itinerary || payload || {};
  const places = payload?.places || payload?.items || [];
  const destination = trip.destination || 'My Trip';
  const stops = places.length;
  const imgs = places.map((p) => firstImage(p?.image)).filter(Boolean);
  return {
    destination,
    dateRange: formatTripDateRange(trip.start_date, trip.end_date),
    stopsLabel: stops ? `${stops} ${stops === 1 ? 'stop' : 'stops'}` : '',
    names: places.map((p) => p?.name).filter(Boolean).slice(0, 3).join('   ·   '),
    hero: imgs[0],
    thumbs: imgs.slice(1, 5),
  };
}

export default async function handler(request) {
  const url = new URL(request.url);
  const token = url.searchParams.get('token') || '';
  const payload = await fetchSharedItinerary(token);

  const fields = payload
    ? fieldsFrom(payload)
    : { destination: 'My Itinerary', dateRange: '', stopsLabel: '', names: 'Plan your trip on TRODDR', hero: undefined, thumbs: [] };

  return new ImageResponse(buildCard(fields), {
    width: 1200,
    height: 630,
    headers: { 'Cache-Control': 'public, s-maxage=3600, stale-while-revalidate=86400' },
  });
}

export { buildCard, fieldsFrom };
