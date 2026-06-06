/* ============================================================
 * TRODDR runtime config : single source of truth for the
 * Supabase URL and anon key used across all partner / admin
 * dashboard pages.
 *
 * To rotate Supabase project (e.g. after recreating, migrating,
 * or changing the anon key), update the two values below.
 * Every page that loads this script will pick them up.
 *
 * Each page reads via:
 *   const SUPABASE_URL  = (window.__ENV__ && window.__ENV__.SUPABASE_URL)  || '...fallback';
 * so this file just sets window.__ENV__ before page scripts run.
 * ============================================================ */
window.__ENV__ = window.__ENV__ || {};

window.__ENV__.SUPABASE_URL  = 'https://rprpwudhplodaqmmwqkf.supabase.co';
window.__ENV__.SUPABASE_ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJwcnB3dWRocGxvZGFxbW13cWtmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTAyODcyODksImV4cCI6MjA2NTg2MzI4OX0.lNL6YZQqZgbsQRJyRAXpaWMC4LxncvPPyXNP1qopTFk';

// PostHog: project (client) key for tracking events from the app.
// This is the public phc_* key : safe to ship to the browser.
window.__ENV__.POSTHOG_PROJECT_KEY = 'phc_1l3cVksuZPD9P5jFg9Qqfy9ZotgfTxG5AXXADo1ND3O';

// For reading analytics into the dashboard we need a Personal API key
// (phx_*), stored as a Supabase Edge Function secret : NOT here.
// The Edge Function posthog-stats reads from it server-side.
