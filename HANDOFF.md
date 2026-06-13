# Troddr Admin Platform — Handoff Document

**Date:** 2026-06-13  
**Project:** Troddr Caribbean travel platform  
**Branch:** main

---

## Project Overview

Troddr is a Caribbean travel and discovery platform (hotels, places, events, loyalty, partner bookings). The frontend is a vanilla HTML/CSS/JS static site with no build step. The backend is Supabase (PostgreSQL) with Row Level Security — all data access goes through `security definer` RPCs granted to the `anon` role. No direct table access from the frontend.

**Supabase project:** `https://rprpwudhplodaqmmwqkf.supabase.co`

---

## What Has Been Completed

### Phase 2 — Hotel Booking Infrastructure

#### 1. `supabase/hotel-booking-infrastructure.sql` (~1,300 lines)
Full idempotent SQL migration. Safe to re-run. Adds:

**New tables:**
- `hotel_room_types` — room types per property
- `hotel_rate_plans` — rate plans per room type
- `hotel_availability` — per-date availability calendar (unique: `room_type_id + stay_date`)
- `booking_room_allocations` — room allocations per confirmed booking
- `booking_timeline_events` — audit log, auto-inserted by `trg_booking_timeline` trigger
- `hotel_inventory_holds` — temporary holds for `instant_manual_inventory` mode
- `booking_cancellation_policies` — per-property or per-rate-plan cancellation policies
- `booking_notification_logs` — notification audit log

**New columns on `places`:**
`booking_mode`, `accepts_stay_bookings`, `bookings_email`, `booking_contact_name`, `check_in_time`, `check_out_time`, `min_nights`, `max_guests`, `cancellation_policy`, `deposit_instructions`, `deposit_required`, `deposit_default_amount`, `deposit_currency`, `commission_terms`, `taxes_fees_notes`, `hold_expiry_minutes`, `internal_booking_notes`

**Booking modes:**
- `request_only` — no inventory check; manual review (safe default)
- `manual_availability` — calendar-based; still manual confirm
- `instant_manual_inventory` — auto-hold on checkout; partner confirms

**15-status booking lifecycle:**
`pending` → `held` → `confirmed` → `declined` → `counter_proposed` → `counter_accepted` → `counter_rejected` → `cancelled_by_guest` → `cancelled_by_partner` → `cancelled` → `expired` → `no_show` → `checked_in` → `checked_out` → `completed`

**Key admin RPCs:**
- `admin_search_places_for_booking(token, query)` — property search (also used for token verification)
- `admin_get_place_booking_config(token, place_id)` — full config payload
- `admin_configure_place_booking(token, place_id, …19 params…)` — property setup
- `admin_upsert_room_type(token, id?, …)` — room CRUD
- `admin_upsert_rate_plan(token, id?, …)` — rate plan CRUD
- `admin_set_availability(token, room_type_id, place_id, dates[], …)` — bulk calendar upsert
- `admin_upsert_cancellation_policy(token, id?, …)` — policy CRUD

**Key partner RPCs:**
- `get_partner_bookings_v2(token, status, type, from, to, guest_name, limit, offset)`
- `partner_update_booking(token, booking_id, action, data jsonb)` — unified action handler
- `export_partner_bookings(token, from, to)` — CSV export source
- `get_booking_detail_by_token(token)` — full booking detail with timeline

**Guest RPCs:**
- `search_stay_availability(place_id, check_in, check_out, adults, children, rooms)`
- `create_inventory_hold / release_inventory_hold`
- `cleanup_expired_holds()` — cron-suitable cleanup

> **Run this migration in Supabase SQL editor before deploying the Phase 2 HTML pages.**

---

#### 2. `partner-bookings.html` (1,217 lines) — Full rewrite
Professional partner booking operations dashboard:
- Table-driven booking list with status/type/date filters and search
- Drawer UI for booking detail (guest info, rooms, notes, payment tracking)
- Audit timeline panel showing all status changes
- Bulk actions for common transitions (confirm, decline, check-in, check-out)
- CSV export via `export_partner_bookings`
- Pagination (25 per page)
- All 15 statuses with color-coded pills

#### 3. `booking.html` (882 lines) — Enhanced
Partner booking action page (linked from email notifications):
- Full 15-status display and action buttons
- Manual payment/deposit tracking fields
- Audit timeline
- Backward-compatible: tries `get_booking_detail_by_token` first; catches error `42883` (function not found) and falls back to legacy `get_booking_by_token`

#### 4. `admin-booking-setup.html` (1,604 lines) — New file
5-tab admin property configurator:

| Tab | Purpose | Key RPC |
|-----|---------|---------|
| Setup | Booking mode, contact, policies, deposit | `admin_configure_place_booking` |
| Rooms | Room types with inline edit forms | `admin_upsert_room_type` |
| Rates | Rate plans grouped by room type | `admin_upsert_rate_plan` |
| Availability | 60-day calendar grid, bulk editor | `admin_set_availability` |
| Policies | Cancellation policies per property/rate | `admin_upsert_cancellation_policy` |

Auth: token entered in gate → stored in `localStorage.troddr_admin_token` (⚠️ should be `sessionStorage` — see Remaining Tasks).

---

## Files Modified / Created (This Phase)

| File | Status | Notes |
|------|--------|-------|
| `supabase/hotel-booking-infrastructure.sql` | Created | ~1,300-line idempotent migration |
| `partner-bookings.html` | Full rewrite | Professional ops dashboard |
| `booking.html` | Enhanced | Timeline + 15 statuses + backward compat |
| `admin-booking-setup.html` | Created | 5-tab property configurator |

---

## Remaining Tasks

### 1. `admin.html` — Unified Admin Dashboard (NOT YET CREATED)

The user requested consolidation of all three admin pages into one dashboard at `troddr.com/admin`. This file **does not exist yet** and is the primary pending deliverable.

**Requirements:**
- Single auth gate; one token works for all sections
- Fix the billing login bug (see Architecture section below)
- Three sections: **Review | Billing | Bookings**
- Top-level section nav (`section-tab` buttons)
- Lazy-load each section's data when first activated
- Sign out clears `sessionStorage` and returns to gate

**Planned ID namespacing (required — conflicts exist):**

| Section | Panel ID prefix | Tab button class |
|---------|----------------|-----------------|
| Review | `rv-{panel}` | `r-tab` |
| Billing | `bl-{panel}` | `b-tab` |
| Bookings | `bk-{panel}` | `bk-tab` |

**Billing panels (prefixed `bl-`):**
`bl-review`, `bl-companies`, `bl-invoice`, `bl-requests`, `bl-setup`, `bl-notifications`, `bl-settings`, `bl-audit`

**Review panels (prefixed `rv-`):**
`rv-specials`, `rv-submissions`, `rv-messages`, `rv-updates`

**Bookings panels (prefixed `bk-`):**
`bk-setup`, `bk-rooms`, `bk-rates`, `bk-availability`, `bk-policies`

**Section containers:**
`<section id="sec-review">`, `<section id="sec-billing">`, `<section id="sec-bookings">`

**Scoped tab switch functions:**
`reviewSwitchTab(key)`, `billingSwitchTab(key)`, `bookingSwitchTab(key)`

**Boot flow:**
1. Check `sessionStorage.troddr_admin_token`
2. If found → call `admin_search_places_for_booking(token, '')` to verify token is valid
3. On success → show `#main`, hide `#gate`, default to Review section
4. On failure → clear token, show gate
5. On submit → store token in `sessionStorage`, re-run boot

**External scripts needed:**
- `js/billing-shared.js` (exposes `window.BillingShared` / `BS`) — used by billing section
- `js/partner-auth.js` — used by billing section

---

### 2. Fix `admin-billing.html` standalone login bug (if keeping the file)

Root cause in `admin-billing.html` lines ~8-9:
```javascript
const SUPABASE_URL  = (window.__ENV__ && window.__ENV__.SUPABASE_URL)  || (window.location.origin + '/api/sb');
const SUPABASE_ANON = (window.__ENV__ && window.__ENV__.SUPABASE_ANON) || '';
```
`window.__ENV__` is never set → falls back to wrong URL and empty ANON key.

**Fix:** Replace with hardcoded credentials (same as `admin-review.html`):
```javascript
const SUPABASE_URL  = 'https://rprpwudhplodaqmmwqkf.supabase.co';
const SUPABASE_ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJwcnB3dWRocGxvZGFxbW13cWtmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTAyODcyODksImV4cCI6MjA2NTg2MzI4OX0.lNL6YZQqZgbsQRJyRAXpaWMC4LxncvPPyXNP1qopTFk';
```

---

### 3. Fix `sessionStorage` vs `localStorage` mismatch

- `admin-review.html` — uses `sessionStorage.troddr_admin_token` ✓
- `admin-billing.html` — uses `sessionStorage.troddr_admin_token` ✓
- `admin-booking-setup.html` — uses `localStorage.troddr_admin_token` ✗ (should be `sessionStorage`)

The unified `admin.html` should use `sessionStorage` consistently throughout.

---

## Important Architectural Decisions

### Auth model
- **Admin:** `admin_tokens` table + `_is_admin(token)` helper. Token entered in a UI gate, verified by calling any admin RPC and checking for an error.
- **Partner:** `partner_access_token` column on `places`/`events`, passed as URL param `?token=…`.
- **Guest:** anonymous via Supabase anon key.

### No payment processing
Phase 2 includes manual payment/deposit tracking fields only. No Stripe, no card capture, no payment gateway. This is an explicit constraint — do not add payment processing without explicit approval.

### No external PMS/channel-manager integrations
The DB schema is designed to support them later, but no integrations are built in Phase 2.

### All data access via RPCs only
Never query Supabase tables directly from the frontend. All calls go through `security definer` RPCs granted to `anon`. This is the only public access layer.

### SQL migrations are idempotent
All migrations use `CREATE TABLE IF NOT EXISTS`, `ADD COLUMN IF NOT EXISTS`, `CREATE OR REPLACE FUNCTION`. Safe to re-run.

### Backward compatibility in `booking.html`
Tries `get_booking_detail_by_token` first; catches Postgres error `42883` (function not found) and falls back to legacy `get_booking_by_token`. This ensures the page works before and after the hotel-booking-infrastructure.sql migration is run.

### Static site — no build step
All pages are self-contained HTML files. No bundler, no framework, no transpilation.

---

## Next Steps (Priority Order)

1. **Create `admin.html`** — unified admin dashboard. This is the primary outstanding deliverable. Architecture fully planned (see Remaining Tasks above). Merge content from `admin-review.html` (773 lines), `admin-billing.html` (1,621 lines), and `admin-booking-setup.html` (1,604 lines).

2. **Run `hotel-booking-infrastructure.sql`** in the Supabase SQL editor if not yet done.

3. **Test the unified admin login** with the existing admin token to confirm the billing bug is fixed.

4. **Optionally retire** `admin-review.html`, `admin-billing.html`, and `admin-booking-setup.html` once `admin.html` is live — or update links to redirect to `admin.html`.

5. **Future phases** (not in scope yet):
   - Payment processing integration
   - External PMS/channel-manager integrations
   - Guest-facing booking flow (search → hold → checkout)
   - Automated email notifications for booking status changes

---

## Key Constants

```javascript
// Correct Supabase credentials — use these in all admin pages
const SUPABASE_URL  = 'https://rprpwudhplodaqmmwqkf.supabase.co';
const SUPABASE_ANON = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJwcnB3dWRocGxvZGFxbW13cWtmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTAyODcyODksImV4cCI6MjA2NTg2MzI4OX0.lNL6YZQqZgbsQRJyRAXpaWMC4LxncvPPyXNP1qopTFk';

// Token storage
sessionStorage.getItem('troddr_admin_token');
sessionStorage.setItem('troddr_admin_token', token);

// Token verification RPC (lightweight — returns empty array, not error, for valid token with no results)
db.rpc('admin_search_places_for_booking', { p_admin_token: token, p_query: '' })
```
