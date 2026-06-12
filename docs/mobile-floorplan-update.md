# Mobile app update — event floor plans v2

**Audience:** whoever updates the TRODDR mobile app (a developer or an AI coding session in the app repo). This document is self-contained — it specifies everything the app needs to render the new floor plan format, with no access to the website repo required.

---

## 1. What changed and why

The partner website's floor plan editor was upgraded from a "pins on an image" tool to a full **builder**: organizers now draw numbered booth rectangles, large zones (stage / bar / emporium), round tables, and free text labels — with or without a background image — and link booths to vendors.

Everything is stored in the **same two columns the app already reads**:

| Column on `public.events` | Before | Now |
|---|---|---|
| `floor_plan_url` (text) | uploaded image URL | same — but may also be a small `data:image/svg+xml` grid placeholder when the organizer built on a blank canvas |
| `floor_plan_markers` (jsonb) | array of pin objects | array of **typed elements** (pins, booths, zones, tables, text) — discriminated by a `type` field |

Nothing was renamed or migrated. An app that only understands the old format keeps working (see §6 fallback rules), but it will show booths as dots instead of rectangles. The goal of this update is native rendering of all five element types.

---

## 2. Two implementation paths

### Path A — webview embed (ship this week)

The website now serves a **public, mobile-first interactive map** for every event at:

```
https://www.troddr.com/map/<event-slug>
```

- No auth, no app chrome, designed for phone screens: pan/zoom canvas, tap a booth → info popover, auto-generated legend.
- Backed by the RPC `get_event_floor_plan_public(p_slug text)` (already deployed with the site) — returns only public-safe fields.
- **App change:** replace the current static floor-plan image screen with a webview pointed at that URL (hide it / fall back to the old image if the event has no `slug`). That's the whole change.

This gets feature parity instantly and is a fine permanent solution for low-traffic screens. Do Path A first even if you also plan Path B — it's the safety net.

### Path B — native rendering (the real fix)

Render the elements natively on a pan/zoom canvas. The rest of this document is the spec for Path B.

---

## 3. Data model

`floor_plan_markers` is one JSON array. Each entry has a `type`; **entries with no `type` are legacy pins**. All other fields per type:

```jsonc
// pin — a point of interest (entrance, restrooms, first aid, …)
{ "id": "el_x1", "type": "pin", "x": 0.5, "y": 0.9,
  "label": "Entrance", "icon": "entrance", "color": "#22c55e",
  "vendor_id": null, "booth": "", "size": "", "description": "" }

// booth — a numbered vendor stall (rectangle)
{ "id": "el_x2", "type": "booth", "x": 0.2, "y": 0.2, "w": 0.04, "h": 0.064,
  "number": 15, "label": "Lucky Crab Seafood", "icon": "food", "color": "#1a9e57",
  "vendor_id": "evt-vendor-uuid", "size": "10x10", "description": "" }

// zone — a large area (stage, bar, emporium, VIP …)
{ "id": "el_x3", "type": "zone", "x": 0.55, "y": 0.3, "w": 0.14, "h": 0.14,
  "label": "Stage", "color": "#1f2937", "description": "" }

// table — decorative furniture, no info attached
{ "id": "el_x4", "type": "table", "x": 0.4, "y": 0.55, "w": 0.024, "h": 0.038,
  "shape": "round", "color": "#b08850" }   // shape: "round" | "rect"

// text — a free-floating label ("SECURITY", "Parking this way →")
{ "id": "el_x5", "type": "text", "x": 0.5, "y": 0.05,
  "label": "SECURITY", "color": "#166534", "fontSize": 0.02 }
```

### Coordinate system (important)

- `x`, `y` are **the element's CENTER**, as fractions (0–1) of the canvas width/height.
- `w`, `h` are fractions of canvas **width** and **height** respectively (so a "square" booth has different `w` and `h` values unless the canvas is square).
- `fontSize` (text only) is a fraction of canvas **width**.
- The canvas is the background image at its natural pixel size, or **1600 × 1000** when there is no real background image.
- Pins are anchored at their point: draw the marker with its tip/center at (`x`,`y`).

### Vendor linking

`vendor_id` on a booth/pin references `event_vendor_id` from the event's vendor list (the `event_vendors.id` join row — the same id the app already gets in event payloads). When a booth has a `vendor_id` but an empty `label`, **display the vendor's name as the title**.

---

## 4. Rendering spec

Draw order (bottom → top): **zones → tables → booths → text → pins**.

| Element | How to draw |
|---|---|
| **zone** | Filled rect, `color` at ~85% opacity, 2px border in `color`, 4px corner radius. Label centered, white, bold, UPPERCASE, font ≈ 20% of zone height (clamp 11–30 canvas-px). |
| **booth** | Filled rect in `color`, thin dark border (rgba(0,0,0,0.25)), 3px radius. `number` centered in white bold, font ≈ 42% of the smaller side (clamp 9–26). If `label` non-empty, draw it in a small white pill just **below** the rect (dark text, ~11px). |
| **table** | `color`-filled ellipse (`shape:"round"`) or rect (`shape:"rect"`), thin dark border. No label, not tappable. |
| **text** | `label` in `color`, bold, centered at (`x`,`y`), size `fontSize × canvasWidth`. |
| **pin** | Circular marker in `color` with white ring, category icon inside (or just the dot if you don't ship icons), `label` in a white pill below. |

Sizes given in "canvas px" — i.e., in the background image's pixel space, so they scale with zoom like everything else.

### Tap behavior

- Tapping a **booth / zone / pin** opens an info card: title (= `label`, else vendor name, else category label), then `Booth <number>` · category · `<size>` ft (e.g. `10 × 20 ft`), then `description`. Omit empty parts.
- **Tables and text are not tappable.**
- If the booth's vendor exists in the event's vendor data, deep-link the card to your existing vendor detail screen.

### Legend

Collect the distinct categories actually used by booths and pins (via `icon`) and show a small legend: color swatch + category label. Square swatch if the category is used by booths, round if only pins.

### Category table

`icon` values map to label + default color (the saved `color` field on each element already contains the resolved color — prefer it; this table is for the legend and for icon art):

| id | label | color |
|---|---|---|
| `food` | Food | `#1a9e57` |
| `drink` | Drink | `#06b6d4` |
| `bar` | Bar | `#0891b2` |
| `stage` | Stage | `#262626` |
| `merch` | Merch | `#ec4899` |
| `artisan` | Artisan | `#7c3aed` |
| `photo` | Photo Op | `#14b8a6` |
| `arcade` | Arcade | `#10b981` |
| `seating` | Seating | `#64748b` |
| `vip` | VIP | `#d4a017` |
| `info` | Info | `#0a7aff` |
| `medic` | First Aid | `#ef4444` |
| `restroom` | Restrooms | `#475569` |
| `entrance` | Entrance | `#22c55e` |
| `exit` | Exit | `#16a34a` |
| `parking` | Parking | `#334155` |

Unknown `icon` value → treat as `food` (legacy data may contain free-form strings like `"pin"`).

---

## 5. Background handling

- If `floor_plan_url` starts with `data:image/svg+xml` → the organizer built on a **blank canvas**. Either render that data URI (it's a tiny grid SVG) or ignore it and draw on a plain white 1600 × 1000 canvas — both look right.
- Otherwise it's a normal HTTPS image in the public `event-floorplans` storage bucket; canvas size = its natural size.
- `floor_plan_url` may be null while `floor_plan_markers` is non-empty (legacy partial saves): use the white 1600 × 1000 canvas.

---

## 6. Compatibility rules (both directions)

1. **No `type` field → it's a pin.** All pre-existing data renders exactly as before.
2. **Unknown `type` → skip it silently.** New element types may be added later (e.g. rotated booths); old app versions must not crash or render garbage.
3. **Never write `floor_plan_markers` from the app.** The web editor is the single writer; an app-side save that strips unknown fields would destroy layout data. (This bit a web page already — the lossy save path was removed.)
4. Coerce defensively: `x/y/w/h/fontSize` may arrive as strings; numbers like `number` may be strings; missing `color` falls back to the category color.

---

## 7. Test checklist

Use an event saved from the new web editor (any event edited at `/partner/event-floorplan`):

- [ ] Legacy event (pins only, no `type` fields) renders identically to the old app version.
- [ ] Mixed event: booths render as colored numbered rectangles, zones as large translucent blocks **under** booths, tables as small circles, text labels at the right size.
- [ ] Booth with `vendor_id` and empty `label` shows the vendor's name in its tap card.
- [ ] `size: "10x20"` displays as "10 × 20 ft"; custom sizes like `"12x35"` too.
- [ ] Event with `data:image/svg+xml` background renders on white/grid, not a broken image.
- [ ] Element with an unrecognized `type` (hand-edit one in the DB to `"future-thing"`) is skipped without a crash.
- [ ] Pan/zoom: elements keep their positions over the background at all zoom levels (everything is drawn in the same canvas space).
- [ ] Webview fallback (Path A) opens `https://www.troddr.com/map/<slug>` and shows the same layout.

## 8. Reference implementations (website repo)

If you have the website repo handy, these files are the source of truth:

- `js/floorplan-builder.js` — the full renderer/editor; `serialize()` documents the exact saved shape, `exportPng()` is a complete canvas-2D reference renderer (~80 lines, easy to port).
- `map.html` — the public attendee viewer (Path A target).
- `supabase/event-map.sql` — column comments + the `get_event_floor_plan_public` RPC.
