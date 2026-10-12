# TRODDR agent readiness

The homepage and missing-path responses negotiate HTML and Markdown using Accept preferences, include Vary: Accept, and reject unsupported types with 406. HEAD responses have no body. The HTML homepage is read directly from index.html to preserve the existing page and its behavior.

Public discovery resources: /llms.txt, /index.md, /developers.md and /developers. The homepage footer, metadata and sitemap link these resources. Organization metadata uses the published Negril, Jamaica location and existing support email; no street address or telephone has been invented.

## Routing maintenance

Edit scripts/vercel-routing-source.json for existing redirects, rewrites and headers, then run npm run build:agents. The script uses Vercel's routing compiler and adds homepage negotiation before filesystem handling and the 404 fallback in the error phase after existing and generated dynamic routes. vercel.json is generated and committed so Vercel sees the fallback configuration before the build starts. The Vercel build regenerates it for consistency. Do not restore high-level rewrites alongside low-level routes; Vercel does not allow mixing them.

Two existing header patterns (/admin-:path* and /partner-:path*) were corrected to explicit wildcard parameters accepted by the routing compiler. Existing app routes and crawler conditions remain in the source configuration.

## Verification

Run npm test, then start vercel dev --listen 3088 --yes and run node scripts/verify-agent-endpoints.js. After deployment, run node scripts/verify-agent-endpoints.js https://troddr.com; this follows redirects and checks final status, content type and body, including Vary on negotiated responses. Vercel's local CLI does not enforce all has conditions; crawler-specific routing should also be checked on a deployed preview.

No production deployment is included in these local edits. Search results cannot be guaranteed by code changes. Submit the updated sitemap through the verified Search Console account, request homepage and developer-page indexing, and earn relevant brand mentions linking to the canonical www.troddr.com domain. The current apex-to-www redirect is a single hop.

Publishing a supported API, OpenAPI contract, SDK or MCP server requires a product decision and an authentication/authorization design; these resources currently document read-only web retrieval instead. A more detailed street address or phone number should only be published after verification by the business.

Local verification: all negotiated responses, public discovery files, sitemap pages and app regression checks passed. The Apple association JSON parses correctly locally, but Vercel CLI 34 overrides its configured application/json header with application/octet-stream. Production currently returns application/json. The verifier reports this local-only limitation and enforces the correct header on deployed hosts.
