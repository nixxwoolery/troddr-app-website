/* ============================================================
 * TRODDR Onboarding — recommendation engine
 * ------------------------------------------------------------
 * Pure functions: map a profile (the wizard answers) + the
 * businesses already attached to the company, against the
 * billing catalog, into a recommended plan + add-on products
 * with an estimated total. No DOM, no network — easy to reason
 * about and verify. submit_onboarding_quote re-prices everything
 * server-side from the catalog, so this is purely advisory.
 * ============================================================ */
(function () {
  // Loyalty tier by number of locations.
  function planForLocations(n, plans) {
    const has = (k) => plans.some((p) => p.key === k);
    if (n <= 1) return has('foundation_loyalty') ? 'foundation_loyalty' : 'fp_single';
    if (n === 2) return 'fp_duo';
    if (n === 3) return 'fp_trio';
    return 'fp_group'; // 4–5 (and 5+, with a note)
  }

  // Event scale -> product code.
  const EVENT_SCALE_PRODUCT = {
    lite: 'event_lite',
    pro: 'event_pro',
    major: 'major_event_hub',
    flagship: 'flagship_event',
    series: 'event_series_hub',
    carnival: 'carnival_hub',
  };

  /* profile fields (all optional, sensible defaults):
   *   location_count int
   *   does_events bool, event_scale: lite|pro|major|flagship|series|carnival
   *   wants_premium_map bool
   *   wants_event_insights bool
   *   sponsor_interest bool
   *   wants_insights: 'none' | 'location' | 'company'
   *   billing_cycle: 'annual' | 'monthly'
   * attached: { locations: int, events: int }  (from the invite)
   */
  function recommend(profile, attached, catalog) {
    profile = profile || {};
    attached = attached || { locations: 0, events: 0 };
    const plans = (catalog && catalog.plans) || [];
    const products = (catalog && catalog.products) || [];
    const productByCode = {};
    products.forEach((p) => { productByCode[p.code] = p; });

    const cycle = profile.billing_cycle === 'monthly' ? 'monthly' : 'annual';
    // Use the larger of stated locations and what's actually attached.
    const locCount = Math.max(
      Number(profile.location_count) || 0,
      Number(attached.locations) || 0,
      1
    );

    const lines = [];
    let total = 0;
    let hasEstimate = false;

    // ---- Plan ----
    const planKey = planForLocations(locCount, plans);
    const plan = plans.find((p) => p.key === planKey);
    if (plan) {
      const unit = cycle === 'monthly' ? Number(plan.monthly_price) : Number(plan.annual_price);
      const amount = unit || 0; // allowance-only plans have no fee
      total += amount;
      lines.push({
        kind: 'plan',
        key: plan.key,
        label: plan.name,
        sublabel: cycle === 'monthly' ? 'billed monthly' : 'billed annually',
        amount,
        estimate: false,
        currency: plan.currency,
        note: locCount > (plan.included_locations || 0)
          ? `Covers ${plan.included_locations} locations — you mentioned ${locCount}; we'll confirm the right tier.`
          : null,
      });
    }

    function addProduct(code, qty, why) {
      const p = productByCode[code];
      if (!p) return;
      const q = qty || 1;
      const ranged = p.unit_amount == null;
      const unit = ranged ? Number(p.min_amount || 0) : Number(p.unit_amount || 0);
      const amount = unit * q;
      total += amount;
      if (ranged) hasEstimate = true;
      lines.push({
        kind: 'product',
        code: p.code,
        label: p.name + (q > 1 ? ` ×${q}` : ''),
        sublabel: why || p.description,
        amount,
        estimate: ranged,
        currency: p.currency,
      });
    }

    // ---- Insights ----
    if (profile.wants_insights === 'company') {
      addProduct(cycle === 'monthly' ? 'company_insights_monthly' : 'company_insights_annual', 1,
        'Company-wide analytics rollup');
    } else if (profile.wants_insights === 'location') {
      addProduct(cycle === 'monthly' ? 'location_insights_monthly' : 'location_insights_annual',
        locCount, `Per-location analytics × ${locCount}`);
    }

    // ---- Events ----
    if (profile.does_events && profile.event_scale) {
      const code = EVENT_SCALE_PRODUCT[profile.event_scale];
      if (code) addProduct(code, 1, 'Troddr Events app for your event');
      if (profile.wants_event_insights) {
        // Major/Flagship hubs already bundle insights.
        if (!['major', 'flagship', 'carnival'].includes(profile.event_scale)) {
          addProduct('event_insights_pro', 1, 'Live dashboard + post-event report');
        }
      }
      if (profile.wants_premium_map && profile.event_scale !== 'flagship') {
        addProduct('map_vendor_floor', 1, 'Vendor / floor-plan map');
      }
    }

    // ---- Sponsor ----
    if (profile.sponsor_interest) {
      addProduct('sponsor_listing', 1, 'Sponsor activation listing');
    }

    return {
      billing_cycle: cycle,
      plan_key: planKey,
      lines,
      total,
      has_estimate: hasEstimate,
      currency: (plan && plan.currency) || (lines[0] && lines[0].currency) || 'USD',
      // selection payload for submit_onboarding_quote (server re-prices)
      selection: {
        plan_key: planKey,
        billing_cycle: cycle,
        products: lines.filter((l) => l.kind === 'product').map((l) => ({ code: l.code, quantity: 1 })),
      },
    };
  }

  window.OnboardingRecommend = { recommend, planForLocations };
})();
