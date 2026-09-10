// api/og/listing-image.js
//
// Server-rendered 1200×630 share card for a place listing, used as the og:image
// for /listings/{slug} shares. Mirrors the in-app share card: the place photo as
// a full-bleed background, a "troddr" wordmark chip, and a bottom panel with the
// name, a "town · parish · $$ · cuisine" meta line, a "Try the {dish}" pill, and
// a "Discover on troddr" footer. Falls back to a solid branded card when the
// place has no photo.
//
//   /api/og/listing-image?slug=devon-house-bakery
//   /api/og/listing-image?slug={uuid}          (map screen shares the id)
//
// Rendered with @vercel/og (Satori). Element tree built with a tiny hyperscript
// helper so this stays a no-build static site.

import { ImageResponse } from '@vercel/og';
import { SUPABASE_URL, SUPABASE_ANON_KEY, firstImage, isUuid } from './_lib/og.js';

export const config = { runtime: 'edge' };

const BLUE = '#0077cc';

const h = (type, props, ...children) => ({
  type,
  key: null,
  props: { ...(props || {}), children: children.length <= 1 ? children[0] : children },
});

// Pull just the fields the card needs (never the partner token).
async function fetchPlace(idOrSlug) {
  const column = isUuid(idOrSlug) ? 'id' : 'slug';
  const url =
    `${SUPABASE_URL}/rest/v1/places?${column}=eq.${encodeURIComponent(idOrSlug)}` +
    `&select=name,town,parish,price_range,cuisine,recommended_dishes,image&limit=1`;
  try {
    const res = await fetch(url, {
      headers: { apikey: SUPABASE_ANON_KEY, Authorization: `Bearer ${SUPABASE_ANON_KEY}` },
    });
    const rows = await res.json();
    return Array.isArray(rows) ? rows[0] || null : null;
  } catch {
    return null;
  }
}

// First recommended dish from a JSON-array string, a real array, or plain text.
function firstDish(field) {
  if (!field) return null;
  if (Array.isArray(field)) return (field.find((v) => typeof v === 'string' && v.trim()) || '').trim() || null;
  if (typeof field === 'string') {
    const s = field.trim();
    if (!s) return null;
    if (s.startsWith('[')) {
      try {
        const arr = JSON.parse(s);
        if (Array.isArray(arr)) return (arr.find((v) => typeof v === 'string' && v.trim()) || '').trim() || null;
      } catch {
        /* fall through */
      }
    }
    // Plain text: take the part before the first comma / newline.
    return s.split(/[,\n]/)[0].trim() || null;
  }
  return null;
}

export default async function handler(request) {
  const { searchParams } = new URL(request.url);
  const slug = (searchParams.get('slug') || '').slice(0, 200);
  const place = slug ? await fetchPlace(slug) : null;

  const name = (place?.name || slug.replace(/-/g, ' ').replace(/\b\w/g, (s) => s.toUpperCase()) || 'TRODDR').slice(0, 80);
  const meta = [place?.town, place?.parish, place?.price_range, place?.cuisine]
    .map((v) => (v == null ? '' : String(v).trim()))
    .filter(Boolean)
    .join('  ·  ')
    .slice(0, 110);
  const dish = firstDish(place?.recommended_dishes);
  const photo = firstImage(place?.image);

  // Wordmark chip (top-left).
  const wordmark = h(
    'div',
    {
      style: {
        display: 'flex',
        position: 'absolute',
        top: '44px',
        left: '48px',
        padding: '12px 24px',
        backgroundColor: 'rgba(17,17,17,0.55)',
        borderRadius: '999px',
        fontSize: '34px',
        fontWeight: 800,
        letterSpacing: '-1px',
        color: '#ffffff',
      },
    },
    'troddr'
  );

  // Bottom info panel.
  const panelChildren = [
    h('div', { style: { display: 'flex', fontSize: '66px', fontWeight: 800, lineHeight: 1.05, color: '#ffffff' } }, name),
  ];
  if (meta) {
    panelChildren.push(
      h('div', { style: { display: 'flex', marginTop: '16px', fontSize: '30px', fontWeight: 500, color: 'rgba(255,255,255,0.92)' } }, meta)
    );
  }
  if (dish) {
    panelChildren.push(
      h(
        'div',
        {
          style: {
            display: 'flex',
            alignSelf: 'flex-start',
            marginTop: '26px',
            padding: '12px 24px',
            backgroundColor: 'rgba(255,255,255,0.95)',
            borderRadius: '14px',
            fontSize: '28px',
            fontWeight: 700,
            color: BLUE,
          },
        },
        `Try the ${dish}`.slice(0, 60)
      )
    );
  }
  panelChildren.push(
    h('div', { style: { display: 'flex', marginTop: '30px', fontSize: '26px', fontWeight: 600, color: 'rgba(255,255,255,0.85)' } }, 'Discover on troddr')
  );

  const panel = h(
    'div',
    {
      style: {
        display: 'flex',
        flexDirection: 'column',
        position: 'absolute',
        left: '0px',
        right: '0px',
        bottom: '0px',
        padding: '56px 64px',
      },
    },
    ...panelChildren
  );

  const layers = [];
  if (photo) {
    // Full-bleed photo background.
    layers.push(
      h('img', {
        src: photo,
        width: 1200,
        height: 630,
        style: { position: 'absolute', top: '0px', left: '0px', width: '1200px', height: '630px', objectFit: 'cover' },
      })
    );
  }
  // Gradient scrim so text stays legible over any photo (and looks intentional
  // on the solid-blue fallback too).
  layers.push(
    h('div', {
      style: {
        display: 'flex',
        position: 'absolute',
        top: '0px',
        left: '0px',
        width: '1200px',
        height: '630px',
        backgroundImage: 'linear-gradient(to bottom, rgba(0,0,0,0.10) 0%, rgba(0,0,0,0.15) 45%, rgba(0,0,0,0.82) 100%)',
      },
    })
  );
  layers.push(wordmark, panel);

  const card = h(
    'div',
    {
      style: {
        position: 'relative',
        display: 'flex',
        width: '1200px',
        height: '630px',
        backgroundColor: BLUE,
        fontFamily: 'sans-serif',
      },
    },
    ...layers
  );

  return new ImageResponse(card, {
    width: 1200,
    height: 630,
    headers: {
      'Cache-Control': 'public, immutable, no-transform, s-maxage=86400, max-age=86400',
    },
  });
}
