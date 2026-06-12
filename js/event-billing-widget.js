/* ============================================================
 * TRODDR Event Dashboard — Billing widget
 * ------------------------------------------------------------
 * Renders a read-only billing summary inside the token-based
 * event dashboard (partner-event.html): host company, event
 * package (incl. comped founding-partner hubs), insights/map
 * status, sponsor products, push cap usage, open invoice, and
 * the access state — with a link back to /company/billing.
 *
 * Free event access and paid insights/reporting are shown as
 * SEPARATE line states on purpose: a comped hub never implies
 * paid insights.
 *
 * Usage: include after troddr-config.js + supabase-js on a page
 * with <section id="billing"><div id="billing-body"></div></section>.
 * Reads the partner event token from PartnerAuth or ?token=.
 * ============================================================ */
(function () {
  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
  }
  function money(n, cur) {
    try {
      return new Intl.NumberFormat('en-US', { style: 'currency', currency: cur || 'USD' }).format(Number(n || 0));
    } catch (e) { return (cur || 'USD') + ' ' + Number(n || 0).toFixed(2); }
  }

  const STATE_META = {
    comped:    { label: 'Comped / Free', bg: '#e8f4ff', fg: '#0077CC' },
    active:    { label: 'Active',        bg: '#e6f5ec', fg: '#1a7f4e' },
    read_only: { label: 'Read-Only',     bg: '#fff4e0', fg: '#b86e00' },
    inactive:  { label: 'Inactive',      bg: '#fdecea', fg: '#c0392b' },
  };
  const PAID_META = {
    purchased:     { label: 'Purchased',     bg: '#e6f5ec', fg: '#1a7f4e' },
    included:      { label: 'Included',      bg: '#e6f5ec', fg: '#1a7f4e' },
    not_purchased: { label: 'Not purchased', bg: '#fff4e0', fg: '#b86e00' },
    not_included:  { label: 'Not included',  bg: '#f8f9fa', fg: '#666' },
  };

  function chip(meta) {
    return `<span style="display:inline-block; font-size:10px; font-weight:700; letter-spacing:0.08em;
      text-transform:uppercase; padding:3px 9px; border-radius:100px;
      background:${meta.bg}; color:${meta.fg};">${esc(meta.label)}</span>`;
  }

  function row(label, valueHtml) {
    return `<div style="display:flex; justify-content:space-between; align-items:center; gap:12px;
      padding:10px 2px; border-bottom:1px solid #f0f0f0; font-size:13px;">
      <span style="color:#666;">${esc(label)}</span><span style="text-align:right;">${valueHtml}</span></div>`;
  }

  async function load() {
    const host = document.getElementById('billing-body');
    if (!host) return;

    const token = (window.PartnerAuth && window.PartnerAuth.getToken({ require: false }))
      || new URLSearchParams(location.search).get('token') || '';
    if (!token || !window.supabase || !window.__ENV__) return;

    const client = window.supabase.createClient(window.__ENV__.SUPABASE_URL, window.__ENV__.SUPABASE_ANON);
    const { data, error } = await client.rpc('get_event_billing_by_token', { p_token: token });
    if (error) {
      console.warn('[event-billing] load failed:', error);
      host.innerHTML = '<div style="padding:16px; background:#f8f9fa; border-radius:10px; color:#666; font-size:13px;">Billing details are unavailable right now.</div>';
      return;
    }
    if (!data || data.ok === false) {
      host.innerHTML = `<div style="padding:16px; background:#f8f9fa; border-radius:10px; color:#666; font-size:13px;">
        ${esc((data && data.message) || 'This event is not attached to a company billing account yet. Contact TRODDR to set one up.')}
      </div>`;
      return;
    }

    const access = data.access || {};
    const state = STATE_META[access.dashboard_state] || STATE_META.inactive;
    const pkg = data.package;
    const push = data.push || {};
    const inv = data.open_invoice;
    const sponsor = data.sponsor_products || [];

    host.innerHTML = `
      <div style="background:#fff; border:1px solid #e8e8e8; border-radius:16px; padding:18px 20px;">
        ${row('Event host company', `<b>${esc(data.company.name)}</b>
          <span style="color:#999; font-size:11px;"> (${esc(data.company.relationship_type)})</span>`)}
        ${row('Dashboard access', chip(state)
          + (access.dashboard_state === 'comped'
             ? '<div style="font-size:11px; color:#999; margin-top:3px;">Free event hub — insights/reporting are billed separately.</div>' : ''))}
        ${row('Event package', pkg
          ? `<b>${esc(pkg.name)}</b> ${pkg.comped ? chip(STATE_META.comped) : `<span style="color:#999; font-size:11px;">(${esc(pkg.source)})</span>`}`
          : '<span style="color:#999;">None yet</span>')}
        ${row('Event insights', chip(PAID_META[data.insights_status] || PAID_META.not_purchased))}
        ${row('Premium event map', chip(PAID_META[data.premium_map_status] || PAID_META.not_included))}
        ${row('Sponsor activation products', sponsor.length
          ? sponsor.map((s) => `<div>${esc(s.description)} · <b>${money(s.amount)}</b></div>`).join('')
          : '<span style="color:#999;">None</span>')}
        ${row('Push notifications', push.cap != null
          ? `<b>${esc(push.used)} of ${esc(push.cap)}</b> <span style="color:#999; font-size:11px;">(reminder/promo count against the cap; logistics/emergency exempt)</span>`
          : `<b>${esc(push.used || 0)} sent</b> <span style="color:#999; font-size:11px;">(no package cap set)</span>`)}
        ${inv ? row('Open invoice', `<b>${esc(inv.invoice_number)}</b> · ${money(inv.total, inv.currency)} ·
          <span style="text-transform:uppercase; font-size:10px; font-weight:700; color:#b86e00;">${esc(inv.status)}</span>`) : ''}
        <div style="margin-top:14px; display:flex; justify-content:space-between; align-items:center; gap:12px; flex-wrap:wrap;">
          <span style="font-size:12px; color:#999;">Invoices and payment confirmations live in the company dashboard.</span>
          <a href="${esc(data.company_billing_url || '/company/billing')}"
             style="display:inline-flex; align-items:center; background:#0077CC; color:#fff; padding:9px 14px;
                    border-radius:8px; font-size:12px; font-weight:700; text-decoration:none;">
            Open Company Billing →</a>
        </div>
      </div>`;
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', load);
  else load();
})();
