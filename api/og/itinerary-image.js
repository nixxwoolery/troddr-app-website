// api/og/itinerary-image.js
//
// Generated PORTRAIT collage used as the og:image for a shared itinerary —
// mirrors the in-app trip card (hero photo, "Trip itinerary" pill, destination,
// dates, stops, stop names, thumbnails, "View this trip on troddr.com").
// Portrait orientation matches the in-app card and renders tall in iMessage.
//
//   /api/og/itinerary-image?id={id}&token={shareToken}
//
// Token-gated via the shared-only RPC; renders a generic branded card if the
// token doesn't resolve (never leaks a private trip).

import { ImageResponse } from '@vercel/og';
import { fetchSharedItinerary, firstImage, formatTripDateRange } from './_lib/og.js';

export const config = { runtime: 'edge' };

export const CARD_W = 1080;
export const CARD_H = 1542;
const PHOTO_H = 1392;
const FOOTER_H = CARD_H - PHOTO_H; // 150
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

const calendarIcon = () =>
  h(
    'svg',
    { width: 46, height: 46, viewBox: '0 0 24 24', fill: 'none' },
    h('rect', { x: 3, y: 4.5, width: 18, height: 16.5, rx: 2.5, stroke: '#fff', strokeWidth: 2 }),
    h('path', { d: 'M3 9.5 H21', stroke: '#fff', strokeWidth: 2 }),
    h('path', { d: 'M8 2.5 V6.5', stroke: '#fff', strokeWidth: 2, strokeLinecap: 'round' }),
    h('path', { d: 'M16 2.5 V6.5', stroke: '#fff', strokeWidth: 2, strokeLinecap: 'round' })
  );

const pinIcon = () =>
  h(
    'svg',
    { width: 46, height: 46, viewBox: '0 0 24 24', fill: 'none' },
    h('path', {
      d: 'M12 22s7-6.5 7-12a7 7 0 1 0-14 0c0 5.5 7 12 7 12z',
      stroke: '#fff',
      strokeWidth: 2,
      strokeLinejoin: 'round',
    }),
    h('circle', { cx: 12, cy: 10, r: 2.6, stroke: '#fff', strokeWidth: 2 })
  );

function buildCard({ destination, dateRange, stopsLabel, names, hero, thumbs }) {
  return h(
    'div',
    {
      style: {
        width: `${CARD_W}px`,
        height: `${CARD_H}px`,
        display: 'flex',
        flexDirection: 'column',
        fontFamily: 'sans-serif',
        backgroundColor: '#0a0a0a',
      },
    },
    // Photo stack
    h(
      'div',
      { style: { display: 'flex', position: 'relative', width: `${CARD_W}px`, height: `${PHOTO_H}px` } },
      hero
        ? h('img', {
            src: safeImg(hero),
            width: CARD_W,
            height: PHOTO_H,
            style: { position: 'absolute', top: 0, left: 0, width: `${CARD_W}px`, height: `${PHOTO_H}px`, objectFit: 'cover' },
          })
        : h('div', { style: { display: 'flex', position: 'absolute', top: 0, left: 0, width: `${CARD_W}px`, height: `${PHOTO_H}px`, backgroundColor: BLUE } }),
      // Legibility gradient
      h('div', {
        style: {
          display: 'flex',
          position: 'absolute',
          top: 0,
          left: 0,
          width: `${CARD_W}px`,
          height: `${PHOTO_H}px`,
          backgroundImage: 'linear-gradient(to bottom, rgba(0,0,0,0.45) 0%, rgba(0,0,0,0) 22%, rgba(0,0,0,0.12) 55%, rgba(0,0,0,0.82) 100%)',
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
            width: `${CARD_W}px`,
            height: `${PHOTO_H}px`,
            padding: '48px',
          },
        },
        // Top bar
        h(
          'div',
          { style: { display: 'flex', alignItems: 'center', justifyContent: 'space-between' } },
          h('div', { style: { display: 'flex', color: '#fff', fontSize: '45px', fontWeight: 800, letterSpacing: '4px' } }, 'TRODDR'),
          h(
            'div',
            { style: { display: 'flex', alignItems: 'center', backgroundColor: 'rgba(0,0,0,0.38)', borderRadius: '999px', padding: '16px 30px' } },
            h('div', { style: { display: 'flex', color: '#fff', fontSize: '38px', fontWeight: 700 } }, 'Trip itinerary')
          )
        ),
        // Bottom block
        h(
          'div',
          { style: { display: 'flex', flexDirection: 'column', paddingLeft: '12px', paddingBottom: '8px' } },
          h('div', { style: { display: 'flex', color: '#fff', fontSize: '132px', fontWeight: 800, letterSpacing: '-2px', lineHeight: 1 } }, destination),
          h(
            'div',
            { style: { display: 'flex', alignItems: 'center', marginTop: '28px' } },
            ...(dateRange
              ? [calendarIcon(), h('div', { style: { display: 'flex', color: '#fff', fontSize: '46px', fontWeight: 600, marginLeft: '14px', marginRight: '48px' } }, dateRange)]
              : []),
            pinIcon(),
            h('div', { style: { display: 'flex', color: '#fff', fontSize: '46px', fontWeight: 600, marginLeft: '14px' } }, stopsLabel)
          ),
          names
            ? h('div', { style: { display: 'flex', color: 'rgba(255,255,255,0.92)', fontSize: '42px', marginTop: '28px' } }, names)
            : null,
          thumbs.length > 0
            ? h(
                'div',
                { style: { display: 'flex', marginTop: '32px' } },
                ...thumbs.map((u) =>
                  h('img', {
                    src: safeImg(u),
                    width: 156,
                    height: 156,
                    style: { width: '156px', height: '156px', borderRadius: '28px', objectFit: 'cover', marginRight: '24px' },
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
      { style: { display: 'flex', width: `${CARD_W}px`, height: `${FOOTER_H}px`, backgroundColor: BLUE, alignItems: 'center', justifyContent: 'center' } },
      h('div', { style: { display: 'flex', color: '#fff', fontSize: '50px', fontWeight: 600 } }, 'View this trip on '),
      h('div', { style: { display: 'flex', color: '#fff', fontSize: '50px', fontWeight: 800, marginLeft: '12px' } }, 'troddr.com')
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
    : { destination: 'My Itinerary', dateRange: '', stopsLabel: 'Plan your trip on TRODDR', names: '', hero: undefined, thumbs: [] };

  return new ImageResponse(buildCard(fields), {
    width: CARD_W,
    height: CARD_H,
    headers: { 'Cache-Control': 'public, s-maxage=3600, stale-while-revalidate=86400' },
  });
}

export { buildCard, fieldsFrom };
