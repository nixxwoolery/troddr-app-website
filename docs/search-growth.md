# Troddr search growth

## Pages prepared

- `/where-to-eat-in-jamaica`: restaurant discovery by destination.
- `/things-to-do-in-jamaica`: destination choices and trip planning.
- `/things-to-do-in-kingston`: city activities and a suggested itinerary.

These are static public pages, linked from the homepage, guides hub and shared guide footer, with canonical URLs, descriptive titles, Article/BreadcrumbList structured data and sitemap entries. The same content is served to visitors and search engines. Rebuild the committed HTML after editing `scripts/build-discovery-pages.js` with `npm run build:discovery`. No deployment has been performed as part of this change.

## Before and after launch

1. Review the editorial copy with the Troddr team. Add firsthand venue details, original photos and practical advice. The initial restaurant selections come from the repository's location previews; they are not confirmation of current operation. Kingston attraction background is attributed on the page to the Jamaica Tourism Board.
2. Publish the website changes through the normal release process. Check all three clean URLs return HTTP 200, their `.html` variants redirect to the clean URL, and the existing guides still load.
3. Verify the domain in Google Search Console, submit `https://www.troddr.com/sitemap.xml` and inspect the three new URLs. Request indexing if appropriate. A submitted sitemap does not guarantee indexing or ranking.
4. Record a baseline of clicks, impressions, click-through rate and average position for each page and target query, separating country and device. Review every 28 days. Search result checks alone are not a reliable baseline, and no Search Console data was available during this work.
5. Expand pages around actual query impressions and visitor needs. Prioritise Kingston restaurant coverage, followed by destination pages with substantial distinct content. Avoid generating many near-identical location pages.
6. Earn relevant editorial links through useful original guides, local hospitality partnerships and coverage that readers would value. Do not buy ranking links or promise a specific placement.

## Editorial priority

The strongest next improvement is information readers cannot get from a generic guide: why a place was selected, who it suits, a realistic route, confirmed practical details and original local photography. Credit actual contributors; add review dates only when someone has reviewed the information. Keep useful recommendations public rather than hiding all detail behind an app download.

## Official guidance

- [Google Search Essentials](https://developers.google.com/search/docs/essentials)
- [Helpful, reliable, people-first content](https://developers.google.com/search/docs/fundamentals/creating-helpful-content)
- [Google crawling and indexing FAQ](https://developers.google.com/search/help/crawling-index-faq)

First-page placement is a goal, not a guaranteed outcome. Track progress using real Search Console data after publication.
