// api/og/itinerary-image.js
//
// Generated portrait image used as the og:image for a shared itinerary.
// It mirrors the in-app trip card without an extra square stage around it.
//
//   /api/og/itinerary-image?id={id}&token={shareToken}
//
// Token-gated via the shared-only RPC; renders a generic branded card if the
// token doesn't resolve (never leaks a private trip).

import { ImageResponse } from '@vercel/og';
import { fetchSharedItinerary, firstImage } from './_lib/og.js';

export const config = { runtime: 'edge' };

export const CANVAS_W = 1080;
export const CANVAS_H = 1500;
export const CARD_W = CANVAS_W;
export const CARD_H = CANVAS_H;
const PHOTO_H = 1380;
const FOOTER_H = CARD_H - PHOTO_H;
const BLUE = '#0077cc';
const CARD_FONT = 'Inter';
const INTER_CSS_URL = 'https://fonts.googleapis.com/css2?family=Inter:wght@700;800;900&display=swap';
let interFontsPromise;

// Short date for the card face: "Jul 18–19" / "Jul 18 – Aug 2" / "Jul 18".
function shortRange(start, end) {
  const toD = (s) => (s ? new Date(`${String(s).slice(0, 10)}T12:00:00`) : null);
  const s = toD(start);
  const e = toD(end);
  if (!s || isNaN(s.getTime())) return '';
  const md = (d) => d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' });
  if (!e || isNaN(e.getTime()) || s.toDateString() === e.toDateString()) return md(s);
  if (s.getMonth() === e.getMonth() && s.getFullYear() === e.getFullYear()) return `${md(s)}–${e.getDate()}`;
  return `${md(s)} – ${md(e)}`;
}

// Pull the first usable image from a place OR an event (different field names).
function stopImage(item) {
  return firstImage(item?.image, item?.image_urls, item?.featured_image_url, item?.cover_image, item?.images);
}

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
    { width: 34, height: 34, viewBox: '0 0 24 24', fill: 'none' },
    h('rect', { x: 3, y: 4.5, width: 18, height: 16.5, rx: 2.5, stroke: '#fff', strokeWidth: 2 }),
    h('path', { d: 'M3 9.5 H21', stroke: '#fff', strokeWidth: 2 }),
    h('path', { d: 'M8 2.5 V6.5', stroke: '#fff', strokeWidth: 2, strokeLinecap: 'round' }),
    h('path', { d: 'M16 2.5 V6.5', stroke: '#fff', strokeWidth: 2, strokeLinecap: 'round' })
  );

const pinIcon = () =>
  h(
    'svg',
    { width: 34, height: 34, viewBox: '0 0 24 24', fill: 'none' },
    h('path', {
      d: 'M12 22s7-6.5 7-12a7 7 0 1 0-14 0c0 5.5 7 12 7 12z',
      stroke: '#fff',
      strokeWidth: 2,
      strokeLinejoin: 'round',
    }),
    h('circle', { cx: 12, cy: 10, r: 2.6, stroke: '#fff', strokeWidth: 2 })
  );

const itineraryIcon = () =>
  h(
    'svg',
    { width: 34, height: 34, viewBox: '0 0 24 24', fill: 'none' },
    h('rect', { x: 4, y: 5, width: 4, height: 14, rx: 1, fill: '#fff' }),
    h('rect', { x: 10, y: 3, width: 4, height: 18, rx: 1, fill: '#fff' }),
    h('rect', { x: 16, y: 5, width: 4, height: 14, rx: 1, fill: '#fff' })
  );

async function loadInterFonts() {
  if (!interFontsPromise) {
    interFontsPromise = (async () => {
      try {
        const cssRes = await fetch(INTER_CSS_URL, {
          headers: { 'User-Agent': 'Mozilla/5.0' },
        });
        if (!cssRes.ok) return [];
        const css = await cssRes.text();
        const fonts = [];
        const blocks = css.match(/@font-face\s*{[^}]+}/g) || [];
        for (const weight of [700, 800, 900]) {
          const block = blocks.find((b) => b.includes(`font-weight: ${weight}`) && b.includes('U+0000-00FF')) ||
            blocks.find((b) => b.includes(`font-weight: ${weight}`));
          const url = block?.match(/url\((https:\/\/[^)]+)\)/)?.[1];
          if (!url) continue;
          const fontRes = await fetch(url);
          if (!fontRes.ok) continue;
          fonts.push({
            name: CARD_FONT,
            data: await fontRes.arrayBuffer(),
            weight,
            style: 'normal',
          });
        }
        return fonts;
      } catch {
        return [];
      }
    })();
  }
  return interFontsPromise;
}

function buildCard({ destination, dateRange, stopsLabel, names, hero, thumbs }) {
  return h(
    'div',
    {
      style: {
        width: `${CANVAS_W}px`,
        height: `${CANVAS_H}px`,
        display: 'flex',
        alignItems: 'flex-start',
        justifyContent: 'flex-start',
        fontFamily: 'sans-serif',
        backgroundColor: '#0a0a0a',
      },
    },
    h(
      'div',
      {
        style: {
          display: 'flex',
          flexDirection: 'column',
          width: `${CARD_W}px`,
          height: `${CARD_H}px`,
          overflow: 'hidden',
          backgroundColor: '#0a0a0a',
        },
      },
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
        h('div', {
          style: {
            display: 'flex',
            position: 'absolute',
            top: 0,
            left: 0,
            width: `${CARD_W}px`,
            height: `${PHOTO_H}px`,
            backgroundImage: 'linear-gradient(to bottom, rgba(0,0,0,0.45) 0%, rgba(0,0,0,0.02) 34%, rgba(0,0,0,0.15) 52%, rgba(0,0,0,0.82) 100%)',
          },
        }),
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
              padding: '56px',
              fontFamily: CARD_FONT,
            },
          },
          h(
            'div',
            { style: { display: 'flex', alignItems: 'flex-start', justifyContent: 'space-between' } },
            h('div', { style: { display: 'flex', color: '#fff', fontSize: '12px', fontWeight: 800, marginLeft: '112px', marginTop: '30px' } }, 'TRODDR'),
            h(
              'div',
              { style: { display: 'flex', alignItems: 'center' } },
              itineraryIcon(),
              h('div', { style: { display: 'flex', color: '#fff', fontSize: '40px', fontWeight: 800, marginLeft: '14px' } }, 'Trip itinerary')
            )
          ),
          h(
            'div',
            { style: { display: 'flex', flexDirection: 'column' } },
            h('div', { style: { display: 'flex', color: '#fff', fontSize: '100px', fontWeight: 900, lineHeight: 1 } }, destination),
            h(
              'div',
              { style: { display: 'flex', alignItems: 'center', marginTop: '28px' } },
              ...(dateRange
                ? [calendarIcon(), h('div', { style: { display: 'flex', color: '#fff', fontSize: '42px', fontWeight: 800, marginLeft: '12px', marginRight: '50px' } }, dateRange)]
                : []),
              pinIcon(),
              h('div', { style: { display: 'flex', color: '#fff', fontSize: '42px', fontWeight: 800, marginLeft: '12px' } }, stopsLabel)
            ),
            names
              ? h('div', {
                  style: {
                    display: 'block',
                    color: 'rgba(255,255,255,0.95)',
                    fontSize: '40px',
                    fontWeight: 700,
                    marginTop: '32px',
                    maxWidth: '968px',
                    whiteSpace: 'nowrap',
                    overflow: 'hidden',
                    textOverflow: 'ellipsis',
                  },
                }, names)
              : null,
            thumbs.length > 0
              ? h(
                  'div',
                  { style: { display: 'flex', marginTop: '42px' } },
                  ...thumbs.map((u) =>
                    h('img', {
                      src: safeImg(u),
                      width: 188,
                      height: 188,
                      style: { width: '188px', height: '188px', borderRadius: '20px', border: '2px solid rgba(255,255,255,0.45)', objectFit: 'cover', marginRight: '28px' },
                    })
                  )
                )
              : null
          )
        )
      ),
      h(
        'div',
        { style: { display: 'flex', width: `${CARD_W}px`, height: `${FOOTER_H}px`, backgroundColor: BLUE, alignItems: 'center', justifyContent: 'center' } },
        h('div', { style: { display: 'flex', color: '#fff', fontSize: '40px', fontWeight: 500 } }, 'View this trip on troddr')
      )
    )
  );
}

function fieldsFrom(payload) {
  const trip = payload?.itinerary || payload || {};
  // Stops = places + events (events come from itinerary_events; the RPC must
  // return them under `events`/`items` for them to appear here).
  const stopsList = [
    ...(payload?.places || []),
    ...(payload?.events || payload?.items || []),
  ];
  const destination = trip.destination || 'My Trip';
  const stops = stopsList.length;
  const imgs = stopsList.map(stopImage).filter(Boolean);
  return {
    destination,
    dateRange: shortRange(trip.start_date, trip.end_date),
    stopsLabel: stops ? `${stops} ${stops === 1 ? 'stop' : 'stops'}` : '',
    names: stopsList.map((p) => p?.name || p?.title).filter(Boolean).join('   ·   '),
    hero: imgs[0],
    thumbs: imgs.slice(1, 5),
  };
}

export default async function handler(request) {
  const url = new URL(request.url);
  const token = url.searchParams.get('token') || '';
  const [payload, fonts] = await Promise.all([
    fetchSharedItinerary(token),
    loadInterFonts(),
  ]);

  const fields = payload
    ? fieldsFrom(payload)
    : { destination: 'My Itinerary', dateRange: '', stopsLabel: 'Plan your trip on TRODDR', names: '', hero: undefined, thumbs: [] };

  const responseOptions = {
    width: CANVAS_W,
    height: CANVAS_H,
    headers: { 'Cache-Control': 'public, s-maxage=3600, stale-while-revalidate=86400' },
  };
  if (fonts.length) responseOptions.fonts = fonts;

  return new ImageResponse(buildCard(fields), responseOptions);
}

export { buildCard, fieldsFrom, loadInterFonts };
