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
