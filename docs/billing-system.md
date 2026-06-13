# TRODDR Manual Billing & Subscription System

Manual (non-Stripe) billing per **company account**: Troddr issues invoices, the
company pays externally and reports it, a Troddr admin verifies the payment, and
only that verification activates the subscription and entitlements.

## Files

| File | What it is |
| --- | --- |
| `supabase/company-billing.sql` | Schema, RLS, RPCs, status transitions, activation logic, audit log |
| `supabase/company-billing-seed.sql` | Entitlement keys, Founding Partner plans, full product/pricing catalog |
| `supabase/event-insights-tracking.sql` | Canonical event analytics taxonomy + rollup views for paid Event Insights |
| `supabase/tests/company-billing-tests.sql` | Transition + activation tests (transaction-wrapped, rolls back) |
| `company-billing.html` → `/company/billing` | Company dashboard Billing page (Supabase **auth** sign-in) |
| `admin-billing.html` → `/admin/billing` | Admin console (admin **token**, same model as `/admin/review`) |
| `js/billing-shared.js` | Shared formatting, status badges, printable invoice/PDF renderer |

## Deploy

```sh
# 1. Apply migrations in order (Supabase SQL editor or CLI):
supabase db execute --file supabase/company-billing.sql
supabase db execute --file supabase/company-billing-seed.sql
supabase db execute --file supabase/event-insights-tracking.sql

# 2. Run the tests (they roll back, leaving no data):
supabase db execute --file supabase/tests/company-billing-tests.sql

# 3. Deploy the site (vercel.json adds /company/billing and /admin/billing).
```

Prerequisites already in the project: `admin_tokens` + `_is_admin()` from
`supabase/admin-review.sql`, and the `places` table.

## Auth model

- **Company users** sign in with Supabase Auth (email/password) at
  `/company/billing`. An admin pre-registers their email on the company account;
  the first sign-in with that email links the auth user automatically. There is
  no self-serve signup into a company.
- **Troddr admins** use the existing `admin_tokens` bearer token at
  `/admin/billing` (same gate as `/admin/review`).
- **Partner access tokens are untouched** — they remain only for the lightweight
  booking-response links and legacy partner pages.

## The core invariant

> A user-reported payment NEVER activates access.

`submit_payment_confirmation` only moves the invoice to `payment_reported` and
the subscription to `payment_pending_review`. The **only** paths that activate
anything are `admin_review_payment(decision => 'approve')` and
`admin_set_invoice_status(status => 'paid')` (for payments verified out-of-band),
both of which call `_activate_paid_invoice`. This is asserted by the tests.

## Invoice lifecycle

```
draft ──issue──▶ issued ──(due date passes)──▶ overdue
                  │  ▲                            │
        company reports payment ◀─────────────────┘
                  ▼  │ (re-report after reject/clarify)
          payment_reported ──admin approve──▶ paid  ──▶ entitlements + subscription activate
                  │
                  ├──admin reject──▶ rejected (company may re-report)
                  └──admin clarify──▶ stays payment_reported, confirmation flagged
any state ──admin──▶ void (terminal)
```

Transitions are enforced by `_assert_invoice_transition`; anything else raises.
Invoice numbers (`TRODDR-INV-YYYY-0001`, per-year counter) are assigned at
**issue** time so abandoned drafts don't burn numbers.

## Access rules

`company_access_state(company_id)` computes effective access:

- `active` + within `paid_through` → **full**
- `active` + lapsed ≤ 7 days → status `past_due`, access **read_only**
- `active` + lapsed > 7 days → status `read_only`, access **read_only**
- `invoice_issued` / `payment_pending_review` → full only while still inside a
  previously paid window (renewals don't interrupt access; new accounts get none)
- `expired` / `canceled` / `read_only` → **read_only**

`company_has_entitlement(company_id, key)` is the feature gate: the entitlement
must be active and unexpired AND the company must have full access.
`dashboard_access` is the one exception — it stays true in read-only mode so
companies can still sign in, see historical data, and pay their invoice.

Renewals resume from the **new** invoice period (`paid_through` jumps to the new
`period_end`). Nothing backfills unpaid gaps; the only paid-through override is
`admin_set_subscription(action => 'adjust_paid_through')`.

Entitlements are **materialized** in `company_entitlements` (sources: `plan`,
`addon`, `manual`) so feature checks never depend on plan names and admins can
audit/adjust each grant.

## Pricing catalog

`subscription_plans` holds the four Founding Partner tiers (Single/Duo/Trio/
Group; monthly + annual prices, included locations/admins). `billing_products`
holds everything else — OTR, Insights, Event products, Carnival, event series,
event insights, premium maps, sponsor products — with fixed prices or min/max
ranges (admin types the agreed price on the line). Push caps live in product
`metadata`. Extra admin seats and onsite support are deliberately request-only.

## Admin console (`/admin/billing`)

- **Payment Review** — pending confirmations with method/date/reference/receipt;
  approve (activates), reject, or request clarification.
- **Companies** — create/edit accounts; attach/detach approved locations (place
  search; the ONLY way locations get attached); manage company users; manual
  subscription controls (activate, read-only, expire, revoke, adjust
  paid-through); grant/revoke individual entitlements; per-company invoices and
  audit history.
- **Invoice Generator** — pick company, add plan lines (auto-priced by cycle,
  auto-period), catalog products, or custom lines; discounts, notes, payment
  instructions, internal notes; save draft → issue; printable PDF.
- **Requests** — company requests for extra admins/insights/events/sponsor
  products; mark in-progress/resolved, then quote via the generator.
- **Audit Log** — every admin/company/system billing action.

## Company Billing page (`/company/billing`)

Shows plan, billing cycle, subscription status, paid-through, included vs
attached locations, admin seats used, active add-ons/entitlements, a read-only
banner when inactive, and all issued invoices with payment-confirmation status.
Actions: view/download invoice PDF, **Confirm Payment** (method, date,
reference, optional receipt upload to the `payment-receipts` bucket, notes), and
request buttons for admins/insights/event coverage/sponsor products. There is
intentionally **no** "add location" action.

## Event Insights collection

`event_analytics_events` has a fixed, check-constrained taxonomy covering the
full required list (event opens, every tab view, interested/going/went, tickets,
schedule saves, map/marker/vendor interactions, vendor/sponsor/band/pass
metrics, activation check-ins/redemptions, outbound links with context, push
sent/opened with category). Clients log through `track_event_metric(...)` (anon
or authed; never throws to the caller).

Rollups (granted to `authenticated` for entitlement-gated reporting surfaces):

- `event_analytics_rollup` — per event × metric, totals + unique attendees
- `event_series_rollup` — parent event + children via `events.parent_event_id`
- `sponsor_analytics_rollup` and `sponsor_activation_funnel` — per-sponsor
  rollups and view → click → check-in → redemption funnels
- `event_retention_30d` — attendees active in the 30 days after the event

`event_push_notifications` records sends with category
(reminder/promo/logistics/emergency); `event_push_cap_usage(event_id)` counts
only reminder/promo against the plan cap (logistics/emergency are exempt but
must be categorized and approved).

## Typical flow (happy path)

1. Admin creates the company, adds the owner's email, attaches approved locations.
2. Admin builds the invoice (e.g. Duo annual + Location Insights), saves draft, issues it.
3. Owner signs in at `/company/billing`, downloads the PDF, pays by bank transfer.
4. Owner clicks **Confirm Payment** → invoice `payment_reported`. Still no access.
5. Admin sees it in **Payment Review**, checks the bank statement, approves.
6. Invoice → `paid`; subscription → `active` with `paid_through`; plan + add-on
   entitlements activate; everything lands in the audit log.

---

## Business Operations Layer (follow-up)

Added by `supabase/company-billing-ops.sql` (run after the three files above),
tested by `supabase/tests/company-billing-ops-tests.sql`.

### Real commercial entities
`company_accounts` now carries `account_type` (hospitality_group / event_host /
sponsor / mixed) and `source_type`/`source_id` (place_group / event_organizer /
sponsor / manual). The admin "New company" form creates companies *from* a
hospitality partner or an event (creating from an event organizer auto-attaches
that event as `host`). Companies are never abstract billing shells.

### Company events
`company_events` links companies to events with `relationship_type` (host,
organizer, sponsor, vendor, production_partner), admin-only attach/detach
(`admin_attach_event` supports event series via `p_include_children`),
plus per-event `package_product_code` and `comped`. Comping requires a written
reason. Company users have no write path to locations or events — enforced by
RLS and verified by tests.

### Event dashboard billing
`get_event_billing_by_token` (partner event token) powers the new Billing
section in `partner-event.html` (via `js/event-billing-widget.js`): host
company, package (paid/assigned/comped), insights + premium map status,
sponsor products, push cap vs usage (reminder/promo only count; logistics/
emergency exempt), open invoice, access state, and a link to `/company/billing`.
A comped hub always shows insights as **not purchased** unless separately paid.

### Payment instructions
`payment_instructions` table (bank, account name, branch, currency, type,
number, SWIFT, notes, active, order) managed from the admin Settings tab.
Seeded with CIBC Caribbean / TRODDR Limited / Manor Park Branch USD Savings +
JMD Chequing **without account numbers** — admins enter numbers in the panel
only. Invoice PDFs show the accounts matching the invoice currency (both if
none match), and fall back to the payment note when a number is blank.

### Invoice copy + settings
`billing_settings` holds editable `invoice_footer_copy` (seeded with the four
default lines), `renewal_reminder_days` (30), `receipt_max_mb` (10), and
`receipt_allowed_types`. All editable in the admin Settings tab.

### Onboarding
`company_accounts.onboarding_status`: not_started → pending_company_review →
billing_info_required → complete. Admin-created companies start at
`billing_info_required`; the company dashboard gates on it and shows the
confirm-billing-details form (legal name, trading name, contacts, country,
address, optional tax ID, preferred currency, business type, role). Users with
no company submit a `company_setup_requests` row (pending_review) which admins
approve (creates company + first admin user) or reject from the Setup tab.

### Notifications
`billing_notifications` rows are written by triggers on invoices, payment
confirmations, subscriptions, and requests (issued/overdue/reported/approved/
rejected/clarification/activated/read-only/renewal/request/setup). Email
sending stays behind this abstraction — the admin Notifications tab is the
queue (mark sent / dismiss); a future mailer drains `status='pending'`.

### Renewals
`admin_run_billing_maintenance` marks past-due invoices overdue and moves
subscriptions lapsed beyond the 7-day grace to read-only. The Review tab lists
companies inside the reminder window; `admin_generate_renewal_invoice` drafts
the renewal (continues from paid_through+1 when current, starts today when
lapsed — never backfills the gap).

### Receipts
The `payment-receipts` bucket is now **private**. Company members upload/read
only within their own `<company_id>/...` folder (pdf/jpg/png enforced by
storage policy AND server-side, size capped by settings; metadata stored on the
confirmation). Admins open receipts through the `admin-receipt-url` edge
function (validates the admin token, mints a 10-minute signed URL). Deploy it:
`supabase functions deploy admin-receipt-url`.

### Requests
`company_requests` now: types extra_admins / location_insights /
company_insights / event_coverage / event_insights / sponsor_activation /
sponsor_report / billing_help; statuses new → in_review → quoted → invoiced →
completed | rejected (transitions enforced); optional related location/event
(validated to belong to the company); admin notes. The admin Requests tab walks
the workflow and jumps into the invoice generator.

### Reason-required overrides
The server refuses without a note: manual activation (comped access),
paid-through adjustment, revoke, entitlement grant/revoke, invoice void,
payment rejection, clarification, and comped event packages. All land in
`billing_audit_log` together with billing-info changes, payment-instruction
changes, setting changes, and event/location attach/detach.

---

## Loyalty plan model (follow-up)

Added by `supabase/company-billing-loyalty.sql` (run after the ops layer and
`billing-specials.sql`), tested by
`supabase/tests/company-billing-loyalty-tests.sql`.

Loyalty/Foundation partners are billed differently from the founding-partner
subscription tiers: their plan centres on an **included specials allowance**
(2 standard specials per location per billing cycle), with extras rolling up as
billable. This is modelled as a first-class plan in the company-account system:

- `subscription_plans` gains `plan_family` (standard / loyalty / event / sponsor)
  and `specials_per_location`. The four Founding Partner / Loyalty tiers and a new
  single-location **Foundation Loyalty** plan (`foundation_loyalty`, J$, no
  recurring fee) are `plan_family = 'loyalty'` with a 2/location allowance.
- `company_specials_usage(company_id)` computes, for the current cycle and each
  approved location: the included allowance, specials used (pending/approved,
  non-void), and billable extras — reading the existing `public.specials`
  billing columns from `billing-specials.sql`.
- `get_company_billing()` and `get_partner_billing_by_token()` add the plan's
  `plan_family`/`specials_per_location` and a `specials` block (only for
  loyalty-family plans).

### Billing pages for loyalty partners

Both `/company/billing` (authenticated) and `/partner/billing` (read-only,
token) render a **Specials Allowance** section — per-location usage bars
(used vs included, with extras flagged) and a billable-extras pill — plus
**Plan Rules** cards (Included allowance / Extra Standard / Featured), driven by
`BillingShared.loyaltyAllowanceHtml()` and `planRulesCardsHtml()`. The section
only appears when the company is on a loyalty-family plan. `/partner/billing`
was rebuilt from the old static placeholder into a real read-only view (plan,
status, paid-through, locations, events, entitlements, invoices with PDF) that
hands off to `/company/billing` for any action.

---

## Interactive onboarding & personalized quote (follow-up)

Added by `supabase/company-onboarding.sql` (run after `company-billing-loyalty.sql`),
tested by `supabase/tests/company-onboarding-tests.sql`. New pages: `onboarding.html`
(`/onboarding`), helper `js/onboarding-recommend.js`.

Replaces the bare "admin pre-registers email → user signs in → confirms billing" path
with a guided invite → signup → confirm → profile → value → personalized quote →
dashboard flow.

### Invite links
`company_onboarding_invites` (token, company, email, claimable snapshot, expiry, status).
Admin generates one from the company detail panel in `/admin/billing`:
`admin_create_onboarding_invite(token, company, email, place_ids[], event_ids[], days)`
registers the owner email (`admin_upsert_company_user`), **pre-attaches** the chosen
places/events (admin attachment = the approval), and returns `/onboarding?invite=…`.
`admin_revoke_onboarding_invite` revokes pending links. `get_onboarding_invite` (anon)
powers the branded welcome screen; revoked/expired/used links are rejected.

### The wizard (`onboarding.html`)
Steps: Welcome → Create account (`auth.signUp` + `accept_onboarding_invite`, which links
the new auth user to the pre-created company via `_resolve_company_user`) → Confirm
businesses → Profiling activity (`submit_onboarding_profile`) → Billing details
(reuses `submit_company_onboarding`) → tailored "What Troddr offers" → personalized quote
→ dashboard. Supports **resume mode**: an authed user with incomplete onboarding hitting
`/company/billing` is redirected to `/onboarding` (no token needed). Email-confirmation
projects get a "confirm then reopen the link" state.

### Recommendation + quote
`js/onboarding-recommend.js` maps profile + attached footprint → a loyalty plan tier
(1→foundation_loyalty/fp_single, 2→fp_duo, 3→fp_trio, 4-5→fp_group) + event/insights/
sponsor products, priced from `get_billing_catalog_for_quote()` (authenticated catalog
read), with ranged products shown "from $X". Add-ons are toggleable; the total
recalculates live.

`submit_onboarding_quote(selection)` is the paywall: it **re-prices everything
server-side from the catalog** (ignores client-sent prices; ranged → `min_amount`),
auto-creates a **DRAFT** invoice via the shared internal `_save_invoice()` helper, records
a `company_requests` row, writes a notification, and sets `onboarding_status='complete'`.
It never issues the invoice and never activates access — an admin reviews and issues it,
the company pays, and admin verification activates entitlements (the core invariant
holds; asserted by the tests). Until then the dashboard is read-only.

`admin_get_company` now also returns `onboarding` (status/profile/quote) and `invites`,
surfaced in the admin company detail panel.
