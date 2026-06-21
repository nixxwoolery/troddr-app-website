/* ============================================================
 * Unified partner sidebar  (v2 — nested, collapsible).
 *
 * One shared component mounted on every partner page via
 *   PartnerSidebar.mount({ active, capabilities, partner })
 *
 * The nav is a two-level tree defined centrally below, so the
 * structure is identical on every page. There are two trees:
 *
 *   • NAV_INDIVIDUAL — shown on every single-location page
 *     (Listing, Insights & Feedback, Booking, Promote,
 *      Specials & Promotions, Account, Event)
 *
 *   • NAV_GROUP — shown on the group landing (/partner/group)
 *     (Listing, Community Insights, Group Insights,
 *      Specials & Promos, Billing)
 *
 * Sections are capability-driven: a section with a `cap` is only
 * rendered when capabilities[cap] is truthy. The section whose
 * `page` matches the current page is auto-expanded and its
 * same-page children act as scroll-spy anchors; every other
 * section is collapsed and its children navigate cross-page.
 * ============================================================ */
(function () {
  if (window.PartnerSidebar) return;

  const ICONS = {
    'ic-doc':       '<path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><path d="M14 3v6h6M8 13h8M8 17h8M8 9h2"/>',
    'ic-chart':     '<path d="M3 13.125C3 12.504 3.504 12 4.125 12h2.25c.621 0 1.125.504 1.125 1.125v6.75C7.5 20.496 6.996 21 6.375 21h-2.25A1.125 1.125 0 013 19.875v-6.75zM9.75 8.625c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125v11.25c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 01-1.125-1.125V8.625zM16.5 4.125c0-.621.504-1.125 1.125-1.125h2.25C20.496 3 21 3.504 21 4.125v15.75c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 01-1.125-1.125V4.125z"/>',
    'ic-users':     '<path d="M18 18.72a9.094 9.094 0 003.741-.479 3 3 0 00-4.682-2.72m.94 3.198l.001.031c0 .225-.012.447-.037.666A11.944 11.944 0 0112 21c-2.17 0-4.207-.576-5.963-1.584A6.062 6.062 0 016 18.719m12 0a5.971 5.971 0 00-3.197-5.971m-8.803 5.971a6.062 6.062 0 015.971-5.971M15 6.75a3 3 0 11-6 0 3 3 0 016 0z"/>',
    'ic-tag':       '<path d="M9.568 3H5.25A2.25 2.25 0 003 5.25v4.318c0 .597.237 1.17.659 1.591l9.581 9.581c.699.699 1.78.872 2.607.33a18.095 18.095 0 005.223-5.223c.542-.827.369-1.908-.33-2.607L11.16 3.66A2.25 2.25 0 009.568 3z"/><path d="M6 6h.008v.008H6V6z"/>',
    'ic-bolt':      '<path d="M13 2L4 14h7l-1 8 9-12h-7l1-8z"/>',
    'ic-dollar':    '<path d="M12 2v20M17 6H9a3 3 0 0 0 0 6h6a3 3 0 0 1 0 6H7"/>',
    'ic-shop':      '<path d="M13.5 21v-7.5a.75.75 0 01.75-.75h3a.75.75 0 01.75.75V21m-4.5 0H2.36m11.14 0H18m0 0h3.64m-1.39 0V9.349m-16.5 11.65V9.35m0 0a3.001 3.001 0 003.75-.615A2.993 2.993 0 009.75 9.75c.896 0 1.7-.393 2.25-1.016a2.993 2.993 0 002.25 1.016c.896 0 1.7-.393 2.25-1.016a3.001 3.001 0 003.75.614m-16.5 0a3.004 3.004 0 01-.621-4.72L4.318 3.44A1.5 1.5 0 015.378 3h13.243a1.5 1.5 0 011.06.44l1.19 1.189a3 3 0 01-.621 4.72m-13.5 8.65h3.75a.75.75 0 00.75-.75V13.5a.75.75 0 00-.75-.75H6.75a.75.75 0 00-.75.75v3.75c0 .415.336.75.75.75z"/>',
    'ic-calendar':  '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/>',
    'ic-lock':      '<rect x="3" y="11" width="18" height="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
    'ic-eye':       '<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
    'ic-chat':      '<path d="M21 11.5a8.4 8.4 0 0 1-1 4 8.5 8.5 0 0 1-7.6 4.5 8.4 8.4 0 0 1-4-1L3 21l1.9-5.4a8.5 8.5 0 0 1-1-4 8.5 8.5 0 0 1 4.5-7.6 8.4 8.4 0 0 1 4-1A8.5 8.5 0 0 1 21 11.5z"/>',
    'ic-edit':      '<path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/>',
    'ic-info':      '<circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/>',
    'ic-map':       '<path d="M9 20l-5.447-2.724A1 1 0 0 1 3 16.382V5.618a1 1 0 0 1 1.447-.894L9 7m0 13l6-3m-6 3V7m6 10l4.553 2.276A1 1 0 0 0 21 18.382V7.618a1 1 0 0 0-.553-.894L15 4m0 13V4m0 0L9 7"/>',
    'ic-mic':       '<path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2M12 19v4M8 23h8"/>',
    'ic-ticket':    '<path d="M2 9a3 3 0 0 1 0 6v2a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-2a3 3 0 0 1 0-6V7a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2zm10-4v14"/>',
    'ic-plus':      '<path d="M12 5v14M5 12h14"/>',
    'ic-list':      '<path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/>',
    'ic-grid':      '<rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/>',
    'ic-megaphone': '<path d="M3 11l18-5v12L3 13v-2z"/><path d="M11.6 16.8a3 3 0 1 1-5.8-1.6"/>',
    'ic-chevron':   '<path d="M9 6l6 6-6 6"/>',
  };

  function ensureIcons() {
    if (document.getElementById('partner-sidebar-icons')) return;
    let svg = `<svg id="partner-sidebar-icons" style="display:none" xmlns="http://www.w3.org/2000/svg"><defs>`;
    Object.keys(ICONS).forEach((id) => {
      svg += `<symbol id="${id}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">${ICONS[id]}</symbol>`;
    });
    svg += `</defs></svg>`;
    const wrapper = document.createElement('div');
    wrapper.innerHTML = svg;
    document.body.insertBefore(wrapper.firstChild, document.body.firstChild);
  }

  // ── Central nav trees ──────────────────────────────────────
  // section: { group, icon, page, cap, children:[ { label, section, page? } ] }
  //   cap   — capability key; omit/null to always show.
  //   page  — route this section's header navigates to.
  //   child.section — anchor id on the child's target page.
  //   child.page    — override target page (cross-page link); defaults to section.page.

  const NAV_INDIVIDUAL = [
    { group: 'Listing', icon: 'ic-doc', page: '/partner/listing', cap: 'listing', children: [
      { label: 'Preview',             section: 'preview' },
      { label: 'Content Info & Links', section: 'contact' },
      { label: 'Opening Hours',       section: 'hours' },
      { label: 'Check-in & Loyalty',  section: 'checkin' },
    ] },
    { group: 'Insights & Feedback', icon: 'ic-chart', page: '/partner/feedback', cap: 'feedback', children: [
      { label: 'Discovery',             section: 'metrics' },
      { label: 'Summary',               section: 'summary' },
      { label: 'Item Insights',         section: 'items' },
      { label: 'Distribution',          section: 'distribution' },
      { label: 'What users are saying', section: 'tags' },
      { label: 'Recent Feedback',       section: 'recent' },
      { label: 'All Feedback',          section: 'feed' },
    ] },
    { group: 'Booking', icon: 'ic-calendar', page: '/partner/bookings', cap: 'bookings', children: [
      { label: 'Booking Requests', section: 'view-main' },
    ] },
    { group: 'Promote', icon: 'ic-megaphone', page: '/partner/loyalty', cap: 'loyalty' },
    { group: 'Insider Perks', icon: 'ic-ticket', page: '/partner/perks', cap: 'loyalty' },
    { group: 'Specials & Promotions', icon: 'ic-tag', page: '/partner/specials', cap: 'specials', children: [
      { label: 'Specials Summary',     section: 'summary' },
      { label: 'Active Specials',      section: 'active' },
      { label: 'Submit a New Special', section: 'upload' },
    ] },
    { group: 'Event', icon: 'ic-calendar', page: '/partner/event', cap: 'event', children: [
      { label: 'Event Dashboard', section: '' },
      { label: 'Floor Plan',      section: '', page: '/partner/event-floorplan' },
    ] },
    { group: 'Account', icon: 'ic-dollar', page: '/partner/billing', cap: 'billing', children: [
      { label: 'Billing Summary',             section: 'summary' },
      { label: 'Locations & Events',          section: 'account' },
      { label: 'Active Add-ons & Entitlements', section: 'addons' },
      { label: 'Invoices',                    section: 'invoices' },
      { label: 'Manage Billing',              section: 'manage' },
    ] },
  ];

  const NAV_GROUP = [
    // Group Insights is a true multi-location feature — only shown when the
    // account owns 2+ places (a restaurant chain / hotel group, etc.).
    // It leads the group nav as the account-wide overview.
    { group: 'Group Insights', icon: 'ic-grid', page: '/partner/group', minPlaces: 2, children: [
      { label: 'Group Insights', section: 'group-insights' },
      { label: 'Item Insights',  section: 'group-items' },
    ] },
    { group: 'Listing', icon: 'ic-doc', page: '/partner/listing', cap: 'listing', children: [
      { label: 'Contact Info',    section: 'contact', page: '/partner/listing' },
      { label: 'Operating Hours', section: 'hours',   page: '/partner/listing' },
    ] },
    { group: 'Community Insights', icon: 'ic-users', page: '/partner/feedback', cap: 'feedback', children: [
      { label: 'Summary',                section: 'summary',      page: '/partner/feedback' },
      { label: 'Discovery',              section: 'metrics',      page: '/partner/feedback' },
      { label: 'Ratings Breakdown',      section: 'ratings',      page: '/partner/feedback' },
      { label: 'Recent Feedback',        section: 'recent',       page: '/partner/feedback' },
      { label: 'Distribution',           section: 'distribution', page: '/partner/feedback' },
      { label: 'What guests are saying', section: 'tags',         page: '/partner/feedback' },
      { label: 'All Feedback',           section: 'feed',         page: '/partner/feedback' },
    ] },
    { group: 'Specials & Promos', icon: 'ic-tag', page: '/partner/specials', cap: 'specials', children: [
      { label: 'Overview', section: 'summary', page: '/partner/specials' },
    ] },
    { group: 'Billing', icon: 'ic-dollar', page: '/partner/billing', cap: 'billing', children: [
      { label: 'Group Billing', section: 'summary', page: '/partner/billing' },
    ] },
  ];

  // Event dashboard is a single page with internal view-panes. Each nav item
  // carries a `section` anchor; the page listens for the `psb:select` event
  // (dispatched on click) to switch to the right pane before scrolling.
  const NAV_EVENT = [
    { group: 'Event Overview', icon: 'ic-info', page: '/partner/event', section: 'overview', children: [
      { label: 'Event Details', section: 'info' },
      { label: 'Edit',          section: 'edit' },
    ] },
    { group: 'Event Insights', icon: 'ic-chart', page: '/partner/event', section: 'engagement', children: [
      { label: 'All Vendors Performance', section: 'vendors' },
    ] },
    { group: 'Event Planning', icon: 'ic-grid', page: '/partner/event', section: 'builder-root', children: [
      { label: 'Floor Plan', section: 'builder-root' },
    ] },
    { group: 'Billing', icon: 'ic-dollar', page: '/partner/event', section: 'billing' },
  ];

  function escapeHtml(s) {
    if (s == null) return '';
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  function iconSvg(id) { return id ? `<svg class="psb-ic"><use href="#${id}"/></svg>` : ''; }

  function childTargetPage(section, child) { return child.page || section.page; }

  // ── Build a single section ─────────────────────────────────
  function sectionHtml(section, active) {
    const isActive = section.page === active;
    const children = section.children || [];
    const hasChildren = children.length > 0;
    const openCls = isActive && hasChildren ? ' open' : '';
    const activeCls = isActive ? ' active' : '';

    let html = `<div class="psb-group${activeCls}${openCls}">`;

    // Header row: anchor navigates to the section's page; the (sibling)
    // chevron button toggles children open/closed.
    const chevron = hasChildren
      ? `<button type="button" class="psb-toggle" aria-label="Toggle ${escapeHtml(section.group)}"><svg class="psb-chev"><use href="#ic-chevron"/></svg></button>`
      : '';
    const headAnchor = (isActive && section.section) ? ` data-section="${section.section}"` : '';
    html += `<div class="psb-head">`
          +   `<a class="psb-grouplink" data-href="${section.page}"${headAnchor}>`
          +     `${iconSvg(section.icon)}<span class="psb-label">${escapeHtml(section.group)}</span>`
          +   `</a>${chevron}`
          + `</div>`;

    // Children.
    if (hasChildren) {
      html += `<div class="psb-sub">`;
      children.forEach((child) => {
        const tPage = childTargetPage(section, child);
        const samePage = tPage === active;
        const anchor = child.section || '';
        if (samePage && anchor) {
          // Live scroll-spy anchor on the current page.
          html += `<a class="psb-sublink jump-link" href="#${anchor}" data-section="${anchor}">${escapeHtml(child.label)}</a>`;
        } else {
          // Cross-page navigation (optionally to an anchor).
          html += `<a class="psb-sublink" data-href="${tPage}" data-hash="${anchor}">${escapeHtml(child.label)}</a>`;
        }
      });
      html += `</div>`;
    }

    html += `</div>`;
    return html;
  }

  function buildHtml(opts) {
    const active = opts.active || '';
    const caps = opts.capabilities || {};
    const partnerEntities = (opts.partner && Array.isArray(opts.partner.entities))
      ? opts.partner.entities : null;
    const hasMultipleEntities = (partnerEntities && partnerEntities.length > 1)
      || opts.hasGroupLanding === true;
    // A "group" in the multi-location sense = 2+ places (restaurant chain,
    // hotel group, etc.). Used to gate group-only nav like Group Insights.
    const placeCount = partnerEntities
      ? partnerEntities.filter((e) => e && e.type === 'place').length : 0;

    const isEvent = active === '/partner/event' || active === '/partner/event-floorplan';
    const tree = (active === '/partner/group') ? NAV_GROUP
               : isEvent ? NAV_EVENT
               : NAV_INDIVIDUAL;

    let html = '';

    // Entity picker (revealed + populated by the page after mount).
    html += `
      <div class="entity-picker hidden" id="entity-picker">
        <div class="partner-tag">Switch entity</div>
        <div class="partner-name" id="partner-name"></div>
        <select class="entity-select" id="entity-select" aria-label="Switch entity"></select>
      </div>
      <div class="sidebar-divider" id="entity-picker-divider" style="display:none"></div>
    `;

    // "All Entities" back-link for group members on a location page.
    if (hasMultipleEntities && active !== '/partner/group') {
      html += `<div class="psb-head psb-solo">`
            +   `<a class="psb-grouplink" data-href="/partner/group">`
            +     `${iconSvg('ic-grid')}<span class="psb-label">All Entities</span></a>`
            + `</div>`;
      html += `<div class="sidebar-divider"></div>`;
    }

    html += `<nav class="psb-nav">`;
    tree.forEach((section) => {
      if (section.cap && !caps[section.cap]) return;
      if (section.minPlaces && placeCount < section.minPlaces) return;
      html += sectionHtml(section, active);
    });
    html += `</nav>`;

    return html;
  }

  // ── Navigation wiring ──────────────────────────────────────
  function getToken() {
    try {
      return (window.PartnerAuth && window.PartnerAuth.getToken({ require: false }))
        || new URLSearchParams(location.search).get('token') || '';
    } catch (e) { return ''; }
  }

  function pageUrl(path, token) {
    const url = new URL(path, window.location.origin);
    if (token) url.searchParams.set('token', token);
    return url.toString();
  }

  function goTo(path, hash) {
    const token = getToken();
    try { sessionStorage.setItem('__partner_intent', path); } catch (e) {}
    try { if (token) sessionStorage.setItem('troddr_partner_token', token); } catch (e) {}
    let dest = pageUrl(path, token);
    if (hash) dest += '#' + hash;
    window.location.href = dest;
  }

  function smoothScrollTo(anchor) {
    const el = anchor ? document.getElementById(anchor) : null;
    if (el) {
      el.scrollIntoView({ behavior: 'smooth', block: 'start' });
      return true;
    }
    return false;
  }

  // In-page section selection. Pages with internal view-panes (the event
  // dashboard) listen for `psb:select` to switch to the right pane *before*
  // we scroll; pages without panes simply scroll.
  function selectSection(anchor) {
    if (!anchor) return;
    document.dispatchEvent(new CustomEvent('psb:select', { detail: { section: anchor } }));
    smoothScrollTo(anchor);
  }

  // Wire one sidebar element's interactive parts. Idempotent — a
  // re-mount or a second `.sidebar` element won't double-bind handlers.
  function wireSidebar(root, active) {
    const token = getToken();

    // Group / solo header links → navigate to their page.
    root.querySelectorAll('.psb-grouplink').forEach((a) => {
      const href = a.dataset.href;
      if (!href) return;
      a.setAttribute('href', pageUrl(href, token));
      if (a.dataset.wired) return;
      a.dataset.wired = '1';
      a.addEventListener('click', (e) => {
        e.preventDefault();
        if (href === active) {
          const sec = a.dataset.section;
          if (sec) selectSection(sec);
          else window.scrollTo({ top: 0, behavior: 'smooth' });
          return;
        }
        goTo(href);
      });
    });

    // Chevron toggles — open/close without navigating.
    root.querySelectorAll('.psb-toggle').forEach((btn) => {
      if (btn.dataset.wired) return;
      btn.dataset.wired = '1';
      btn.addEventListener('click', (e) => {
        e.preventDefault();
        e.stopPropagation();
        const group = btn.closest('.psb-group');
        if (group) group.classList.toggle('open');
      });
    });

    // Sub-links.
    root.querySelectorAll('.psb-sublink').forEach((a) => {
      const crossPage = a.dataset.href;
      if (crossPage) {
        const hash = a.dataset.hash || '';
        a.setAttribute('href', pageUrl(crossPage, token) + (hash ? '#' + hash : ''));
        if (a.dataset.wired) return;
        a.dataset.wired = '1';
        a.addEventListener('click', (e) => { e.preventDefault(); goTo(crossPage, hash); });
      } else {
        if (a.dataset.wired) return;
        a.dataset.wired = '1';
        a.addEventListener('click', (e) => {
          const anchor = a.dataset.section;
          if (anchor && document.getElementById(anchor)) {
            e.preventDefault();
            selectSection(anchor);
          }
        });
      }
    });
  }

  /** Mount the sidebar into every .sidebar element on the page. */
  function mount(opts) {
    opts = opts || {};
    ensureIcons();
    const sidebars = document.querySelectorAll('.sidebar');
    if (!sidebars.length) return;
    const html = buildHtml(opts);
    sidebars.forEach((sb) => { sb.innerHTML = html; wireSidebar(sb, opts.active || ''); });
  }

  /** Scroll-spy for the active section's same-page anchors. */
  function setupScrollspy() {
    const jumpLinks = document.querySelectorAll('.psb-sublink.jump-link');
    if (!jumpLinks.length) return;
    const sections = Array.from(jumpLinks)
      .map((l) => document.getElementById(l.dataset.section))
      .filter(Boolean);
    function update() {
      const scrollY = window.scrollY + 120;
      const visible = sections.filter((sec) => sec.offsetParent !== null);
      let activeId = visible[0] && visible[0].id;
      visible.forEach((sec) => { if (sec.offsetTop <= scrollY) activeId = sec.id; });
      jumpLinks.forEach((l) => l.classList.toggle('active', l.dataset.section === activeId));
    }
    window.addEventListener('scroll', update, { passive: true });
    update();
  }

  window.PartnerSidebar = { mount, setupScrollspy };
})();
