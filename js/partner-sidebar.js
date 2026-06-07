/* ============================================================
 * Unified partner sidebar.
 *
 * Each partner page mounts the same nav structure
 * (Overview / Your Business / Promote / Events / Account)
 * via PartnerSidebar.mount({ active, jumpLinks, capabilities }).
 *
 * Pages still own their own:
 *   - entity-picker block (rendered separately)
 *   - "On this page" jump-link list (passed in via options)
 *
 * This keeps a single source of truth for the cross-page nav.
 * ============================================================ */
(function () {
  if (window.PartnerSidebar) return;

  const ICONS = {
    'ic-doc':       '<path d="M14 3H6a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2V9z"/><path d="M14 3v6h6M8 13h8M8 17h8M8 9h2"/>',
    'ic-chart':     '<path d="M3 13.125C3 12.504 3.504 12 4.125 12h2.25c.621 0 1.125.504 1.125 1.125v6.75C7.5 20.496 6.996 21 6.375 21h-2.25A1.125 1.125 0 013 19.875v-6.75zM9.75 8.625c0-.621.504-1.125 1.125-1.125h2.25c.621 0 1.125.504 1.125 1.125v11.25c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 01-1.125-1.125V8.625zM16.5 4.125c0-.621.504-1.125 1.125-1.125h2.25C20.496 3 21 3.504 21 4.125v15.75c0 .621-.504 1.125-1.125 1.125h-2.25a1.125 1.125 0 01-1.125-1.125V4.125z"/>',
    'ic-bell':      '<path d="M14.857 17.082a23.848 23.848 0 005.454-1.31A8.967 8.967 0 0118 9.75v-.7V9A6 6 0 006 9v.75a8.967 8.967 0 01-2.312 6.022c1.733.64 3.56 1.085 5.455 1.31m5.714 0a24.255 24.255 0 01-5.714 0m5.714 0a3 3 0 11-5.714 0"/>',
    'ic-shield':    '<path d="M9 12.75L11.25 15 15 9.75M21 12c0 1.268-.63 2.39-1.593 3.068a3.745 3.745 0 01-1.043 3.296 3.745 3.745 0 01-3.296 1.043A3.745 3.745 0 0112 21c-1.268 0-2.39-.63-3.068-1.593a3.746 3.746 0 01-3.296-1.043 3.745 3.745 0 01-1.043-3.296A3.745 3.745 0 013 12c0-1.268.63-2.39 1.593-3.068a3.745 3.745 0 011.043-3.296 3.746 3.746 0 013.296-1.043A3.746 3.746 0 0112 3c1.268 0 2.39.63 3.068 1.593a3.746 3.746 0 013.296 1.043 3.746 3.746 0 011.043 3.296A3.745 3.745 0 0121 12z"/>',
    'ic-heart':     '<path d="M21 8.25c0-2.485-2.099-4.5-4.688-4.5-1.935 0-3.597 1.126-4.312 2.733-.715-1.607-2.377-2.733-4.313-2.733C5.1 3.75 3 5.765 3 8.25c0 7.22 9 12 9 12s9-4.78 9-12z"/>',
    'ic-users':     '<path d="M18 18.72a9.094 9.094 0 003.741-.479 3 3 0 00-4.682-2.72m.94 3.198l.001.031c0 .225-.012.447-.037.666A11.944 11.944 0 0112 21c-2.17 0-4.207-.576-5.963-1.584A6.062 6.062 0 016 18.719m12 0a5.971 5.971 0 00-3.197-5.971m-8.803 5.971a6.062 6.062 0 015.971-5.971M15 6.75a3 3 0 11-6 0 3 3 0 016 0z"/>',
    'ic-tag':       '<path d="M9.568 3H5.25A2.25 2.25 0 003 5.25v4.318c0 .597.237 1.17.659 1.591l9.581 9.581c.699.699 1.78.872 2.607.33a18.095 18.095 0 005.223-5.223c.542-.827.369-1.908-.33-2.607L11.16 3.66A2.25 2.25 0 009.568 3z"/><path d="M6 6h.008v.008H6V6z"/>',
    'ic-book':      '<path d="M12 6.042A8.967 8.967 0 006 3.75c-1.052 0-2.062.18-3 .512v14.25A8.987 8.987 0 016 18c2.305 0 4.408.867 6 2.292m0-14.25a8.966 8.966 0 016-2.292c1.052 0 2.062.18 3 .512v14.25A8.987 8.987 0 0018 18a8.967 8.967 0 00-6 2.292m0-14.25v14.25"/>',
    'ic-bolt':      '<path d="M13 2L4 14h7l-1 8 9-12h-7l1-8z"/>',
    'ic-dollar':    '<path d="M12 2v20M17 6H9a3 3 0 0 0 0 6h6a3 3 0 0 1 0 6H7"/>',
    'ic-floorplan': '<path d="M9 6.75V15m6-6v8.25m.503 3.498l4.875-2.437c.381-.19.622-.58.622-1.006V4.82c0-.836-.88-1.38-1.628-1.006l-3.869 1.934c-.317.159-.69.159-1.006 0L9.503 3.252a1.125 1.125 0 00-1.006 0L3.622 5.689C3.24 5.88 3 6.27 3 6.695V19.18c0 .836.88 1.38 1.628 1.006l3.869-1.934c.317-.159.69-.159 1.006 0l4.994 2.497c.317.158.69.158 1.006 0z"/>',
    'ic-shop':      '<path d="M13.5 21v-7.5a.75.75 0 01.75-.75h3a.75.75 0 01.75.75V21m-4.5 0H2.36m11.14 0H18m0 0h3.64m-1.39 0V9.349m-16.5 11.65V9.35m0 0a3.001 3.001 0 003.75-.615A2.993 2.993 0 009.75 9.75c.896 0 1.7-.393 2.25-1.016a2.993 2.993 0 002.25 1.016c.896 0 1.7-.393 2.25-1.016a3.001 3.001 0 003.75.614m-16.5 0a3.004 3.004 0 01-.621-4.72L4.318 3.44A1.5 1.5 0 015.378 3h13.243a1.5 1.5 0 011.06.44l1.19 1.189a3 3 0 01-.621 4.72m-13.5 8.65h3.75a.75.75 0 00.75-.75V13.5a.75.75 0 00-.75-.75H6.75a.75.75 0 00-.75.75v3.75c0 .415.336.75.75.75z"/>',
    'ic-calendar':  '<rect x="3" y="5" width="18" height="16" rx="2"/><path d="M3 10h18M8 3v4M16 3v4"/>',
    'ic-lock':      '<rect x="3" y="11" width="18" height="11" rx="2" ry="2"/><path d="M7 11V7a5 5 0 0 1 10 0v4"/>',
    'ic-eye':       '<path d="M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>',
    'ic-chat':      '<path d="M21 11.5a8.4 8.4 0 0 1-1 4 8.5 8.5 0 0 1-7.6 4.5 8.4 8.4 0 0 1-4-1L3 21l1.9-5.4a8.5 8.5 0 0 1-1-4 8.5 8.5 0 0 1 4.5-7.6 8.4 8.4 0 0 1 4-1A8.5 8.5 0 0 1 21 11.5z"/>',
    'ic-edit':      '<path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.121 2.121 0 0 1 3 3L12 15l-4 1 1-4 9.5-9.5z"/>',
    'ic-info':      '<circle cx="12" cy="12" r="10"/><path d="M12 16v-4M12 8h.01"/>',
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

  const PAGES = [
    {
      group: 'Overview',
      items: [
        { href: '/partner/listing',  icon: 'ic-doc',    label: 'Listing' },
        { comingSoon: true,          icon: 'ic-chart',  label: 'Performance' },
        { comingSoon: true,          icon: 'ic-bell',   label: 'Notifications' },
        { href: '/partner/feedback', icon: 'ic-users',  label: 'Community Insights' },
        { comingSoon: true,          icon: 'ic-heart',  label: 'Engagement' },
      ],
    },
    {
      group: 'Your Business',
      items: [
        { href: '/partner/bookings', icon: 'ic-calendar', label: 'Booking Requests' },
        { comingSoon: true,          icon: 'ic-shield',   label: 'Listing Health' },
      ],
    },
    {
      group: 'Promote',
      items: [
        { href: '/partner/specials', icon: 'ic-tag',  label: 'Specials & Promos' },
        { comingSoon: true,          icon: 'ic-book', label: 'Featured in Guides' },
        { href: '/partner/loyalty',  icon: 'ic-bolt', label: 'Loyalty' },
      ],
    },
    {
      group: 'Events',
      items: [
        { href: '/partner/event',  icon: 'ic-calendar',  label: 'My Event' },
        { comingSoon: true,        icon: 'ic-floorplan', label: 'Floor Plan' },
        { comingSoon: true,        icon: 'ic-shop',      label: 'Vendor Insights' },
      ],
    },
    {
      group: 'Account',
      items: [
        { href: '/partner/billing', icon: 'ic-dollar', label: 'Billing' },
      ],
    },
  ];

  function pageLinkHtml(item, active) {
    const isActive = item.href && active && item.href === active;
    const icon = `<svg><use href="#${item.icon}"/></svg>`;
    if (item.comingSoon) {
      return `<a class="coming-soon">${icon} ${item.label}</a>`;
    }
    const cls = isActive ? 'page-link active' : 'page-link';
    return `<a class="${cls}" data-href="${item.href}">${icon} ${item.label}</a>`;
  }

  function jumpLinkHtml(link) {
    const icon = link.icon ? `<svg><use href="#${link.icon}"/></svg> ` : '';
    const idAttr = link.id ? ` id="${link.id}"` : '';
    const hidden = link.hidden ? ' style="display:none"' : '';
    return `<a href="#${link.section}" class="jump-link" data-section="${link.section}"${idAttr}${hidden}>${icon}${link.label}</a>`;
  }

  function buildHtml(opts) {
    const active = opts.active || '';
    let html = `
      <div class="entity-picker hidden" id="entity-picker">
        <div class="partner-tag">Partner</div>
        <div class="partner-name" id="partner-name"></div>
        <select class="entity-select" id="entity-select" aria-label="Switch entity"></select>
      </div>
      <div class="sidebar-divider" id="entity-picker-divider" style="display:none"></div>
    `;
    PAGES.forEach((group) => {
      html += `<div class="sidebar-title">${group.group}</div>`;
      group.items.forEach((item) => {
        html += pageLinkHtml(item, active);
      });
    });
    if (opts.jumpLinks && opts.jumpLinks.length) {
      html += `<div class="sidebar-divider"></div><div class="sidebar-title">On this page</div>`;
      opts.jumpLinks.forEach((link) => { html += jumpLinkHtml(link); });
    }
    return html;
  }

  /** Mount the sidebar into the first matching .sidebar element. */
  function mount(opts) {
    ensureIcons();
    const sidebars = document.querySelectorAll('.sidebar');
    if (!sidebars.length) return;
    const html = buildHtml(opts || {});
    sidebars.forEach((sb) => { sb.innerHTML = html; });
    // Wire cross-page navigation if PartnerAuth is loaded.
    if (window.PartnerAuth && opts && opts.capabilities !== undefined) {
      window.PartnerAuth.setupPageLinks(opts.capabilities);
    } else if (window.PartnerAuth) {
      window.PartnerAuth.setupPageLinks();
    }
  }

  /** Activate scrollspy across jump-links currently rendered in the sidebar. */
  function setupScrollspy() {
    const jumpLinks = document.querySelectorAll('.jump-link');
    if (!jumpLinks.length) return;
    const sections = Array.from(jumpLinks)
      .map((l) => document.getElementById(l.dataset.section))
      .filter(Boolean);
    function update() {
      const scrollY = window.scrollY + 120;
      let activeId = sections[0] && sections[0].id;
      sections.forEach((sec) => { if (sec.offsetTop <= scrollY) activeId = sec.id; });
      jumpLinks.forEach((l) => l.classList.toggle('active', l.dataset.section === activeId));
    }
    window.addEventListener('scroll', update, { passive: true });
    update();
  }

  window.PartnerSidebar = { mount, setupScrollspy };
})();
