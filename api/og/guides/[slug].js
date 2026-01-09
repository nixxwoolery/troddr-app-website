export const config = {
    runtime: 'edge',
  };
  
  const SUPABASE_URL = process.env.SUPABASE_URL || 'https://rprpwudhplodaqmmwqkf.supabase.co';
  const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJwcnB3dWRocGxvZGFxbW13cWtmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTAyODcyODksImV4cCI6MjA2NTg2MzI4OX0.lNL6YZQqZgbsQRJyRAXpaWMC4LxncvPPyXNP1qopTFk';
  
  const BOT_PATTERNS = [
    /facebookexternalhit/i, /Facebot/i, /Twitterbot/i, /WhatsApp/i,
    /LinkedInBot/i, /Slackbot/i, /TelegramBot/i, /Discordbot/i,
    /Pinterest/i, /Applebot/i, /iMessage/i, /Googlebot/i, /bingbot/i,
  ];
  
  function isBot(userAgent) {
    if (!userAgent) return false;
    return BOT_PATTERNS.some(pattern => pattern.test(userAgent));
  }
  
  async function fetchGuide(slug) {
    try {
      const res = await fetch(
        `${SUPABASE_URL}/rest/v1/guides?slug=eq.${encodeURIComponent(slug)}&select=*`,
        {
          headers: {
            'apikey': SUPABASE_ANON_KEY,
            'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
          },
        }
      );
      const data = await res.json();
      return data?.[0] || null;
    } catch (e) {
      console.error('Fetch error:', e);
      return null;
    }
  }
  
  function makeAbsolute(url) {
    if (!url) return null;
    if (url.startsWith('http')) return url;
    return `https://troddr.com${url.startsWith('/') ? '' : '/'}${url}`;
  }
  
  function getImageUrl(guide) {
    if (!guide) return null;
    
    // Check common image field names
    const imageFields = [guide.image_url, guide.image, guide.cover_image, guide.thumbnail];
    
    for (const field of imageFields) {
      if (!field) continue;
      
      try {
        const parsed = typeof field === 'string' ? JSON.parse(field) : field;
        if (Array.isArray(parsed) && parsed.length > 0) {
          return makeAbsolute(parsed[0]);
        }
      } catch {
        if (Array.isArray(field) && field.length > 0) {
          return makeAbsolute(field[0]);
        }
        if (typeof field === 'string' && field.trim()) {
          return makeAbsolute(field.trim());
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
    
    const pathParts = url.pathname.split('/');
    const slug = pathParts[pathParts.length - 1] || '';
    const decodedSlug = decodeURIComponent(slug);
    
    const debugMode = url.searchParams.get('debug') === '1';
    
    // Regular users → serve guides.html
    if (!isBot(userAgent) && !debugMode) {
      try {
        const htmlResponse = await fetch(`${url.origin}/guides.html?slug=${encodeURIComponent(decodedSlug)}`);
        const html = await htmlResponse.text();
        return new Response(html, {
          status: 200,
          headers: { 'Content-Type': 'text/html; charset=utf-8' },
        });
      } catch (e) {
        return Response.redirect(`${url.origin}/guides.html?slug=${encodeURIComponent(decodedSlug)}`, 302);
      }
    }
    
    // Bots → return OG meta tags
    const guide = await fetchGuide(decodedSlug);
    
    if (debugMode) {
      return new Response(JSON.stringify({
        slug: decodedSlug,
        found: !!guide,
        title: guide?.title,
        description: guide?.description,
        imageField: guide?.image_url || guide?.image,
        extractedImage: getImageUrl(guide),
        allFields: guide ? Object.keys(guide) : [],
      }, null, 2), {
        headers: { 'Content-Type': 'application/json' },
      });
    }
    
    const baseUrl = 'https://troddr.com';
    const title = guide?.title || decodedSlug.replace(/-/g, ' ').replace(/\b\w/g, s => s.toUpperCase());
    const location = guide?.location || guide?.destination || '';
    
    const ogTitle = `${title}${location ? ` — ${location}` : ''} | TRODDR Guide`;
    const description = guide?.description 
      ? guide.description.substring(0, 200) 
      : `Explore ${title} on TRODDR — your guide to the best places in Jamaica!`;
    
    const image = getImageUrl(guide) || `${baseUrl}/images/og-default.jpg`;
    const canonical = `${baseUrl}/guides/${encodeURIComponent(decodedSlug)}`;
    
    const html = `<!DOCTYPE html>
  <html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>${escapeHtml(ogTitle)}</title>
    <meta name="description" content="${escapeHtml(description)}" />
    
    <meta property="og:type" content="website" />
    <meta property="og:url" content="${escapeHtml(canonical)}" />
    <meta property="og:title" content="${escapeHtml(ogTitle)}" />
    <meta property="og:description" content="${escapeHtml(description)}" />
    <meta property="og:image" content="${escapeHtml(image)}" />
    <meta property="og:image:width" content="1200" />
    <meta property="og:image:height" content="630" />
    <meta property="og:site_name" content="TRODDR" />
    
    <meta name="twitter:card" content="summary_large_image" />
    <meta name="twitter:url" content="${escapeHtml(canonical)}" />
    <meta name="twitter:title" content="${escapeHtml(ogTitle)}" />
    <meta name="twitter:description" content="${escapeHtml(description)}" />
    <meta name="twitter:image" content="${escapeHtml(image)}" />
    
    <link rel="canonical" href="${escapeHtml(canonical)}" />
    <link rel="icon" type="image/png" href="/images/troddr_logo.png" />
  </head>
  <body>
    <h1>${escapeHtml(title)}</h1>
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