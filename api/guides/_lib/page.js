import { BASE_URL, escapeHtml, firstImage, sbSelect } from '../../og/_lib/og.js';

export const GUIDE_CSS = `
  :root{--ink:#102033;--muted:#5d6b79;--blue:#0878c9;--navy:#10283f;--aqua:#dff7f3;--line:#dbe4ea}
  *{box-sizing:border-box}html{scroll-behavior:smooth}body{margin:0;color:var(--ink);background:#fff;font:16px/1.6 -apple-system,BlinkMacSystemFont,"SF Pro Text",system-ui,sans-serif;-webkit-font-smoothing:antialiased}
  a{color:inherit}.shell{width:min(1120px,calc(100% - 36px));margin:auto}.nav{position:sticky;z-index:5;top:0;background:rgba(255,255,255,.82);border-bottom:1px solid rgba(16,32,51,.08);backdrop-filter:blur(22px) saturate(180%)}.nav-in{min-height:72px;display:flex;align-items:center;justify-content:space-between;gap:28px}.brand{color:var(--blue);font-size:28px;font-weight:800;letter-spacing:-.06em;text-decoration:none}.nav-links{display:flex;align-items:center;gap:24px}.nav-link{font-size:14px;font-weight:650;text-decoration:none;white-space:nowrap}.nav-cta{padding:10px 17px;border-radius:999px;background:var(--blue);color:#fff;font-size:14px;font-weight:750;text-decoration:none;white-space:nowrap}
  .hero{padding:72px 0 52px;background:radial-gradient(circle at 82% 8%,rgba(19,190,165,.2),transparent 32%),linear-gradient(135deg,#f6fbff,#f4f9fa 58%,#fbf7e9)}.crumb{margin-bottom:22px;color:var(--blue);font-size:13px;font-weight:700;text-decoration:none}.hero-grid{display:grid;grid-template-columns:1.05fr .95fr;gap:56px;align-items:center}.eyebrow{display:inline-flex;padding:7px 11px;border:1px solid rgba(8,120,201,.14);border-radius:999px;background:rgba(255,255,255,.68);color:var(--blue);font-size:11px;font-weight:750;letter-spacing:.1em;text-transform:uppercase}.hero h1{margin:18px 0;font-size:clamp(42px,6vw,72px);line-height:1;letter-spacing:-.055em;text-wrap:balance}.lede{max-width:680px;margin:0;color:var(--muted);font-size:19px;line-height:1.65;white-space:pre-line}.cover{width:100%;aspect-ratio:4/3;object-fit:cover;border-radius:30px;box-shadow:0 36px 80px rgba(16,40,63,.2)}.cover-fallback{display:grid;place-items:center;background:linear-gradient(145deg,#0a8e82,#0878c9);color:#fff;font-size:72px;font-weight:800}
  .meta{display:flex;flex-wrap:wrap;gap:9px;margin-top:26px}.pill{padding:8px 12px;border-radius:999px;background:#fff;border:1px solid var(--line);font-size:13px;font-weight:650}.content{padding:68px 0 86px}.content-grid{display:grid;grid-template-columns:1fr 350px;gap:70px;align-items:start}.content h2{margin:0 0 16px;font-size:clamp(30px,4vw,46px);line-height:1.1;letter-spacing:-.04em}.content p{color:var(--muted);font-size:18px}.preview-list{display:grid;gap:12px;margin:28px 0}.preview{padding:18px 20px;border:1px solid var(--line);border-radius:18px;background:#f8fafb}.preview strong{display:block;font-size:17px}.preview span{color:var(--muted);font-size:14px}.more{padding:20px;border:1px dashed #9ecbe7;border-radius:18px;background:#f4fbff;color:var(--blue);font-weight:700;text-align:center}
  .cta{position:sticky;top:98px;padding:28px;border-radius:28px;background:var(--navy);color:#fff;box-shadow:0 28px 60px rgba(16,40,63,.18)}.cta h2{font-size:27px}.cta p{color:rgba(255,255,255,.72);font-size:15px}.button{display:flex;justify-content:center;margin-top:22px;padding:14px 18px;border-radius:999px;background:var(--blue);color:#fff;font-weight:750;text-decoration:none;transition:transform .12s ease}.button:active{transform:scale(.97)}.store-row{display:flex;gap:12px;margin-top:12px}.store-row a{flex:1;color:rgba(255,255,255,.78);font-size:12px;text-align:center}
  .cards{display:grid;grid-template-columns:repeat(3,1fr);gap:20px;padding:54px 0 88px}.card{overflow:hidden;border:1px solid var(--line);border-radius:24px;background:#fff;text-decoration:none;box-shadow:0 1px 2px rgba(16,32,51,.03)}.card img,.card-art{display:block;width:100%;aspect-ratio:16/10;object-fit:cover}.card-art{background:linear-gradient(145deg,#dff7f3,#dceefa)}.card-body{padding:20px}.card small{color:var(--blue);font-weight:750;text-transform:uppercase}.card h2{margin:6px 0 8px;font-size:22px;line-height:1.15;letter-spacing:-.03em}.card p{margin:0;color:var(--muted);font-size:14px}.hub-head{padding:72px 0 20px}.hub-head h1{margin:0;font-size:clamp(44px,7vw,78px);line-height:1;letter-spacing:-.055em}.hub-head p{max-width:720px;color:var(--muted);font-size:19px}.footer{padding:34px 0;background:#0b1b2a;color:rgba(255,255,255,.72)}
  @media(max-width:800px){.nav-in{padding:14px 0;align-items:flex-start}.nav-links{justify-content:flex-end;flex-wrap:wrap;gap:8px 16px}.nav-link{font-size:13px}.nav-cta{padding:7px 12px;font-size:13px}.hero{padding-top:48px}.hero-grid,.content-grid{grid-template-columns:1fr}.hero-grid{gap:34px}.cover{border-radius:22px}.content-grid{gap:42px}.cta{position:static}.cards{grid-template-columns:1fr}.store-row{flex-direction:column}.hero h1{font-size:48px}}
  @media(prefers-reduced-motion:reduce){html{scroll-behavior:auto}.button{transition:none}}
`;

export function cleanImage(value) {
  if (!value) return null;
  return firstImage(String(value).replace(/["']+$/g, ''));
}

export function pageHead({ title, description, canonical, image, type = 'article', schema }) {
  const t = escapeHtml(title);
  const d = escapeHtml(description);
  const c = escapeHtml(canonical);
  const img = escapeHtml(image || `${BASE_URL}/api/og-image?title=${encodeURIComponent(title)}&subtitle=TRODDR%20Guide`);
  return `<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>${t}</title><meta name="description" content="${d}"><link rel="canonical" href="${c}"><meta property="og:type" content="${type}"><meta property="og:site_name" content="TRODDR"><meta property="og:title" content="${t}"><meta property="og:description" content="${d}"><meta property="og:url" content="${c}"><meta property="og:image" content="${img}"><meta name="twitter:card" content="summary_large_image"><meta name="twitter:title" content="${t}"><meta name="twitter:description" content="${d}"><meta name="twitter:image" content="${img}"><link rel="icon" href="/images/troddr_logo.png"><meta name="apple-itunes-app" content="app-id=6751852075"><style>${GUIDE_CSS}</style><link rel="stylesheet" href="/css/footer-shared.css?v=2">${schema ? `<script type="application/ld+json">${JSON.stringify(schema).replace(/</g, '\\u003c')}</script>` : ''}</head>`;
}

export function nav() {
  return `<header class="nav"><div class="shell nav-in"><a class="brand" href="/">troddr</a><nav class="nav-links" aria-label="Primary navigation"><a class="nav-link" href="/about.html">About</a><a class="nav-link" href="/guides">Guides</a><a class="nav-link" href="/#features">Features</a><a class="nav-link" href="/#faq">FAQ</a><a class="nav-link" href="/contact.html">Contact</a><a class="nav-cta" href="/#demo">Download the App</a></nav></div></header>`;
}

export function footer() {
  return `<footer class="footer" role="contentinfo">
        <div class="section-container">
            <div class="footer-content">
                <div class="footer-section">
                    <h3>TRODDR</h3>
                    <p>Jamaica's curated travel guide. Luxury retreats, local restaurants, hidden beaches, and everything worth doing across the island. Built by locals, for travellers who want the real Jamaica.</p>
                </div>
                <div class="footer-section">
                    <h3>Company</h3>
                    <nav class="footer-links" aria-label="Company links">
                        <a href="/about.html">About Us</a>
                        <a href="/#features">Features</a>
                        <a href="/contact.html">Contact</a>
                        <a href="/#demo">Download the App</a>
                    </nav>
                </div>
                <div class="footer-section">
                    <h3>Discover</h3>
                    <nav class="footer-links" aria-label="Discovery links">
                        <a href="/app" aria-label="Discover places to eat in Jamaica">Eat</a>
                        <a href="/app" aria-label="Discover places to stay in Jamaica">Stay</a>
                        <a href="/app" aria-label="Discover things to do in Jamaica">Play</a>
                        <a href="/app" aria-label="Jamaica events and festivals">Events</a>
                        <a href="/app" aria-label="Explore Jamaica destinations">Destinations</a>
                    </nav>
                </div>
                <div class="footer-section">
                    <h3>Plan</h3>
                    <nav class="footer-links" aria-label="Planning tools">
                        <a href="/app" aria-label="Jamaica trip planning tool">Trip Planner</a>
                        <a href="/app" aria-label="Jamaica itinerary ideas">Itineraries</a>
                        <a href="/guides" aria-label="Jamaica travel guides">Travel Guides</a>
                        <a href="/app" aria-label="Local Jamaica travel tips">Local Tips</a>
                    </nav>
                </div>
                <div class="footer-section">
                    <h3>Support</h3>
                    <nav class="footer-links" aria-label="Support links">
                        <a href="/contact.html" aria-label="Get help and support">Help Center</a>
                        <a href="/contact.html">Contact Us</a>
                        <a href="/privacy.html">Privacy Policy</a>
                        <a href="/terms_and_conditions.html">Terms of Service</a>
                        <a href="/delete-account.html">Account Deletion</a>
                    </nav>
                </div>
                <div class="footer-section">
                    <h3>Contact</h3>
                    <div class="footer-links">
                        <a href="mailto:hello@troddr.com" aria-label="Email us at hello@troddr.com">hello@troddr.com</a>
                    </div>
                </div>
            </div>
            <div class="footer-bottom">
                <p>© 2026 TRODDR.</p>
                <p>Made with ❤️ in Jamaica. <br>Jamaica's curated travel guide, eat, stay and explore like a local.</p>
            </div>
        </div>
    </footer></body></html>`;
}

export async function fetchGuides() {
  const guides = await sbSelect('guides?select=slug,title,description,image_url,location,category,type,is_itinerary_guide,country,best_for,created_at&country=eq.Jamaica&order=created_at.desc');
  const missing = guides.filter((guide) => !cleanImage(guide.image_url)).map((guide) => guide.slug);
  if (!missing.length) return guides;

  const slugFilter = missing.map(encodeURIComponent).join(',');
  const spots = await sbSelect(`view_guide_details?guide_slug=in.(${slugFilter})&select=guide_slug,image,ordering&image=not.is.null&order=ordering.asc`);
  const firstPlaceImage = new Map();
  spots.forEach((spot) => {
    const image = cleanImage(spot.image);
    if (image && !firstPlaceImage.has(spot.guide_slug)) firstPlaceImage.set(spot.guide_slug, image);
  });
  return guides.map((guide) => ({ ...guide, image_url: cleanImage(guide.image_url) || firstPlaceImage.get(guide.slug) || null }));
}
