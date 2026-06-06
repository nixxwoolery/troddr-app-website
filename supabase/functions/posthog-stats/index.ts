// =============================================================
// posthog-stats: Edge Function that proxies PostHog HogQL queries
// for the partner dashboard.
//
// Security: the caller passes a partner_access_token. We verify
// it owns the requested slug before we ever hit PostHog. The PostHog
// API key never leaves the server.
//
// Required Edge Function secrets:
//   POSTHOG_API_KEY     phx_*  Personal API key with query:read
//   POSTHOG_PROJECT_ID  numeric project id from the PostHog URL
//   POSTHOG_HOST        https://app.posthog.com (or eu equivalent)
//   SUPABASE_URL        auto-populated by Supabase
//   SUPABASE_SERVICE_ROLE_KEY  auto-populated by Supabase
// =============================================================
import { serve } from 'https://deno.land/std@0.224.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.45.4';

const POSTHOG_API_KEY    = Deno.env.get('POSTHOG_API_KEY');
const POSTHOG_PROJECT_ID = Deno.env.get('POSTHOG_PROJECT_ID');
const POSTHOG_HOST       = Deno.env.get('POSTHOG_HOST') ?? 'https://app.posthog.com';
const SUPABASE_URL       = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY   = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const supa = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

const corsHeaders = {
  'Access-Control-Allow-Origin':  '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

interface VerifiedEntity {
  type: 'place' | 'event';
  slug: string;
  name: string;
}

/**
 * Look up the token and return what entity it belongs to + its slug.
 * Returns null if the token doesn't resolve.
 */
async function verifyToken(token: string): Promise<VerifiedEntity | null> {
  // Try place first
  const { data: place } = await supa
    .from('places')
    .select('slug, name')
    .eq('partner_access_token', token)
    .maybeSingle();
  if (place) return { type: 'place', slug: place.slug, name: place.name };

  // Then event
  const { data: event } = await supa
    .from('events')
    .select('slug, title')
    .eq('partner_access_token', token)
    .maybeSingle();
  if (event) return { type: 'event', slug: event.slug, name: event.title };

  return null;
}

/**
 * Run a HogQL query against PostHog and return its results.
 */
async function hogql(query: string): Promise<any> {
  const res = await fetch(
    `${POSTHOG_HOST}/api/projects/${POSTHOG_PROJECT_ID}/query/`,
    {
      method:  'POST',
      headers: {
        'Authorization': `Bearer ${POSTHOG_API_KEY}`,
        'Content-Type':  'application/json',
      },
      body: JSON.stringify({
        query: { kind: 'HogQLQuery', query },
      }),
    },
  );
  if (!res.ok) {
    const text = await res.text();
    throw new Error(`PostHog ${res.status}: ${text.slice(0, 200)}`);
  }
  return await res.json();
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  try {
    if (!POSTHOG_API_KEY || !POSTHOG_PROJECT_ID) {
      return new Response(
        JSON.stringify({ ok: false, error: 'PostHog is not configured yet on the server.' }),
        { status: 503, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      );
    }

    const body = await req.json();
    const token: string = (body?.token ?? '').toString();
    const range: number = Math.max(1, Math.min(365, parseInt(body?.range_days ?? '30', 10) || 30));

    if (!token) {
      return new Response(
        JSON.stringify({ ok: false, error: 'Missing token' }),
        { status: 400, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      );
    }

    const entity = await verifyToken(token);
    if (!entity) {
      return new Response(
        JSON.stringify({ ok: false, error: 'Invalid or revoked token' }),
        { status: 401, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
      );
    }

    // Path pattern this entity lives at in the app + on the web
    const pathPattern = entity.type === 'place'
      ? `/listings/${entity.slug}`
      : `/events/${entity.slug}`;

    // 1. Daily views over the last N days
    const trendQuery = `
      SELECT
        toDate(timestamp) AS day,
        count()           AS views,
        uniq(distinct_id) AS unique_visitors
      FROM events
      WHERE event = '$pageview'
        AND properties.$pathname LIKE '%${pathPattern}%'
        AND timestamp >= now() - INTERVAL ${range} DAY
      GROUP BY day
      ORDER BY day
    `;

    // 2. Top referrers (where guests came from)
    const referrerQuery = `
      SELECT
        coalesce(nullIf(properties.$referring_domain, ''), 'direct') AS source,
        count()           AS views,
        uniq(distinct_id) AS unique_visitors
      FROM events
      WHERE event = '$pageview'
        AND properties.$pathname LIKE '%${pathPattern}%'
        AND timestamp >= now() - INTERVAL ${range} DAY
      GROUP BY source
      ORDER BY views DESC
      LIMIT 10
    `;

    // 3. Top UTM sources (paid / campaign attribution)
    const utmQuery = `
      SELECT
        coalesce(nullIf(properties.utm_source, ''), '(none)') AS utm_source,
        count() AS views
      FROM events
      WHERE event = '$pageview'
        AND properties.$pathname LIKE '%${pathPattern}%'
        AND timestamp >= now() - INTERVAL ${range} DAY
      GROUP BY utm_source
      ORDER BY views DESC
      LIMIT 10
    `;

    // 4. Country breakdown
    const countryQuery = `
      SELECT
        coalesce(nullIf(properties.$geoip_country_code, ''), 'Unknown') AS country,
        count()           AS views,
        uniq(distinct_id) AS unique_visitors
      FROM events
      WHERE event = '$pageview'
        AND properties.$pathname LIKE '%${pathPattern}%'
        AND timestamp >= now() - INTERVAL ${range} DAY
      GROUP BY country
      ORDER BY views DESC
      LIMIT 15
    `;

    // 5. Totals (single row, fast)
    const totalsQuery = `
      SELECT
        count()           AS total_views,
        uniq(distinct_id) AS unique_visitors
      FROM events
      WHERE event = '$pageview'
        AND properties.$pathname LIKE '%${pathPattern}%'
        AND timestamp >= now() - INTERVAL ${range} DAY
    `;

    const [trend, referrers, utm, countries, totals] = await Promise.all([
      hogql(trendQuery),
      hogql(referrerQuery),
      hogql(utmQuery),
      hogql(countryQuery),
      hogql(totalsQuery),
    ]);

    // PostHog HogQL responses come back as { results: [[col1, col2, …], …], columns: […] }
    const shape = (resp: any, cols: string[]) =>
      (resp?.results ?? []).map((row: any[]) =>
        Object.fromEntries(cols.map((c, i) => [c, row[i]])),
      );

    const totalsRow = shape(totals, ['total_views', 'unique_visitors'])[0]
      ?? { total_views: 0, unique_visitors: 0 };

    return new Response(JSON.stringify({
      ok: true,
      entity: { type: entity.type, slug: entity.slug, name: entity.name },
      range_days: range,
      total_views:      Number(totalsRow.total_views     ?? 0),
      unique_visitors:  Number(totalsRow.unique_visitors ?? 0),
      trend:           shape(trend,    ['day', 'views', 'unique_visitors']),
      top_referrers:   shape(referrers,['source', 'views', 'unique_visitors']),
      top_utm_sources: shape(utm,      ['utm_source', 'views']),
      top_countries:   shape(countries,['country', 'views', 'unique_visitors']),
    }), {
      headers: { ...corsHeaders, 'Content-Type': 'application/json' },
    });
  } catch (e: any) {
    console.error('[posthog-stats] error', e);
    return new Response(
      JSON.stringify({ ok: false, error: String(e?.message ?? e) }),
      { status: 500, headers: { ...corsHeaders, 'Content-Type': 'application/json' } },
    );
  }
});
