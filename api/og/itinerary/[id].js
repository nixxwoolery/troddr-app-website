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
  
  async function fetchItinerary(id) {
    try {
      // Fetch by ID or share_id
      let res = await fetch(
        `${SUPABASE_URL}/rest/v1/itineraries?id=eq.${encodeURIComponent(id)}&select=*`,
        {
          headers: {
            'apikey': SUPABASE_ANON_KEY,
            'Authorization': `Bearer ${SUPABASE_ANON_KEY}`,
          },
        }
      );
      let data = await res.json();
      if (data && data.length > 0) return data[0];
  
      // Try share_id
      res = await fetch(
        `${SUPABASE_URL}/rest/v1/itineraries?share_id=eq.${encodeURIComponent(id)}&select=*`,
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
    
    const pathParts = url.pathname.split('/');
    const id = pathParts[pathParts.length - 1] || '';
    const decodedId = decodeURIComponent(id);
    
    // Also check for tripId in query params
    const tripId = url.searchParams.get('tripId') || decodedId;
    
    const debugMode = url.searchParams.get('debug') === '1';
    
    // Regular users → serve itinerary.html
    if (!isBot(userAgent) && !debugMode) {
      try {
        const queryParams = new URLSearchParams();
        if (tripId) queryParams.set('tripId', tripId);
        const destination = url.searchParams.get('destination');
        if (destination) queryParams.set('destination', destination);
        
        const htmlResponse = await fetch(`${url.origin}/itinerary.html?${queryParams.toString()}`);
        const html = await htmlResponse.text();
        return new Response(html, {
          status: 200,
          headers: { 'Content-Type': 'text/html; charset=utf-8' },
        });
      } catch (e) {
        return Response.redirect(`${url.origin}/itinerary.html?tripId=${encodeURIComponent(tripId)}`, 302);
      }
    }
    
    // Bots → return OG meta tags
    const itinerary = tripId ? await fetchItinerary(tripId) : null;
    
    if (debugMode) {
      return new Response(JSON.stringify({
        id: tripId,
        found: !!itinerary,
        title: itinerary?.title,
        name: itinerary?.name,
        trip_name: itinerary?.trip_name,
        destination: itinerary?.destination,
        imageField: itinerary?.cover_image || itinerary?.image,
        extractedImage: getImageUrl(itinerary),
        allFields: itinerary ? Object.keys(itinerary) : [],
        rawData: itinerary,
      }, null, 2), {
        headers: { 'Content-Type': 'application/json' },
      });
    }
    
    const baseUrl = 'https://troddr.com';
    // Try multiple possible title field names
    const title = itinerary?.title || itinerary?.name || itinerary?.trip_name || itinerary?.itinerary_name || 'My Jamaica Trip';
    const destination = itinerary?.destination || itinerary?.location || 'Jamaica';
    const placeCount = itinerary?.place_count || itinerary?.places_count || (Array.isArray(itinerary?.slugs) ? itinerary.slugs.length : '') || '';
    
    const ogTitle = `${title} | TRODDR Itinerary`;
    let description = itinerary?.description;
    if (!description) {
      description = `Check out this ${destination} itinerary on TRODDR!`;
      if (placeCount) {
        description = `Explore ${placeCount} amazing places in ${destination} with this TRODDR itinerary!`;
      }
    }
    
    const image = getImageUrl(itinerary) || `${baseUrl}/images/og-default.jpg`;
    const canonical = tripId 
      ? `${baseUrl}/itinerary?tripId=${encodeURIComponent(tripId)}`
      : `${baseUrl}/itinerary`;
    
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