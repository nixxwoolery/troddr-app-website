/* ============================================================
 * Unified partner sidebar.
 *
 * Each partner page mounts the same nav structure via
 * PartnerSidebar.mount({ active, capabilities, jumpLinks, partner }).
 *
 * Sections are capability-driven : if the partner doesn't have
 * a section (e.g. event partner without listings), it isn't shown.
 * "On this page" jump-links sit at the top so they're visible
 * without scrolling.
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
    'ic-pass':      '<rect x="3" y="6" width="18" height="12" rx="2"/><path d="M9 6v12M3 12h6"/>',
    'ic-bus':       '<path d="M8 21h8M5 17h14a2 2 0 0 0 2-2v-7a4 4 0 0 0-4-4H7a4 4 0 0 0-4 4v7a2 2 0 0 0 2 2zm2 0v3m10-3v3M3 13h18M7 12.5h.01M17 12.5h.01"/>',
    'ic-mic':       '<path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"/><path d="M19 10v2a7 7 0 0 1-14 0v-2M12 19v4M8 23h8"/>',
    'ic-ticket':    '<path d="M2 9a3 3 0 0 1 0 6v2a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2v-2a3 3 0 0 1 0-6V7a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2zm10-4v14"/>',
    'ic-plus':      '<path d="M12 5v14M5 12h14"/>',
    'ic-list':      '<path d="M8 6h13M8 12h13M8 18h13M3 6h.01M3 12h.01M3 18h.01"/>',
    'ic-grid':      '<rect x="3" y="3" width="7" height="7"/><rect x="14" y="3" width="7" height="7"/><rect x="14" y="14" width="7" height="7"/><rect x="3" y="14" width="7" height="7"/>',
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

  // Section spec : capability-driven cross-page nav.
  // Only items whose `cap` is truthy in `capabilities` are rendered.
  // Sections with zero rendered items are hidden entirely.
  const SECTIONS = [
    {
      group: 'Listing',
      items: [
        { href: '/partner/listing',  icon: 'ic-doc',      label: 'Listing',            cap: 'listing' },
        { href: '/partner/feedback', icon: 'ic-users',    label: 'Community Insights', cap: 'feedback' },
        { href: '/partner/bookings', icon: 'ic-calendar', label: 'Booking Requests',   cap: 'bookings' },
      ],
    },
    {
      group: 'Promote',
      items: [
        { href: '/partner/specials', icon: 'ic-tag',  label: 'Specials & Promos', cap: 'specials' },
        { href: '/partner/loyalty',  icon: 'ic-bolt', label: 'Loyalty',           cap: 'loyalty' },
      ],
    },
    {
      group: 'Event',
      items: [
        { href: '/partner/event', icon: 'ic-calendar', label: 'Event Dashboard', cap: 'event' },
      ],
    },
    {
      group: 'Account',
      items: [
        { href: '/partner/billing', icon: 'ic-dollar', label: 'Billing', cap: 'billing' },
      ],
    },
  ];

  function pageLinkHtml(item, active) {
    const isActive = item.href && active && item.href === active;
    const icon = `<svg><use href="#${item.icon}"/></svg>`;
    const cls = isActive ? 'page-link active' : 'page-link';
    return `<a class="${cls}" data-href="${item.href}">${icon} ${escapeHtml(item.label)}</a>`;
  }

  function jumpLinkHtml(link) {
    // Special: header-only entry (no section, just visual group label).
    if (link.header) {
      const hidden = link.hidden ? ' style="display:none"' : '';
      return `<div class="sidebar-title" style="padding-top:14px;"${hidden}>${escapeHtml(link.header)}</div>`;
    }
    const icon = link.icon ? `<svg><use href="#${link.icon}"/></svg> ` : '';
    const idAttr = link.id ? ` id="${link.id}"` : '';
    const hidden = link.hidden ? ' style="display:none"' : '';
    return `<a href="#${link.section}" class="jump-link" data-section="${link.section}"${idAttr}${hidden}>${icon}${escapeHtml(link.label)}</a>`;
  }

  function escapeHtml(s) {
    if (s == null) return '';
    return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
      .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
  }

  function buildHtml(opts) {
    const active = opts.active || '';
    const caps = opts.capabilities || {};
    // Multi-entity is inferred from the partner blob when the caller passes
    // it ; otherwise fall back to the explicit hasGroupLanding flag.
    const partnerEntities = (opts.partner && Array.isArray(opts.partner.entities))
      ? opts.partner.entities
      : null;
    const hasMultipleEntities = (partnerEntities && partnerEntities.length > 1)
      || opts.hasGroupLanding === true;

    let html = '';

    // Entity picker container (revealed + populated by the page's
    // renderEntityPicker after PartnerSidebar.mount).
    html += `
      <div class="entity-picker hidden" id="entity-picker">
        <div class="partner-tag">Switch entity</div>
        <div class="partner-name" id="partner-name"></div>
        <select class="entity-select" id="entity-select" aria-label="Switch entity"></select>
      </div>
      <div class="sidebar-divider" id="entity-picker-divider" style="display:none"></div>
    `;

    // "All Entities" link back to the group landing, shown on every page
    // (except the group landing itself) when the partner has more than one.
    if (hasMultipleEntities && active !== '/partner/group') {
      html += `<a class="page-link" data-href="/partner/group"><svg><use href="#ic-grid"/></svg> All Entities</a>`;
      html += `<div class="sidebar-divider"></div>`;
    }

    // "On this page" jump-links.
    if (opts.jumpLinks && opts.jumpLinks.length) {
      html += `<div class="sidebar-title">On this page</div>`;
      opts.jumpLinks.forEach((link) => { html += jumpLinkHtml(link); });
      html += `<div class="sidebar-divider"></div>`;
    }

    // Cross-page nav, capability-driven.
    SECTIONS.forEach((section) => {
      const visible = section.items.filter((item) => caps[item.cap]);
      if (!visible.length) return;
      html += `<div class="sidebar-title">${escapeHtml(section.group)}</div>`;
      visible.forEach((item) => { html += pageLinkHtml(item, active); });
    });

    return html;
  }

  /** Mount the sidebar into every .sidebar element on the page. */
  function mount(opts) {
    ensureIcons();
    const sidebars = document.querySelectorAll('.sidebar');
    if (!sidebars.length) return;
    const html = buildHtml(opts || {});
    sidebars.forEach((sb) => { sb.innerHTML = html; });
    if (window.PartnerAuth) {
      window.PartnerAuth.setupPageLinks(opts && opts.capabilities);
    }
  }

  /** Activate scrollspy for jump-links currently in the sidebar. */
  function setupScrollspy() {
    const jumpLinks = document.querySelectorAll('.jump-link');
    if (!jumpLinks.length) return;
    const sections = Array.from(jumpLinks)
      .map((l) => document.getElementById(l.dataset.section))
      .filter(Boolean);
    function update() {
      const scrollY = window.scrollY + 120;
      // Skip sections inside hidden ancestors (e.g. inactive view panes).
      // offsetParent is null for any element with display:none in its
      // ancestor chain, which gives us a reliable visibility check.
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
