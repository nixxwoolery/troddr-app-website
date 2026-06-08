/* ============================================================
 * TRODDR runtime config : single source of truth for the
 * Supabase URL and anon key used across all partner / admin
 * dashboard pages.
 *
 * IMPORTANT : SUPABASE_URL now points at the same-origin proxy
 * (/api/sb), which Vercel rewrites to https://rprpwudhplodaqmmwqkf
 * .supabase.co. This means dashboard requests look like they're
 * going to troddr.com itself, so Safari content blockers,
 * 1Blocker / AdGuard, iCloud Private Relay, and corporate
 * firewalls that block supabase.co can't see or block them.
 *
 * The rewrite is defined in vercel.json:
 *   { "source": "/api/sb/:path*",
 *     "destination": "https://rprpwudhplodaqmmwqkf.supabase.co/:path*" }
 *
 * If you ever need to bypass the proxy for debugging, set
 * window.__SB_BYPASS_PROXY__ = true before this script loads
 * (e.g. via a query param + tiny inline shim).
 *
 * To rotate Supabase project, update SUPABASE_HOST below AND
 * the destination in vercel.json so they stay in sync.
 * ============================================================ */
window.__ENV__ = window.__ENV__ || {};

// Direct Supabase host (kept here for reference and emergency bypass).
window.__ENV__.SUPABASE_HOST   = 'https://rprpwudhplodaqmmwqkf.supabase.co';
window.__ENV__.SUPABASE_DIRECT = 'https://rprpwudhplodaqmmwqkf.supabase.co';

// Same-origin proxy URL : every supabase-js call (rest, auth, storage,
// functions) hits /api/sb/* on the current origin, which Vercel rewrites
// to the supabase host. Bypassable via window.__SB_BYPASS_PROXY__.
function resolveSupabaseUrl() {
  if (typeof window === 'undefined') return window.__ENV__.SUPABASE_HOST;
  if (window.__SB_BYPASS_PROXY__) return window.__ENV__.SUPABASE_HOST;
  try {
    // Localhost / file:// origins don't have the Vercel rewrite, so fall back
    // to direct Supabase in dev. Production (troddr.com + Vercel previews)
    // goes through the proxy.
    const o = window.location.origin || '';
    if (/^https?:\/\/localhost|^https?:\/\/127\.|^https?:\/\/0\.0\.0\.0|^file:/.test(o)) {
      return window.__ENV__.SUPABASE_HOST;
    }
    return o + '/api/sb';
  } catch (e) {
    return window.__ENV__.SUPABASE_HOST;
  }
}

window.__ENV__.SUPABASE_URL  = resolveSupabaseUrl();
window.__ENV__.SUPABASE_ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJwcnB3dWRocGxvZGFxbW13cWtmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTAyODcyODksImV4cCI6MjA2NTg2MzI4OX0.lNL6YZQqZgbsQRJyRAXpaWMC4LxncvPPyXNP1qopTFk';

// PostHog: project (client) key for tracking events from the app.
// This is the public phc_* key : safe to ship to the browser.
window.__ENV__.POSTHOG_PROJECT_KEY = 'phc_1l3cVksuZPD9P5jFg9Qqfy9ZotgfTxG5AXXADo1ND3O';

// For reading analytics into the dashboard we need a Personal API key
// (phx_*), stored as a Supabase Edge Function secret : NOT here.
// The Edge Function posthog-stats reads from it server-side.
