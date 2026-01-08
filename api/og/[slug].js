// api/og/[slug].js - Place this file at: api/og/[slug].js

export const config = {
    runtime: 'edge',
  };
  
  const SUPABASE_URL = process.env.SUPABASE_URL || 'https://rprpwudhplodaqmmwqkf.supabase.co';
  const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJwcnB3dWRocGxvZGFxbW13cWtmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTAyODcyODksImV4cCI6MjA2NTg2MzI4OX0.lNL6YZQqZgbsQRJyRAXpaWMC4LxncvPPyXNP1qopTFk';
  
  // Bot user agents for link preview crawlers
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
      // Try specials_slug first (matches your listings.html code)
      let res = await fetch(
        `${SUPABASE_URL}/rest/v1/places?specials_slug=eq.${encodeURIComponent(slug)}&select=name,description,town,parish,image`,
        {
          headers: {
            'apikey': SUPABASE_ANON_KEY,
            'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
          },
        }
      );
      let data = await res.json();
      if (data && data.length > 0) return data[0];
  
      // Fallback to slug field
      res = await fetch(
        `${SUPABASE_URL}/rest/v1/places?slug=eq.${encodeURIComponent(slug)}&select=name,description,town,parish,image`,
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
  
  function getFirstImage(imageField) {
    if (!imageField) return null;
    if (Array.isArray(imageField)) return imageField[0] || null;
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
    
    // ============================================
    // REGULAR USERS → Serve the actual listings.html
    // ============================================
    if (!isBot(userAgent)) {
      try {
        const htmlResponse = await fetch(`${url.origin}/listings.html?slug=${encodeURIComponent(decodedSlug)}`);
        const html = await htmlResponse.text();
        return new Response(html, {
          status: 200,
          headers: {
            'Content-Type': 'text/html; charset=utf-8',
          },
        });
      } catch (e) {
        // Fallback: redirect if fetch fails
        return Response.redirect(`${url.origin}/listings.html?slug=${encodeURIComponent(decodedSlug)}`, 302);
      }
    }
    
    // ============================================
    // BOTS → Return HTML with proper OG meta tags
    // ============================================
    const place = await fetchPlace(decodedSlug);
    
    const baseUrl = url.origin;
    const name = place?.name || decodedSlug.replace(/-/g, ' ').replace(/\b\w/g, s => s.toUpperCase());
    const location = [place?.town, place?.parish].filter(Boolean).join(', ');
    
    const title = `${name}${location ? ` in ${location}` : ''} — TRODDR`;
    const description = place?.description 
      ? place.description.substring(0, 200) 
      : `Check out ${name}${location ? ` in ${location}` : ''} on TRODDR!`;
    
    let image = getFirstImage(place?.image);
    if (!image) {
      image = `${baseUrl}/images/og-default.jpg`;
    } else if (!image.startsWith('http')) {
      image = `${baseUrl}${image.startsWith('/') ? '' : '/'}${image}`;
    }
    
    const canonical = `${baseUrl}/listings/${encodeURIComponent(decodedSlug)}`;
    
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