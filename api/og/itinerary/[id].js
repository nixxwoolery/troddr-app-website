// api/og/itinerary/[id].js

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
  
  async function fetchItineraryByToken(token) {
    if (!token) return null;
    
    const tryRpc = async (t) => {
      try {
        const res = await fetch(
          `${SUPABASE_URL}/rest/v1/rpc/get_shared_itinerary`,
          {
            method: 'POST',
            headers: {
              'apikey': SUPABASE_ANON_KEY,
              'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
              'Content-Type': 'application/json',
            },
            body: JSON.stringify({ _token: t }),
          }
        );
        const data = await res.json();
        // RPC returns object with items array if successful, or error
        if (data && !data.error && (data.title || data.items)) return data;
        return null;
      } catch (e) {
        return null;
      }
    };
  
    // 1. Try token as-is
    let result = await tryRpc(token);
    if (result) return result;
  
    // 2. If token has dashes, try without them
    if (token.includes('-')) {
      const tokenNoDash = token.replace(/-/g, '');
      result = await tryRpc(tokenNoDash);
      if (result) return result;
    }
  
    // 3. If token is 32 hex chars (no dashes), try with UUID dashes
    if (/^[0-9a-fA-F]{32}$/.test(token)) {
      const tokenDashed = token.replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/, '$1-$2-$3-$4-$5');
      result = await tryRpc(tokenDashed);
      if (result) return result;
    }
  
    return null;
  }
  
  function makeAbsolute(url) {
    if (!url) return null;
    if (url.startsWith('http')) return url;
    return `https://troddr.com${url.startsWith('/') ? '' : '/'}${url}`;
  }
  
  function getImageUrl(itinerary) {
    if (!itinerary) return null;
    
    const imageFields = [itinerary.cover_image, itinerary.image, itinerary.image_url, itinerary.thumbnail];
    
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
    
    // Extract token from path: /itinerary/[token] or /api/og/itinerary/[token]
    const pathParts = url.pathname.split('/');
    const token = pathParts[pathParts.length - 1] || '';
    const decodedToken = decodeURIComponent(token);
    
    const debugMode = url.searchParams.get('debug') === '1';
    
    // Regular users → serve itinerary.html with the token
    if (!isBot(userAgent) && !debugMode) {
      try {
        const htmlResponse = await fetch(`${url.origin}/itinerary.html?tripId=${encodeURIComponent(decodedToken)}`);
        const html = await htmlResponse.text();
        return new Response(html, {
          status: 200,
          headers: { 'Content-Type': 'text/html; charset=utf-8' },
        });
      } catch (e) {
        return Response.redirect(`${url.origin}/itinerary.html?tripId=${encodeURIComponent(decodedToken)}`, 302);
      }
    }
    
    // Bots → use RPC to get itinerary data (same as itinerary.html)
    const itinerary = await fetchItineraryByToken(decodedToken);
    
    if (debugMode) {
      // Show what formats we would try
      const tokenFormats = [decodedToken];
      if (decodedToken.includes('-')) {
        tokenFormats.push(decodedToken.replace(/-/g, ''));
      }
      if (/^[0-9a-fA-F]{32}$/.test(decodedToken)) {
        tokenFormats.push(decodedToken.replace(/^(.{8})(.{4})(.{4})(.{4})(.{12})$/, '$1-$2-$3-$4-$5'));
      }
      
      return new Response(JSON.stringify({
        token: decodedToken,
        tokenFormatsTried: tokenFormats,
        found: !!itinerary,
        title: itinerary?.title,
        destination: itinerary?.destination,
        itemsCount: itinerary?.items?.length || 0,
        start_date: itinerary?.start_date,
        end_date: itinerary?.end_date,
        allFields: itinerary ? Object.keys(itinerary) : [],
      }, null, 2), {
        headers: { 'Content-Type': 'application/json' },
      });
    }
    
    const baseUrl = 'https://troddr.com';
    const title = itinerary?.title || 'My Jamaica Trip';
    const destination = itinerary?.destination || 'Jamaica';
    const itemsCount = itinerary?.items?.length || itinerary?.items_count || '';
    
    // Format date range like itinerary.html does
    const fmtDate = (iso) => {
      if (!iso) return '';
      try { return new Date(iso).toLocaleDateString(undefined, { month: 'short', day: 'numeric' }); } catch { return ''; }
    };
    const dateRange = (itinerary?.start_date && itinerary?.end_date) 
      ? `(${fmtDate(itinerary.start_date)}–${fmtDate(itinerary.end_date)})` 
      : '';
    
    const ogTitle = `${title} | TRODDR Itinerary`;
    
    // Build description like the share text in itinerary.html
    let description;
    if (itemsCount) {
      description = `I'm going to ${destination} ${dateRange} with ${itemsCount} stops! Check out my trip plans on TRODDR!`;
    } else {
      description = `Check out this ${destination} itinerary on TRODDR!`;
    }
    
    // Get image from first item if available
    const firstItemWithImage = itinerary?.items?.find(item => item?.image);
    const image = firstItemWithImage?.image || `${baseUrl}/images/og-default.jpg`;
    const canonical = `${baseUrl}/itinerary/${encodeURIComponent(decodedToken)}`;
    
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
    <p>${escapeHtml(destination)}</p>
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