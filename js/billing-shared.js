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

  /* Printable invoice document. `inv` is the invoice jsonb from the
   * RPCs (with line_items), `company` is { name, billing_email }.
   * Returns a full HTML document string. */
  function invoiceDocument(inv, company) {
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
    ${inv.payment_instructions ? `<div class="block"><h3>Payment Instructions</h3><p>${esc(inv.payment_instructions)}</p></div>` : ''}
    ${inv.notes ? `<div class="block"><h3>Notes</h3><p>${esc(inv.notes)}</p></div>` : ''}
    <div class="block"><h3>How payment works</h3>
      <p>Pay using the instructions above, then submit "Confirm Payment" in your TRODDR dashboard with your reference number. Access is activated once TRODDR verifies the payment. No GCT applied.</p>
    </div>
  </div>

  <div class="foot">TRODDR · troddr.com · Made with care in Jamaica</div>
  <script>window.addEventListener('load', function(){ setTimeout(function(){ window.print(); }, 250); });<\/script>
</body>
</html>`;
  }

  function openInvoicePdf(inv, company) {
    const w = window.open('', '_blank');
    if (!w) { alert('Allow pop-ups to download the invoice PDF.'); return; }
    w.document.open();
    w.document.write(invoiceDocument(inv, company));
    w.document.close();
  }

  window.BillingShared = {
    money,
    fmtDate,
    esc,
    invoiceStatus: (s) => statusMeta(INVOICE_STATUS, s),
    subscriptionStatus: (s) => statusMeta(SUBSCRIPTION_STATUS, s),
    confirmationStatus: (s) => statusMeta(CONFIRMATION_STATUS, s),
    invoiceDocument,
    openInvoicePdf,
  };
})();
