// api/og/_lib/og.js
//
// Shared helpers for the Open Graph (link-unfurl) functions. Every entity
// handler (listings, events, specials, guides, itineraries) imports from here
// so the unfurl card is identical across types: same meta block, same branded
// fallback image, same crawler-friendly redirect.
//
// This directory is prefixed with `_`, so Vercel does NOT turn it into a route
// — it is only ever pulled in via `import`.

export const BASE_URL = 'https://www.troddr.com';

export const SUPABASE_URL =
  process.env.SUPABASE_URL || 'https://rprpwudhplodaqmmwqkf.supabase.co';
export const SUPABASE_ANON_KEY =
  process.env.SUPABASE_ANON_KEY ||
  'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJwcnB3dWRocGxvZGFxbW13cWtmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTAyODcyODksImV4cCI6MjA2NTg2MzI4OX0.lNL6YZQqZgbsQRJyRAXpaWMC4LxncvPPyXNP1qopTFk';

// User agents that read OG/Twitter tags. Bots get the meta page; humans get
// proxied the real .html (or are redirected upstream by vercel.json).
const BOT_PATTERNS = [
  /facebookexternalhit/i, /Facebot/i, /Twitterbot/i, /WhatsApp/i,
  /LinkedInBot/i, /Slackbot/i, /TelegramBot/i, /Discordbot/i,
  /Pinterest/i, /Applebot/i, /iMessage/i, /Googlebot/i, /bingbot/i,
  /redditbot/i, /vkShare/i, /SkypeUriPreview/i,
];

export function isBot(userAgent) {
  if (!userAgent) return false;
  return BOT_PATTERNS.some((pattern) => pattern.test(userAgent));
}

// ── Supabase REST/RPC ────────────────────────────────────────────────────────

const SB_HEADERS = {
  apikey: SUPABASE_ANON_KEY,
  Authorization: `Bearer ${SUPABASE_ANON_KEY}`,
};

// GET /rest/v1/<path> → parsed JSON array (or [] on any failure).
export async function sbSelect(path) {
  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/${path}`, { headers: SB_HEADERS });
    const data = await res.json();
    return Array.isArray(data) ? data : [];
  } catch (e) {
    console.error('sbSelect error:', e);
    return [];
  }
}

// POST /rest/v1/rpc/<fn> → parsed JSON (or null on any failure/error payload).
export async function sbRpc(fn, body) {
  try {
    const res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: { ...SB_HEADERS, 'Content-Type': 'application/json' },
      body: JSON.stringify(body),
    });
    const data = await res.json();
    if (data && data.error) return null;
    return data ?? null;
  } catch (e) {
    console.error('sbRpc error:', e);
    return null;
  }
}

// ── Value coercion ───────────────────────────────────────────────────────────

export function escapeHtml(str) {
  if (str === null || str === undefined) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

// Ensure a fully-qualified https URL. Crawlers reject relative og:image values.
export function makeAbsolute(url) {
  if (!url || typeof url !== 'string') return null;
  const trimmed = url.trim();
  if (!trimmed) return null;
  if (/^https?:\/\//i.test(trimmed)) return trimmed;
  return `${BASE_URL}${trimmed.startsWith('/') ? '' : '/'}${trimmed}`;
}

// Coerce an image field that may be a string, a JSON-encoded array, or a real
// array into the first valid absolute URL. Returns null when nothing usable.
export function firstImage(...fields) {
  for (const field of fields) {
    if (!field) continue;

    if (Array.isArray(field)) {
      const hit = field.find((v) => typeof v === 'string' && v.trim());
      const abs = makeAbsolute(hit);
      if (abs) return abs;
      continue;
    }

    if (typeof field === 'string') {
      const s = field.trim();
      if (!s) continue;
      // Might be a JSON-encoded array: '["https://…", …]'
      if (s.startsWith('[')) {
        try {
          const parsed = JSON.parse(s);
          if (Array.isArray(parsed)) {
            const hit = parsed.find((v) => typeof v === 'string' && v.trim());
            const abs = makeAbsolute(hit);
            if (abs) return abs;
            continue;
          }
        } catch {
          /* fall through to treat as plain string */
        }
      }
      const abs = makeAbsolute(s);
      if (abs) return abs;
    }
  }
  return null;
}

// ── Branded fallback image ───────────────────────────────────────────────────

// URL to the server-rendered 1200×630 branded card (see api/og-image.js).
// Used as og:image whenever an entity has no photo of its own.
export function fallbackImageUrl({ title, subtitle } = {}) {
  const params = new URLSearchParams();
  if (title) params.set('title', String(title).slice(0, 120));
  if (subtitle) params.set('subtitle', String(subtitle).slice(0, 120));
  const qs = params.toString();
  return `${BASE_URL}/api/og-image${qs ? `?${qs}` : ''}`;
}

// ── Human passthrough ────────────────────────────────────────────────────────

// Proxy the real static page to humans so the URL bar stays put and there is
// no flash of an intermediate page. Falls back to a redirect if the fetch
// fails for any reason.
export async function serveHumanPage(origin, htmlPath) {
  try {
    const res = await fetch(`${origin}${htmlPath}`);
    const html = await res.text();
    return new Response(html, {
      status: 200,
      headers: { 'Content-Type': 'text/html; charset=utf-8' },
    });
  } catch {
    return Response.redirect(`${origin}${htmlPath}`, 302);
  }
}

// ── The shared OG page ───────────────────────────────────────────────────────

/**
 * Render the complete, consistent OG/Twitter meta page served to crawlers.
 *
 * @param {object}  opts
 * @param {string}  opts.title         Card title (already branded as you want it).
 * @param {string}  opts.description   Card subtitle / description line.
 * @param {?string} opts.imageUrl      Real entity photo (absolute https). When
 *                                     falsy, a branded fallback image is used.
 * @param {string}  opts.canonicalUrl  The public URL the share points at.
 * @param {string} [opts.type]         og:type (default "website").
 * @param {string} [opts.imageTitle]   Title baked into the fallback image.
 * @param {string} [opts.imageSubtitle]Subtitle baked into the fallback image.
 */
export function renderOgPage({
  title,
  description,
  imageUrl,
  canonicalUrl,
  type = 'website',
  imageTitle,
  imageSubtitle,
}) {
  const image =
    makeAbsolute(imageUrl) ||
    fallbackImageUrl({ title: imageTitle ?? title, subtitle: imageSubtitle ?? description });

  const t = escapeHtml(title);
  const d = escapeHtml(description);
  const img = escapeHtml(image);
  const canonical = escapeHtml(canonicalUrl);
  const ogType = escapeHtml(type);

  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${t}</title>
  <meta name="description" content="${d}" />

  <!-- Open Graph / Facebook / iMessage / WhatsApp -->
  <meta property="og:type" content="${ogType}" />
  <meta property="og:site_name" content="TRODDR" />
  <meta property="og:url" content="${canonical}" />
  <meta property="og:title" content="${t}" />
  <meta property="og:description" content="${d}" />
  <meta property="og:image" content="${img}" />
  <meta property="og:image:secure_url" content="${img}" />
  <meta property="og:image:width" content="1200" />
  <meta property="og:image:height" content="630" />
  <meta property="og:image:alt" content="${t}" />

  <!-- Twitter -->
  <meta name="twitter:card" content="summary_large_image" />
  <meta name="twitter:site" content="@troddr" />
  <meta name="twitter:url" content="${canonical}" />
  <meta name="twitter:title" content="${t}" />
  <meta name="twitter:description" content="${d}" />
  <meta name="twitter:image" content="${img}" />

  <link rel="canonical" href="${canonical}" />
  <link rel="icon" type="image/png" href="/images/troddr_logo.png" />

  <!-- Crawlers read the tags above; humans who land here bounce to the real page. -->
  <meta http-equiv="refresh" content="0; url=${canonical}" />
</head>
<body>
  <h1>${t}</h1>
  <p>${d}</p>
  <p><a href="${canonical}">View on TRODDR</a></p>
  <script>window.location.replace(${JSON.stringify(canonicalUrl)});</script>
</body>
</html>`;

  return new Response(html, {
    status: 200,
    headers: {
      'Content-Type': 'text/html; charset=utf-8',
      'Cache-Control': 'public, s-maxage=3600, stale-while-revalidate=86400',
    },
  });
}

// Extract the last non-empty path segment, decoded. Works for both the public
// URL and the rewritten /api/og/... target.
export function lastPathSegment(pathname) {
  const parts = pathname.split('/').filter(Boolean);
  const raw = parts[parts.length - 1] || '';
  try {
    return decodeURIComponent(raw);
  } catch {
    return raw;
  }
}

// UUID v1–v5 test, used to decide slug-vs-id lookups.
export function isUuid(s) {
  return (
    !!s &&
    /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(s)
  );
}
