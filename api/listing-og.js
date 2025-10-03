// api/listing-og.js
import { createClient } from '@supabase/supabase-js';

const supabase = createClient(
  process.env.SUPABASE_URL,
  process.env.SUPABASE_ANON_KEY
);

export default async function handler(req, res) {
  const { slug } = req.query;

  // Fetch place from Supabase
  const { data: place } = await supabase
    .from('places')
    .select('*')
    .eq('slug', slug)
    .maybeSingle();

  if (!place) {
    res.status(404).send('Not found');
    return;
  }

  const title = `${place.name} — TRODDR`;
  const desc = place.description || `Discover ${place.name} on TRODDR.`;
  let img = '/images/og-default.jpg';
  if (place.image) {
    try {
      const parsed = typeof place.image === 'string' ? JSON.parse(place.image) : place.image;
      if (Array.isArray(parsed) && parsed.length > 0) {
        img = parsed[0];
      }
    } catch {
      if (Array.isArray(place.image) && place.image.length > 0) {
        img = place.image[0];
      }
    }
  }
  const url = `https://troddr.com/listings/${slug}`;

  res.setHeader('Content-Type', 'text/html');
  res.send(`
    <!doctype html>
    <html lang="en">
    <head>
      <title>${title}</title>
      <meta property="og:title" content="${title}" />
      <meta property="og:description" content="${desc}" />
      <meta property="og:type" content="website" />
      <meta property="og:url" content="${url}" />
      <meta property="og:image" content="${img}" />
      <meta name="twitter:card" content="summary_large_image" />
      <meta name="twitter:title" content="${title}" />
      <meta name="twitter:description" content="${desc}" />
      <meta name="twitter:image" content="${img}" />
      <link rel="canonical" href="${url}" />
    </head>
    <body>
      <script>
        // Redirect real users to your static listings.html
        window.location.href = "/listings.html?slug=${slug}";
      </script>
    </body>
    </html>
  `);
}