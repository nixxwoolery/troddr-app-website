/* ============================================================
 * TRODDR Billing — shared helpers
 * Used by company-billing.html (company dashboard) and
 * admin-billing.html (Troddr admin console).
 * ============================================================ */
(function () {
  if (window.BillingShared) return;

  function money(amount, currency) {
    const n = Number(amount || 0);
    const cur = currency || 'USD';
    try {
      return new Intl.NumberFormat('en-US', {
        style: 'currency', currency: cur, minimumFractionDigits: 2,
      }).format(n);
    } catch (e) {
      return cur + ' ' + n.toFixed(2);
    }
  }

  function fmtDate(value) {
    if (!value) return '—';
    const d = new Date(value.length === 10 ? value + 'T12:00:00' : value);
    if (isNaN(d)) return value;
    return d.toLocaleDateString('en-US', { year: 'numeric', month: 'short', day: 'numeric' });
  }

  const INVOICE_STATUS = {
    draft:            { label: 'Draft',            cls: 'neutral' },
    issued:           { label: 'Issued',           cls: 'info' },
    payment_reported: { label: 'Payment Reported', cls: 'warn' },
    paid:             { label: 'Paid',             cls: 'good' },
    rejected:         { label: 'Rejected',         cls: 'bad' },
    void:             { label: 'Void',             cls: 'neutral' },
    overdue:          { label: 'Overdue',          cls: 'bad' },
  };

  const SUBSCRIPTION_STATUS = {
    invoice_issued:         { label: 'Invoice Issued',   cls: 'info' },
    payment_pending_review: { label: 'Payment In Review', cls: 'warn' },
    active:                 { label: 'Active',           cls: 'good' },
    past_due:               { label: 'Past Due',         cls: 'warn' },
    read_only:              { label: 'Read-Only',        cls: 'bad' },
    expired:                { label: 'Expired',          cls: 'bad' },
    canceled:               { label: 'Canceled',         cls: 'neutral' },
  };

  const CONFIRMATION_STATUS = {
    submitted:           { label: 'Under Review',          cls: 'warn' },
    approved:            { label: 'Verified',              cls: 'good' },
    rejected:            { label: 'Rejected',              cls: 'bad' },
    needs_clarification: { label: 'Clarification Needed',  cls: 'warn' },
  };

  function statusMeta(map, status) {
    return map[status] || { label: status || '—', cls: 'neutral' };
  }

  function esc(s) {
    return String(s == null ? '' : s)
      .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;');
  }

  /* Resolve which payment-instruction records apply to an invoice.
   * `instructions` is either an array or {USD:[...],JMD:[...]} from
   * get_company_billing. Shows the invoice currency's accounts; if
   * none exist for that currency, shows everything active. */
  function instructionsForInvoice(inv, instructions) {
    if (!instructions) return [];
    if (Array.isArray(instructions)) {
      const match = instructions.filter((i) => i.currency === inv.currency);
      return match.length ? match : instructions;
    }
    const match = instructions[inv.currency] || [];
    if (match.length) return match;
    return [].concat(instructions.USD || [], instructions.JMD || []);
  }

  function bankBlockHtml(list) {
    if (!list || !list.length) return '';
    return list.map((b) => `
      <div class="bank">
        <div class="bank-name">${esc(b.bank_name)} — ${esc(b.currency)} ${esc(b.account_type || '')}</div>
        <div class="bank-kv"><span>Account name</span><span>${esc(b.account_name)}</span></div>
        ${b.branch_name ? `<div class="bank-kv"><span>Branch</span><span>${esc(b.branch_name)}</span></div>` : ''}
        ${b.account_number
          ? `<div class="bank-kv"><span>Account number</span><span>${esc(b.account_number)}</span></div>`
          : (b.payment_notes ? `<div class="bank-kv"><span>Account number</span><span>${esc(b.payment_notes)}</span></div>` : '')}
        ${b.routing_or_swift ? `<div class="bank-kv"><span>Routing/SWIFT</span><span>${esc(b.routing_or_swift)}</span></div>` : ''}
        ${b.account_number && b.payment_notes ? `<div class="bank-note">${esc(b.payment_notes)}</div>` : ''}
      </div>`).join('');
  }

  const DEFAULT_FOOTER_COPY = [
    'Access is activated after payment verification by TRODDR.',
    'Please include the invoice number in your payment reference.',
    'After payment, return to your dashboard and submit your payment confirmation.',
    'User-reported payment does not activate access until reviewed by TRODDR.',
  ];

  /* Printable invoice document. `inv` is the invoice jsonb from the
   * RPCs (with line_items), `company` is { name, billing_email }.
   * `opts` (optional): { instructions: array | {USD,JMD}, footerCopy: [..] }.
   * Returns a full HTML document string. */
  function invoiceDocument(inv, company, opts) {
    opts = opts || {};
    const banks = instructionsForInvoice(inv, opts.instructions);
    const footerCopy = (opts.footerCopy && opts.footerCopy.length) ? opts.footerCopy : DEFAULT_FOOTER_COPY;
    const meta = statusMeta(INVOICE_STATUS, inv.status);
    const lines = (inv.line_items || []).map((li) => `
      <tr>
        <td>
          <div class="li-desc">${esc(li.description)}</div>
          ${li.period_start || li.period_end
            ? `<div class="li-period">${fmtDate(li.period_start)} – ${fmtDate(li.period_end)}</div>` : ''}
        </td>
        <td class="num">${esc(li.quantity)}</td>
        <td class="num">${money(li.unit_amount, inv.currency)}</td>
        <td class="num">${money(li.amount, inv.currency)}</td>
      </tr>`).join('');

    const discountRow = Number(inv.discount_amount) > 0 ? `
      <tr class="totals">
        <td colspan="3">Discount${inv.discount_note ? ' — ' + esc(inv.discount_note) : ''}</td>
        <td class="num">−${money(inv.discount_amount, inv.currency)}</td>
      </tr>` : '';

    return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8" />
<title>${esc(inv.invoice_number || 'Invoice')} · TRODDR</title>
<style>
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body { font-family: 'Poppins', Inter, system-ui, sans-serif; color: #111; padding: 48px; font-size: 13px; line-height: 1.55; }
  .top { display: flex; justify-content: space-between; align-items: flex-start; margin-bottom: 36px; }
  .logo { font-size: 30px; font-weight: 800; color: #0077CC; letter-spacing: -1px; }
  .logo small { display: block; font-size: 11px; font-weight: 500; color: #666; letter-spacing: 0.04em; margin-top: 2px; }
  .inv-id { text-align: right; }
  .inv-id h1 { font-size: 20px; letter-spacing: -0.3px; }
  .badge { display: inline-block; margin-top: 6px; font-size: 10px; font-weight: 700; letter-spacing: 0.1em; text-transform: uppercase; padding: 4px 10px; border-radius: 4px; background: #f0f0f0; color: #555; }
  .badge.good { background: #e6f5ec; color: #1a7f4e; }
  .badge.warn { background: #fff4e0; color: #b86e00; }
  .badge.bad  { background: #fdecea; color: #c0392b; }
  .meta { display: grid; grid-template-columns: 1fr 1fr; gap: 24px; margin-bottom: 30px; }
  .meta h3 { font-size: 10px; font-weight: 700; letter-spacing: 0.1em; text-transform: uppercase; color: #999; margin-bottom: 6px; }
  .meta .name { font-weight: 700; font-size: 15px; }
  .meta .kv { display: flex; gap: 10px; } .meta .kv span:first-child { color: #666; min-width: 110px; }
  table { width: 100%; border-collapse: collapse; margin-bottom: 8px; }
  th { text-align: left; font-size: 10px; font-weight: 700; letter-spacing: 0.08em; text-transform: uppercase; color: #999; padding: 8px 10px; border-bottom: 2px solid #111; }
  td { padding: 11px 10px; border-bottom: 1px solid #eee; vertical-align: top; }
  th.num, td.num { text-align: right; white-space: nowrap; font-variant-numeric: tabular-nums; }
  .li-desc { font-weight: 600; } .li-period { font-size: 11px; color: #888; margin-top: 2px; }
  tr.totals td { border-bottom: none; padding: 6px 10px; color: #444; }
  tr.grand td { border-top: 2px solid #111; border-bottom: none; font-size: 16px; font-weight: 800; padding-top: 12px; }
  .blocks { margin-top: 30px; display: grid; gap: 18px; }
  .block h3 { font-size: 10px; font-weight: 700; letter-spacing: 0.1em; text-transform: uppercase; color: #999; margin-bottom: 4px; }
  .block p { white-space: pre-wrap; color: #333; }
  .bank { border: 1px solid #eee; border-radius: 8px; padding: 10px 14px; margin-bottom: 8px; }
  .bank-name { font-weight: 700; margin-bottom: 4px; }
  .bank-kv { display: flex; gap: 10px; font-size: 12px; } .bank-kv span:first-child { color: #666; min-width: 120px; }
  .bank-note { font-size: 11px; color: #888; margin-top: 4px; }
  .footer-copy { margin-top: 6px; } .footer-copy li { font-size: 11px; color: #555; margin-left: 16px; line-height: 1.7; }
  .foot { margin-top: 44px; padding-top: 16px; border-top: 1px solid #eee; font-size: 11px; color: #999; text-align: center; }
  @media print { body { padding: 24px; } .no-print { display: none; } }
</style>
</head>
<body>
  <div class="top">
    <div class="logo">troddr<small>TRODDR · Kingston, Jamaica · billing@troddr.com</small></div>
    <div class="inv-id">
      <h1>${esc(inv.invoice_number || 'Draft Invoice')}</h1>
      <span class="badge ${meta.cls}">${esc(meta.label)}</span>
    </div>
  </div>

  <div class="meta">
    <div>
      <h3>Billed To</h3>
      <div class="name">${esc((company && company.name) || '')}</div>
      <div>${esc((company && company.billing_email) || '')}</div>
    </div>
    <div>
      <h3>Invoice Details</h3>
      <div class="kv"><span>Issue date</span><span>${fmtDate(inv.issue_date)}</span></div>
      <div class="kv"><span>Due date</span><span>${fmtDate(inv.due_date)}</span></div>
      ${inv.period_start || inv.period_end
        ? `<div class="kv"><span>Billing period</span><span>${fmtDate(inv.period_start)} – ${fmtDate(inv.period_end)}</span></div>` : ''}
      <div class="kv"><span>Currency</span><span>${esc(inv.currency || 'USD')}</span></div>
    </div>
  </div>

  <table>
    <thead><tr><th>Description</th><th class="num">Qty</th><th class="num">Unit</th><th class="num">Amount</th></tr></thead>
    <tbody>
      ${lines}
      <tr class="totals"><td colspan="3">Subtotal</td><td class="num">${money(inv.subtotal, inv.currency)}</td></tr>
      ${discountRow}
      <tr class="grand"><td colspan="3">Total Due</td><td class="num">${money(inv.total, inv.currency)}</td></tr>
    </tbody>
  </table>

  <div class="blocks">
    ${banks.length ? `<div class="block"><h3>Pay To</h3>${bankBlockHtml(banks)}</div>` : ''}
    ${inv.payment_instructions ? `<div class="block"><h3>Payment Instructions</h3><p>${esc(inv.payment_instructions)}</p></div>` : ''}
    ${inv.notes ? `<div class="block"><h3>Notes</h3><p>${esc(inv.notes)}</p></div>` : ''}
    <div class="block"><h3>How payment works</h3>
      <ul class="footer-copy">${footerCopy.map((l) => `<li>${esc(l)}</li>`).join('')}</ul>
      <p style="margin-top:6px; font-size:11px; color:#888;">No GCT applied.</p>
    </div>
  </div>

  <div class="foot">TRODDR · troddr.com · Made with care in Jamaica</div>
  <script>window.addEventListener('load', function(){ setTimeout(function(){ window.print(); }, 250); });<\/script>
</body>
</html>`;
  }

  function openInvoicePdf(inv, company, opts) {
    const w = window.open('', '_blank');
    if (!w) { alert('Allow pop-ups to download the invoice PDF.'); return; }
    w.document.open();
    w.document.write(invoiceDocument(inv, company, opts));
    w.document.close();
  }

  /* ---- Loyalty plan: specials allowance + plan-rules cards ----
   * `specials` is the company_specials_usage() payload, `plan` is
   * the plan block. Returns HTML for the loyalty billing section.
   * Both /company/billing and /partner/billing render this. */
  function loyaltyAllowanceHtml(plan, specials) {
    const limit = (specials && specials.included_per_location) || (plan && plan.specials_per_location) || 0;
    const locs = (specials && specials.locations) || [];
    const billableTotal = (specials && specials.billable_total) || 0;

    const locRows = locs.length ? locs.map((l) => {
      const used = l.used || 0;
      const within = Math.min(used, limit);
      const over = Math.max(used - limit, 0);
      const pct = limit ? Math.min(100, Math.round((within / limit) * 100)) : 0;
      return `
        <div class="sp-loc">
          <div class="sp-loc-head">
            <span class="sp-loc-name">${esc(l.name)}</span>
            <span class="sp-loc-count">${esc(within)} of ${esc(limit)} included${over ? ` · ${esc(over)} extra` : ''}</span>
          </div>
          <div class="sp-bar"><span style="width:${pct}%"></span></div>
        </div>`;
    }).join('') : '<div class="sp-empty">No locations attached yet.</div>';

    return `
      <div class="sp-allowance">
        <div class="sp-allowance-head">
          <div>
            <div class="sp-allowance-num">${esc(limit)}<span>included specials / location</span></div>
            <div class="sp-allowance-sub">Resets each billing cycle${specials && specials.cycle_end ? ' · cycle ends ' + fmtDate(specials.cycle_end) : ''}</div>
          </div>
          ${billableTotal
            ? `<span class="pill warn">${esc(billableTotal)} billable extra${billableTotal === 1 ? '' : 's'} this cycle</span>`
            : '<span class="pill good">Within allowance</span>'}
        </div>
        <div class="sp-locs">${locRows}</div>
      </div>`;
  }

  function planRulesCardsHtml(plan) {
    const limit = (plan && plan.specials_per_location) || 2;
    return `
      <div class="pr-grid">
        <div class="pr-card">
          <div class="pr-name">Included</div>
          <div class="pr-headline">Allowance</div>
          <div class="pr-price">${limit}<span>/location</span></div>
          <ul class="pr-feat">
            <li>${limit} included standard specials per location</li>
            <li>Allowance resets each billing cycle</li>
            <li>Rejected specials never become billable</li>
            <li>Loyalty program + basic analytics</li>
          </ul>
        </div>
        <div class="pr-card featured">
          <div class="pr-name featured">Extra Standard</div>
          <div class="pr-headline">After included specials</div>
          <div class="pr-price">Quoted<span>/special</span></div>
          <ul class="pr-feat">
            <li>Tracked automatically after the included specials</li>
            <li>Billed to your company account after approval</li>
            <li>Usage separated by location</li>
            <li>Appears on your invoices</li>
          </ul>
        </div>
        <div class="pr-card">
          <div class="pr-name">Featured</div>
          <div class="pr-headline">Hero placement</div>
          <div class="pr-price">Quoted<span>/campaign</span></div>
          <ul class="pr-feat">
            <li>Hero placement on the home screen</li>
            <li>Featured in the weekly newsletter</li>
            <li>Cross-promotion with curated guides</li>
            <li>Full attribution analytics</li>
          </ul>
        </div>
      </div>`;
  }

  // Shared CSS for the loyalty section (injected once).
  function ensureLoyaltyStyles() {
    if (document.getElementById('billing-loyalty-styles')) return;
    const s = document.createElement('style');
    s.id = 'billing-loyalty-styles';
    s.textContent = `
      .sp-allowance{background:#fff;border:1px solid var(--border,#e8e8e8);border-radius:16px;padding:20px 22px;margin-bottom:14px}
      .sp-allowance-head{display:flex;justify-content:space-between;align-items:flex-start;gap:12px;flex-wrap:wrap;margin-bottom:14px}
      .sp-allowance-num{font-size:28px;font-weight:800;letter-spacing:-0.8px;line-height:1;color:var(--blue,#0077CC)}
      .sp-allowance-num span{display:block;font-size:12px;font-weight:600;color:var(--grey-mid,#666);letter-spacing:0;margin-top:4px}
      .sp-allowance-sub{font-size:12px;color:var(--grey-mid,#666);margin-top:6px}
      .sp-locs{display:grid;gap:12px}
      .sp-loc-head{display:flex;justify-content:space-between;gap:10px;font-size:13px;margin-bottom:5px}
      .sp-loc-name{font-weight:600}
      .sp-loc-count{color:var(--grey-mid,#666);font-size:12px}
      .sp-bar{height:7px;background:var(--bg-soft,#f0f0f0);border-radius:100px;overflow:hidden}
      .sp-bar span{display:block;height:100%;background:var(--blue,#0077CC);border-radius:100px}
      .sp-empty{font-size:13px;color:var(--grey-mid,#666);padding:8px 0}
      .pr-grid{display:grid;grid-template-columns:repeat(3,1fr);gap:12px}
      .pr-card{background:#fff;border:1px solid var(--border,#e8e8e8);border-radius:10px;padding:14px 16px;display:flex;flex-direction:column;gap:6px}
      .pr-card.featured{border-color:var(--blue,#0077CC);box-shadow:0 0 0 1px var(--blue,#0077CC)}
      .pr-name{font-size:11px;font-weight:700;letter-spacing:0.1em;text-transform:uppercase;color:var(--grey-mid,#666)}
      .pr-name.featured{color:var(--blue,#0077CC)}
      .pr-headline{font-size:15px;font-weight:700;letter-spacing:-0.2px}
      .pr-price{font-size:22px;font-weight:800;color:var(--blue,#0077CC);letter-spacing:-0.6px;margin-top:2px}
      .pr-price span{font-size:12px;color:var(--grey-mid,#666);font-weight:500;margin-left:4px}
      .pr-feat{display:grid;gap:3px;margin-top:4px;font-size:12px;color:var(--grey-dark,#333);line-height:1.45}
      .pr-feat li{list-style:none;padding-left:16px;position:relative}
      .pr-feat li::before{content:'';position:absolute;left:0;top:7px;width:6px;height:6px;background:var(--blue,#0077CC);border-radius:50%}
      @media(max-width:880px){.pr-grid{grid-template-columns:1fr}}
    `;
    document.head.appendChild(s);
  }

  window.BillingShared = {
    money,
    fmtDate,
    esc,
    loyaltyAllowanceHtml,
    planRulesCardsHtml,
    ensureLoyaltyStyles,
    invoiceStatus: (s) => statusMeta(INVOICE_STATUS, s),
    subscriptionStatus: (s) => statusMeta(SUBSCRIPTION_STATUS, s),
    confirmationStatus: (s) => statusMeta(CONFIRMATION_STATUS, s),
    invoiceDocument,
    openInvoicePdf,
  };
})();
