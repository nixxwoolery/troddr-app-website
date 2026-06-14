// api/og-image.js
//
// Server-rendered 1200×630 branded fallback card, used as og:image whenever a
// shared entity has no photo of its own. Solid TRODDR blue (#0077cc), white
// "troddr" wordmark, dynamic title + subtitle, "troddr.com" footer — mirrors
// the in-app share cards.
//
//   /api/og-image?title=...&subtitle=...
//
// Rendered with @vercel/og (Satori). We build the element tree with a tiny
// hyperscript helper so this stays a no-build, no-JSX static site.

import { ImageResponse } from '@vercel/og';

export const config = { runtime: 'edge' };

const BLUE = '#0077cc';
const BAND = '#1a8fe0';

// Minimal React.createElement stand-in: returns a plain element-like object
// that Satori understands ({ type, props: { ...props, children } }).
const h = (type, props, ...children) => ({
  type,
  key: null,
  props: { ...(props || {}), children: children.length <= 1 ? children[0] : children },
});

export default function handler(request) {
  const { searchParams } = new URL(request.url);
  const title = (searchParams.get('title') || 'TRODDR').slice(0, 120);
  const subtitle = (searchParams.get('subtitle') || '').slice(0, 120);

  const card = h(
    'div',
    {
      style: {
        width: '1200px',
        height: '630px',
        display: 'flex',
        flexDirection: 'column',
        justifyContent: 'space-between',
        alignItems: 'center',
        padding: '72px',
        backgroundColor: BLUE,
        color: '#ffffff',
        fontFamily: 'sans-serif',
      },
    },
    // Wordmark
    h(
      'div',
      {
        style: {
          display: 'flex',
          fontSize: '46px',
          fontWeight: 800,
          letterSpacing: '-1px',
        },
      },
      'troddr'
    ),
    // Title + subtitle
    h(
      'div',
      {
        style: {
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          flexGrow: 1,
          textAlign: 'center',
        },
      },
      h(
        'div',
        {
          style: {
            display: 'flex',
            fontSize: '64px',
            fontWeight: 800,
            lineHeight: 1.1,
            textAlign: 'center',
          },
        },
        title
      ),
      subtitle
        ? h(
            'div',
            {
              style: {
                display: 'flex',
                marginTop: '32px',
                padding: '16px 32px',
                backgroundColor: BAND,
                borderRadius: '18px',
                fontSize: '32px',
                fontWeight: 500,
              },
            },
            subtitle
          )
        : null
    ),
    // Footer
    h(
      'div',
      {
        style: {
          display: 'flex',
          fontSize: '30px',
          fontWeight: 600,
          opacity: 0.95,
        },
      },
      'troddr.com'
    )
  );

  return new ImageResponse(card, {
    width: 1200,
    height: 630,
    headers: {
      'Cache-Control': 'public, immutable, no-transform, s-maxage=86400, max-age=86400',
    },
  });
}
