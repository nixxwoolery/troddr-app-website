/**
 * Cloudflare Worker to inject dynamic OG meta tags for listing pages
 * Deploy this as a Worker and route /listings/* requests through it
 */

const SUPABASE_URL = 'https://rprpwudhplodaqmmwqkf.supabase.co';
const SUPABASE_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJwcnB3dWRocGxvZGFxbW13cWtmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTAyODcyODksImV4cCI6MjA2NTg2MzI4OX0.lNL6YZQqZgbsQRJyRAXpaWMC4LxncvPPyXNP1qopTFk';

// List of known bot user agents for link previews
const BOT_USER_AGENTS = [
  'facebookexternalhit',
  'Facebot',
  'Twitterbot',
  'WhatsApp',
  'LinkedInBot',
  'Slackbot',
  'TelegramBot',
  'Discordbot',
  'Pinterest',
  'Applebot',
  'iMessageLinkPreview',
  'Googlebot',
  'bingbot',
];

function isBot(userAgent) {
  if (!userAgent) return false;
  const ua = userAgent.toLowerCase();
  return BOT_USER_AGENTS.some(bot => ua.includes(bot.toLowerCase()));
}

async function fetchPlaceBySlug(slug) {
  try {
    // Try direct table lookup first
    const response = await fetch(
      `${SUPABASE_URL}/rest/v1/places?specials_slug=eq.${encodeURIComponent(slug)}&select=*`,
      {
        headers: {
          'apikey': SUPABASE_ANON_KEY,
          'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
        },
      }
    );
    
    const data = await response.json();
    if (data && data.length > 0) {
      return data[0];
    }
    
    // Try RPC fallback
    const rpcResponse = await fetch(
      `${SUPABASE_URL}/rest/v1/rpc/get_place_public`,
      {
        method: 'POST',
        headers: {
          'apikey': SUPABASE_ANON_KEY,
          'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
          'Content-Type': 'application/json',
        },
        body: JSON.stringify({ _slug: slug }),
      }
    );
    
    const rpcData = await rpcResponse.json();
    if (rpcData) return rpcData;
    
    return null;
  } catch (e) {
    console.error('Error fetching place:', e);
    return null;
  }
}

function getFirstImage(imageField) {
  if (!imageField) return null;
  
  if (Array.isArray(imageField)) {
    return imageField[0] || null;
  }
  
  if (typeof imageField === 'string') {
    const trimmed = imageField.trim();
    if (trimmed.startsWith('[')) {
      try {
        const parsed = JSON.parse(trimmed);
        if (Array.isArray(parsed)) return parsed[0] || null;
      } catch {}
    }
    return trimmed || null;
  }
  
  return null;
}

function escapeHtml(str) {
  if (!str) return '';
  return str
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function generateMetaTags(place, slug, baseUrl) {
  const name = place?.name || slug.replace(/-/g, ' ').replace(/\b\w/g, s => s.toUpperCase());
  const location = [place?.town, place?.parish].filter(Boolean).join(', ');
  
  const title = `${name}${location ? ` in ${location}` : ''} — TRODDR`;
  const description = place?.description || `Check out ${name}${location ? ` in ${location}` : ''} on TRODDR!`;
  const image = getFirstImage(place?.image) || `${baseUrl}/images/og-default.jpg`;
  const url = `${baseUrl}/listings/${encodeURIComponent(slug)}`;
  
  return `
  <title>${escapeHtml(title)}</title>
  <meta name="description" content="${escapeHtml(description)}" />
  
  <!-- Open Graph / Facebook -->
  <meta property="og:type" content="website" />
  <meta property="og:url" content="${escapeHtml(url)}" />
  <meta property="og:title" content="${escapeHtml(title)}" />
  <meta property="og:description" content="${escapeHtml(description)}" />
  <meta property="og:image" content="${escapeHtml(image)}" />
  <meta property="og:site_name" content="TRODDR" />
  
  <!-- Twitter -->
  <meta name="twitter:card" content="summary_large_image" />
  <meta name="twitter:url" content="${escapeHtml(url)}" />
  <meta name="twitter:title" content="${escapeHtml(title)}" />
  <meta name="twitter:description" content="${escapeHtml(description)}" />
  <meta name="twitter:image" content="${escapeHtml(image)}" />
  
  <!-- Canonical -->
  <link rel="canonical" href="${escapeHtml(url)}" />
`;
}

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    const userAgent = request.headers.get('user-agent') || '';
    
    // Check if this is a listing page request
    const listingMatch = url.pathname.match(/\/listings\/([^/?#]+)/i);
    
    if (!listingMatch) {
      // Not a listing page, pass through to origin
      return fetch(request);
    }
    
    const slug = decodeURIComponent(listingMatch[1]);
    
    // For bots, we ALWAYS inject meta tags
    // For regular users, we can optionally do the same or pass through
    const shouldInjectMeta = isBot(userAgent);
    
    // Fetch the original HTML
    const originResponse = await fetch(request);
    
    if (!originResponse.ok) {
      return originResponse;
    }
    
    // If not a bot, just return the original response
    if (!shouldInjectMeta) {
      return originResponse;
    }
    
    // Fetch place data
    const place = await fetchPlaceBySlug(slug);
    
    // Get the original HTML
    let html = await originResponse.text();
    
    // Generate meta tags
    const baseUrl = `${url.protocol}//${url.host}`;
    const metaTags = generateMetaTags(place, slug, baseUrl);
    
    // Replace the existing <title> tag and inject our meta tags
    // Remove the old title
    html = html.replace(/<title>.*?<\/title>/i, '');
    
    // Inject our meta tags right after <head>
    html = html.replace(/<head>/i, `<head>${metaTags}`);
    
    // Return modified HTML
    return new Response(html, {
      status: originResponse.status,
      headers: {
        ...Object.fromEntries(originResponse.headers),
        'Content-Type': 'text/html; charset=utf-8',
      },
    });
  },
};