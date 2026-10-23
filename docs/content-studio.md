# Content Studio

Open `/admin#/content` after signing in. The standalone preview supports `#overview`, `#create`, `#library`, `#places`, and `#inspiration` links.

## Dashboard and countries

A persistent country selector scopes published guide counts, directory counts, inspiration, draft library, place searches, and performance. Country names come from the live public places table. The chosen country is kept in session storage, independently of private drafts and credentials.

- Overview: live country directory/guide counts, recent private draft, top places/guides by views over 30 days, and country-specific inspiration.
- Create: guides, posts, photo stories, new place profiles, and place updates.
- Library: country-specific drafts with search and type filters. Older drafts without a country are explicitly available under Needs a country and must be assigned before saving.
- Places: paginated, country-specific place directory with name/town search and category filter. Draft an update starts from an existing place's description, address, town, category, website, phone, and photos.
- Inspiration: existing country guides and place cards, linked to their public pages, with a shortcut to start a guide from a place.

Performance reuses `admin_get_performance(token, days)` and joins its results against the complete public slug lists for the selected country. Only attributable place and guide views are summed. Missing analytics are displayed as unavailable, never replaced with sample metrics. Private post draft views are not included. No production analytics were verified without an admin token.

## Creating and writing

A guide progresses through Details (country, type, category, title and editorial notes), Places (search, category filter, multiple selections, reading order), and Writing (article canvas and one recommendation field per selected place). Sensory writing cues are optional, collapsible guidance beside each place's writing area; they are not inserted in the preview or saved as story text. Other formats start with their relevant setup and continue into writing. Place updates retain an immutable link to their source place; changing live place data is a future publishing operation.

Selected places are stored in `guidePlaces`, including the source slug and country. Both client selection and the draft migration reject a known place from another country. Existing inline guide place blocks are migrated into the selection without dropping recommendation text. Text, headings, quotes and photos can be ordered on the writing canvas. Previews render text through DOM text nodes and safely construct public place links.

Original place photos are references in `placeDetails.existingImages`, with checkboxes to propose retention/removal. New uploads are resized to 1600px and JPEG-encoded, with a maximum of ten uploads and approximately 7.5 MB of photo data per draft. Originals are not retained. New photos are embedded in the private draft JSON, suitable for a small library; a larger archive needs object storage and library pagination.

Focus mode, captions, cover selection, Cmd/Ctrl+S and explicit save are supported. Autosave runs after 1.8 seconds of edits once a title and country are present and the server is available. Typing can continue during a save. Unsaved work is protected by navigation confirmation. Existing drafts use optimistic concurrency.

## Backend and deployment

Apply `supabase/migrations/20261022210000_admin_content_studio.sql` before enabling cloud saving. It relies on `public._is_admin(text)`. The private table has RLS and no direct anon/authenticated access; every RPC checks the admin token. The migration requires a country and verifies that guide selections refer to places in that country.

No production migration or deployment was applied. Local/remote migration histories differ; do not run a general `supabase db push` without reconciling history or isolating the intended migration.

When the library is unavailable, editing and preview can be explored, but edits only live in memory and the interface labels saving as unavailable. No silent local storage of private drafts is used.

All formats save as private drafts in the same table. Place profiles/updates use `kind=post` with a `contentPurpose` and structured `placeDetails`; guide drafts use `kind=guide`. Publishing to `places`, `guides`, `guide_spots`, or public post URLs is not implemented. Existing place updates do not mutate the live directory.

## Validation

`npm test` covers legacy draft conversion, structured-story round trips, ordering, photo references, country isolation, cross-country place rejection, and guide metadata. Browser checks cover guide setup/type/category, selection, per-place writing, sensory cues staying out of preview, public country switching, and live directory data. Full authenticated saving and live performance require the admin session and migration.

## Instagram and photo intake

Create now includes an Instagram format. Each draft also has App/Instagram destination checkboxes, so one guide or story can have a social companion sharing the same photos. The writing screen offers an optional companion action, format (photo post, carousel, story sequence, reel plan), editable caption and frame/shot outline. Build from this draft fills only empty fields using the existing title, introduction, recommendations and photo captions; it does not call an AI service or invent place details. The brief downloads as text and requires at least one photo. It does not publish to Instagram or render final graphic/video assets.

Details asks Do you have photos? with a multi-file picker, drag/drop, paste support, thumbnails, removal and an add-later choice. The first intake image becomes the cover, with the rest added inline. Drafts may be saved while gathering photos; the missing-photo state remains visible and Instagram brief export asks for a photo first.

### Private object storage (new)

The media migration supersedes the earlier embedded-image saving behavior. Apply both editorial migrations, then deploy `supabase/functions/admin-content-media/index.ts` with the normal Supabase function workflow. The service-role environment is available only inside the function. No migration/function has been deployed by this change.

The private `content-media` bucket routes files to:

`<country-slug>/<guides|places|posts|instagram>/<draft-uuid>/photos/<photo-uuid>.jpg`

The country and content purpose belong to the draft; adding an Instagram companion reuses the original draft's photo paths. App-only and Instagram-only drafts use their respective content purpose folder. The shared path generator validates UUIDs and the allowed purpose list. The function checks the existing admin token, verifies the country, computes the path itself, validates the JPEG bytes/size, uploads the object, and registers its draft/country/purpose in `admin_content_media`. The save RPC accepts only paths registered to that exact draft, country and purpose. A restrictive storage policy prevents older broad browser policies from granting access to this bucket.

Uploads run before the draft save. Successful media manifests survive subsequent upload/save failures for retry. Pending photos are explicitly labelled Not uploaded yet and remain in memory until saving works. Saving stops on any routing or upload failure. No image bytes or expiring signed URLs are stored in the final draft JSON; signed read URLs are issued after admin-token verification and renewed on reopening. Existing legacy embedded photos upload through this path when their draft is next saved. Previously public place photos retained in a proposed place update remain references to their existing URLs.

The endpoint supports up to 5 MB per JPEG. The client resizes to 1600px, limits each draft to ten new photos, and limits in-memory new photo data to approximately 7.5 MB. Original files are not retained. Removed/deleted draft photos are not immediately purged from storage; abandoned uploads need a future retention/cleanup job. This avoids accidentally removing photos still referenced by another saved revision.

Validation includes deterministic folder routing, rejection of injected IDs/unsupported types, signed-URL stripping, Instagram destination preservation, and social brief derivation. The local photo picker and pending-upload flow can be tested without credentials; cloud upload/read/save integration requires deploying the function and migrations and signing into the admin. Deno is not installed locally, so the edge function has not been type-checked or executed against production.

## Dedicated Instagram and photo workspaces

The destination checkboxes have been removed. Instagram now has a dedicated top-level tab (`#instagram`) with its own draft list, a new-draft action, and a saved/app-draft repurposing action. App editors offer Create Instagram version, which forks a separate social draft rather than mixing the social editor into the app page. Existing source captions are retained when present. Unsaved source/fork records can be held in memory in this tab and are labelled accordingly; closing/reloading loses them unless they were saved. Page-close warnings also cover these held drafts.

A repurposed draft gets a new ID and new photo IDs. Previously uploaded photos are copied by the admin media function into the new Instagram draft's folder after verifying the source registry and country; another draft's private path is not reused as though it belongs to the new draft. This requires redeploying the updated media function. Locally pending photo data can be reused directly before upload. No live Instagram connection or automatic posting is involved.

The writing canvas reports total word count and an opening preview at an editorial 240-character marker. Instagram captions have their own word/character count and an adjustable estimated more break (default 125 characters). The first-sentence check reports whether the sentence extends beyond that marker. These are preview guides, not a guarantee of writing quality or exact device/platform truncation.

### Photo studio

`#photos` opens an independent browser photo editor, also accessible through Edit photo on an uploaded draft photo. It supports JPG/PNG/WebP, exposure, contrast, highlights, shadows, warmth, saturation, sharpening, four looks, zoom and pan crop, 90-degree rotation, flip, a luminance histogram, undo/redo and before/after comparison. Output presets include original proportions, app landscape, square, 4:5, 3:4 and 9:16. Text layers support multiline text, font, colour, size, position, optional dark backing, and direct dragging.

Downloads are rendered JPEG/PNG files at the selected pixel dimensions with adjustments and text baked in. Use edited copy adds a new photo and edit recipe to the current draft; the source photo is retained. Reopening a version uses its source photo when present to avoid applying adjustments twice. Standalone session copies must be downloaded to keep them; this workspace does not silently upload to storage.

The editor handles raster files rather than RAW data and does not provide healing, masking, lens correction or professional colour-profile management. Photo editing/export runs locally without an admin token. Persisting copies still needs the storage/database deployment described above. Per-draft uploads were previously resized to 1600px; standalone editor imports can use a larger source (20 MB file limit, internal working image capped at 4096px). Exporting a small source at a larger preset may upscale it.

QA exported an actual 1080 × 1350 JPEG with colour changes and text applied. Tests cover output sizing, crop bounds at pan/zoom extremes, neutral pixel preservation, saturation/exposure, sharpening, Unicode opening counts, and edit-recipe/source reference persistence.


Dehaze supports -100 to +100 with estimated airlight correction; this is a raster approximation, not Adobe’s algorithm. Instagram is global across app countries. Its internal scope is External and new media routes to external/instagram/<draft>/photos; country selection is hidden in social workflows. Existing registered Instagram photos remain valid in their original paths.


## Place authoring
Create focuses on new place, guide and update place. Photo studio's Add to a place exports the current edit into a target picker, with country-scoped search or a new place. Both attach the photo to a private draft first. Review & apply saves the draft then calls admin-content-media publish-place. Registered private photos are copied to images/place images/<place ID>/<draft ID>/<photo ID>.jpg; only these verified URLs and existing source images enter the live place. Public copies created before a failed database update may be orphaned and should be cleaned up by retention tooling.

Deploy 20261023120000_content_place_authoring.sql after both earlier content migrations, then redeploy admin-content-media. No production deployment performed. Frontend and raster workflow are locally verified; live place creation/updates require this backend deployment and an admin token. SQL routines include conflict checks for the draft revision, original place fields and photos. The apply RPC is service-role-only; the read RPC validates the existing admin token.

The field catalogue covers every column in the checked-in places schema except id (generated), name (title), country (header), image (photo workflow), partner_id and partner_access_token (ownership/credentials, preserved and managed elsewhere). JSON fields accept structured JSON; arrays accept one item per line. This is schema coverage, not a custom visual editor for every data shape. Unrelated tables such as room inventory remain in their dedicated admin tools.


## Editorial dashboard refinement
Overview includes live country-scoped collection coverage (photos and curator notes) and category mix, a published-guide showcase, private draft continuation and existing analytics. Coverage measures records with image URLs, not a network audit of every original. Guide cards try their own cover and then images from view_guide_details, in ordering order; broken candidates advance to the next source. No unrelated stock imagery is substituted. The current inspiration query displays up to 1,000 published guides; the overview features the latest three.

Place section visibility follows Eat / Stay / Play; shared editorial/location fields remain, and publishing/structured-data fields are collapsed separately. Switching category hides but preserves entered values. Saving does not fill hidden fields with blank defaults. Legacy title-case categories are normalised in the editor and directory search is case insensitive. Motion uses short reversible hover/press transitions and non-blocking page reveals, with reduced-motion, reduced-transparency and contrast preferences. Preview article CSS is now scoped so it cannot distort directory cards.


## The writing room
The white/slate editorial palette uses DM Serif Display for the masthead and display headings, Poppins for controls. The overview has a manual daily three-item checklist. Writing room is available from both the main header and draft toolbar, without navigating away. The flip-style 25/5 timer uses a persisted deadline rather than counting interval ticks; pause/resume and reset work across reloads. Sessions do not advance automatically into another mode. Completion is announced in the tools panel; no notifications or sound permissions are requested.

The adjustable session word goal counts net word changes from open drafts during focus time, including Instagram captions. It excludes the scratchpad and does not count a draft’s existing words when it is opened. Timer state, goal, word progress, local-day focus-session count, checklist and scratchpad persist in browser localStorage. They are local to this browser and are not synchronised to Supabase. Closing the panel leaves a running timer badge. The checklist represents self-reported work, not automatic publishing metrics. Reset clears the current timer and word progress, retaining notes and the daily checklist.
