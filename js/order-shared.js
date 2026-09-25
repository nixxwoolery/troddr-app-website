/* Shared helpers between partner-event-orders.html and
 * partner-event-order-analytics.html - kept small and dependency-free so
 * either page can load it as a plain <script> tag, no build step. */
(function () {
  function esc(s) {
    return (s ?? '').replace(/[&<>"]/g, (m) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[m]));
  }

  function money(n, c) {
    if (n == null) return null;
    const symbol = (c === 'JMD' || c === 'USD') ? '$' : '';
    return symbol + Number(n).toLocaleString(undefined, { minimumFractionDigits: 0, maximumFractionDigits: 2 });
  }

  // Minutes → "45m" or "2h 5m". Used anywhere a duration in minutes is shown.
  function fmtDuration(mins) {
    const m = Math.max(0, Math.round(mins));
    if (m < 60) return m + 'm';
    const h = Math.floor(m / 60), r = m % 60;
    return h + 'h' + (r ? ' ' + r + 'm' : '');
  }

  // Reveals and populates the #entity-picker select that js/partner-sidebar.js
  // always injects (hidden) at the top of the sidebar, for partners with more
  // than one place/event under the same account.
  function renderEntityPicker(partner) {
    if (!partner || !partner.entities || partner.entities.length < 2) return;
    const picker = document.getElementById('entity-picker');
    if (!picker) return;
    picker.classList.remove('hidden');
    const div = document.getElementById('entity-picker-divider');
    if (div) div.style.display = '';
    const nameEl = document.getElementById('partner-name');
    if (nameEl) nameEl.textContent = partner.name || 'Partner';

    const select = document.getElementById('entity-select');
    const places = partner.entities.filter((e) => e.type === 'place');
    const events = partner.entities.filter((e) => e.type === 'event');
    const opt = (e) => {
      const sel = e.id === partner.current_id ? ' selected' : '';
      const safe = String(e.name || '').replace(/[<>&"]/g, '');
      return `<option value="${e.token}" data-type="${e.type}"${sel}>${safe}</option>`;
    };
    let html = '';
    if (places.length) html += '<optgroup label="Places">' + places.map(opt).join('') + '</optgroup>';
    if (events.length) html += '<optgroup label="Events">' + events.map(opt).join('') + '</optgroup>';
    select.innerHTML = html;
    select.addEventListener('change', () => {
      const o = select.options[select.selectedIndex];
      const token = o.value;
      const path = o.dataset.type === 'event' ? '/partner/event' : '/partner/listing';
      if (window.PartnerAuth) window.PartnerAuth.navigate(path, token);
      else location.href = `${path}?token=${encodeURIComponent(token)}`;
    });
  }

  window.OrderShared = { esc, money, fmtDuration, renderEntityPicker };
})();
