/* ============================================================
   TRODDR Floor Plan Builder — shared engine
   Powers partner-event-floorplan.html (organizer) and m.html
   (designer invite). Host pages mount it with:

     const fp = FloorplanBuilder.mount({
       container,                  // HTMLElement to render into
       elements: [...],            // saved floor_plan_markers (any mix of legacy pins + new shapes)
       backgroundUrl: '…'|null,    // saved floor_plan_url
       vendors: [{event_vendor_id, vendor_name}],
       onSave: async ({backgroundUrl, elements}) => ({ok}|{ok:false,error}),
       onUploadBackground: async (file) => url,   // omit to hide upload UI (designer mode)
       saveLabel: 'Save',
       actions: [{label, icon, onClick, primary}],// extra toolbar buttons
     });

   Storage model (events.floor_plan_markers jsonb array) — one array,
   discriminated by `type`; legacy entries with no type are pins:
     pin   {id, type?:'pin', x, y, label, icon, color, vendor_id, booth, size, description}
     booth {id, type:'booth', x, y, w, h, number, label, icon, color, vendor_id, size, description}
     zone  {id, type:'zone',  x, y, w, h, label, color, description}
     table {id, type:'table', x, y, w, h, color, shape:'round'|'rect'}
     text  {id, type:'text',  x, y, label, color, fontSize}
   x/y are CENTER fractions (0-1) of the canvas; w/h are fractions of
   canvas width/height; fontSize is a fraction of canvas width. Legacy
   pin renderers that ignore type will show shapes as pins at their
   centers — degraded but not broken.
   ============================================================ */
(function () {
  'use strict';

  // ── Category library (booths + pins share it) ─────────────
  const CATEGORIES = [
    { id: 'food',     label: 'Food',      icon: 'fpb-utensils', color: '#1a9e57' },
    { id: 'drink',    label: 'Drink',     icon: 'fpb-glass',    color: '#06b6d4' },
    { id: 'bar',      label: 'Bar',       icon: 'fpb-wine',     color: '#0891b2' },
    { id: 'stage',    label: 'Stage',     icon: 'fpb-music',    color: '#262626' },
    { id: 'merch',    label: 'Merch',     icon: 'fpb-bag',      color: '#ec4899' },
    { id: 'artisan',  label: 'Artisan',   icon: 'fpb-palette',  color: '#7c3aed' },
    { id: 'photo',    label: 'Photo Op',  icon: 'fpb-camera',   color: '#14b8a6' },
    { id: 'arcade',   label: 'Arcade',    icon: 'fpb-pad',      color: '#10b981' },
    { id: 'seating',  label: 'Seating',   icon: 'fpb-chair',    color: '#64748b' },
    { id: 'vip',      label: 'VIP',       icon: 'fpb-crown',    color: '#d4a017' },
    { id: 'info',     label: 'Info',      icon: 'fpb-info',     color: '#0a7aff' },
    { id: 'medic',    label: 'First Aid', icon: 'fpb-medic',    color: '#ef4444' },
    { id: 'restroom', label: 'Restrooms', icon: 'fpb-restroom', color: '#475569' },
    { id: 'entrance', label: 'Entrance',  icon: 'fpb-enter',    color: '#22c55e' },
    { id: 'exit',     label: 'Exit',      icon: 'fpb-exit',     color: '#16a34a' },
    { id: 'parking',  label: 'Parking',   icon: 'fpb-car',      color: '#334155' },
  ];
  const CAT_BY_ID = Object.fromEntries(CATEGORIES.map(c => [c.id, c]));
  const DEFAULT_CAT = 'food';
  // Legacy free-form icon names → category ids.
  const LEGACY_ICONS = { pin: DEFAULT_CAT, food: 'food', drink: 'drink', stage: 'stage', restroom: 'restroom', info: 'info', exit: 'exit', parking: 'parking' };

  const ZONE_COLORS = ['#b03a2e', '#1f2937', '#0e7490', '#6d28d9', '#b45309', '#166534'];
  const TABLE_COLOR = '#b08850';
  const TEXT_SIZES = [{ id: 's', label: 'Small', v: 0.011 }, { id: 'm', label: 'Medium', v: 0.016 }, { id: 'l', label: 'Large', v: 0.024 }, { id: 'xl', label: 'X-Large', v: 0.034 }];
  const PRESET_FT = ['10x10', '10x20', '10x30', '20x20', '20x30'];

  const WORLD_DEFAULT = { w: 1600, h: 1000 };
  const GRID = 20;            // world px
  const SNAP_PX = 7;          // screen px snap threshold
  const MIN_SIZE = 14;        // world px minimum shape size

  // ── Icon sprite (lucide outlines), injected once per page ──
  const SYMBOLS = '<svg width="0" height="0" style="position:absolute" aria-hidden="true"><defs>'
    + '<symbol id="fpb-utensils" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M3 2v7c0 1.1.9 2 2 2h4a2 2 0 0 0 2-2V2"/><path d="M7 2v20"/><path d="M21 15V2v0a5 5 0 0 0-5 5v6c0 1.1.9 2 2 2h3Zm0 0v7"/></symbol>'
    + '<symbol id="fpb-glass" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M15.2 22H8.8a2 2 0 0 1-2-1.79L5 3h14l-1.81 17.21A2 2 0 0 1 15.2 22Z"/><path d="M6 12a5 5 0 0 1 6 0 5 5 0 0 0 6 0"/></symbol>'
    + '<symbol id="fpb-wine" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M8 22h8"/><path d="M7 10h10"/><path d="M12 15v7"/><path d="M12 15a5 5 0 0 0 5-5V3H7v7a5 5 0 0 0 5 5Z"/></symbol>'
    + '<symbol id="fpb-music" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18V5l12-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="18" cy="16" r="3"/></symbol>'
    + '<symbol id="fpb-bag" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M6 2 3 6v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2V6l-3-4Z"/><path d="M3 6h18"/><path d="M16 10a4 4 0 0 1-8 0"/></symbol>'
    + '<symbol id="fpb-camera" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M14.5 4h-5L7 7H4a2 2 0 0 0-2 2v9a2 2 0 0 0 2 2h16a2 2 0 0 0 2-2V9a2 2 0 0 0-2-2h-3l-2.5-3Z"/><circle cx="12" cy="13" r="3"/></symbol>'
    + '<symbol id="fpb-info" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><path d="M12 16v-4"/><path d="M12 8h.01"/></symbol>'
    + '<symbol id="fpb-medic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"/><path d="M12 8v8"/><path d="M8 12h8"/></symbol>'
    + '<symbol id="fpb-restroom" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><circle cx="7" cy="5" r="2"/><path d="M5 22v-7H3l2-6h4l2 6H9v7Z"/><circle cx="17" cy="5" r="2"/><path d="M15 22V12h-2l2-5h4l2 5h-2v10Z"/></symbol>'
    + '<symbol id="fpb-enter" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4"/><path d="m10 17 5-5-5-5"/><path d="M15 12H3"/></symbol>'
    + '<symbol id="fpb-exit" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4"/><polyline points="16 17 21 12 16 7"/><line x1="21" y1="12" x2="9" y2="12"/></symbol>'
    + '<symbol id="fpb-car" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M19 17h2c.6 0 1-.4 1-1v-3c0-.9-.7-1.7-1.5-1.9C18.7 10.6 16 10 16 10s-1.3-1.4-2.2-2.3c-.5-.4-1.1-.7-1.8-.7H5c-.6 0-1.1.4-1.4.9l-1.4 2.9A3.7 3.7 0 0 0 2 12v4c0 .6.4 1 1 1h2"/><circle cx="7" cy="17" r="2"/><circle cx="17" cy="17" r="2"/></symbol>'
    + '<symbol id="fpb-chair" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M19 9V6a2 2 0 0 0-2-2H7a2 2 0 0 0-2 2v3"/><path d="M3 11v5a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-5a2 2 0 0 0-4 0v2H7v-2a2 2 0 0 0-4 0Z"/><path d="M5 18v2"/><path d="M19 18v2"/></symbol>'
    + '<symbol id="fpb-crown" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="m2 4 3 12h14l3-12-6 7-4-7-4 7-6-7zm3 16h14"/></symbol>'
    + '<symbol id="fpb-palette" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><circle cx="13.5" cy="6.5" r=".5"/><circle cx="17.5" cy="10.5" r=".5"/><circle cx="8.5" cy="7.5" r=".5"/><circle cx="6.5" cy="12.5" r=".5"/><path d="M12 2C6.5 2 2 6.5 2 12s4.5 10 10 10c.926 0 1.648-.746 1.648-1.688 0-.437-.18-.835-.437-1.125-.29-.289-.438-.652-.438-1.125a1.64 1.64 0 0 1 1.668-1.668h1.996c3.051 0 5.555-2.503 5.555-5.554C21.5 6.71 17.21 2 12 2z"/></symbol>'
    + '<symbol id="fpb-pad" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M6 12h4"/><path d="M8 10v4"/><rect x="2" y="6" width="20" height="12" rx="2"/></symbol>'
    + '<symbol id="fpb-pin" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M20 10c0 6-8 12-8 12s-8-6-8-12a8 8 0 0 1 16 0Z"/><circle cx="12" cy="10" r="3"/></symbol>'
    + '<symbol id="fpb-cursor" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="m3 3 7.07 16.97 2.51-7.39 7.39-2.51L3 3z"/></symbol>'
    + '<symbol id="fpb-square" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"/></symbol>'
    + '<symbol id="fpb-zone-ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2" stroke-dasharray="4 3"/></symbol>'
    + '<symbol id="fpb-circle" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/></symbol>'
    + '<symbol id="fpb-type" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><polyline points="4 7 4 4 20 4 20 7"/><line x1="9" y1="20" x2="15" y2="20"/><line x1="12" y1="4" x2="12" y2="20"/></symbol>'
    + '<symbol id="fpb-undo" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M3 7v6h6"/><path d="M21 17a9 9 0 0 0-9-9 9 9 0 0 0-6 2.3L3 13"/></symbol>'
    + '<symbol id="fpb-redo" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M21 7v6h-6"/><path d="M3 17a9 9 0 0 1 9-9 9 9 0 0 1 6 2.3L21 13"/></symbol>'
    + '<symbol id="fpb-download" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></symbol>'
    + '<symbol id="fpb-upload" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="17 8 12 3 7 8"/><line x1="12" y1="3" x2="12" y2="15"/></symbol>'
    + '<symbol id="fpb-save" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z"/><polyline points="17 21 17 13 7 13 7 21"/><polyline points="7 3 7 8 15 8"/></symbol>'
    + '<symbol id="fpb-trash" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></symbol>'
    + '<symbol id="fpb-copy" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></symbol>'
    + '<symbol id="fpb-sparkle" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l1.9 5.7L19.5 10l-5.6 1.3L12 17l-1.9-5.7L4.5 10l5.6-1.3L12 3z"/></symbol>'
    + '<symbol id="fpb-grid-ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"/><path d="M3 9h18"/><path d="M3 15h18"/><path d="M9 3v18"/><path d="M15 3v18"/></symbol>'
    + '</defs></svg>';

  // ── Small helpers ─────────────────────────────────────────
  const uid = () => 'el_' + Math.random().toString(36).slice(2, 10);
  const esc = (s) => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v));
  const num = (v, d = 0) => { const n = Number(v); return Number.isFinite(n) ? n : d; };

  function blankCanvasUri(w, h, cell) {
    w = w || WORLD_DEFAULT.w; h = h || WORLD_DEFAULT.h; cell = cell || 50;
    const svg =
      `<svg xmlns="http://www.w3.org/2000/svg" width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">` +
      `<rect width="${w}" height="${h}" fill="#fcfdfe"/>` +
      `<path d="${Array.from({ length: Math.floor(w / cell) }, (_, i) => `M${(i + 1) * cell} 0V${h}`).join('')}` +
      `${Array.from({ length: Math.floor(h / cell) }, (_, i) => `M0 ${(i + 1) * cell}H${w}`).join('')}" ` +
      `stroke="#e8eef4" stroke-width="1"/></svg>`;
    return 'data:image/svg+xml,' + encodeURIComponent(svg);
  }
  const isBlankUri = (url) => typeof url === 'string' && url.startsWith('data:image/svg+xml');

  function normalizeElement(m) {
    const el = Object.assign({}, m);
    el.id = el.id || uid();
    el.type = el.type || 'pin';
    el.x = num(el.x); el.y = num(el.y);
    if (el.type !== 'pin' && el.type !== 'text') { el.w = num(el.w, 0.04); el.h = num(el.h, 0.06); }
    if (el.type === 'pin' || el.type === 'booth') {
      el.icon = CAT_BY_ID[el.icon] ? el.icon : (LEGACY_ICONS[el.icon] || DEFAULT_CAT);
      el.color = el.color || CAT_BY_ID[el.icon].color;
    }
    if (el.type === 'text') el.fontSize = num(el.fontSize, 0.016);
    if (el.type === 'table') { el.shape = el.shape === 'rect' ? 'rect' : 'round'; el.color = el.color || TABLE_COLOR; }
    return el;
  }

  // ── Starter template (modelled on a typical festival site map) ──
  function festivalTemplate() {
    const els = [];
    const W = WORLD_DEFAULT.w, H = WORLD_DEFAULT.h;
    const bw = 64 / W, bh = 64 / H;
    let n = 1;
    const booth = (cxPx, cyPx, cat) => els.push(normalizeElement({
      id: uid(), type: 'booth', x: cxPx / W, y: cyPx / H, w: bw, h: bh,
      number: n++, label: '', icon: cat, color: CAT_BY_ID[cat].color,
    }));
    // Bottom row (booths 1..12) and top row (13..24), like vendor rows along the site edges.
    for (let i = 0; i < 12; i++) booth(140 + i * 70, 880, i < 2 ? 'drink' : 'food');
    for (let i = 0; i < 12; i++) booth(140 + i * 70, 130, i % 5 === 0 ? 'merch' : 'food');
    // Big zones
    els.push(normalizeElement({ id: uid(), type: 'zone', x: 760 / W, y: 230 / H, w: 200 / W, h: 130 / H, label: 'Stage', color: '#1f2937' }));
    els.push(normalizeElement({ id: uid(), type: 'zone', x: 1050 / W, y: 230 / H, w: 220 / W, h: 120 / H, label: 'Bar', color: '#0e7490' }));
    els.push(normalizeElement({ id: uid(), type: 'zone', x: 420 / W, y: 240 / H, w: 240 / W, h: 140 / H, label: 'VIP Lounge', color: '#b45309' }));
    // Scattered tables in the middle field
    [[420, 560], [560, 640], [700, 540], [860, 620], [1020, 540], [1180, 620], [620, 460], [940, 460], [1240, 500], [300, 640]]
      .forEach(([x, y]) => els.push(normalizeElement({ id: uid(), type: 'table', x: x / W, y: y / H, w: 38 / W, h: 38 / H, shape: 'round', color: TABLE_COLOR })));
    // Pins
    els.push(normalizeElement({ id: uid(), type: 'pin', x: 800 / W, y: 940 / H, label: 'Entrance', icon: 'entrance' }));
    els.push(normalizeElement({ id: uid(), type: 'pin', x: 1480 / W, y: 320 / H, label: 'Restrooms', icon: 'restroom' }));
    els.push(normalizeElement({ id: uid(), type: 'pin', x: 120 / W, y: 320 / H, label: 'First Aid', icon: 'medic' }));
    return els;
  }

  // ── Builder ───────────────────────────────────────────────
  class Builder {
    constructor(opts) {
      this.opts = opts || {};
      this.container = opts.container;
      this.vendors = Array.isArray(opts.vendors) ? opts.vendors : [];
      this.elements = (Array.isArray(opts.elements) ? opts.elements : []).map(normalizeElement);
      this.bgUrl = (opts.backgroundUrl && !isBlankUri(opts.backgroundUrl)) ? opts.backgroundUrl : null;
      this.world = Object.assign({}, WORLD_DEFAULT);
      this.tool = 'select';
      this.selectedId = null;
      this.pinCategory = 'info';
      this.boothCategory = DEFAULT_CAT;
      this.lastBoothSize = { w: 64, h: 64 };   // world px
      this.snap = true;
      this.dirty = false;
      this.undoStack = [];
      this.redoStack = [];
      this._lastUndoPush = 0;
      this.panzoom = null;
      this.spacePan = false;
      this._gesture = null;
    }

    // ── Mount / DOM ─────────────────────────────────────────
    mount() {
      if (!document.getElementById('fpb-pin')) {
        const holder = document.createElement('div');
        holder.innerHTML = SYMBOLS;
        document.body.appendChild(holder.firstChild);
      }
      this.container.innerHTML = this.template();
      this.refs();
      this.wireToolbar();
      this.wireCanvas();
      this.wireKeyboard();
      this.renderSide();
      this.renderLegend();
      this.setBackground(this.bgUrl, { silent: true });
      this.setTool('select');
      if (!this.bgUrl && !this.elements.length) this.showEmpty(true);
      window.addEventListener('beforeunload', this._beforeUnload = (e) => {
        if (!this.dirty) return;
        e.preventDefault(); e.returnValue = '';
      });
      return this;
    }

    template() {
      const o = this.opts;
      const tools = [
        ['select', 'fpb-cursor', 'Select', 'V'],
        ['booth', 'fpb-square', 'Booth', 'B'],
        ['zone', 'fpb-zone-ic', 'Zone', 'Z'],
        ['table', 'fpb-circle', 'Table', 'O'],
        ['text', 'fpb-type', 'Text', 'T'],
        ['pin', 'fpb-pin', 'Pin', 'P'],
      ].map(([id, ic, lb, k]) => `<button type="button" class="fpb-tool-btn" data-tool="${id}" title="${lb} (${k})"><svg><use href="#${ic}"/></svg>${lb}<span class="kbd">${k}</span></button>`).join('');

      const extra = (o.actions || []).map((a, i) =>
        `<button type="button" class="fpb-btn ${a.primary ? 'primary' : ''}" data-action="${i}">${a.icon ? `<svg><use href="#${a.icon}"/></svg>` : ''}${esc(a.label)}</button>`).join('');

      const uploadBtn = o.onUploadBackground
        ? `<label class="fpb-btn" title="Upload a venue image to trace or display behind your layout"><svg><use href="#fpb-upload"/></svg>Background<input type="file" data-ref="bgInput" accept="image/png,image/jpeg" hidden /></label>`
        : '';

      return `
<div class="fpb">
  <div class="fpb-toolbar">
    <div class="fpb-tools" data-ref="tools">${tools}</div>
    <span class="fpb-tb-sep"></span>
    <label class="fpb-toggle" title="Snap to grid and to other booths"><input type="checkbox" data-ref="snapToggle" checked />Snap</label>
    <span class="fpb-opacity" data-ref="opacityWrap" hidden>Image <input type="range" min="10" max="100" value="100" data-ref="opacityRange" /></span>
    <span class="fpb-tb-spacer"></span>
    <span class="fpb-dirty clean" data-ref="dirtyLabel">No unsaved changes</span>
    <button type="button" class="fpb-btn icon-only" data-ref="undoBtn" title="Undo (Ctrl+Z)" disabled><svg><use href="#fpb-undo"/></svg></button>
    <button type="button" class="fpb-btn icon-only" data-ref="redoBtn" title="Redo (Ctrl+Shift+Z)" disabled><svg><use href="#fpb-redo"/></svg></button>
    ${uploadBtn}
    <button type="button" class="fpb-btn" data-ref="exportBtn" title="Download the floor plan as a PNG image"><svg><use href="#fpb-download"/></svg>Export</button>
    ${extra}
    <button type="button" class="fpb-btn primary" data-ref="saveBtn"><svg><use href="#fpb-save"/></svg>${esc(o.saveLabel || 'Save')}</button>
  </div>

  <div class="fpb-body">
    <div class="fpb-viewport" data-ref="viewport">
      <div class="fpb-canvas" data-ref="canvas">
        <img class="fpb-bg" data-ref="bg" alt="" hidden />
        <div class="fpb-grid" data-ref="grid" style="background-size:${GRID}px ${GRID}px;"></div>
        <div class="fpb-els" data-ref="els"></div>
        <div class="fpb-guide-v" data-ref="guideV" hidden></div>
        <div class="fpb-guide-h" data-ref="guideH" hidden></div>
        <div class="fpb-rubber" data-ref="rubber" hidden></div>
      </div>
      <div class="fpb-hint" data-ref="hint" hidden></div>
      <div class="fpb-zoom">
        <button type="button" data-ref="zoomIn" title="Zoom in">＋</button>
        <button type="button" data-ref="zoomFit" title="Fit to screen">⊙</button>
        <button type="button" data-ref="zoomOut" title="Zoom out">−</button>
      </div>
      <div class="fpb-empty" data-ref="empty" hidden>
        <h3>Build your event floor plan</h3>
        <p>Lay out numbered booths, stages, bars and tables on a blank canvas — or start from a template and rearrange it. You can add a venue photo behind it any time.</p>
        <div class="choices">
          <button type="button" class="choice" data-ref="startBlank"><svg><use href="#fpb-grid-ic"/></svg>Blank canvas<small>Draw everything yourself</small></button>
          <button type="button" class="choice" data-ref="startTemplate"><svg><use href="#fpb-sparkle"/></svg>Festival starter<small>Booth rows, stage, bar &amp; tables to rearrange</small></button>
          ${o.onUploadBackground ? `<label class="choice"><svg><use href="#fpb-upload"/></svg>Venue image<small>Upload a map or aerial photo to build on</small><input type="file" data-ref="emptyUpload" accept="image/png,image/jpeg" /></label>` : ''}
        </div>
        <div class="fpb-status" data-ref="emptyStatus"></div>
      </div>
    </div>

    <aside class="fpb-side" data-ref="side"></aside>
  </div>

  <div class="fpb-legend" data-ref="legend"></div>
  <div class="fpb-status" data-ref="status"></div>
</div>`;
    }

    refs() {
      this.$ = {};
      this.container.querySelectorAll('[data-ref]').forEach(n => { this.$[n.dataset.ref] = n; });
    }

    // ── Toolbar wiring ──────────────────────────────────────
    wireToolbar() {
      const $ = this.$;
      $.tools.querySelectorAll('[data-tool]').forEach(b => b.addEventListener('click', () => this.setTool(b.dataset.tool)));
      $.snapToggle.addEventListener('change', () => { this.snap = $.snapToggle.checked; this.updateGridVisibility(); });
      $.undoBtn.addEventListener('click', () => this.undo());
      $.redoBtn.addEventListener('click', () => this.redo());
      $.exportBtn.addEventListener('click', () => this.exportPng());
      $.saveBtn.addEventListener('click', () => this.save());
      $.zoomIn.addEventListener('click', () => this.panzoom && this.panzoom.zoomIn());
      $.zoomOut.addEventListener('click', () => this.panzoom && this.panzoom.zoomOut());
      $.zoomFit.addEventListener('click', () => this.fit());
      if ($.opacityRange) $.opacityRange.addEventListener('input', () => { this.$.bg.style.opacity = $.opacityRange.value / 100; });
      if ($.bgInput) $.bgInput.addEventListener('change', (e) => this.uploadBackground(e.target.files[0], this.$.status));
      if ($.emptyUpload) $.emptyUpload.addEventListener('change', (e) => this.uploadBackground(e.target.files[0], this.$.emptyStatus));
      if ($.startBlank) $.startBlank.addEventListener('click', () => { this.showEmpty(false); });
      if ($.startTemplate) $.startTemplate.addEventListener('click', () => {
        this.pushUndo();
        this.elements = festivalTemplate();
        this.showEmpty(false);
        this.setDirty(true);
        this.renderAll();
      });
      (this.opts.actions || []).forEach((a, i) => {
        const btn = this.container.querySelector(`[data-action="${i}"]`);
        if (btn) btn.addEventListener('click', () => a.onClick());
      });
    }

    setTool(tool) {
      this.tool = tool;
      const $ = this.$;
      $.tools.querySelectorAll('[data-tool]').forEach(b => b.classList.toggle('active', b.dataset.tool === tool));
      $.viewport.className = 'fpb-viewport tool-' + tool;
      if (this.panzoom) this.panzoom.setOptions({ disablePan: tool !== 'select' });
      const hints = {
        booth: 'Click to stamp a booth, or drag to draw one. Booths auto-number — press V when done.',
        zone: 'Drag to draw a zone (stage, bar, emporium…). Click for a default size.',
        table: 'Click to place a table. Drag to size it.',
        text: 'Click anywhere to add a text label.',
        pin: 'Pick a category on the right, then click the map to drop a pin.',
      };
      this.hint(hints[tool] || '');
      this.renderSide();
    }

    hint(msg) {
      this.$.hint.hidden = !msg;
      this.$.hint.textContent = msg || '';
    }

    showEmpty(show) {
      this.$.empty.hidden = !show;
      if (!show && !this.bgUrl) this.setBackground(null, { silent: true });
      if (!show) this.fit();
    }

    updateGridVisibility() {
      // Grid lines show on the blank canvas, or whenever snapping is on over an image (faint guide).
      this.$.grid.style.display = (!this.bgUrl || this.snap) ? '' : 'none';
      this.$.grid.style.opacity = this.bgUrl ? 0.5 : 1;
    }

    // ── Background / canvas sizing ──────────────────────────
    setBackground(url, opts2) {
      const silent = opts2 && opts2.silent;
      this.bgUrl = url || null;
      const img = this.$.bg;
      if (url) {
        img.hidden = false;
        img.src = url;
        img.onload = () => {
          this.world = { w: img.naturalWidth || WORLD_DEFAULT.w, h: img.naturalHeight || WORLD_DEFAULT.h };
          this.sizeCanvas();
          this.fit();
        };
        if (this.$.opacityWrap) this.$.opacityWrap.hidden = false;
      } else {
        img.hidden = true;
        img.removeAttribute('src');
        this.world = Object.assign({}, WORLD_DEFAULT);
        this.sizeCanvas();
        this.fit();
        if (this.$.opacityWrap) this.$.opacityWrap.hidden = true;
      }
      this.updateGridVisibility();
      if (!silent) this.setDirty(true);
    }

    sizeCanvas() {
      this.$.canvas.style.width = this.world.w + 'px';
      this.$.canvas.style.height = this.world.h + 'px';
      this.renderElements();
    }

    initPanzoom(start) {
      if (this.panzoom) { try { this.panzoom.destroy(); } catch (e) {} }
      this.panzoom = Panzoom(this.$.canvas, {
        maxScale: 5, minScale: 0.05, step: 0.18, canvas: true,
        disablePan: this.tool !== 'select',
        cursor: '',
        startScale: start ? start.scale : 1,
        startX: start ? start.x : 0,
        startY: start ? start.y : 0,
      });
      if (!this._wheel) {
        this._wheel = (e) => this.panzoom && this.panzoom.zoomWithWheel(e);
        this.$.viewport.addEventListener('wheel', this._wheel);
      }
    }

    fit() {
      const vp = this.$.viewport;
      if (!vp.clientWidth || !vp.clientHeight) return;
      const s = Math.min(vp.clientWidth / this.world.w, vp.clientHeight / this.world.h) * 0.96;
      // Panzoom resets pan to startX/Y in a deferred setTimeout after
      // construction, which clobbers any synchronous pan() — so recreate the
      // instance and let that deferral do the centring. Its transform-origin
      // is 50% 50% (assumed by its wheel-zoom focal math), hence this formula.
      this.initPanzoom({
        scale: s,
        x: (vp.clientWidth - this.world.w) / (2 * s),
        y: (vp.clientHeight - this.world.h) / (2 * s),
      });
    }

    // ── Coordinates ─────────────────────────────────────────
    worldPoint(e) {
      const rect = this.$.canvas.getBoundingClientRect();
      return {
        x: (e.clientX - rect.left) / rect.width * this.world.w,
        y: (e.clientY - rect.top) / rect.height * this.world.h,
      };
    }
    scale() { return this.panzoom ? this.panzoom.getScale() : 1; }

    // ── Canvas interaction ──────────────────────────────────
    wireCanvas() {
      this.initPanzoom();
      const canvas = this.$.canvas;

      canvas.addEventListener('pointerdown', (e) => {
        if (this.spacePan) return;                       // let panzoom pan
        const handle = e.target.closest('.fpb-h');
        if (handle) { this.startResize(e, handle.dataset.h); return; }
        const elDiv = e.target.closest('.fpb-el');
        if (elDiv) {
          e.stopPropagation();
          this.select(elDiv.dataset.id);
          this.startMove(e);
          return;
        }
        if (this.tool === 'select') return;              // empty space: panzoom pans; click deselects (below)
        this.startDraw(e);
      });

      // Click on empty space in select mode → deselect (but not after a pan-drag).
      let downAt = null;
      this.$.viewport.addEventListener('pointerdown', (e) => { downAt = { x: e.clientX, y: e.clientY }; });
      this.$.viewport.addEventListener('pointerup', (e) => {
        if (!downAt) return;
        const moved = Math.hypot(e.clientX - downAt.x, e.clientY - downAt.y) > 4;
        downAt = null;
        if (moved || this.tool !== 'select') return;
        if (e.target.closest('.fpb-el') || e.target.closest('.fpb-zoom')) return;
        if (this.selectedId) { this.selectedId = null; this.renderAll(); }
      });
    }

    // Move (drag) the selected element.
    startMove(e) {
      const el = this.byId(this.selectedId);
      if (!el) return;
      e.preventDefault();
      this.panzoom.setOptions({ disablePan: true });
      const start = { cx: e.clientX, cy: e.clientY, x: el.x, y: el.y };
      let moved = false, pushed = false;
      const onMove = (ev) => {
        const s = this.scale();
        const dx = (ev.clientX - start.cx) / s / this.world.w;
        const dy = (ev.clientY - start.cy) / s / this.world.h;
        if (!moved && Math.hypot(ev.clientX - start.cx, ev.clientY - start.cy) < 3) return;
        if (!pushed) { this.pushUndo(); pushed = true; }
        moved = true;
        let nx = start.x + dx, ny = start.y + dy;
        if (el.type !== 'pin' && el.type !== 'text') {
          const snapped = this.snapShape(el, nx, ny);
          nx = snapped.x; ny = snapped.y;
        } else {
          this.clearGuides();
          if (this.snap && el.type !== 'pin') {
            nx = Math.round(nx * this.world.w / (GRID / 2)) * (GRID / 2) / this.world.w;
            ny = Math.round(ny * this.world.h / (GRID / 2)) * (GRID / 2) / this.world.h;
          }
        }
        el.x = clamp(nx, 0, 1); el.y = clamp(ny, 0, 1);
        this.positionElementDiv(el);
      };
      const onUp = () => {
        window.removeEventListener('pointermove', onMove);
        window.removeEventListener('pointerup', onUp);
        this.clearGuides();
        this.panzoom.setOptions({ disablePan: this.tool !== 'select' });
        if (moved) { this.setDirty(true); this.renderAll(); }
      };
      window.addEventListener('pointermove', onMove);
      window.addEventListener('pointerup', onUp);
    }

    // Edge/grid snapping for shape moves; returns snapped centre fractions and shows guides.
    snapShape(el, nx, ny) {
      this.clearGuides();
      if (!this.snap) return { x: nx, y: ny };
      const W = this.world.w, H = this.world.h;
      const th = SNAP_PX / this.scale();
      const wpx = el.w * W, hpx = el.h * H;
      let cx = nx * W, cy = ny * H;

      const xLines = [], yLines = [];
      this.elements.forEach(o => {
        if (o.id === el.id || o.type === 'pin' || o.type === 'text') return;
        const ow = o.w * W, oh = o.h * H, ocx = o.x * W, ocy = o.y * H;
        xLines.push(ocx - ow / 2, ocx, ocx + ow / 2);
        yLines.push(ocy - oh / 2, ocy, ocy + oh / 2);
      });

      let bestX = null, bestY = null;
      const tryX = (mine, off) => xLines.forEach(c => { const d = Math.abs(mine - c); if (d < th && (!bestX || d < bestX.d)) bestX = { d, to: c, off }; });
      const tryY = (mine, off) => yLines.forEach(c => { const d = Math.abs(mine - c); if (d < th && (!bestY || d < bestY.d)) bestY = { d, to: c, off }; });
      tryX(cx - wpx / 2, wpx / 2); tryX(cx, 0); tryX(cx + wpx / 2, -wpx / 2);
      tryY(cy - hpx / 2, hpx / 2); tryY(cy, 0); tryY(cy + hpx / 2, -hpx / 2);

      if (bestX) { cx = bestX.to + bestX.off; this.$.guideV.style.left = (bestX.to / W * 100) + '%'; this.$.guideV.hidden = false; }
      else { cx = Math.round((cx - wpx / 2) / GRID) * GRID + wpx / 2; }
      if (bestY) { cy = bestY.to + bestY.off; this.$.guideH.style.top = (bestY.to / H * 100) + '%'; this.$.guideH.hidden = false; }
      else { cy = Math.round((cy - hpx / 2) / GRID) * GRID + hpx / 2; }

      return { x: cx / W, y: cy / H };
    }
    clearGuides() { this.$.guideV.hidden = true; this.$.guideH.hidden = true; }

    // Resize via handles.
    startResize(e, dir) {
      const el = this.byId(this.selectedId);
      if (!el || el.type === 'pin' || el.type === 'text') return;
      e.preventDefault(); e.stopPropagation();
      this.panzoom.setOptions({ disablePan: true });
      this.pushUndo();
      const W = this.world.w, H = this.world.h;
      const start = {
        cx: e.clientX, cy: e.clientY,
        l: (el.x - el.w / 2) * W, t: (el.y - el.h / 2) * H,
        r: (el.x + el.w / 2) * W, b: (el.y + el.h / 2) * H,
      };
      const onMove = (ev) => {
        const s = this.scale();
        const dx = (ev.clientX - start.cx) / s;
        const dy = (ev.clientY - start.cy) / s;
        let { l, t, r, b } = start;
        if (dir.includes('w')) l = start.l + dx;
        if (dir.includes('e')) r = start.r + dx;
        if (dir.includes('n')) t = start.t + dy;
        if (dir.includes('s')) b = start.b + dy;
        if (this.snap) {
          if (dir.includes('w')) l = Math.round(l / GRID) * GRID;
          if (dir.includes('e')) r = Math.round(r / GRID) * GRID;
          if (dir.includes('n')) t = Math.round(t / GRID) * GRID;
          if (dir.includes('s')) b = Math.round(b / GRID) * GRID;
        }
        if (r - l < MIN_SIZE) { if (dir.includes('w')) l = r - MIN_SIZE; else r = l + MIN_SIZE; }
        if (b - t < MIN_SIZE) { if (dir.includes('n')) t = b - MIN_SIZE; else b = t + MIN_SIZE; }
        el.x = (l + r) / 2 / W; el.y = (t + b) / 2 / H;
        el.w = (r - l) / W; el.h = (b - t) / H;
        this.positionElementDiv(el);
      };
      const onUp = () => {
        window.removeEventListener('pointermove', onMove);
        window.removeEventListener('pointerup', onUp);
        this.panzoom.setOptions({ disablePan: this.tool !== 'select' });
        if (el.type === 'booth') this.lastBoothSize = { w: el.w * W, h: el.h * H };
        this.setDirty(true);
        this.renderAll();
      };
      window.addEventListener('pointermove', onMove);
      window.addEventListener('pointerup', onUp);
    }

    // Draw / stamp new elements.
    startDraw(e) {
      e.preventDefault(); e.stopPropagation();
      const tool = this.tool;
      const start = this.worldPoint(e);
      let dragging = false;
      const rubber = this.$.rubber;
      const snapPt = (p) => this.snap
        ? { x: Math.round(p.x / GRID) * GRID, y: Math.round(p.y / GRID) * GRID }
        : p;

      const onMove = (ev) => {
        const cur = this.worldPoint(ev);
        if (!dragging && Math.hypot(cur.x - start.x, cur.y - start.y) * this.scale() < 5) return;
        dragging = true;
        if (tool === 'pin' || tool === 'text') return;
        const a = snapPt(start), b = snapPt(cur);
        const l = Math.min(a.x, b.x), t = Math.min(a.y, b.y);
        rubber.hidden = false;
        rubber.style.left = (l / this.world.w * 100) + '%';
        rubber.style.top = (t / this.world.h * 100) + '%';
        rubber.style.width = (Math.abs(b.x - a.x) / this.world.w * 100) + '%';
        rubber.style.height = (Math.abs(b.y - a.y) / this.world.h * 100) + '%';
      };
      const onUp = (ev) => {
        window.removeEventListener('pointermove', onMove);
        window.removeEventListener('pointerup', onUp);
        rubber.hidden = true;
        const end = this.worldPoint(ev);
        if (tool === 'pin') { this.addPin(end); return; }
        if (tool === 'text') { this.addText(start); return; }
        let rect;
        if (dragging) {
          const a = snapPt(start), b = snapPt(end);
          rect = { l: Math.min(a.x, b.x), t: Math.min(a.y, b.y), w: Math.abs(b.x - a.x), h: Math.abs(b.y - a.y) };
          if (rect.w < MIN_SIZE || rect.h < MIN_SIZE) rect = null;
        }
        if (!rect) {
          const def = tool === 'booth' ? this.lastBoothSize
            : tool === 'zone' ? { w: 220, h: 140 }
            : { w: 38, h: 38 };
          const p = snapPt({ x: start.x - def.w / 2, y: start.y - def.h / 2 });
          rect = { l: p.x, t: p.y, w: def.w, h: def.h };
        }
        this.addShape(tool, rect);
      };
      window.addEventListener('pointermove', onMove);
      window.addEventListener('pointerup', onUp);
    }

    nextBoothNumber() {
      let max = 0;
      this.elements.forEach(el => {
        if (el.type !== 'booth') return;
        const n = parseInt(el.number, 10);
        if (Number.isFinite(n) && n > max) max = n;
      });
      return max + 1;
    }

    addShape(tool, rect) {
      this.pushUndo();
      const W = this.world.w, H = this.world.h;
      const base = {
        id: uid(), type: tool,
        x: clamp((rect.l + rect.w / 2) / W, 0, 1),
        y: clamp((rect.t + rect.h / 2) / H, 0, 1),
        w: rect.w / W, h: rect.h / H,
      };
      let el;
      if (tool === 'booth') {
        const cat = CAT_BY_ID[this.boothCategory] || CAT_BY_ID[DEFAULT_CAT];
        el = Object.assign(base, { number: this.nextBoothNumber(), label: '', icon: cat.id, color: cat.color, vendor_id: null, size: '', description: '' });
        this.lastBoothSize = { w: rect.w, h: rect.h };
      } else if (tool === 'zone') {
        el = Object.assign(base, { label: 'Zone', color: ZONE_COLORS[0], description: '' });
      } else {
        el = Object.assign(base, { shape: 'round', color: TABLE_COLOR });
      }
      this.elements.push(el);
      this.setDirty(true);
      this.select(el.id);
      // Stay in the tool so rows can be stamped quickly.
    }

    addPin(p) {
      this.pushUndo();
      const cat = CAT_BY_ID[this.pinCategory] || CAT_BY_ID.info;
      const el = normalizeElement({
        id: uid(), type: 'pin',
        x: clamp(p.x / this.world.w, 0, 1), y: clamp(p.y / this.world.h, 0, 1),
        label: '', icon: cat.id, color: cat.color, vendor_id: null, booth: '', size: '', description: '',
      });
      this.elements.push(el);
      this.setDirty(true);
      this.select(el.id);
    }

    addText(p) {
      this.pushUndo();
      const el = normalizeElement({
        id: uid(), type: 'text',
        x: clamp(p.x / this.world.w, 0, 1), y: clamp(p.y / this.world.h, 0, 1),
        label: '', color: '#111111', fontSize: 0.016,
      });
      this.elements.push(el);
      this.setDirty(true);
      this.select(el.id);
      const input = this.$.side.querySelector('[data-f="label"]');
      if (input) input.focus();
    }

    duplicateSelected() {
      const el = this.byId(this.selectedId);
      if (!el) return;
      this.pushUndo();
      const copy = JSON.parse(JSON.stringify(el));
      copy.id = uid();
      if (el.type === 'booth') {
        copy.x = clamp(el.x + el.w, 0, 1);            // adjacent to the right → instant rows
        copy.number = this.nextBoothNumber();
        copy.vendor_id = null; copy.label = '';
      } else if (el.type === 'zone' || el.type === 'table') {
        copy.x = clamp(el.x + (el.w || 0.02) + 12 / this.world.w, 0, 1);
      } else {
        copy.x = clamp(el.x + 20 / this.world.w, 0, 1);
        copy.y = clamp(el.y + 20 / this.world.h, 0, 1);
      }
      this.elements.push(copy);
      this.setDirty(true);
      this.select(copy.id);
    }

    deleteSelected() {
      const el = this.byId(this.selectedId);
      if (!el) return;
      this.pushUndo();
      this.elements = this.elements.filter(x => x.id !== el.id);
      this.selectedId = null;
      this.setDirty(true);
      this.renderAll();
    }

    // ── Keyboard ────────────────────────────────────────────
    wireKeyboard() {
      this._keydown = (e) => {
        if (e.target.closest('input, textarea, select')) return;
        const meta = e.metaKey || e.ctrlKey;
        if (meta && e.key.toLowerCase() === 'z') { e.preventDefault(); e.shiftKey ? this.redo() : this.undo(); return; }
        if (meta && e.key.toLowerCase() === 'y') { e.preventDefault(); this.redo(); return; }
        if (meta && e.key.toLowerCase() === 'd') { e.preventDefault(); this.duplicateSelected(); return; }
        if (e.key === ' ') { e.preventDefault(); if (!this.spacePan) { this.spacePan = true; this.$.viewport.classList.add('space-pan'); this.panzoom.setOptions({ disablePan: false }); } return; }
        if (e.key === 'Escape') {
          if (this.tool !== 'select') this.setTool('select');
          else if (this.selectedId) { this.selectedId = null; this.renderAll(); }
          return;
        }
        if ((e.key === 'Delete' || e.key === 'Backspace') && this.selectedId) { e.preventDefault(); this.deleteSelected(); return; }
        const toolKeys = { v: 'select', b: 'booth', z: 'zone', o: 'table', t: 'text', p: 'pin' };
        if (!meta && toolKeys[e.key.toLowerCase()]) { this.setTool(toolKeys[e.key.toLowerCase()]); return; }
        if (e.key.startsWith('Arrow') && this.selectedId) {
          e.preventDefault();
          const el = this.byId(this.selectedId);
          const step = (e.shiftKey ? GRID : 2);
          this.pushUndo(true);
          if (e.key === 'ArrowLeft') el.x -= step / this.world.w;
          if (e.key === 'ArrowRight') el.x += step / this.world.w;
          if (e.key === 'ArrowUp') el.y -= step / this.world.h;
          if (e.key === 'ArrowDown') el.y += step / this.world.h;
          el.x = clamp(el.x, 0, 1); el.y = clamp(el.y, 0, 1);
          this.setDirty(true);
          this.positionElementDiv(el);
        }
      };
      this._keyup = (e) => {
        if (e.key === ' ') {
          this.spacePan = false;
          this.$.viewport.classList.remove('space-pan');
          this.panzoom.setOptions({ disablePan: this.tool !== 'select' });
        }
      };
      document.addEventListener('keydown', this._keydown);
      document.addEventListener('keyup', this._keyup);
    }

    // ── Undo / redo ─────────────────────────────────────────
    pushUndo(throttled) {
      const now = Date.now();
      if (throttled && now - this._lastUndoPush < 600) return;
      this._lastUndoPush = now;
      this.undoStack.push(JSON.stringify(this.elements));
      if (this.undoStack.length > 80) this.undoStack.shift();
      this.redoStack = [];
      this.updateUndoButtons();
    }
    undo() {
      if (!this.undoStack.length) return;
      this.redoStack.push(JSON.stringify(this.elements));
      this.elements = JSON.parse(this.undoStack.pop()).map(normalizeElement);
      if (!this.byId(this.selectedId)) this.selectedId = null;
      this.setDirty(true);
      this.renderAll();
    }
    redo() {
      if (!this.redoStack.length) return;
      this.undoStack.push(JSON.stringify(this.elements));
      this.elements = JSON.parse(this.redoStack.pop()).map(normalizeElement);
      if (!this.byId(this.selectedId)) this.selectedId = null;
      this.setDirty(true);
      this.renderAll();
    }
    updateUndoButtons() {
      this.$.undoBtn.disabled = !this.undoStack.length;
      this.$.redoBtn.disabled = !this.redoStack.length;
    }

    // ── Rendering ───────────────────────────────────────────
    byId(id) { return this.elements.find(x => x.id === id) || null; }

    select(id) {
      this.selectedId = id;
      this.renderAll();
    }

    renderAll() {
      this.renderElements();
      this.renderSide();
      this.renderLegend();
      this.updateUndoButtons();
    }

    positionElementDiv(el) {
      const div = this.$.els.querySelector(`.fpb-el[data-id="${el.id}"]`);
      if (!div) return;
      if (el.type === 'pin' || el.type === 'text') {
        div.style.left = (el.x * 100) + '%';
        div.style.top = (el.y * 100) + '%';
      } else {
        div.style.left = ((el.x - el.w / 2) * 100) + '%';
        div.style.top = ((el.y - el.h / 2) * 100) + '%';
      }
    }

    renderElements() {
      const W = this.world.w, H = this.world.h;
      const handles = (el, corners) => el.id !== this.selectedId ? '' :
        (corners ? ['nw', 'ne', 'se', 'sw'] : ['nw', 'n', 'ne', 'e', 'se', 's', 'sw', 'w'])
          .map(h => `<i class="fpb-h" data-h="${h}"></i>`).join('');

      this.$.els.innerHTML = this.elements.map(el => {
        const sel = el.id === this.selectedId ? ' selected' : '';
        if (el.type === 'booth') {
          const wpx = el.w * W, hpx = el.h * H;
          const numSize = clamp(Math.min(wpx, hpx) * 0.42, 9, 26);
          const lblSize = clamp(wpx * 0.16, 9, 12);
          return `<div class="fpb-el fpb-booth${sel}" data-id="${el.id}" style="left:${(el.x - el.w / 2) * 100}%;top:${(el.y - el.h / 2) * 100}%;width:${el.w * 100}%;height:${el.h * 100}%;--c:${esc(el.color)}">
            <span class="num" style="font-size:${numSize}px">${esc(el.number != null && el.number !== '' ? el.number : '')}</span>
            ${el.label ? `<span class="fpb-el-label" style="font-size:${lblSize}px">${esc(el.label)}</span>` : ''}
            ${handles(el)}</div>`;
        }
        if (el.type === 'zone') {
          const hpx = el.h * H;
          const fs = clamp(hpx * 0.2, 11, 30);
          return `<div class="fpb-el fpb-zone${sel}" data-id="${el.id}" style="left:${(el.x - el.w / 2) * 100}%;top:${(el.y - el.h / 2) * 100}%;width:${el.w * 100}%;height:${el.h * 100}%;--c:${esc(el.color)}">
            <span class="zlabel" style="font-size:${fs}px">${esc(el.label || '')}</span>
            ${handles(el)}</div>`;
        }
        if (el.type === 'table') {
          return `<div class="fpb-el fpb-table ${el.shape === 'rect' ? '' : 'round'}${sel}" data-id="${el.id}" style="left:${(el.x - el.w / 2) * 100}%;top:${(el.y - el.h / 2) * 100}%;width:${el.w * 100}%;height:${el.h * 100}%;--c:${esc(el.color)}">${handles(el, true)}</div>`;
        }
        if (el.type === 'text') {
          const fs = Math.max(9, (el.fontSize || 0.016) * W);
          return `<div class="fpb-el fpb-text${sel}${el.label ? '' : ' empty'}" data-id="${el.id}" style="left:${el.x * 100}%;top:${el.y * 100}%;font-size:${fs}px;--c:${esc(el.color || '#111')}">${esc(el.label || 'Text')}</div>`;
        }
        const cat = CAT_BY_ID[el.icon] || CAT_BY_ID[DEFAULT_CAT];
        return `<div class="fpb-el fpb-pin${sel}" data-id="${el.id}" style="left:${el.x * 100}%;top:${el.y * 100}%;">
          <div class="fpb-pin-bubble" style="--c:${esc(el.color || cat.color)}"><svg><use href="#${cat.icon}"/></svg></div>
          ${el.label ? `<span class="fpb-el-label">${esc(el.label)}</span>` : ''}</div>`;
      }).join('');
    }

    // ── Side panel ──────────────────────────────────────────
    renderSide() {
      const side = this.$.side;
      if (!side) return;
      const el = this.byId(this.selectedId);
      if (el) { side.innerHTML = this.editFormHtml(el); this.wireEditForm(el); return; }
      if (this.tool === 'pin' || this.tool === 'booth') {
        const isPin = this.tool === 'pin';
        const current = isPin ? this.pinCategory : this.boothCategory;
        side.innerHTML = `
          <h3>${isPin ? 'Pin' : 'Booth'} category</h3>
          <div class="fpb-helper">${isPin ? 'Pick a category, then click the map to drop the pin.' : 'New booths use this category colour. Click the map to stamp; drag to size.'}</div>
          <div class="fpb-cat-grid">${CATEGORIES.map(c => `
            <button type="button" class="fpb-cat-btn${c.id === current ? ' active' : ''}" data-cat="${c.id}">
              <span class="swatch" style="background:${c.color}"><svg><use href="#${c.icon}"/></svg></span>${esc(c.label)}
            </button>`).join('')}</div>`;
        side.querySelectorAll('[data-cat]').forEach(b => b.addEventListener('click', () => {
          if (isPin) this.pinCategory = b.dataset.cat; else this.boothCategory = b.dataset.cat;
          this.renderSide();
        }));
        return;
      }
      side.innerHTML = `<h3>Layout</h3>${this.listHtml()}`;
      side.querySelectorAll('li[data-id]').forEach(li => li.addEventListener('click', () => this.select(li.dataset.id)));
    }

    listHtml() {
      if (!this.elements.length) {
        return `<div class="fpb-helper">Use the tools above the canvas: <strong>Booth</strong> stamps numbered vendor stalls, <strong>Zone</strong> draws stages &amp; bars, <strong>Pin</strong> marks entrances and facilities.</div><ul class="fpb-list"><li class="empty-note">Nothing placed yet.</li></ul>`;
      }
      const groups = [
        ['Booths', this.elements.filter(e => e.type === 'booth').sort((a, b) => num(a.number) - num(b.number))],
        ['Zones', this.elements.filter(e => e.type === 'zone')],
        ['Pins', this.elements.filter(e => e.type === 'pin')],
        ['Text', this.elements.filter(e => e.type === 'text')],
        ['Tables', this.elements.filter(e => e.type === 'table')],
      ];
      const vendorName = (id) => {
        const v = this.vendors.find(v => String(v.event_vendor_id || v.vendor_id) === String(id));
        return v ? (v.vendor_name || v.name) : null;
      };
      let html = '<ul class="fpb-list">';
      groups.forEach(([title, items]) => {
        if (!items.length) return;
        html += `<li class="group-head">${title} · ${items.length}</li>`;
        html += items.map(el => {
          const active = el.id === this.selectedId ? ' active' : '';
          const cat = CAT_BY_ID[el.icon];
          let name, meta = '', dotCls = 'dot', color = el.color || '#999';
          if (el.type === 'booth') {
            name = `${el.number != null && el.number !== '' ? '#' + esc(el.number) + ' ' : ''}${esc(el.label || (vendorName(el.vendor_id) || (cat ? cat.label : 'Booth')))}`;
            meta = [cat ? cat.label : '', el.size ? el.size.replace('x', '×') + ' ft' : ''].filter(Boolean).join(' · ');
          } else if (el.type === 'zone') { name = esc(el.label || 'Zone'); }
          else if (el.type === 'text') { name = esc(el.label || '(empty text)'); dotCls += ' round'; color = '#ddd'; }
          else if (el.type === 'table') { name = 'Table'; dotCls += ' round'; }
          else { name = esc(el.label || (cat ? cat.label : 'Pin')); meta = cat ? cat.label : ''; dotCls += ' round'; }
          return `<li class="item${active}" data-id="${el.id}">
            <span class="${dotCls}" style="background:${esc(color)}"></span>
            <div style="flex:1;min-width:0;"><div class="name">${name}</div>${meta ? `<div class="meta">${esc(meta)}</div>` : ''}</div>
          </li>`;
        }).join('');
      });
      return html + '</ul>';
    }

    editFormHtml(el) {
      const f = (label, inner) => `<div class="fpb-field"><label>${label}</label>${inner}</div>`;
      const catOptions = CATEGORIES.map(c => `<option value="${c.id}"${el.icon === c.id ? ' selected' : ''}>${esc(c.label)}</option>`).join('');
      const vendorOptions = '<option value="">— None —</option>' + this.vendors.map(v => {
        const id = v.event_vendor_id || v.vendor_id || '';
        const assignedTo = this.elements.find(o => o.id !== el.id && o.vendor_id && String(o.vendor_id) === String(id));
        return `<option value="${esc(id)}"${String(el.vendor_id) === String(id) ? ' selected' : ''}>${esc(v.vendor_name || v.name || 'Vendor')}${assignedTo ? ' · placed' : ''}</option>`;
      }).join('');
      const sizeVal = el.size || '';
      const isPreset = PRESET_FT.includes(sizeVal);
      const sizeOptions = `<option value="">— Not set —</option>` + PRESET_FT.map(s => `<option value="${s}"${sizeVal === s ? ' selected' : ''}>${s.replace('x', ' × ')}</option>`).join('') + `<option value="custom"${sizeVal && !isPreset ? ' selected' : ''}>Custom…</option>`;
      const customParts = (!isPreset && sizeVal) ? sizeVal.split('x') : ['', ''];
      const sizeFields = f('Booth / tent size (ft)', `<select data-f="sizeSel">${sizeOptions}</select>`) +
        `<div class="fpb-field" data-f="sizeCustomWrap" ${(!isPreset && sizeVal) ? '' : 'hidden'}><label>Custom size (ft)</label>
          <div class="fpb-field-row"><input data-f="sizeW" type="number" min="1" max="500" placeholder="W" value="${esc(customParts[0])}"/><input data-f="sizeD" type="number" min="1" max="500" placeholder="D" value="${esc(customParts[1])}"/></div></div>`;
      const actions = (extra) => `<div class="fpb-actions">
          <button type="button" class="fpb-btn" data-f="done">Done</button>
          ${extra || ''}
          <button type="button" class="fpb-btn" data-f="dup" title="Duplicate (Ctrl+D)"><svg><use href="#fpb-copy"/></svg></button>
          <button type="button" class="fpb-btn danger" data-f="del" title="Delete"><svg><use href="#fpb-trash"/></svg></button>
        </div>`;

      if (el.type === 'booth') {
        return `<h3>Booth</h3>
          <div class="fpb-field-row">
            ${f('Number', `<input data-f="number" type="text" maxlength="10" value="${esc(el.number != null ? el.number : '')}"/>`)}
            ${f('Category', `<select data-f="cat">${catOptions}</select>`)}
          </div>
          ${f('Label / vendor name', `<input data-f="label" type="text" maxlength="80" placeholder="e.g. Lucky Crab Seafood" value="${esc(el.label || '')}"/>`)}
          ${this.vendors.length ? f('Vendor', `<select data-f="vendor">${vendorOptions}</select>`) : ''}
          ${sizeFields}
          ${f('Notes (optional)', `<textarea data-f="desc" rows="2" maxlength="240">${esc(el.description || '')}</textarea>`)}
          ${actions()}`;
      }
      if (el.type === 'zone') {
        return `<h3>Zone</h3>
          ${f('Label', `<input data-f="label" type="text" maxlength="60" placeholder="e.g. Stage / Bar / Emporium" value="${esc(el.label || '')}"/>`)}
          <div class="fpb-field"><label>Colour</label><div class="fpb-color-row">
            ${ZONE_COLORS.map(c => `<button type="button" class="fpb-color-dot${el.color === c ? ' active' : ''}" data-zc="${c}" style="background:${c}"></button>`).join('')}
            <input type="color" data-f="colorPick" value="${esc(/^#[0-9a-f]{6}$/i.test(el.color || '') ? el.color : '#b03a2e')}" title="Custom colour"/>
          </div></div>
          ${f('Notes (optional)', `<textarea data-f="desc" rows="2" maxlength="240">${esc(el.description || '')}</textarea>`)}
          ${actions()}`;
      }
      if (el.type === 'table') {
        return `<h3>Table</h3>
          ${f('Shape', `<select data-f="shape"><option value="round"${el.shape !== 'rect' ? ' selected' : ''}>Round</option><option value="rect"${el.shape === 'rect' ? ' selected' : ''}>Rectangular</option></select>`)}
          <div class="fpb-field"><label>Colour</label><div class="fpb-color-row">
            ${['#b08850', '#64748b', '#8d6e63', '#94a3b8'].map(c => `<button type="button" class="fpb-color-dot${el.color === c ? ' active' : ''}" data-zc="${c}" style="background:${c}"></button>`).join('')}
          </div></div>
          ${actions()}`;
      }
      if (el.type === 'text') {
        const cur = TEXT_SIZES.reduce((best, s) => Math.abs(s.v - (el.fontSize || 0.016)) < Math.abs(best.v - (el.fontSize || 0.016)) ? s : best, TEXT_SIZES[1]);
        return `<h3>Text label</h3>
          ${f('Text', `<input data-f="label" type="text" maxlength="120" placeholder="e.g. SECURITY" value="${esc(el.label || '')}"/>`)}
          <div class="fpb-field-row">
            ${f('Size', `<select data-f="tsize">${TEXT_SIZES.map(s => `<option value="${s.v}"${s.id === cur.id ? ' selected' : ''}>${s.label}</option>`).join('')}</select>`)}
            ${f('Colour', `<input data-f="colorPick" type="color" value="${esc(/^#[0-9a-f]{6}$/i.test(el.color || '') ? el.color : '#111111')}"/>`)}
          </div>
          ${actions()}`;
      }
      // pin
      return `<h3>Pin</h3>
        ${f('Label', `<input data-f="label" type="text" maxlength="80" placeholder="e.g. Entrance" value="${esc(el.label || '')}"/>`)}
        ${f('Category', `<select data-f="cat">${catOptions}</select>`)}
        ${this.vendors.length ? f('Vendor (optional)', `<select data-f="vendor">${vendorOptions}</select>`) : ''}
        ${f('Booth number (optional)', `<input data-f="booth" type="text" maxlength="20" value="${esc(el.booth || '')}"/>`)}
        ${f('Description (optional)', `<textarea data-f="desc" rows="2" maxlength="240">${esc(el.description || '')}</textarea>`)}
        ${actions()}`;
    }

    wireEditForm(el) {
      const side = this.$.side;
      const q = (f) => side.querySelector(`[data-f="${f}"]`);
      const apply = () => {
        this.pushUndo(true);
        if (q('label')) el.label = q('label').value.trim();
        if (q('number')) el.number = q('number').value.trim();
        if (q('cat')) {
          const cat = CAT_BY_ID[q('cat').value] || CAT_BY_ID[DEFAULT_CAT];
          el.icon = cat.id; el.color = cat.color;
        }
        if (q('vendor')) el.vendor_id = q('vendor').value || null;
        if (q('booth')) el.booth = q('booth').value.trim();
        if (q('desc')) el.description = q('desc').value.trim();
        if (q('shape')) el.shape = q('shape').value;
        if (q('tsize')) el.fontSize = Number(q('tsize').value) || 0.016;
        if (q('colorPick') && el.type !== 'zone') el.color = q('colorPick').value;
        if (q('sizeSel')) {
          const v = q('sizeSel').value;
          q('sizeCustomWrap').hidden = v !== 'custom';
          if (v === 'custom') {
            const w = parseInt(q('sizeW').value, 10), d = parseInt(q('sizeD').value, 10);
            el.size = (w > 0 && d > 0) ? `${w}x${d}` : '';
          } else el.size = v || '';
        }
        this.setDirty(true);
        this.renderElements();
        this.renderLegend();
      };
      side.querySelectorAll('input, select, textarea').forEach(n => {
        n.addEventListener('input', apply);
        n.addEventListener('change', apply);
      });
      // Vendor pick fills an empty label with the vendor name.
      if (q('vendor')) q('vendor').addEventListener('change', () => {
        const opt = q('vendor').selectedOptions[0];
        if (opt && opt.value && q('label') && !q('label').value.trim()) {
          q('label').value = opt.textContent.replace(/ · placed$/, '');
          apply();
        }
      });
      if (q('colorPick') && el.type === 'zone') q('colorPick').addEventListener('input', () => {
        el.color = q('colorPick').value;
        side.querySelectorAll('.fpb-color-dot').forEach(d => d.classList.remove('active'));
        this.setDirty(true); this.renderElements();
      });
      side.querySelectorAll('[data-zc]').forEach(b => b.addEventListener('click', () => {
        this.pushUndo(true);
        el.color = b.dataset.zc;
        side.querySelectorAll('.fpb-color-dot').forEach(d => d.classList.toggle('active', d === b));
        this.setDirty(true); this.renderElements();
      }));
      q('done').addEventListener('click', () => { this.selectedId = null; this.renderAll(); });
      q('dup').addEventListener('click', () => this.duplicateSelected());
      q('del').addEventListener('click', () => this.deleteSelected());
    }

    renderLegend() {
      const used = new Map();
      this.elements.forEach(el => {
        if (el.type !== 'booth' && el.type !== 'pin') return;
        const cat = CAT_BY_ID[el.icon];
        if (!cat) return;
        const entry = used.get(cat.id) || { cat, square: false };
        if (el.type === 'booth') entry.square = true;   // square swatch when the category is used for booths
        used.set(cat.id, entry);
      });
      this.$.legend.innerHTML = [...used.values()].map(({ cat: c, square }) => `
        <span class="fpb-legend-item"><span class="swatch ${square ? 'sq' : ''}" style="background:${c.color}"><svg><use href="#${c.icon}"/></svg></span>${esc(c.label)}</span>`).join('');
    }

    // ── Dirty / status ──────────────────────────────────────
    setDirty(yes) {
      this.dirty = !!yes;
      const el = this.$.dirtyLabel;
      el.textContent = yes ? 'Unsaved changes' : 'No unsaved changes';
      el.classList.toggle('clean', !yes);
      if (this.opts.onDirtyChange) this.opts.onDirtyChange(this.dirty);
    }
    status(msg, kind, node) {
      const el = node || this.$.status;
      el.textContent = msg || '';
      el.className = 'fpb-status' + (kind ? ' ' + kind : '');
      if (kind === 'success') setTimeout(() => { if (el.textContent === msg) { el.textContent = ''; el.className = 'fpb-status'; } }, 3000);
    }

    // ── Background upload ───────────────────────────────────
    async uploadBackground(file, statusNode) {
      if (!file || !this.opts.onUploadBackground) return;
      if (file.size > 8 * 1024 * 1024) { this.status('Image is over 8 MB. Try a smaller version.', 'error', statusNode); return; }
      this.status('Uploading…', '', statusNode);
      try {
        const url = await this.opts.onUploadBackground(file);
        if (!url) throw new Error('Upload failed.');
        this.setBackground(url);
        this.showEmpty(false);
        this.status('Background set. Lay your booths on top of it.', 'success', statusNode);
      } catch (err) {
        console.error('[fpb] upload', err);
        this.status((err && err.message) || 'Upload failed.', 'error', statusNode);
      }
    }

    // ── Serialize / save ────────────────────────────────────
    serialize() {
      return this.elements.map(el => {
        const base = { id: el.id, type: el.type, x: el.x, y: el.y };
        if (el.type === 'pin') return Object.assign(base, {
          label: el.label || '', icon: el.icon || DEFAULT_CAT, color: el.color || CAT_BY_ID[DEFAULT_CAT].color,
          vendor_id: el.vendor_id || null, booth: el.booth || '', size: el.size || '', description: el.description || '',
        });
        if (el.type === 'booth') return Object.assign(base, {
          w: el.w, h: el.h, number: el.number != null ? el.number : '',
          label: el.label || '', icon: el.icon || DEFAULT_CAT, color: el.color || CAT_BY_ID[DEFAULT_CAT].color,
          vendor_id: el.vendor_id || null, size: el.size || '', description: el.description || '',
        });
        if (el.type === 'zone') return Object.assign(base, { w: el.w, h: el.h, label: el.label || '', color: el.color || ZONE_COLORS[0], description: el.description || '' });
        if (el.type === 'table') return Object.assign(base, { w: el.w, h: el.h, shape: el.shape || 'round', color: el.color || TABLE_COLOR });
        return Object.assign(base, { label: el.label || '', color: el.color || '#111111', fontSize: el.fontSize || 0.016 });
      });
    }

    async save() {
      if (!this.opts.onSave) return;
      const btn = this.$.saveBtn;
      btn.disabled = true;
      this.status('Saving…');
      try {
        const res = await this.opts.onSave({
          backgroundUrl: this.bgUrl || blankCanvasUri(this.world.w, this.world.h),
          elements: this.serialize(),
        });
        if (res && res.ok === false) { this.status(res.error || 'Save failed.', 'error'); return; }
        this.setDirty(false);
        this.status('Saved.', 'success');
      } catch (err) {
        this.status((err && err.message) || 'Network error.', 'error');
      } finally {
        btn.disabled = false;
      }
    }

    // ── PNG export ──────────────────────────────────────────
    async exportPng() {
      const W = this.world.w, H = this.world.h;
      const cv = document.createElement('canvas');
      cv.width = W; cv.height = H;
      const ctx = cv.getContext('2d');
      ctx.fillStyle = '#ffffff';
      ctx.fillRect(0, 0, W, H);

      if (this.bgUrl) {
        try {
          const img = new Image();
          img.crossOrigin = 'anonymous';
          await new Promise((res, rej) => { img.onload = res; img.onerror = rej; img.src = this.bgUrl; });
          ctx.drawImage(img, 0, 0, W, H);
        } catch (e) { /* draw without background */ }
      }

      const order = { zone: 0, table: 1, booth: 2, text: 3, pin: 4 };
      const els = [...this.elements].sort((a, b) => (order[a.type] || 0) - (order[b.type] || 0));
      els.forEach(el => {
        const cx = el.x * W, cy = el.y * H;
        if (el.type === 'zone' || el.type === 'booth' || el.type === 'table') {
          const w = el.w * W, h = el.h * H, l = cx - w / 2, t = cy - h / 2;
          ctx.save();
          ctx.fillStyle = el.color || '#1a7f4e';
          if (el.type === 'zone') ctx.globalAlpha = 0.85;
          ctx.strokeStyle = 'rgba(0,0,0,0.3)';
          if (el.type === 'table' && el.shape !== 'rect') {
            ctx.beginPath(); ctx.ellipse(cx, cy, w / 2, h / 2, 0, 0, Math.PI * 2); ctx.fill();
            ctx.globalAlpha = 1; ctx.stroke();
          } else {
            ctx.fillRect(l, t, w, h);
            ctx.globalAlpha = 1; ctx.strokeRect(l, t, w, h);
          }
          ctx.fillStyle = '#fff';
          ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
          if (el.type === 'booth' && el.number != null && el.number !== '') {
            ctx.font = `800 ${clamp(Math.min(w, h) * 0.42, 9, 26)}px Poppins, sans-serif`;
            ctx.fillText(String(el.number), cx, cy);
          }
          if (el.type === 'zone' && el.label) {
            ctx.font = `800 ${clamp(h * 0.2, 11, 30)}px Poppins, sans-serif`;
            ctx.fillText(el.label.toUpperCase(), cx, cy, w - 8);
          }
          if (el.type === 'booth' && el.label) {
            const fs = clamp(w * 0.16, 9, 12);
            ctx.font = `600 ${fs}px Poppins, sans-serif`;
            const tw = ctx.measureText(el.label).width + 10;
            ctx.fillStyle = 'rgba(255,255,255,0.95)';
            ctx.fillRect(cx - tw / 2, t + h + 3, tw, fs + 6);
            ctx.fillStyle = '#111';
            ctx.fillText(el.label, cx, t + h + 3 + (fs + 6) / 2);
          }
          ctx.restore();
        } else if (el.type === 'text') {
          ctx.save();
          ctx.fillStyle = el.color || '#111';
          ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
          ctx.font = `700 ${Math.max(9, (el.fontSize || 0.016) * W)}px Poppins, sans-serif`;
          ctx.fillText(el.label || '', cx, cy);
          ctx.restore();
        } else {
          ctx.save();
          ctx.beginPath(); ctx.arc(cx, cy, 13, 0, Math.PI * 2);
          ctx.fillStyle = el.color || '#0a7aff'; ctx.fill();
          ctx.lineWidth = 3; ctx.strokeStyle = '#fff'; ctx.stroke();
          if (el.label) {
            ctx.font = '600 11px Poppins, sans-serif';
            ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
            const tw = ctx.measureText(el.label).width + 10;
            ctx.fillStyle = 'rgba(255,255,255,0.95)';
            ctx.fillRect(cx - tw / 2, cy + 17, tw, 17);
            ctx.fillStyle = '#111';
            ctx.fillText(el.label, cx, cy + 25);
          }
          ctx.restore();
        }
      });

      try {
        const a = document.createElement('a');
        a.download = 'floor-plan.png';
        a.href = cv.toDataURL('image/png');
        a.click();
      } catch (e) {
        this.status('Export blocked: the background image does not allow cross-origin export.', 'error');
      }
    }

    // ── Public API ──────────────────────────────────────────
    api() {
      return {
        save: () => this.save(),
        isDirty: () => this.dirty,
        getElements: () => this.serialize(),
        getBackgroundUrl: () => this.bgUrl,
        setVendors: (v) => { this.vendors = Array.isArray(v) ? v : []; this.renderSide(); },
        destroy: () => {
          document.removeEventListener('keydown', this._keydown);
          document.removeEventListener('keyup', this._keyup);
          window.removeEventListener('beforeunload', this._beforeUnload);
          if (this.panzoom) { try { this.panzoom.destroy(); } catch (e) {} }
          this.container.innerHTML = '';
        },
      };
    }
  }

  window.FloorplanBuilder = {
    mount(opts) { return new Builder(opts).mount().api(); },
    CATEGORIES,
    blankCanvasUri,
  };
})();
