// api/og/[slug].js

export const config = {
  runtime: 'edge',
};

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://rprpwudhplodaqmmwqkf.supabase.co';
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJwcnB3dWRocGxvZGFxbW13cWtmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTAyODcyODksImV4cCI6MjA2NTg2MzI4OX0.lNL6YZQqZgbsQRJyRAXpaWMC4LxncvPPyXNP1qopTFk';

const BOT_PATTERNS = [
  /facebookexternalhit/i,
  /Facebot/i,
  /Twitterbot/i,
  /WhatsApp/i,
  /LinkedInBot/i,
  /Slackbot/i,
  /TelegramBot/i,
  /Discordbot/i,
  /Pinterest/i,
  /Applebot/i,
  /iMessage/i,
  /Googlebot/i,
  /bingbot/i,
];

function isBot(userAgent) {
  if (!userAgent) return false;
  return BOT_PATTERNS.some(pattern => pattern.test(userAgent));
}

async function fetchPlace(slug) {
  try {
    // Try slug field first (this is what your original api/listing-og.js used)
    let res = await fetch(
      `${SUPABASE_URL}/rest/v1/places?slug=eq.${encodeURIComponent(slug)}&select=*`,
      {
        headers: {
          'apikey': SUPABASE_ANON_KEY,
          'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
        },
      }
    );
    let data = await res.json();
    if (data && data.length > 0) return data[0];

    // Fallback to specials_slug
    res = await fetch(
      `${SUPABASE_URL}/rest/v1/places?specials_slug=eq.${encodeURIComponent(slug)}&select=*`,
      {
        headers: {
          'apikey': SUPABASE_ANON_KEY,
          'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
        },
      }
    );
    data = await res.json();
    return data?.[0] || null;
  } catch (e) {
    console.error('Fetch error:', e);
    return null;
  }
}

// Match your original makeAbsolute function
function makeAbsolute(url) {
  if (!url) return null;
  if (url.startsWith('http')) return url;
  return `https://troddr.com${url.startsWith('/') ? '' : '/'}${url}`;
}

// Match your original image parsing logic from api/listing-og.js
function getImageUrl(place) {
  if (!place) return null;
  
  // Check the image field (this is what your original code used)
  if (place.image) {
    try {
      // Try parsing as JSON (handles '["url1", "url2"]' format)
      const parsed = typeof place.image === 'string' ? JSON.parse(place.image) : place.image;
      if (Array.isArray(parsed) && parsed.length > 0) {
        return makeAbsolute(parsed[0]);
      }
    } catch {
      // If JSON parse fails, check if it's already an array
      if (Array.isArray(place.image) && place.image.length > 0) {
        return makeAbsolute(place.image[0]);
      }
      // Or a plain string URL
      if (typeof place.image === 'string' && place.image.trim()) {
        return makeAbsolute(place.image.trim());
      }
    }
  }
  
  return null;
}

function escapeHtml(str) {
  if (!str) return '';
  return String(str)
    .replace(/&/g, '&amp;')
    .replace(/"/g, '&quot;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;');
}

export default async function handler(request) {
  const url = new URL(request.url);
  const userAgent = request.headers.get('user-agent') || '';
  
  // Extract slug from /api/og/[slug]
  const pathParts = url.pathname.split('/');
  const slug = pathParts[pathParts.length - 1] || '';
  const decodedSlug = decodeURIComponent(slug);
  
  // Debug mode: add ?debug=1 to see raw data
  const debugMode = url.searchParams.get('debug') === '1';
  
  // ============================================
  // REGULAR USERS → Serve the actual listings.html
  // ============================================
  if (!isBot(userAgent) && !debugMode) {
    try {
      const htmlResponse = await fetch(`${url.origin}/listings.html?slug=${encodeURIComponent(decodedSlug)}`);
      const html = await htmlResponse.text();
      return new Response(html, {
        status: 200,
        headers: { 'Content-Type': 'text/html; charset=utf-8' },
      });
    } catch (e) {
      return Response.redirect(`${url.origin}/listings.html?slug=${encodeURIComponent(decodedSlug)}`, 302);
    }
  }
  
  // ============================================
  // BOTS (or debug mode) → Return HTML with OG tags
  // ============================================
  const place = await fetchPlace(decodedSlug);
  
  // Debug output - visit /listings/your-slug?debug=1 to see raw data
  if (debugMode) {
    return new Response(JSON.stringify({
      slug: decodedSlug,
      found: !!place,
      name: place?.name,
      town: place?.town,
      parish: place?.parish,
      imageField: place?.image,
      imageFieldType: typeof place?.image,
      extractedImage: getImageUrl(place),
      allFields: place ? Object.keys(place) : [],
    }, null, 2), {
      headers: { 'Content-Type': 'application/json' },
    });
  }
  
  const baseUrl = 'https://troddr.com';
  const name = place?.name || decodedSlug.replace(/-/g, ' ').replace(/\b\w/g, s => s.toUpperCase());
  const location = [place?.town, place?.parish].filter(Boolean).join(', ');
  
  const title = `${name}${location ? ` in ${location}` : ''} — TRODDR`;
  const description = place?.description 
    ? place.description.substring(0, 200) 
    : `Check out ${name}${location ? ` in ${location}` : ''} on TRODDR!`;
  
  // Get image using the same logic as your original code
  const image = getImageUrl(place) || `${baseUrl}/images/og-default.jpg`;
  const canonical = `${baseUrl}/listings/${encodeURIComponent(decodedSlug)}`;
  
  console.log('OG Meta:', { slug: decodedSlug, name, image, found: !!place });
  
  const html = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>${escapeHtml(title)}</title>
  <meta name="description" content="${escapeHtml(description)}" />
  
  <!-- Open Graph / Facebook / iMessage / WhatsApp -->
  <meta property="og:type" content="website" />
  <meta property="og:url" content="${escapeHtml(canonical)}" />
  <meta property="og:title" content="${escapeHtml(title)}" />
  <meta property="og:description" content="${escapeHtml(description)}" />
  <meta property="og:image" content="${escapeHtml(image)}" />
  <meta property="og:image:width" content="1200" />
  <meta property="og:image:height" content="630" />
  <meta property="og:site_name" content="TRODDR" />
  
  <!-- Twitter -->
  <meta name="twitter:card" content="summary_large_image" />
  <meta name="twitter:url" content="${escapeHtml(canonical)}" />
  <meta name="twitter:title" content="${escapeHtml(title)}" />
  <meta name="twitter:description" content="${escapeHtml(description)}" />
  <meta name="twitter:image" content="${escapeHtml(image)}" />
  
  <link rel="canonical" href="${escapeHtml(canonical)}" />
  <link rel="icon" type="image/png" href="/images/troddr_logo.png" />
</head>
<body>
  <h1>${escapeHtml(name)}</h1>
  ${location ? `<p>${escapeHtml(location)}</p>` : ''}
  <p>${escapeHtml(description)}</p>
  <p><a href="${escapeHtml(canonical)}">View on TRODDR</a></p>
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