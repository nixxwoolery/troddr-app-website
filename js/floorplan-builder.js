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
     zone  {id, type:'zone',  x, y, w, h, label, color, description, points?}
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
  const COUNTER_COLOR = '#0891b2';
  const TEXT_SIZES = [{ id: 's', label: 'Small', v: 0.011 }, { id: 'm', label: 'Medium', v: 0.016 }, { id: 'l', label: 'Large', v: 0.024 }, { id: 'xl', label: 'X-Large', v: 0.034 }];
  const PRESET_FT = ['10x10', '10x20', '10x30', '20x20', '20x30'];
  // Booth name-label size multipliers.
  const LBL_SIZES = { s: 0.8, m: 1, l: 1.4, xl: 1.9 };

  // ── Object library (the "Object" tool) ────────────────────
  // Generic placeable furniture/structures. Each has a real-world default
  // footprint in feet. `connect:true` kinds snap end-to-end into a group
  // (bars, barrier runs). `round` draws as an ellipse. `text` lets the
  // shape carry a label that renders inside it.
  // `ic:true` renders the object's icon inside the box; `deco` tags a kind for
  // special canvas styling (trees, lights). `connect:true` snaps into runs.
  const OBJECTS = [
    { kind: 'table-round', cat: 'Seating',        label: 'Round table',   icon: 'fpb-circle',  shape: 'round', ftW: 5,  ftH: 5,   color: '#b08850' },
    { kind: 'table-rect',  cat: 'Seating',        label: 'Banquet table', icon: 'fpb-square',  shape: 'rect',  ftW: 8,  ftH: 2.5, color: '#b08850' },
    { kind: 'cocktail',    cat: 'Seating',        label: 'Cocktail table',icon: 'fpb-circle',  shape: 'round', ftW: 2.5,ftH: 2.5, color: '#a9885a' },
    { kind: 'chair',       cat: 'Seating',        label: 'Chair',         icon: 'fpb-chair',   shape: 'rect',  ftW: 1.6,ftH: 1.6, color: '#8d6e63' },
    { kind: 'bench',       cat: 'Seating',        label: 'Bench',         icon: 'fpb-square',  shape: 'rect',  ftW: 5,  ftH: 1.5, color: '#8d6e63' },
    { kind: 'food-truck',  cat: 'Food & bar',     label: 'Food truck',    icon: 'fpb-truck',   shape: 'rect',  ftW: 20, ftH: 8,   color: '#b45309', text: true, ic: true },
    { kind: 'counter',     cat: 'Food & bar',     label: 'Bar / counter', icon: 'fpb-counter', shape: 'rect',  ftW: 8,  ftH: 2,   color: '#0891b2', connect: true },
    { kind: 'food-tent',   cat: 'Food & bar',     label: 'Food tent',     icon: 'fpb-square',  shape: 'rect',  ftW: 10, ftH: 10,  color: '#1a9e57', text: true },
    { kind: 'stage',       cat: 'Structures',     label: 'Stage',         icon: 'fpb-music',   shape: 'rect',  ftW: 24, ftH: 16,  color: '#262626', text: true },
    { kind: 'dancefloor',  cat: 'Structures',     label: 'Dance floor',   icon: 'fpb-grid-ic', shape: 'rect',  ftW: 20, ftH: 20,  color: '#6d28d9', text: true },
    { kind: 'tent',        cat: 'Structures',     label: 'Marquee tent',  icon: 'fpb-square',  shape: 'rect',  ftW: 20, ftH: 20,  color: '#e2e8f0', text: true },
    { kind: 'restroom-blk',cat: 'Access & safety',label: 'Restrooms',     icon: 'fpb-restroom',shape: 'rect',  ftW: 12, ftH: 10,  color: '#475569', text: true, ic: true },
    { kind: 'ticket',      cat: 'Access & safety',label: 'Ticket booth',  icon: 'fpb-info',    shape: 'rect',  ftW: 8,  ftH: 8,   color: '#d4a017', text: true, ic: true },
    { kind: 'barrier',     cat: 'Access & safety',label: 'Crowd barrier', icon: 'fpb-counter', shape: 'rect',  ftW: 8,  ftH: 0.7, color: '#475569', connect: true },
    { kind: 'generator',   cat: 'Access & safety',label: 'Generator',     icon: 'fpb-square',  shape: 'rect',  ftW: 8,  ftH: 4,   color: '#334155', text: true, ic: true },
    { kind: 'tree',        cat: 'Decor & site',   label: 'Tree',          icon: 'fpb-tree',    shape: 'round', ftW: 16, ftH: 16,  color: '#2f7d4f', deco: 'tree' },
    { kind: 'planter',     cat: 'Decor & site',   label: 'Planter / shrub',icon: 'fpb-tree',   shape: 'round', ftW: 4,  ftH: 4,   color: '#3f9d63', deco: 'tree' },
    { kind: 'lights',      cat: 'Decor & site',   label: 'String lights', icon: 'fpb-lights',  shape: 'rect',  ftW: 24, ftH: 0.6, color: '#f5b301', connect: true, deco: 'lights' },
    { kind: 'fence',       cat: 'Decor & site',   label: 'Fencing',       icon: 'fpb-fence',   shape: 'rect',  ftW: 10, ftH: 0.5, color: '#6b7280', connect: true, deco: 'fence' },
    { kind: 'rect',        cat: 'Basic',          label: 'Rectangle',     icon: 'fpb-square',  shape: 'rect',  ftW: 6,  ftH: 6,   color: '#64748b', text: true },
    { kind: 'circle',      cat: 'Basic',          label: 'Circle',        icon: 'fpb-circle',  shape: 'round', ftW: 6,  ftH: 6,   color: '#64748b', text: true },
  ];
  const OBJ_BY_KIND = Object.fromEntries(OBJECTS.map(o => [o.kind, o]));
  const OBJ_CATS = OBJECTS.reduce((a, o) => (a.includes(o.cat) ? a : a.concat(o.cat)), []);
  const DEFAULT_OBJ = 'table-round';


  const WORLD_DEFAULT = { w: 1600, h: 1000 };
  const SNAP_PX = 7;          // screen px snap threshold (for edge magnets)
  const ROT_SNAP = 15;        // rotation snap (degrees)

  // ── Real-world scale ──────────────────────────────────────
  // Everything is to-scale: world px = feet × ppf (pixels-per-foot).
  const DEFAULT_PPF = 12;            // px per foot for a fresh blank canvas
  const DEFAULT_SITE_FT = { w: 200, h: 120 }; // default blank-canvas site size
  const DEFAULT_BG = '#ffffff';      // canvas paper colour
  const SNAP_FT = 1;                 // snap increment (feet)
  const MIN_FT = 1;                  // minimum shape size (feet)
  const GRID_MAJOR_FT = 10;          // bold grid line every N feet

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
    + '<symbol id="fpb-crop" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M6 2v14a2 2 0 0 0 2 2h14"/><path d="M18 22V8a2 2 0 0 0-2-2H2"/><path d="M14 6v8H6"/></symbol>'
    + '<symbol id="fpb-save" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M19 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11l5 5v11a2 2 0 0 1-2 2z"/><polyline points="17 21 17 13 7 13 7 21"/><polyline points="7 3 7 8 15 8"/></symbol>'
    + '<symbol id="fpb-trash" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></symbol>'
    + '<symbol id="fpb-copy" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="13" height="13" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></symbol>'
    + '<symbol id="fpb-link" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71"/><path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71"/></symbol>'
    + '<symbol id="fpb-sparkle" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l1.9 5.7L19.5 10l-5.6 1.3L12 17l-1.9-5.7L4.5 10l5.6-1.3L12 3z"/></symbol>'
    + '<symbol id="fpb-grid-ic" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"/><path d="M3 9h18"/><path d="M3 15h18"/><path d="M9 3v18"/><path d="M15 3v18"/></symbol>'
    + '<symbol id="fpb-counter" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><rect x="2" y="9" width="20" height="6" rx="1"/><path d="M2 12h20"/></symbol>'
    + '<symbol id="fpb-ruler" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M21.3 8.7 8.7 21.3a1 1 0 0 1-1.4 0l-4.6-4.6a1 1 0 0 1 0-1.4L15.3 2.7a1 1 0 0 1 1.4 0l4.6 4.6a1 1 0 0 1 0 1.4Z"/><path d="m7.5 10.5 2 2"/><path d="m10.5 7.5 2 2"/><path d="m13.5 4.5 2 2"/><path d="m4.5 13.5 2 2"/></symbol>'
    + '<symbol id="fpb-shapes" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><rect x="3" y="3" width="11" height="11" rx="1.5"/><circle cx="15.5" cy="15.5" r="6"/></symbol>'
    + '<symbol id="fpb-rotate" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M21 12a9 9 0 1 1-3-6.7"/><path d="M21 3v5h-5"/></symbol>'
    + '<symbol id="fpb-measure" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M3 12h18"/><path d="M3 8v8"/><path d="M21 8v8"/><path d="M8 10v4"/><path d="M13 10v4"/></symbol>'
    + '<symbol id="fpb-truck" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M10 17h4V5H2v12h3"/><path d="M20 17h2v-3.34a4 4 0 0 0-1.17-2.83L19 9h-5v8h1"/><circle cx="7.5" cy="17.5" r="2.5"/><circle cx="17.5" cy="17.5" r="2.5"/></symbol>'
    + '<symbol id="fpb-tree" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M12 2 6 9h3l-4 5h4l-3 4h12l-3-4h4l-4-5h3z"/><path d="M12 18v4"/></symbol>'
    + '<symbol id="fpb-lights" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M2 5c5 5 15 5 20 0"/><path d="M6 7v2"/><path d="M12 8v2"/><path d="M18 7v2"/><circle cx="6" cy="11" r="1.5"/><circle cx="12" cy="12" r="1.5"/><circle cx="18" cy="11" r="1.5"/></symbol>'
    + '<symbol id="fpb-fence" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M4 8h16"/><path d="M4 14h16"/><path d="M6 4v16"/><path d="M12 4v16"/><path d="M18 4v16"/></symbol>'
    + '<symbol id="fpb-layer-up" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="m12 3 9 5-9 5-9-5 9-5z"/><path d="m3 16 9 5 9-5"/></symbol>'
    + '<symbol id="fpb-edit" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><path d="M11 4H4a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7"/><path d="M18.5 2.5a2.12 2.12 0 0 1 3 3L12 15l-4 1 1-4z"/></symbol>'
    + '<symbol id="fpb-palette2" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-linecap="round" stroke-linejoin="round"><circle cx="13.5" cy="6.5" r="1.5"/><circle cx="17.5" cy="10.5" r="1.5"/><circle cx="6.5" cy="12.5" r="1.5"/><circle cx="8.5" cy="7.5" r="1.5"/><path d="M12 2C6.5 2 2 6.5 2 12s4.5 10 10 10c1 0 1.6-.8 1.6-1.7 0-.4-.2-.8-.4-1.1-.3-.3-.4-.7-.4-1.1a1.6 1.6 0 0 1 1.6-1.6H16c3 0 5.5-2.5 5.5-5.5C21.5 6.2 17.2 2 12 2z"/></symbol>'
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
    // Legacy types fold into the unified `shape` object model.
    if (el.type === 'table') { el.type = 'shape'; el.kind = el.shape === 'rect' ? 'table-rect' : 'table-round'; }
    else if (el.type === 'counter') { el.type = 'shape'; el.kind = 'counter'; }
    if (el.type !== 'pin' && el.type !== 'text') { el.w = num(el.w, 0.04); el.h = num(el.h, 0.06); }
    if (el.type === 'pin' || el.type === 'booth') {
      el.icon = CAT_BY_ID[el.icon] ? el.icon : (LEGACY_ICONS[el.icon] || DEFAULT_CAT);
      el.color = el.color || CAT_BY_ID[el.icon].color;
    }
    if (el.type === 'text') { el.fontSize = num(el.fontSize, 0.016); el.rot = num(el.rot, 0); }
    if (el.type === 'shape') {
      const o = OBJ_BY_KIND[el.kind] || OBJ_BY_KIND[DEFAULT_OBJ];
      el.kind = o.kind;
      el.shape = o.shape;
      el.color = el.color || o.color;
      if (o.connect) el.groupId = el.groupId || null;
    }
    if (el.type === 'zone' && Array.isArray(el.points) && el.points.length >= 3) {
      el.points = el.points.map(p => [clamp(num(p && p[0]), 0, 1), clamp(num(p && p[1]), 0, 1)]);
    } else if (el.type === 'zone') delete el.points;
    if (el.type === 'booth' || el.type === 'zone' || el.type === 'shape') el.rot = num(el.rot, 0);
    if (el.type === 'booth' || el.type === 'zone') {
      el.labelScale = clamp(num(el.labelScale, 1), 0.5, 3);
      el.labelRot = num(el.labelRot, 0);
    }
    return el;
  }

  // ── Starter template (a to-scale 220 × 140 ft festival site) ──
  const TEMPLATE_SITE_FT = { w: 220, h: 140 };
  function festivalTemplate() {
    const els = [];
    const W = TEMPLATE_SITE_FT.w, H = TEMPLATE_SITE_FT.h;   // feet
    // Everything below is in real feet; fractions are ft / site-ft.
    const boothFt = 10, bw = boothFt / W, bh = boothFt / H, gapFt = 2;
    let n = 1;
    const booth = (cxFt, cyFt, cat) => els.push(normalizeElement({
      id: uid(), type: 'booth', x: cxFt / W, y: cyFt / H, w: bw, h: bh,
      number: n++, label: '', icon: cat, color: CAT_BY_ID[cat].color, size: `${boothFt}x${boothFt}`,
    }));
    // Vendor rows along the top and bottom edges (10 ft booths, 2 ft aisles).
    for (let i = 0; i < 12; i++) booth(20 + i * (boothFt + gapFt), 125, i < 2 ? 'drink' : 'food');
    for (let i = 0; i < 12; i++) booth(20 + i * (boothFt + gapFt), 18, i % 5 === 0 ? 'merch' : 'food');
    // Big zones (feet)
    els.push(normalizeElement({ id: uid(), type: 'zone', x: 105 / W, y: 32 / H, w: 30 / W, h: 20 / H, label: 'Stage', color: '#1f2937' }));
    els.push(normalizeElement({ id: uid(), type: 'zone', x: 60 / W, y: 34 / H, w: 34 / W, h: 20 / H, label: 'VIP Lounge', color: '#b45309' }));
    // A bar built from three connected 16 ft counters (one group).
    const barGid = 'bar_' + uid();
    [150, 166, 182].forEach((cx) => els.push(normalizeElement({
      id: uid(), type: 'counter', x: cx / W, y: 34 / H, w: 16 / W, h: 2 / H,
      label: 'Bar', color: COUNTER_COLOR, groupId: barGid, size: '16x2',
    })));
    // Scattered cocktail tables (5 ft round) in the middle field
    [[60, 78], [80, 90], [100, 75], [122, 86], [145, 75], [168, 86], [88, 64], [134, 64], [176, 70], [44, 90]]
      .forEach(([x, y]) => els.push(normalizeElement({ id: uid(), type: 'table', x: x / W, y: y / H, w: 5 / W, h: 5 / H, shape: 'round', color: TABLE_COLOR })));
    // Pins
    els.push(normalizeElement({ id: uid(), type: 'pin', x: 110 / W, y: 134 / H, label: 'Entrance', icon: 'entrance' }));
    els.push(normalizeElement({ id: uid(), type: 'pin', x: 205 / W, y: 45 / H, label: 'Restrooms', icon: 'restroom' }));
    els.push(normalizeElement({ id: uid(), type: 'pin', x: 16 / W, y: 45 / H, label: 'First Aid', icon: 'medic' }));
    return els;
  }

  // ── Builder ───────────────────────────────────────────────
  class Builder {
    constructor(opts) {
      this.opts = opts || {};
      this.container = opts.container;
      this.readOnly = !!opts.readOnly;
      this.vendors = Array.isArray(opts.vendors) ? opts.vendors : [];
      this.draftKey = !this.readOnly && opts.draftKey ? String(opts.draftKey) : null;
      this.recoveredDraft = false;
      let draft = null;
      if (this.draftKey) {
        try { draft = JSON.parse(localStorage.getItem(this.draftKey) || 'null'); } catch (e) { draft = null; }
      }
      // A browser draft is only authoritative when it is newer than the event
      // record. This prevents an old/empty local draft from hiding a map that
      // was successfully saved from another tab or device.
      const serverUpdatedAt = opts.serverUpdatedAt ? Date.parse(opts.serverUpdatedAt) : 0;
      if (draft && serverUpdatedAt && num(draft.updatedAt) <= serverUpdatedAt) draft = null;
      const raw = (draft && Array.isArray(draft.elements) ? draft.elements : (Array.isArray(opts.elements) ? opts.elements : [])).slice();
      if (draft && Array.isArray(draft.elements)) this.recoveredDraft = true;
      // Pull the scale meta entry (if any) out of the markers array.
      const metaIdx = raw.findIndex(m => m && m.type === 'meta');
      const meta = metaIdx >= 0 ? raw.splice(metaIdx, 1)[0] : null;
      this.elements = raw.filter(m => m && m.type !== 'meta').map(normalizeElement);
      const initialBg = this.recoveredDraft ? draft.backgroundUrl : opts.backgroundUrl;
      this.bgUrl = (initialBg && !isBlankUri(initialBg)) ? initialBg : null;
      // Scale: ppf (px per foot) is the single source of truth. siteFt is the
      // blank-canvas extent in feet. For image backgrounds the world comes from
      // the image's natural pixels and only ppf (calibration) is meaningful.
      this.ppf = meta && meta.ppf > 0 ? num(meta.ppf, DEFAULT_PPF) : DEFAULT_PPF;
      this.siteFt = meta && meta.siteFtW > 0
        ? { w: num(meta.siteFtW, DEFAULT_SITE_FT.w), h: num(meta.siteFtH, DEFAULT_SITE_FT.h) }
        : Object.assign({}, DEFAULT_SITE_FT);
      this.calibrated = !!(meta && meta.calibrated);
      this.bg = (meta && meta.bg) || DEFAULT_BG;     // canvas paper colour
      this.world = this.bgUrl
        ? Object.assign({}, WORLD_DEFAULT)                       // replaced on image load
        : (meta && meta.worldW > 0 && meta.worldH > 0)
          ? { w: num(meta.worldW, WORLD_DEFAULT.w), h: num(meta.worldH, WORLD_DEFAULT.h) }
          : { w: this.siteFt.w * this.ppf, h: this.siteFt.h * this.ppf };
      this.tool = 'select';
      this._sel = [];                            // selected element ids (multi-select)
      this.pinCategory = 'info';
      this.boothCategory = DEFAULT_CAT;
      this.objKind = DEFAULT_OBJ;                 // active object-library item
      this.zoneMode = 'rect';                     // rectangle or traced freeform zone
      this.zonePoints = [];                       // click-by-click polygon vertices
      this.lastBoothFt = { w: 10, h: 10 };      // default booth footprint (feet)
      this.snap = true;
      this.dirty = false;
      this.undoStack = [];
      this.redoStack = [];
      this._lastUndoPush = 0;
      this.panzoom = null;
      this.spacePan = false;
      this._gesture = null;
      this.crop = null;
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
      if (!this.readOnly) {
        this.wireToolbar();
        this.wireKeyboard();
      }
      this.wireCanvas();
      this.renderSide();
      this.renderLegend();
      this.setBackground(this.bgUrl, { silent: true });
      if (!this.readOnly) {
        this.setTool('select');
        if (!this.bgUrl && !this.elements.length) this.showEmpty(true);
        if (this.recoveredDraft) {
          this.setDirty(true);
          this.status('Recovered your unsaved map from this browser. Save when ready.', 'success');
        }
        window.addEventListener('beforeunload', this._beforeUnload = (e) => {
          if (!this.dirty) return;
          e.preventDefault(); e.returnValue = '';
        });
      }
      return this;
    }

    template() {
      const o = this.opts;
      if (this.readOnly) {
        return `
<div class="fpb readonly">
  <div class="fpb-body">
    <div class="fpb-viewport" data-ref="viewport">
      <div class="fpb-canvas" data-ref="canvas">
        <img class="fpb-bg" data-ref="bg" alt="" hidden />
        <div class="fpb-grid" data-ref="grid" hidden></div>
        <div class="fpb-els" data-ref="els"></div>
        <div class="fpb-guide-v" data-ref="guideV" hidden></div>
        <div class="fpb-guide-h" data-ref="guideH" hidden></div>
        <div class="fpb-rubber" data-ref="rubber" hidden></div>
      </div>
      <div class="fpb-zoom">
        <button type="button" data-ref="zoomIn" title="Zoom in">＋</button>
        <button type="button" data-ref="zoomFit" title="Fit to screen">⊙</button>
        <button type="button" data-ref="zoomOut" title="Zoom out">−</button>
      </div>
      <div class="fpb-pop" data-ref="pop" hidden></div>
    </div>
  </div>
  <div class="fpb-legend" data-ref="legend"></div>
</div>`;
      }
      const tools = [
        ['select', 'fpb-cursor', 'Select', 'V'],
        ['booth', 'fpb-square', 'Booth', 'B'],
        ['object', 'fpb-shapes', 'Object', 'O'],
        ['zone', 'fpb-zone-ic', 'Zone', 'Z'],
        ['freezone', 'fpb-edit', 'Polygon zone', ''],
        ['text', 'fpb-type', 'Text', 'T'],
        ['pin', 'fpb-pin', 'Pin', 'P'],
        ['measure', 'fpb-measure', 'Measure', 'M'],
      ].map(([id, ic, lb, k]) => `<button type="button" class="fpb-tool-btn" data-tool="${id}" title="${lb}${k ? ` (${k})` : ''}"><svg><use href="#${ic}"/></svg>${lb}${k ? `<span class="kbd">${k}</span>` : ''}</button>`).join('');

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
    <button type="button" class="fpb-btn" data-ref="scaleBtn" title="Set the canvas scale (feet)"><svg><use href="#fpb-ruler"/></svg><span data-ref="scaleLabel">Scale</span></button>
    <span class="fpb-opacity" data-ref="opacityWrap" hidden>Image <input type="range" min="10" max="100" value="100" data-ref="opacityRange" /></span>
    <span class="fpb-tb-spacer"></span>
    <span class="fpb-dirty clean" data-ref="dirtyLabel">No unsaved changes</span>
    <button type="button" class="fpb-btn icon-only" data-ref="undoBtn" title="Undo (Ctrl+Z)" disabled><svg><use href="#fpb-undo"/></svg></button>
    <button type="button" class="fpb-btn icon-only" data-ref="redoBtn" title="Redo (Ctrl+Shift+Z)" disabled><svg><use href="#fpb-redo"/></svg></button>
    ${uploadBtn}
    ${o.onUploadBackground ? '<button type="button" class="fpb-btn" data-ref="rotateMapBtn" title="Rotate the saved floor plan 90 degrees clockwise"><svg><use href="#fpb-rotate"/></svg>Rotate</button>' : ''}
    ${o.onUploadBackground ? '<button type="button" class="fpb-btn" data-ref="cropMapBtn" title="Crop the uploaded floor plan image"><svg><use href="#fpb-crop"/></svg>Crop</button>' : ''}
    ${o.onUploadBackground ? '<button type="button" class="fpb-btn" data-ref="traceOnlyBtn" title="Hide the uploaded image from the saved guest map while keeping your traced layout"><svg><use href="#fpb-grid-ic"/></svg>Trace only</button>' : ''}
    <button type="button" class="fpb-btn" data-ref="exportBtn" title="Download the floor plan as a PNG image"><svg><use href="#fpb-download"/></svg>Export</button>
    ${extra}
    ${o.onListVersions ? '<button type="button" class="fpb-btn" data-ref="historyBtn"><svg><use href="#fpb-undo"/></svg>Version history</button>' : ''}
    <button type="button" class="fpb-btn primary" data-ref="saveBtn"><svg><use href="#fpb-save"/></svg>${esc(o.saveLabel || 'Save')}</button>
  </div>

  <div class="fpb-body">
    <div class="fpb-viewport" data-ref="viewport">
      <div class="fpb-canvas" data-ref="canvas">
        <img class="fpb-bg" data-ref="bg" alt="" hidden />
        <div class="fpb-grid" data-ref="grid"></div>
        <div class="fpb-els" data-ref="els"></div>
        <div class="fpb-guide-v" data-ref="guideV" hidden></div>
        <div class="fpb-guide-h" data-ref="guideH" hidden></div>
        <div class="fpb-rubber" data-ref="rubber" hidden></div>
        <div class="fpb-callipers" data-ref="callipers" hidden></div>
        <div class="fpb-crop-layer" data-ref="cropLayer" hidden>
          <div class="fpb-crop-shade fpb-crop-shade-top" data-ref="cropShadeTop"></div>
          <div class="fpb-crop-shade fpb-crop-shade-right" data-ref="cropShadeRight"></div>
          <div class="fpb-crop-shade fpb-crop-shade-bottom" data-ref="cropShadeBottom"></div>
          <div class="fpb-crop-shade fpb-crop-shade-left" data-ref="cropShadeLeft"></div>
          <div class="fpb-crop-box" data-ref="cropBox">
            <span data-crop-handle="nw"></span><span data-crop-handle="ne"></span>
            <span data-crop-handle="se"></span><span data-crop-handle="sw"></span>
          </div>
        </div>
      </div>
      <div class="fpb-dim" data-ref="dim" hidden></div>
      <div class="fpb-hint" data-ref="hint" hidden></div>
      <div class="fpb-crop-actions" data-ref="cropActions" hidden>
        <button type="button" class="fpb-btn" data-ref="cropCancelBtn">Cancel</button>
        <button type="button" class="fpb-btn primary" data-ref="cropApplyBtn"><svg><use href="#fpb-crop"/></svg>Apply crop</button>
      </div>
      <div class="fpb-zoom">
        <button type="button" data-ref="zoomIn" title="Zoom in">＋</button>
        <button type="button" data-ref="zoomFit" title="Fit to screen">⊙</button>
        <button type="button" data-ref="zoomOut" title="Zoom out">−</button>
      </div>
      <div class="fpb-empty" data-ref="empty" hidden>
        <h3>Build your event floor plan</h3>
        <p>Lay out numbered booths, stages, bars and tables on a to-scale canvas — or start from a template and rearrange it. You can add a venue photo behind it any time.</p>
        <div class="fpb-sitedims">
          <label>Site size</label>
          <input data-ref="siteW" type="number" min="10" max="5000" value="${DEFAULT_SITE_FT.w}" /><span>×</span><input data-ref="siteH" type="number" min="10" max="5000" value="${DEFAULT_SITE_FT.h}" /><span>ft</span>
        </div>
        <div class="choices">
          <button type="button" class="choice" data-ref="startBlank"><svg><use href="#fpb-grid-ic"/></svg>Blank canvas<small>Drawn to your site size</small></button>
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
      if ($.scaleBtn) $.scaleBtn.addEventListener('click', () => this.openScale());
      $.undoBtn.addEventListener('click', () => this.undo());
      $.redoBtn.addEventListener('click', () => this.redo());
      $.exportBtn.addEventListener('click', () => this.exportPng());
      if ($.rotateMapBtn) $.rotateMapBtn.addEventListener('click', () => this.rotateMapClockwise());
      if ($.cropMapBtn) $.cropMapBtn.addEventListener('click', () => this.startCrop());
      if ($.cropCancelBtn) $.cropCancelBtn.addEventListener('click', () => this.cancelCrop());
      if ($.cropApplyBtn) $.cropApplyBtn.addEventListener('click', () => this.applyCrop());
      if ($.cropBox) $.cropBox.addEventListener('pointerdown', (e) => this.startCropDrag(e));
      if ($.traceOnlyBtn) $.traceOnlyBtn.addEventListener('click', () => this.useBackgroundAsTraceOnly());
      if ($.historyBtn) $.historyBtn.addEventListener('click', () => this.openVersionHistory());
      $.saveBtn.addEventListener('click', () => this.save());
      $.zoomIn.addEventListener('click', () => this.panzoom && this.panzoom.zoomIn());
      $.zoomOut.addEventListener('click', () => this.panzoom && this.panzoom.zoomOut());
      $.zoomFit.addEventListener('click', () => this.fit());
      if ($.opacityRange) $.opacityRange.addEventListener('input', () => { this.$.bg.style.opacity = $.opacityRange.value / 100; });
      if ($.bgInput) $.bgInput.addEventListener('change', (e) => this.uploadBackground(e.target.files[0], this.$.status));
      if ($.emptyUpload) $.emptyUpload.addEventListener('change', (e) => this.uploadBackground(e.target.files[0], this.$.emptyStatus));
      if ($.startBlank) $.startBlank.addEventListener('click', () => {
        if ($.siteW && $.siteH) this.setSiteFt($.siteW.value, $.siteH.value);
        this.showEmpty(false);
      });
      if ($.startTemplate) $.startTemplate.addEventListener('click', () => {
        this.pushUndo();
        this.siteFt = Object.assign({}, TEMPLATE_SITE_FT);
        this.world = { w: this.siteFt.w * this.ppf, h: this.siteFt.h * this.ppf };
        this.elements = festivalTemplate();
        this.sizeCanvas();
        this.updateGridVisibility();
        this.showEmpty(false);
        this.setDirty(true);
        this.renderAll();
      });
      (this.opts.actions || []).forEach((a, i) => {
        const btn = this.container.querySelector(`[data-action="${i}"]`);
        if (btn) btn.addEventListener('click', () => a.onClick());
      });
    }

    async openVersionHistory() {
      if (!this.opts.onListVersions) return;
      const wrap = document.createElement('div');
      wrap.className = 'fpb-modal';
      wrap.innerHTML = `<div class="fpb-modal-card fpb-history-card"><h3>Floor plan version history</h3><p>Every successful save creates a recoverable version.</p><div class="fpb-history-list"><div class="fpb-helper">Loading versions…</div></div><div class="fpb-modal-actions"><button type="button" class="fpb-btn" data-close>Close</button></div></div>`;
      document.body.appendChild(wrap);
      const close = () => wrap.remove();
      wrap.querySelector('[data-close]').addEventListener('click', close);
      wrap.addEventListener('click', e => { if (e.target === wrap) close(); });
      const list = wrap.querySelector('.fpb-history-list');
      try {
        const versions = await this.opts.onListVersions();
        if (!Array.isArray(versions) || !versions.length) {
          list.innerHTML = '<div class="fpb-helper">No saved versions yet. Your next save will create one.</div>';
          return;
        }
        list.innerHTML = versions.map((v, i) => {
          const when = v.created_at ? new Date(v.created_at).toLocaleString() : 'Unknown time';
          const restored = v.restored_from_version ? ` · restored from v${esc(v.restored_from_version)}` : '';
          return `<div class="fpb-history-row"><div><strong>Version ${esc(v.version_number)}</strong>${i === 0 ? '<span class="fpb-current">Current</span>' : ''}<small>${esc(when)} · ${esc(v.marker_count || 0)} items · ${esc(v.source || 'save')}${restored}</small></div>${i ? `<button type="button" class="fpb-btn" data-restore="${esc(v.version_number)}">Restore</button>` : ''}</div>`;
        }).join('');
        list.querySelectorAll('[data-restore]').forEach(btn => btn.addEventListener('click', async () => {
          const version = Number(btn.dataset.restore);
          if (!confirm(`Restore version ${version}? The current map will remain in version history.`)) return;
          btn.disabled = true; btn.textContent = 'Restoring…';
          try {
            const result = await this.opts.onRestoreVersion(version);
            if (result && result.ok === false) throw new Error(result.error || 'Restore failed.');
            this.clearDraft();
            location.reload();
          } catch (err) {
            btn.disabled = false; btn.textContent = 'Restore';
            this.status((err && err.message) || 'Restore failed.', 'error');
          }
        }));
      } catch (err) {
        list.innerHTML = `<div class="fpb-helper">${esc((err && err.message) || 'Could not load version history.')}</div>`;
      }
    }

    setTool(tool) {
      const activeTool = tool;
      if (this.zonePoints.length && tool !== 'freezone') this.cancelPolygonZone();
      if (tool === 'freezone') { this.zoneMode = 'freeform'; tool = 'zone'; }
      else if (tool === 'zone') this.zoneMode = 'rect';
      // Switching to a placement tool clears the selection so its palette shows.
      if (tool !== 'select' && this.selectedId) this.selectedId = null;
      this.tool = tool;
      const $ = this.$;
      $.tools.querySelectorAll('[data-tool]').forEach(b => b.classList.toggle('active', b.dataset.tool === activeTool));
      $.viewport.className = 'fpb-viewport tool-' + tool;
      if (this.panzoom) this.panzoom.setOptions({ disablePan: tool !== 'select' });
      const hints = {
        booth: 'Click to stamp a booth, or drag to draw one. Set its real size (ft) on the right — the box scales to match.',
        object: 'Pick an object on the right (table, chair, bar, barrier, ticket booth…), then click or drag to place it. Connectable pieces snap into runs.',
        zone: this.zoneMode === 'freeform' ? 'Click each corner of the zone. Double-click the final point—or press Enter—to finish. Escape cancels.' : 'Drag to draw a rectangular zone. Choose Polygon on the right for irregular areas.',
        text: 'Click anywhere to add a text label.',
        pin: 'Pick a category on the right, then click the map to drop a pin.',
        measure: 'Drag to measure a distance in feet. Nothing is placed.',
      };
      this.hint(hints[tool] || '');
      this.renderElements();
      this.renderSide();
    }

    hint(msg) {
      if (!this.$.hint) return;
      this.$.hint.hidden = !msg;
      this.$.hint.textContent = msg || '';
    }

    showEmpty(show) {
      this.$.empty.hidden = !show;
      if (!show && !this.bgUrl) this.setBackground(null, { silent: true });
      if (!show) this.fit();
    }

    updateGridVisibility() {
      if (this.readOnly) return;   // viewers never see the grid
      this.updateGrid();
      this.updateScaleLabel();
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
          // A fresh image has no real scale yet — guess one so booths aren't
          // absurd, and flag it so we can nudge the organizer to calibrate.
          if (!this.calibrated) this.ppf = Math.max(4, Math.round(this.world.w / 240));
          this.sizeCanvas();
          this.updateGridVisibility();
          this.fit();
          this.renderSide();
        };
        if (this.$.opacityWrap) this.$.opacityWrap.hidden = false;
      } else {
        img.hidden = true;
        img.removeAttribute('src');
        this.world = { w: this.siteFt.w * this.ppf, h: this.siteFt.h * this.ppf };
        this.sizeCanvas();
        this.fit();
        if (this.$.opacityWrap) this.$.opacityWrap.hidden = true;
      }
      this.updateGridVisibility();
      if (!silent) this.setDirty(true);
    }

    // Blank-canvas site dimensions (feet) → resize the world, keeping booths
    // at their real footprint (their feet are derived from the old scale first).
    setSiteFt(wFt, hFt) {
      wFt = clamp(num(wFt, this.siteFt.w), 10, 5000);
      hFt = clamp(num(hFt, this.siteFt.h), 10, 5000);
      if (this.bgUrl) return;                       // images carry their own scale
      const fts = this.elements.map(el => (el.w != null)
        ? { id: el.id, wf: this.elWidthFt(el), hf: this.elHeightFt(el) } : null);
      this.siteFt = { w: wFt, h: hFt };
      this.world = { w: wFt * this.ppf, h: hFt * this.ppf };
      // Re-derive fractional w/h so footprints stay constant in feet.
      fts.forEach(f => { if (!f) return; const el = this.byId(f.id); if (el) { el.w = this.ftToFracW(f.wf); el.h = this.ftToFracH(f.hf); } });
      this.sizeCanvas();
      this.updateGridVisibility();
      this.fit();
      this.setDirty(true);
    }

    updateScaleLabel() {
      if (!this.$.scaleLabel) return;
      this.$.scaleLabel.textContent = this.bgUrl
        ? (this.calibrated ? `${this.fmtFt(this.ppf)} px/ft` : 'Set scale')
        : `${Math.round(this.siteFt.w)}×${Math.round(this.siteFt.h)} ft`;
      this.$.scaleBtn.classList.toggle('attn', !!this.bgUrl && !this.calibrated);
    }

    // ── Layer order ─────────────────────────────────────────
    toFront(el) { this.pushUndo(); this.elements = this.elements.filter(x => x !== el); this.elements.push(el); this.setDirty(true); this.renderElements(); }
    toBack(el) { this.pushUndo(); this.elements = this.elements.filter(x => x !== el); this.elements.unshift(el); this.setDirty(true); this.renderElements(); }

    // Touch long-press → open the context menu (mirrors right-click).
    armLongPress(e) {
      const elDiv = e.target.closest('.fpb-el');
      const id = elDiv ? elDiv.dataset.id : null;
      const sx = e.clientX, sy = e.clientY;
      clearTimeout(this._lpTimer);
      const cleanup = () => { clearTimeout(this._lpTimer); window.removeEventListener('pointermove', move); window.removeEventListener('pointerup', cleanup); };
      const move = (ev) => { if (Math.hypot(ev.clientX - sx, ev.clientY - sy) > 10) cleanup(); };  // a drag cancels it
      this._lpTimer = setTimeout(() => {
        this._lpFired = true;
        if (id && !this.isSelected(id)) this.select(id);
        if (navigator.vibrate) { try { navigator.vibrate(8); } catch (e2) {} }
        this.openContextMenu({ clientX: sx, clientY: sy }, id);
      }, 480);
      window.addEventListener('pointermove', move);
      window.addEventListener('pointerup', cleanup);
    }

    // ── Right-click context menu ────────────────────────────
    closeContextMenu() {
      document.querySelectorAll('.fpb-ctx').forEach(m => m.remove());   // clear any (stray) menus
      this._ctx = null;
      if (this._ctxOff) { window.removeEventListener('pointerdown', this._ctxOff, true); this._ctxOff = null; }
    }
    openContextMenu(e, id) {
      this.closeContextMenu();
      const el = id ? this.byId(id) : null;
      const multi = this._sel.length > 1;
      const item = (label, icon, fn, danger) => ({ label, icon, fn, danger });
      const sub = (label, icon, swatches, fn) => ({ label, icon, swatches, fn });
      const palette = ['#1a9e57', '#0891b2', '#262626', '#6d28d9', '#d4a017', '#b45309', '#475569', '#b08850'];
      let items;
      if (el) {
        const inZone = el.type === 'zone' ? this.elements.filter(o => o !== el && o.type !== 'zone' && this.zoneContains(el, o)) : [];
        items = [
          !multi && item('Edit', 'fpb-edit', () => { this.select(el.id); }),
          (el.type === 'zone' && inZone.length) && item(`Select all inside (${inZone.length})`, 'fpb-shapes', () => { this._sel = inZone.map(o => o.id); this.renderAll(); }),
          (el.type !== 'pin' && el.type !== 'text') && sub(multi ? 'Colour all' : 'Colour', 'fpb-palette2', palette, (c) => {
            this.pushUndo(); (multi ? this.selectedEls() : [el]).forEach(o => { if (o.type !== 'pin' && o.type !== 'text') o.color = c; }); this.setDirty(true); this.renderElements();
          }),
          this.isRotatable(el) && item('Rotate 90°', 'fpb-rotate', () => { this.pushUndo(); (multi ? this.selectedEls() : [el]).forEach(o => { if (o.rot != null) o.rot = (((o.rot + 90) % 360) + 360) % 360; }); this.setDirty(true); this.renderElements(); }),
          item('Bring to front', 'fpb-layer-up', () => (multi ? this.selectedEls() : [el]).forEach(o => this.toFront(o))),
          item('Send to back', 'fpb-layer-up', () => (multi ? this.selectedEls() : [el]).forEach(o => this.toBack(o))),
          item('Duplicate', 'fpb-copy', () => { if (multi) this.duplicateSelection(); else { this.select(el.id); this.duplicateSelected(); } }),
          item('Delete', 'fpb-trash', () => { this.pushUndo(); const ids = new Set(multi ? this._sel : [el.id]); this.elements = this.elements.filter(x => !ids.has(x.id)); this._sel = []; this.setDirty(true); this.renderAll(); }, true),
        ];
      } else {
        items = [
          item('Canvas & scale…', 'fpb-ruler', () => this.openScale()),
          !this.bgUrl && sub('Canvas colour', 'fpb-palette2', ['#ffffff', '#f4f1ea', '#eef2f6', '#dfe9d8', '#1f2937', '#14321f'], (c) => { this.bg = c; this.applyBg(); this.setDirty(true); }),
          item('Add objects', 'fpb-shapes', () => this.setTool('object')),
          this.bgUrl && item('Use image as trace only', 'fpb-grid-ic', () => this.useBackgroundAsTraceOnly()),
          item(this.bgUrl ? 'Rotate map 90°' : 'Rotate canvas 90°', 'fpb-rotate', () => this.rotateMapClockwise()),
          item('Fit to screen', 'fpb-grid-ic', () => this.fit()),
        ];
      }
      items = items.filter(Boolean);
      const menu = document.createElement('div');
      menu.className = 'fpb-ctx';
      menu.innerHTML = items.map((it, i) => it.swatches
        ? `<div class="fpb-ctx-row" data-i="${i}"><span class="fpb-ctx-lbl"><svg><use href="#${it.icon}"/></svg>${esc(it.label)}</span><span class="fpb-ctx-sw">${it.swatches.map(c => `<button type="button" data-c="${c}" style="background:${c}"></button>`).join('')}</span></div>`
        : `<button type="button" class="fpb-ctx-item${it.danger ? ' danger' : ''}" data-i="${i}"><svg><use href="#${it.icon}"/></svg>${esc(it.label)}</button>`).join('');
      document.body.appendChild(menu);
      this._ctx = menu;
      menu.style.left = clamp(e.clientX, 4, window.innerWidth - menu.offsetWidth - 4) + 'px';
      menu.style.top = clamp(e.clientY, 4, window.innerHeight - menu.offsetHeight - 4) + 'px';
      menu.querySelectorAll('.fpb-ctx-item').forEach(b => b.addEventListener('click', () => { const it = items[+b.dataset.i]; this.closeContextMenu(); it.fn(); }));
      menu.querySelectorAll('.fpb-ctx-sw button').forEach(b => b.addEventListener('click', () => { const row = b.closest('[data-i]'); const it = items[+row.dataset.i]; it.fn(b.dataset.c); this.closeContextMenu(); }));
      this._ctxOff = (ev) => { if (!menu.contains(ev.target)) this.closeContextMenu(); };
      setTimeout(() => { if (this._ctxOff) window.addEventListener('pointerdown', this._ctxOff, true); }, 0);
    }

    // Scale dialog: site dimensions for a blank canvas, calibration for an image.
    openScale() {
      const isImg = !!this.bgUrl;
      const wrap = document.createElement('div');
      wrap.className = 'fpb-modal';
      const swatches = ['#ffffff', '#f4f1ea', '#eef2f6', '#1f2937', '#14321f', '#0c1f33'];
      const colorBlock = `<div class="fpb-field"><span>Canvas colour</span><div class="fpb-color-row">
          ${swatches.map(c => `<button type="button" class="fpb-color-dot${(this.bg || '').toLowerCase() === c ? ' active' : ''}" data-x="bgdot" data-c="${c}" style="background:${c}"></button>`).join('')}
          <input type="color" data-x="bg" value="${esc(/^#[0-9a-f]{6}$/i.test(this.bg || '') ? this.bg : DEFAULT_BG)}" title="Custom colour"/>
        </div></div>`;
      wrap.innerHTML = `<div class="fpb-modal-card">
        <h3>Canvas &amp; scale</h3>
        ${isImg
          ? `<p>At the current scale this image is about <strong>${Math.round(this.world.w / this.ppf)} × ${Math.round(this.world.h / this.ppf)} ft</strong>${this.calibrated ? '' : ' — <strong>not calibrated yet.</strong>'}</p>
             <p class="fpb-helper">Calibrate against a distance you know — a building edge, road width, or a marked dimension on the plan.</p>
             ${colorBlock}
             <div class="fpb-modal-actions"><button type="button" data-x="cal" class="fpb-btn primary"><svg><use href="#fpb-ruler"/></svg>Draw calibration line</button><button type="button" data-x="cancel" class="fpb-btn">Done</button></div>`
          : `<div class="fpb-field-row"><label class="fpb-field"><span>Site width (ft)</span><input data-x="w" type="number" min="10" max="5000" value="${Math.round(this.siteFt.w)}"></label><label class="fpb-field"><span>Site depth (ft)</span><input data-x="h" type="number" min="10" max="5000" value="${Math.round(this.siteFt.h)}"></label></div>
             <p class="fpb-helper">Placed items keep their real footprint when you change the site size.</p>
             ${colorBlock}
             <div class="fpb-modal-actions"><button type="button" data-x="rotate" class="fpb-btn"><svg><use href="#fpb-rotate"/></svg>Rotate 90°</button><button type="button" data-x="apply" class="fpb-btn primary">Apply</button><button type="button" data-x="cancel" class="fpb-btn">Cancel</button></div>`}
      </div>`;
      this.container.appendChild(wrap);
      const close = () => wrap.remove();
      const q = (s) => wrap.querySelector(`[data-x="${s}"]`);
      const setBg = (c) => { this.bg = c; this.applyBg(); this.setDirty(true); wrap.querySelectorAll('[data-x="bgdot"]').forEach(d => d.classList.toggle('active', d.dataset.c.toLowerCase() === c.toLowerCase())); if (q('bg')) q('bg').value = /^#[0-9a-f]{6}$/i.test(c) ? c : DEFAULT_BG; };
      wrap.addEventListener('click', (e) => { if (e.target === wrap) close(); });
      wrap.querySelectorAll('[data-x="bgdot"]').forEach(d => d.addEventListener('click', () => setBg(d.dataset.c)));
      if (q('bg')) q('bg').addEventListener('input', () => setBg(q('bg').value));
      if (q('cancel')) q('cancel').onclick = close;
      if (q('apply')) q('apply').onclick = () => { this.setSiteFt(q('w').value, q('h').value); close(); };
      if (q('rotate')) q('rotate').onclick = () => { this.rotateCanvas(); close(); };
      if (q('cal')) q('cal').onclick = () => { close(); this.startCalibration(); };
    }

    startCalibration() {
      this.setTool('select');
      this.hint('Drag a line along a distance you know, then enter its real length in feet.');
      this.panzoom.setOptions({ disablePan: true });
      const cal = this.$.callipers;
      let start = null;
      const down = (e) => { if (e.target.closest('.fpb-zoom')) return; e.preventDefault(); start = this.worldPoint(e); };
      const move = (e) => { if (!start) return; this.drawCallipers(start, this.worldPoint(e)); };
      const up = (e) => {
        if (!start) return;
        const cur = this.worldPoint(e);
        const distPx = Math.hypot(cur.x - start.x, cur.y - start.y);
        cleanup();
        if (distPx < 6) { cal.hidden = true; this.hint(''); return; }
        const ans = window.prompt('How long is that line, in feet?', '20');
        cal.hidden = true; this.hint('');
        const ft = parseFloat(ans);
        if (ft > 0) {
          // Keep every placed shape at its real footprint across the rescale.
          const fts = this.elements.map(el => el.w != null ? { id: el.id, wf: this.elWidthFt(el), hf: this.elHeightFt(el) } : null);
          this.ppf = distPx / ft;
          this.calibrated = true;
          fts.forEach(fE => { if (!fE) return; const el = this.byId(fE.id); if (el) { el.w = this.ftToFracW(fE.wf); el.h = this.ftToFracH(fE.hf); } });
          this.updateGridVisibility();
          this.renderAll();
          this.setDirty(true);
          this.status(`Scale set — 1 ft = ${this.fmtFt(this.ppf)} px.`, 'success');
        }
      };
      const cleanup = () => {
        this.$.viewport.removeEventListener('pointerdown', down);
        window.removeEventListener('pointermove', move);
        window.removeEventListener('pointerup', up);
        this.panzoom.setOptions({ disablePan: this.tool !== 'select' });
      };
      this.$.viewport.addEventListener('pointerdown', down);
      window.addEventListener('pointermove', move);
      window.addEventListener('pointerup', up);
    }

    drawCallipers(a, b) {
      const cal = this.$.callipers;
      cal.hidden = false;
      cal.style.left = a.x + 'px';
      cal.style.top = a.y + 'px';
      cal.style.width = Math.hypot(b.x - a.x, b.y - a.y) + 'px';
      cal.style.transform = `rotate(${Math.atan2(b.y - a.y, b.x - a.x)}rad)`;
    }

    // Recompute the foot grid backing image from the current scale.
    updateGrid() {
      if (!this.$.grid) return;
      const minor = this.ppf, major = this.ppf * GRID_MAJOR_FT;
      this.$.grid.style.backgroundImage =
        'linear-gradient(to right, rgba(14,80,140,0.18) 1px, transparent 1px),' +
        'linear-gradient(to bottom, rgba(14,80,140,0.18) 1px, transparent 1px),' +
        'linear-gradient(to right, rgba(14,80,140,0.07) 1px, transparent 1px),' +
        'linear-gradient(to bottom, rgba(14,80,140,0.07) 1px, transparent 1px)';
      this.$.grid.style.backgroundSize =
        `${major}px ${major}px, ${major}px ${major}px, ${minor}px ${minor}px, ${minor}px ${minor}px`;
    }

    sizeCanvas() {
      this.$.canvas.style.width = this.world.w + 'px';
      this.$.canvas.style.height = this.world.h + 'px';
      this.applyBg();
      this.renderElements();
    }
    applyBg() { if (this.$.canvas) this.$.canvas.style.background = this.bg || DEFAULT_BG; }

    useBackgroundAsTraceOnly() {
      if (!this.bgUrl) {
        this.status('There is no background image to hide.', 'error');
        return;
      }
      this.bgUrl = null;
      if (this.$.bg) {
        this.$.bg.hidden = true;
        this.$.bg.removeAttribute('src');
      }
      if (this.$.opacityWrap) this.$.opacityWrap.hidden = true;
      this.undoStack = [];
      this.redoStack = [];
      this.updateUndoButtons();
      this.sizeCanvas();
      this.updateGridVisibility();
      this.fit();
      this.setDirty(true);
      this.renderAll();
      this.status('Trace image hidden. Click Save so guests see the simplified map.', 'success');
    }

    // Reorient the whole layout 90° clockwise (blank canvas only — an image
    // carries its own orientation). Rotates every element and swaps the site.
    rotateCanvas() {
      if (this.bgUrl) { this.status('Canvas rotation isn’t available with a background image.', 'error'); return; }
      this.pushUndo();
      const fts = this.elements.map(el => el.w != null ? { id: el.id, wf: this.elWidthFt(el), hf: this.elHeightFt(el) } : null);
      this.siteFt = { w: this.siteFt.h, h: this.siteFt.w };
      this.world = { w: this.siteFt.w * this.ppf, h: this.siteFt.h * this.ppf };
      this.elements.forEach((el, i) => {
        const nx = 1 - el.y, ny = el.x;        // 90° CW about the centre
        el.x = nx; el.y = ny;
        if (fts[i]) { el.w = this.ftToFracW(fts[i].wf); el.h = this.ftToFracH(fts[i].hf); }
        if (el.rot != null) el.rot = (((el.rot + 90) % 360) + 360) % 360;
      });
      this.sizeCanvas();
      this.updateGridVisibility();
      this.fit();
      this.setDirty(true);
      this.renderAll();
    }

    rotateElementsClockwise(oldW, oldH, newW, newH) {
      const safeOldW = oldW || this.world.w || WORLD_DEFAULT.w;
      const safeOldH = oldH || this.world.h || WORLD_DEFAULT.h;
      const safeNewW = newW || safeOldH;
      const safeNewH = newH || safeOldW;
      this.elements.forEach((el) => {
        const oldX = num(el.x);
        const oldY = num(el.y);
        el.x = clamp(1 - oldY, 0, 1);
        el.y = clamp(oldX, 0, 1);
        if (el.w != null && el.h != null) {
          const oldPxW = num(el.w) * safeOldW;
          const oldPxH = num(el.h) * safeOldH;
          el.w = clamp(oldPxW / safeNewW, 0.001, 1);
          el.h = clamp(oldPxH / safeNewH, 0.001, 1);
        }
        if (el.rot != null) el.rot = (((num(el.rot) + 90) % 360) + 360) % 360;
      });
    }

    loadImageForCanvas(url) {
      return new Promise((resolve, reject) => {
        const img = new Image();
        img.crossOrigin = 'anonymous';
        img.onload = () => resolve(img);
        img.onerror = () => reject(new Error('Could not load the floor plan image for rotation.'));
        img.src = url;
      });
    }

    canvasToBlob(canvas) {
      return new Promise((resolve, reject) => {
        canvas.toBlob((blob) => blob ? resolve(blob) : reject(new Error('Could not create the rotated floor plan image.')), 'image/png');
      });
    }

    startCrop() {
      if (!this.bgUrl) {
        this.status('Upload a map image before cropping.', 'error');
        return;
      }
      if (!this.opts.onUploadBackground) {
        this.status('This view cannot save a cropped background image.', 'error');
        return;
      }
      this.closeContextMenu();
      this.setTool('select');
      this.crop = {
        x: Math.round(this.world.w * 0.08),
        y: Math.round(this.world.h * 0.08),
        w: Math.round(this.world.w * 0.84),
        h: Math.round(this.world.h * 0.84),
      };
      if (this.panzoom) this.panzoom.setOptions({ disablePan: true });
      if (this.$.cropLayer) this.$.cropLayer.hidden = false;
      if (this.$.cropActions) this.$.cropActions.hidden = false;
      if (this.$.cropMapBtn) this.$.cropMapBtn.classList.add('active');
      this.hint('Drag the crop box, or pull a corner handle. Apply crop when it frames the map.');
      this.renderCrop();
    }

    cancelCrop() {
      this.crop = null;
      if (this.$.cropLayer) this.$.cropLayer.hidden = true;
      if (this.$.cropActions) this.$.cropActions.hidden = true;
      if (this.$.cropMapBtn) this.$.cropMapBtn.classList.remove('active');
      if (this.panzoom) this.panzoom.setOptions({ disablePan: this.tool !== 'select' });
      this.hint('');
    }

    renderCrop() {
      if (!this.crop || !this.$.cropBox) return;
      const c = this.crop;
      const box = this.$.cropBox;
      box.style.left = c.x + 'px';
      box.style.top = c.y + 'px';
      box.style.width = c.w + 'px';
      box.style.height = c.h + 'px';
      if (this.$.cropShadeTop) {
        this.$.cropShadeTop.style.left = '0px';
        this.$.cropShadeTop.style.top = '0px';
        this.$.cropShadeTop.style.width = this.world.w + 'px';
        this.$.cropShadeTop.style.height = c.y + 'px';
        this.$.cropShadeRight.style.left = (c.x + c.w) + 'px';
        this.$.cropShadeRight.style.top = c.y + 'px';
        this.$.cropShadeRight.style.width = Math.max(0, this.world.w - c.x - c.w) + 'px';
        this.$.cropShadeRight.style.height = c.h + 'px';
        this.$.cropShadeBottom.style.left = '0px';
        this.$.cropShadeBottom.style.top = (c.y + c.h) + 'px';
        this.$.cropShadeBottom.style.width = this.world.w + 'px';
        this.$.cropShadeBottom.style.height = Math.max(0, this.world.h - c.y - c.h) + 'px';
        this.$.cropShadeLeft.style.left = '0px';
        this.$.cropShadeLeft.style.top = c.y + 'px';
        this.$.cropShadeLeft.style.width = c.x + 'px';
        this.$.cropShadeLeft.style.height = c.h + 'px';
      }
    }

    startCropDrag(e) {
      if (!this.crop) return;
      e.preventDefault();
      e.stopPropagation();
      const handle = e.target.dataset.cropHandle || '';
      const start = this.worldPoint(e);
      const startCrop = Object.assign({}, this.crop);
      const min = Math.min(80, Math.max(24, Math.min(this.world.w, this.world.h) * 0.06));
      const move = (ev) => {
        const cur = this.worldPoint(ev);
        const dx = cur.x - start.x;
        const dy = cur.y - start.y;
        let x = startCrop.x, y = startCrop.y, w = startCrop.w, h = startCrop.h;
        if (!handle) {
          x = clamp(startCrop.x + dx, 0, this.world.w - startCrop.w);
          y = clamp(startCrop.y + dy, 0, this.world.h - startCrop.h);
        } else {
          if (handle.includes('w')) {
            x = clamp(startCrop.x + dx, 0, startCrop.x + startCrop.w - min);
            w = startCrop.x + startCrop.w - x;
          }
          if (handle.includes('e')) {
            w = clamp(startCrop.w + dx, min, this.world.w - startCrop.x);
          }
          if (handle.includes('n')) {
            y = clamp(startCrop.y + dy, 0, startCrop.y + startCrop.h - min);
            h = startCrop.y + startCrop.h - y;
          }
          if (handle.includes('s')) {
            h = clamp(startCrop.h + dy, min, this.world.h - startCrop.y);
          }
        }
        this.crop = { x: Math.round(x), y: Math.round(y), w: Math.round(w), h: Math.round(h) };
        this.renderCrop();
      };
      const up = () => {
        window.removeEventListener('pointermove', move);
        window.removeEventListener('pointerup', up);
      };
      window.addEventListener('pointermove', move);
      window.addEventListener('pointerup', up);
    }

    remapElementsForCrop(crop, oldW, oldH) {
      const newW = Math.max(1, crop.w);
      const newH = Math.max(1, crop.h);
      this.elements.forEach((el) => {
        const oldX = num(el.x) * oldW;
        const oldY = num(el.y) * oldH;
        el.x = clamp((oldX - crop.x) / newW, 0, 1);
        el.y = clamp((oldY - crop.y) / newH, 0, 1);
        if (el.w != null && el.h != null) {
          el.w = clamp(num(el.w) * oldW / newW, 0.001, 1);
          el.h = clamp(num(el.h) * oldH / newH, 0.001, 1);
        }
      });
    }

    async applyCrop() {
      if (!this.crop || !this.bgUrl || !this.opts.onUploadBackground) return;
      const btn = this.$.cropApplyBtn;
      const crop = Object.assign({}, this.crop);
      const oldW = this.world.w;
      const oldH = this.world.h;
      if (crop.w < 10 || crop.h < 10) {
        this.status('Crop area is too small.', 'error');
        return;
      }
      if (btn) btn.disabled = true;
      this.status('Cropping floor plan image...');
      try {
        const img = await this.loadImageForCanvas(this.bgUrl);
        const scaleX = (img.naturalWidth || oldW) / oldW;
        const scaleY = (img.naturalHeight || oldH) / oldH;
        const sx = Math.round(crop.x * scaleX);
        const sy = Math.round(crop.y * scaleY);
        const sw = Math.round(crop.w * scaleX);
        const sh = Math.round(crop.h * scaleY);
        const canvas = document.createElement('canvas');
        canvas.width = Math.max(1, sw);
        canvas.height = Math.max(1, sh);
        const ctx = canvas.getContext('2d');
        ctx.drawImage(img, sx, sy, sw, sh, 0, 0, canvas.width, canvas.height);
        const blob = await this.canvasToBlob(canvas);
        if (blob.size > 8 * 1024 * 1024) {
          throw new Error('Cropped image is over 8 MB. Use a smaller crop or upload a smaller map image first.');
        }
        const file = new File([blob], `floor-plan-cropped-${Date.now()}.png`, { type: 'image/png' });
        const url = await this.opts.onUploadBackground(file);
        if (!url) throw new Error('Cropped image upload failed.');
        this.remapElementsForCrop(crop, oldW, oldH);
        this.world = { w: canvas.width, h: canvas.height };
        this.siteFt = { w: canvas.width / this.ppf, h: canvas.height / this.ppf };
        this.cancelCrop();
        this.setBackground(url, { silent: true });
        this.undoStack = [];
        this.redoStack = [];
        this.updateUndoButtons();
        this.setDirty(true);
        this.renderAll();
        this.status('Map cropped. Click Save so the app uses the cropped version.', 'success');
      } catch (err) {
        console.error('[fpb] crop background', err);
        this.status((err && err.message) || 'Crop failed.', 'error');
      } finally {
        if (btn) btn.disabled = false;
      }
    }

    async rotateBackgroundClockwise() {
      if (!this.bgUrl || !this.opts.onUploadBackground) return false;
      this.status('Rotating floor plan image…');
      const oldW = this.world.w;
      const oldH = this.world.h;
      const img = await this.loadImageForCanvas(this.bgUrl);
      const canvas = document.createElement('canvas');
      canvas.width = img.naturalHeight || oldH || WORLD_DEFAULT.h;
      canvas.height = img.naturalWidth || oldW || WORLD_DEFAULT.w;
      const ctx = canvas.getContext('2d');
      ctx.translate(canvas.width, 0);
      ctx.rotate(Math.PI / 2);
      ctx.drawImage(img, 0, 0);
      const blob = await this.canvasToBlob(canvas);
      if (blob.size > 8 * 1024 * 1024) {
        throw new Error('Rotated image is over 8 MB. Upload a smaller map image first.');
      }
      const file = new File([blob], `floor-plan-rotated-${Date.now()}.png`, { type: 'image/png' });
      const url = await this.opts.onUploadBackground(file);
      if (!url) throw new Error('Rotated image upload failed.');
      this.rotateElementsClockwise(oldW, oldH, canvas.width, canvas.height);
      this.setBackground(url, { silent: true });
      this.undoStack = [];
      this.redoStack = [];
      this.updateUndoButtons();
      this.setDirty(true);
      this.renderAll();
      this.status('Map rotated. Click Save so the app uses the portrait version.', 'success');
      return true;
    }

    async rotateMapClockwise() {
      if (this.bgUrl) {
        if (!this.opts.onUploadBackground) {
          this.status('This view cannot save a rotated background image.', 'error');
          return;
        }
        try {
          await this.rotateBackgroundClockwise();
        } catch (err) {
          console.error('[fpb] rotate background', err);
          this.status((err && err.message) || 'Rotation failed.', 'error');
        }
        return;
      }
      this.rotateCanvas();
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

    // ── Feet ⇄ canvas conversions (ppf = px per foot) ───────
    snapWorld(px) { return Math.round(px / this.ppf) * this.ppf; }   // snap world px to 1 ft
    ftToFracW(ft) { return (ft * this.ppf) / this.world.w; }
    ftToFracH(ft) { return (ft * this.ppf) / this.world.h; }
    elWidthFt(el) { return el.w * this.world.w / this.ppf; }
    elHeightFt(el) { return el.h * this.world.h / this.ppf; }
    fmtFt(ft) { const r = Math.round(ft * 10) / 10; return (Number.isInteger(r) ? r : r.toFixed(1)); }
    // White or dark label text depending on the fill's luminance.
    textOn(hex) {
      const m = /^#?([0-9a-f]{6})$/i.exec(hex || '');
      if (!m) return '#fff';
      const n = parseInt(m[1], 16), r = n >> 16, g = (n >> 8) & 255, b = n & 255;
      return (0.299 * r + 0.587 * g + 0.114 * b) > 150 ? '#1a1a1a' : '#fff';
    }

    // ── Canvas interaction ──────────────────────────────────
    wireCanvas() {
      this.initPanzoom();
      const canvas = this.$.canvas;

      if (this.readOnly) {
        // View mode: pan/zoom freely; a tap (no drag) on an element opens
        // its info popover. Any pan/zoom movement dismisses it.
        this.$.zoomIn.addEventListener('click', () => this.panzoom && this.panzoom.zoomIn());
        this.$.zoomOut.addEventListener('click', () => this.panzoom && this.panzoom.zoomOut());
        this.$.zoomFit.addEventListener('click', () => { this.hidePopover(); this.fit(); });
        canvas.addEventListener('panzoomchange', () => this.hidePopover());
        let down = null;
        this.$.viewport.addEventListener('pointerdown', (e) => { down = { x: e.clientX, y: e.clientY }; });
        this.$.viewport.addEventListener('pointerup', (e) => {
          if (!down) return;
          const moved = Math.hypot(e.clientX - down.x, e.clientY - down.y) > 6;
          down = null;
          if (moved || e.target.closest('.fpb-zoom') || e.target.closest('.fpb-pop')) return;
          const elDiv = e.target.closest('.fpb-el');
          if (elDiv) this.showPopover(elDiv.dataset.id); else this.hidePopover();
        });
        return;
      }

      canvas.addEventListener('pointerdown', (e) => {
        if (this.spacePan || e.button === 2) return;     // let panzoom pan / right-click → context menu
        this._lpFired = false;
        // Touch: in select mode a long-press opens the context menu (no right-click).
        if (e.pointerType === 'touch' && this.tool === 'select' && !e.target.closest('.fpb-h, .fpb-rot-h')) this.armLongPress(e);
        const rotH = e.target.closest('.fpb-rot-h');
        if (rotH) { this.startRotate(e); return; }
        const handle = e.target.closest('.fpb-h');
        if (handle) { this.startResize(e, handle.dataset.h); return; }
        const elDiv = e.target.closest('.fpb-el');
        if (elDiv) {
          e.stopPropagation();
          const id = elDiv.dataset.id;
          if (e.shiftKey) { this.toggleSelect(id); return; }   // shift-click builds a multi-selection
          if (!this.isSelected(id)) this.select(id);           // plain click selects just this one
          this.startMove(e, id);
          return;
        }
        if (this.tool === 'select') return;              // empty space: panzoom pans; click deselects (below)
        if (this.tool === 'measure') { this.startMeasure(e); return; }
        this.startDraw(e);
      });

      // Right-click anywhere → context menu (item menu or canvas menu).
      canvas.addEventListener('contextmenu', (e) => {
        e.preventDefault();
        const elDiv = e.target.closest('.fpb-el');
        if (elDiv) { if (!this.isSelected(elDiv.dataset.id)) this.select(elDiv.dataset.id); this.openContextMenu(e, elDiv.dataset.id); }
        else this.openContextMenu(e, null);
      });

      // Click on empty space in select mode → deselect (but not after a pan-drag).
      let downAt = null;
      this.$.viewport.addEventListener('pointerdown', (e) => { downAt = { x: e.clientX, y: e.clientY }; });
      this.$.viewport.addEventListener('pointerup', (e) => {
        if (!downAt) return;
        const moved = Math.hypot(e.clientX - downAt.x, e.clientY - downAt.y) > 4;
        downAt = null;
        if (moved || this.tool !== 'select' || e.button === 2) return;
        if (e.target.closest('.fpb-el') || e.target.closest('.fpb-zoom')) return;
        if (this._sel.length) { this._sel = []; this.renderAll(); }
      });
    }

    // ── Read-only info popover ──────────────────────────────
    vendorName(id) {
      if (!id) return null;
      const v = this.vendors.find(v => String(v.event_vendor_id || v.vendor_id) === String(id));
      return v ? (v.vendor_name || v.name || null) : null;
    }

    showPopover(id) {
      const el = this.byId(id);
      // Bare objects and text labels carry no extra info worth a popover.
      if (!el || el.type === 'text' || (el.type === 'shape' && !el.label)) { this.hidePopover(); return; }
      const cat = CAT_BY_ID[el.icon];
      const obj = el.type === 'shape' ? OBJ_BY_KIND[el.kind] : null;
      const vendor = this.vendorName(el.vendor_id);
      const title = el.label || vendor || (el.type === 'zone' ? 'Zone' : obj ? obj.label : (cat ? cat.label : 'Location'));
      const rows = [];
      if (el.type === 'booth' && el.number != null && el.number !== '') rows.push(`Booth ${esc(el.number)}`);
      if (obj) rows.push(esc(obj.label));
      if (el.type !== 'zone' && el.type !== 'shape' && cat) rows.push(esc(cat.label));
      if (el.size) rows.push(esc(String(el.size).replace('x', ' × ')) + ' ft');
      this.$.pop.innerHTML = `
        <div class="pop-title"><span class="pop-dot" style="background:${esc(el.color || (cat && cat.color) || '#0a7aff')}"></span>${esc(title)}</div>
        ${rows.length ? `<div class="pop-meta">${rows.join(' · ')}</div>` : ''}
        ${vendor && el.label && vendor !== el.label ? `<div class="pop-meta">${esc(vendor)}</div>` : ''}
        ${el.description ? `<div class="pop-desc">${esc(el.description)}</div>` : ''}`;
      // Position near the element, clamped inside the viewport.
      const elDiv = this.$.els.querySelector(`.fpb-el[data-id="${el.id}"]`);
      const vpRect = this.$.viewport.getBoundingClientRect();
      const r = elDiv.getBoundingClientRect();
      this.$.pop.hidden = false;
      const pw = this.$.pop.offsetWidth, ph = this.$.pop.offsetHeight;
      let left = r.left - vpRect.left + r.width / 2 - pw / 2;
      left = clamp(left, 8, vpRect.width - pw - 8);
      let top = r.top - vpRect.top - ph - 10;
      if (top < 8) top = r.bottom - vpRect.top + 10;
      this.$.pop.style.left = left + 'px';
      this.$.pop.style.top = top + 'px';
      this.selectedId = el.id;
      this.renderElements();
    }

    hidePopover() {
      if (!this.$.pop || this.$.pop.hidden) return;
      this.$.pop.hidden = true;
      this.selectedId = null;
      this.renderElements();
    }

    // Move (drag) the grabbed element — and any multi-selection / connected run with it.
    startMove(e, grabbedId) {
      const el = this.byId(grabbedId || this.selectedId);
      if (!el) return;
      e.preventDefault();
      this.panzoom.setOptions({ disablePan: true });
      const start = { cx: e.clientX, cy: e.clientY, x: el.x, y: el.y };
      // Followers are only explicitly selected elements or connected shape runs.
      // A zone is a visual boundary, never a parent container: moving or
      // reshaping it must not move booths, labels, or objects inside it.
      const followerSet = new Set(this._sel.filter(id => id !== el.id));
      if (el.type === 'shape' && el.groupId) {
        this.elements.forEach(o => { if (o.type === 'shape' && o.groupId === el.groupId && o !== el) followerSet.add(o.id); });
      }
      const single = followerSet.size === 0;
      const group = [...followerSet].map(id => this.byId(id)).filter(Boolean).map(o => ({ o, dx: o.x - el.x, dy: o.y - el.y }));
      let moved = false, pushed = false;
      const onMove = (ev) => {
        if (this._lpFired) return;            // a touch long-press opened the menu — don't drag
        const s = this.scale();
        const dx = (ev.clientX - start.cx) / s / this.world.w;
        const dy = (ev.clientY - start.cy) / s / this.world.h;
        if (!moved && Math.hypot(ev.clientX - start.cx, ev.clientY - start.cy) < 3) return;
        if (!pushed) { this.pushUndo(); pushed = true; }
        moved = true;
        let nx = start.x + dx, ny = start.y + dy;
        // Only single, axis-aligned shapes use edge magnets; groups just grid-snap.
        if (single && el.type !== 'pin' && el.type !== 'text') {
          const snapped = this.snapShape(el, nx, ny);
          nx = snapped.x; ny = snapped.y;
        } else {
          this.clearGuides();
          if (this.snap && el.type !== 'pin') {
            nx = this.snapWorld(nx * this.world.w) / this.world.w;
            ny = this.snapWorld(ny * this.world.h) / this.world.h;
          }
        }
        el.x = clamp(nx, 0, 1); el.y = clamp(ny, 0, 1);
        this.positionElementDiv(el);
        group.forEach(({ o, dx: ox, dy: oy }) => { o.x = clamp(el.x + ox, 0, 1); o.y = clamp(el.y + oy, 0, 1); this.positionElementDiv(o); });
      };
      const onUp = () => {
        window.removeEventListener('pointermove', onMove);
        window.removeEventListener('pointerup', onUp);
        this.clearGuides();
        this.panzoom.setOptions({ disablePan: this.tool !== 'select' });
        if (moved) { if (single && this.isConnect(el)) this.connectShape(el); this.setDirty(true); this.renderAll(); }
      };
      window.addEventListener('pointermove', onMove);
      window.addEventListener('pointerup', onUp);
    }

    // Is element o's centre inside zone z (accounting for the zone's rotation)?
    zoneContains(z, o) {
      const W = this.world.w, H = this.world.h;
      const dx = (o.x - z.x) * W, dy = (o.y - z.y) * H;
      const th = -(z.rot || 0) * Math.PI / 180, cos = Math.cos(th), sin = Math.sin(th);
      const lx = dx * cos - dy * sin, ly = dx * sin + dy * cos;   // into zone's local frame
      if (!z.points || z.points.length < 3) return Math.abs(lx) <= z.w * W / 2 && Math.abs(ly) <= z.h * H / 2;
      const px = lx / (z.w * W) + 0.5, py = ly / (z.h * H) + 0.5;
      let inside = false;
      for (let i = 0, j = z.points.length - 1; i < z.points.length; j = i++) {
        const a = z.points[i], b = z.points[j];
        if (((a[1] > py) !== (b[1] > py)) && px < (b[0] - a[0]) * (py - a[1]) / ((b[1] - a[1]) || 1e-9) + a[0]) inside = !inside;
      }
      return inside;
    }

    // Rotate the selected element by dragging the rotation handle.
    isRotatable(el) { return el && (el.type === 'booth' || el.type === 'zone' || el.type === 'shape' || el.type === 'text'); }
    isConnect(el) { return el && el.type === 'shape' && OBJ_BY_KIND[el.kind] && OBJ_BY_KIND[el.kind].connect; }
    startRotate(e) {
      const el = this.byId(this.selectedId);
      if (!this.isRotatable(el)) return;
      e.preventDefault(); e.stopPropagation();
      this.panzoom.setOptions({ disablePan: true });
      this.pushUndo();
      const div = this.$.els.querySelector(`.fpb-el[data-id="${el.id}"]`);
      const r = div.getBoundingClientRect();
      const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
      const onMove = (ev) => {
        let deg = Math.atan2(ev.clientY - cy, ev.clientX - cx) * 180 / Math.PI + 90;
        if (!ev.shiftKey) deg = Math.round(deg / ROT_SNAP) * ROT_SNAP;   // snap unless Shift
        el.rot = ((Math.round(deg) % 360) + 360) % 360;
        this.positionElementDiv(el);
        this.showDimText(`${el.rot}°`, ev);
      };
      const onUp = () => {
        window.removeEventListener('pointermove', onMove);
        window.removeEventListener('pointerup', onUp);
        this.panzoom.setOptions({ disablePan: this.tool !== 'select' });
        this.hideDim();
        this.setDirty(true); this.renderAll();
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
      else { cx = this.snapWorld(cx - wpx / 2) + wpx / 2; }
      if (bestY) { cy = bestY.to + bestY.off; this.$.guideH.style.top = (bestY.to / H * 100) + '%'; this.$.guideH.hidden = false; }
      else { cy = this.snapWorld(cy - hpx / 2) + hpx / 2; }

      return { x: cx / W, y: cy / H };
    }
    clearGuides() { this.$.guideV.hidden = true; this.$.guideH.hidden = true; }

    // Floating "W × H ft" readout that follows the pointer during draw/resize.
    showDim(el, ev) { this.showDimText(`${this.fmtFt(this.elWidthFt(el))} × ${this.fmtFt(this.elHeightFt(el))} ft`, ev); }
    showDimText(text, ev) {
      const d = this.$.dim;
      if (!d) return;
      const vp = this.$.viewport.getBoundingClientRect();
      d.textContent = text;
      d.hidden = false;
      d.style.left = clamp(ev.clientX - vp.left + 14, 4, vp.width - 90) + 'px';
      d.style.top = clamp(ev.clientY - vp.top - 30, 4, vp.height - 24) + 'px';
    }
    hideDim() { if (this.$.dim) this.$.dim.hidden = true; }

    // Resize via handles.
    startResize(e, dir) {
      const el = this.byId(this.selectedId);
      if (!el || el.type === 'pin') return;
      if (el.type === 'text') { this.startTextResize(e); return; }
      e.preventDefault(); e.stopPropagation();
      this.panzoom.setOptions({ disablePan: true });
      this.pushUndo();
      const W = this.world.w, H = this.world.h;
      const minPx = MIN_FT * this.ppf;
      // Resize in the element's own (possibly rotated) frame: the edge/corner
      // opposite the handle stays anchored in world space.
      const th = (el.rot || 0) * Math.PI / 180, cos = Math.cos(th), sin = Math.sin(th);
      const ux = { x: cos, y: sin }, uy = { x: -sin, y: cos };
      const sx = dir.includes('e') ? 1 : dir.includes('w') ? -1 : 0;
      const sy = dir.includes('s') ? 1 : dir.includes('n') ? -1 : 0;
      const start = { cx: e.clientX, cy: e.clientY, x0: el.x * W, y0: el.y * H, w0: el.w * W, h0: el.h * H };
      const onMove = (ev) => {
        const s = this.scale();
        const dx = (ev.clientX - start.cx) / s, dy = (ev.clientY - start.cy) / s;
        const C0 = { x: start.x0, y: start.y0 }, w0 = start.w0, h0 = start.h0;
        // Fixed anchor and the moving handle's new world position.
        const A = { x: C0.x - sx * w0 / 2 * ux.x - sy * h0 / 2 * uy.x, y: C0.y - sx * w0 / 2 * ux.y - sy * h0 / 2 * uy.y };
        const P = { x: C0.x + sx * w0 / 2 * ux.x + sy * h0 / 2 * uy.x + dx, y: C0.y + sx * w0 / 2 * ux.y + sy * h0 / 2 * uy.y + dy };
        const V = { x: P.x - A.x, y: P.y - A.y };
        let nw = sx !== 0 ? sx * (V.x * ux.x + V.y * ux.y) : w0;
        let nh = sy !== 0 ? sy * (V.x * uy.x + V.y * uy.y) : h0;
        if (this.snap) { if (sx !== 0) nw = this.snapWorld(nw); if (sy !== 0) nh = this.snapWorld(nh); }
        nw = Math.max(nw, minPx); nh = Math.max(nh, minPx);
        const C = { x: A.x + sx * nw / 2 * ux.x + sy * nh / 2 * uy.x, y: A.y + sx * nw / 2 * ux.y + sy * nh / 2 * uy.y };
        el.x = C.x / W; el.y = C.y / H; el.w = nw / W; el.h = nh / H;
        this.positionElementDiv(el);
        this.showDim(el, ev);
      };
      const onUp = () => {
        window.removeEventListener('pointermove', onMove);
        window.removeEventListener('pointerup', onUp);
        this.panzoom.setOptions({ disablePan: this.tool !== 'select' });
        this.hideDim();
        // A drag-resized booth / sized object writes its footprint back to the size field.
        if (el.type === 'booth' || el.type === 'shape') {
          if (el.type === 'booth') this.lastBoothFt = { w: this.elWidthFt(el), h: this.elHeightFt(el) };
          el.size = `${Math.round(this.elWidthFt(el))}x${Math.round(this.elHeightFt(el))}`;
        }
        if (this.isConnect(el)) this.connectShape(el);
        this.setDirty(true);
        this.renderAll();
      };
      window.addEventListener('pointermove', onMove);
      window.addEventListener('pointerup', onUp);
    }

    startTextResize(e) {
      const el = this.byId(this.selectedId);
      if (!el || el.type !== 'text') return;
      e.preventDefault(); e.stopPropagation();
      this.panzoom.setOptions({ disablePan: true }); this.pushUndo();
      const div = this.$.els.querySelector(`.fpb-el[data-id="${el.id}"]`), r = div.getBoundingClientRect();
      const cx = r.left + r.width / 2, cy = r.top + r.height / 2;
      const d0 = Math.max(12, Math.hypot(e.clientX - cx, e.clientY - cy)), fs0 = el.fontSize || 0.016;
      const onMove = ev => {
        const factor = Math.hypot(ev.clientX - cx, ev.clientY - cy) / d0;
        el.fontSize = clamp(fs0 * factor, 0.006, 0.12);
        div.style.fontSize = Math.max(7, el.fontSize * this.world.w) + 'px';
        this.showDimText(`${Math.round(el.fontSize * this.world.w)} px`, ev);
      };
      const onUp = () => {
        window.removeEventListener('pointermove', onMove); window.removeEventListener('pointerup', onUp);
        this.panzoom.setOptions({ disablePan: this.tool !== 'select' }); this.hideDim(); this.setDirty(true); this.renderAll();
      };
      window.addEventListener('pointermove', onMove); window.addEventListener('pointerup', onUp);
    }

    // Draw / stamp new elements.
    startDraw(e) {
      e.preventDefault(); e.stopPropagation();
      const tool = this.tool;
      if (tool === 'zone' && this.zoneMode === 'freeform') { this.startFreeformZone(e); return; }
      const start = this.worldPoint(e);
      let dragging = false;
      const rubber = this.$.rubber;
      const minPx = MIN_FT * this.ppf;
      const snapPt = (p) => this.snap
        ? { x: this.snapWorld(p.x), y: this.snapWorld(p.y) }
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
        this.showDimText(`${this.fmtFt(Math.abs(b.x - a.x) / this.ppf)} × ${this.fmtFt(Math.abs(b.y - a.y) / this.ppf)} ft`, ev);
      };
      const onUp = (ev) => {
        window.removeEventListener('pointermove', onMove);
        window.removeEventListener('pointerup', onUp);
        rubber.hidden = true;
        this.hideDim();
        const end = this.worldPoint(ev);
        if (tool === 'pin') { this.addPin(end); return; }
        if (tool === 'text') { this.addText(start); return; }
        let rect;
        if (dragging) {
          const a = snapPt(start), b = snapPt(end);
          rect = { l: Math.min(a.x, b.x), t: Math.min(a.y, b.y), w: Math.abs(b.x - a.x), h: Math.abs(b.y - a.y) };
          if (rect.w < minPx || rect.h < minPx) rect = null;
        }
        if (!rect) {
          // Click-stamp default footprints, in feet → world px.
          const o = OBJ_BY_KIND[this.objKind] || OBJ_BY_KIND[DEFAULT_OBJ];
          const defFt = tool === 'booth' ? this.lastBoothFt
            : tool === 'object' ? { w: o.ftW, h: o.ftH }
            : tool === 'zone' ? { w: 30, h: 20 }
            : { w: 4, h: 4 };
          const def = { w: defFt.w * this.ppf, h: defFt.h * this.ppf };
          const p = snapPt({ x: start.x - def.w / 2, y: start.y - def.h / 2 });
          rect = { l: p.x, t: p.y, w: def.w, h: def.h };
        }
        this.addShape(tool, rect);
      };
      window.addEventListener('pointermove', onMove);
      window.addEventListener('pointerup', onUp);
    }

    startFreeformZone(e) {
      e.preventDefault(); e.stopPropagation();
      const p = this.worldPoint(e), last = this.zonePoints[this.zonePoints.length - 1];
      if (!last || Math.hypot(p.x - last.x, p.y - last.y) * this.scale() > 4) this.zonePoints.push(p);
      this.drawPolygonDraft();
      if (e.detail >= 2 && this.zonePoints.length >= 3) this.finishPolygonZone();
    }

    drawPolygonDraft() {
      const pts = this.zonePoints, rubber = this.$.rubber;
      if (!pts.length) { rubber.hidden = true; return; }
      const xs = pts.map(p => p.x), ys = pts.map(p => p.y), l = Math.min(...xs), t = Math.min(...ys);
      const w = Math.max(2, Math.max(...xs) - l), h = Math.max(2, Math.max(...ys) - t);
      rubber.hidden = false; rubber.classList.add('freeform');
      rubber.style.left = l / this.world.w * 100 + '%'; rubber.style.top = t / this.world.h * 100 + '%';
      rubber.style.width = w / this.world.w * 100 + '%'; rubber.style.height = h / this.world.h * 100 + '%';
      rubber.style.clipPath = `polygon(${pts.map(p => `${(p.x-l)/w*100}% ${(p.y-t)/h*100}%`).join(',')})`;
      this.status(`${pts.length} point${pts.length === 1 ? '' : 's'} added. Double-click the final point to finish.`);
    }

    cancelPolygonZone() {
      this.zonePoints = [];
      const rubber = this.$.rubber;
      rubber.hidden = true; rubber.classList.remove('freeform'); rubber.style.removeProperty('clip-path');
    }

    finishPolygonZone() {
      const pts = this.zonePoints.slice();
      if (pts.length < 3) { this.status('Add at least 3 points to make a polygon zone.', 'error'); return; }
      const xs = pts.map(p => p.x), ys = pts.map(p => p.y), l = Math.min(...xs), t = Math.min(...ys);
      const w = Math.max(...xs)-l, h = Math.max(...ys)-t;
      if (w < MIN_FT*this.ppf || h < MIN_FT*this.ppf) { this.status('Make the zone a little larger.', 'error'); return; }
      this.cancelPolygonZone(); this.pushUndo();
      const el = normalizeElement({ id:uid(), type:'zone', x:(l+w/2)/this.world.w, y:(t+h/2)/this.world.h, w:w/this.world.w, h:h/this.world.h, rot:0, label:'Zone', color:ZONE_COLORS[0], description:'', points:pts.map(p=>[(p.x-l)/w,(p.y-t)/h]) });
      this.elements.push(el); this.setDirty(true); this.select(el.id);
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
        id: uid(), type: tool, rot: 0,
        x: clamp((rect.l + rect.w / 2) / W, 0, 1),
        y: clamp((rect.t + rect.h / 2) / H, 0, 1),
        w: rect.w / W, h: rect.h / H,
      };
      const wFt = rect.w / this.ppf, hFt = rect.h / this.ppf;
      let el;
      if (tool === 'booth') {
        const cat = CAT_BY_ID[this.boothCategory] || CAT_BY_ID[DEFAULT_CAT];
        el = Object.assign(base, { number: this.nextBoothNumber(), label: '', icon: cat.id, color: cat.color, vendor_id: null, size: `${Math.round(wFt)}x${Math.round(hFt)}`, description: '' });
        this.lastBoothFt = { w: wFt, h: hFt };
      } else if (tool === 'zone') {
        el = Object.assign(base, { label: 'Zone', color: ZONE_COLORS[0], description: '' });
      } else {   // object
        const o = OBJ_BY_KIND[this.objKind] || OBJ_BY_KIND[DEFAULT_OBJ];
        el = Object.assign(base, { type: 'shape', kind: o.kind, shape: o.shape, label: '', color: o.color, size: `${Math.round(wFt)}x${Math.round(hFt)}` });
        if (o.connect) el.groupId = null;
      }
      this.elements.push(el);
      if (this.isConnect(el)) this.connectShape(el);   // auto-join bars / barrier runs
      this.setDirty(true);
      this.select(el.id);
      // Stay in the tool so rows can be stamped quickly.
    }

    // Resize a booth/counter to the feet stored in el.size, keeping its centre.
    applySizeFt(el) {
      if (!el || !el.size || el.w == null) return;
      const parts = String(el.size).split('x');
      const wf = parseFloat(parts[0]), hf = parseFloat(parts[1]);
      if (!(wf > 0) || !(hf > 0)) return;
      el.w = clamp(this.ftToFracW(wf), 0, 1);
      el.h = clamp(this.ftToFracH(hf), 0, 1);
      if (el.type === 'booth') this.lastBoothFt = { w: wf, h: hf };
    }

    // ── Connectable objects → groups (bars, barrier runs) ───
    // When a connectable object's edge lands flush (within ~1 ft) of another of
    // the same kind, merge them into one group so the run drags as a unit.
    connectShape(el) {
      const W = this.world.w, H = this.world.h, tol = this.ppf * 1.2;
      if (el.rot) return;   // only axis-aligned pieces auto-connect
      const ax = { l: (el.x - el.w / 2) * W, r: (el.x + el.w / 2) * W, t: (el.y - el.h / 2) * H, b: (el.y + el.h / 2) * H };
      for (const o of this.elements) {
        if (o === el || o.type !== 'shape' || o.kind !== el.kind || o.rot) continue;
        const bx = { l: (o.x - o.w / 2) * W, r: (o.x + o.w / 2) * W, t: (o.y - o.h / 2) * H, b: (o.y + o.h / 2) * H };
        const xOverlap = Math.min(ax.r, bx.r) - Math.max(ax.l, bx.l) > -tol;
        const yOverlap = Math.min(ax.b, bx.b) - Math.max(ax.t, bx.t) > -tol;
        const touch = (Math.abs(ax.r - bx.l) < tol || Math.abs(ax.l - bx.r) < tol) && yOverlap
                   || (Math.abs(ax.b - bx.t) < tol || Math.abs(ax.t - bx.b) < tol) && xOverlap;
        if (touch) {
          const gid = o.groupId || el.groupId || ('grp_' + uid());
          const label = o.label || el.label || '';
          this.elements.forEach(c => { if (c.type === 'shape' && c.kind === el.kind && (c === el || c === o || (c.groupId && (c.groupId === o.groupId || c.groupId === el.groupId)))) { c.groupId = gid; if (label) c.label = label; } });
          el.groupId = gid;
        }
      }
    }

    // ── Measure tool — drag to read a distance in feet (places nothing) ──
    startMeasure(e) {
      e.preventDefault(); e.stopPropagation();
      const cal = this.$.callipers;
      const start = this.worldPoint(e);
      const onMove = (ev) => {
        const cur = this.worldPoint(ev);
        this.drawCallipers(start, cur);
        this.showDimText(`${this.fmtFt(Math.hypot(cur.x - start.x, cur.y - start.y) / this.ppf)} ft`, ev);
      };
      const onUp = () => {
        window.removeEventListener('pointermove', onMove);
        window.removeEventListener('pointerup', onUp);
        setTimeout(() => { cal.hidden = true; this.hideDim(); }, 1400);   // linger briefly
      };
      window.addEventListener('pointermove', onMove);
      window.addEventListener('pointerup', onUp);
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
      } else if (this.isConnect(el)) {
        copy.x = clamp(el.x + el.w, 0, 1);            // flush to the right → chains the run
      } else if (el.type === 'zone' || el.type === 'shape') {
        copy.x = clamp(el.x + (el.w || 0.02) + 12 / this.world.w, 0, 1);
      } else {
        copy.x = clamp(el.x + 20 / this.world.w, 0, 1);
        copy.y = clamp(el.y + 20 / this.world.h, 0, 1);
      }
      this.elements.push(copy);
      if (this.isConnect(copy)) this.connectShape(copy);
      this.setDirty(true);
      this.select(copy.id);
    }

    deleteSelected() {
      if (!this._sel.length) return;
      this.pushUndo();
      const ids = new Set(this._sel);
      this.elements = this.elements.filter(x => !ids.has(x.id));
      this._sel = [];
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
          if (this.zonePoints.length) { this.cancelPolygonZone(); this.status('Polygon cancelled.'); return; }
          this.closeContextMenu();
          if (this.tool !== 'select') this.setTool('select');
          else if (this._sel.length) { this._sel = []; this.renderAll(); }
          return;
        }
        if (e.key === 'Enter' && this.zonePoints.length) { e.preventDefault(); this.finishPolygonZone(); return; }
        if (meta && e.key.toLowerCase() === 'a') { e.preventDefault(); this._sel = this.elements.map(x => x.id); this.renderAll(); return; }
        if ((e.key === 'Delete' || e.key === 'Backspace') && this._sel.length) { e.preventDefault(); this.deleteSelected(); return; }
        const toolKeys = { v: 'select', b: 'booth', o: 'object', z: 'zone', t: 'text', p: 'pin', m: 'measure' };
        if (!meta && toolKeys[e.key.toLowerCase()]) { this.setTool(toolKeys[e.key.toLowerCase()]); return; }
        if (e.key.startsWith('Arrow') && this._sel.length) {
          e.preventDefault();
          const step = (e.shiftKey ? this.ppf : 2);   // Shift = 1 ft nudge
          this.pushUndo(true);
          this.selectedEls().forEach(el => {
            if (e.key === 'ArrowLeft') el.x -= step / this.world.w;
            if (e.key === 'ArrowRight') el.x += step / this.world.w;
            if (e.key === 'ArrowUp') el.y -= step / this.world.h;
            if (e.key === 'ArrowDown') el.y += step / this.world.h;
            el.x = clamp(el.x, 0, 1); el.y = clamp(el.y, 0, 1);
            this.positionElementDiv(el);
          });
          this.setDirty(true);
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
      if (!this.$.undoBtn) return;
      this.$.undoBtn.disabled = !this.undoStack.length;
      this.$.redoBtn.disabled = !this.redoStack.length;
    }

    // ── Rendering ───────────────────────────────────────────
    byId(id) { return this.elements.find(x => x.id === id) || null; }

    // Selection: `selectedId` is the sole selection (for editing); `_sel`
    // holds the full multi-selection used for highlight and group drag.
    get selectedId() { return this._sel.length === 1 ? this._sel[0] : null; }
    set selectedId(v) { this._sel = (v == null) ? [] : [v]; }
    get selectedIds() { return this._sel; }
    isSelected(id) { return this._sel.indexOf(id) >= 0; }
    toggleSelect(id) {
      const i = this._sel.indexOf(id);
      if (i >= 0) this._sel.splice(i, 1); else this._sel.push(id);
      this.renderAll();
    }
    selectedEls() { return this._sel.map(id => this.byId(id)).filter(Boolean); }

    select(id) {
      this._sel = id == null ? [] : [id];
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
        if (el.type === 'text') div.style.transform = `translate(-50%, -50%) rotate(${el.rot || 0}deg)`;
      } else {
        div.style.left = ((el.x - el.w / 2) * 100) + '%';
        div.style.top = ((el.y - el.h / 2) * 100) + '%';
        if (el.rot) div.style.transform = `rotate(${el.rot}deg)`;
        else div.style.removeProperty('transform');
      }
    }

    renderElements() {
      const W = this.world.w, H = this.world.h;
      const selEl = this.byId(this.selectedId);
      const single = this._sel.length === 1;
      // Box rotation + counter-rotation that keeps labels upright.
      const tf = (el) => el.rot ? `transform:rotate(${el.rot}deg);` : '';
      const up = (el) => el.rot ? `transform:rotate(${-el.rot}deg);` : '';
      const handles = (el, corners) => (this.readOnly || !single || el.id !== this.selectedId) ? '' :
        (corners ? ['nw', 'ne', 'se', 'sw'] : ['nw', 'n', 'ne', 'e', 'se', 's', 'sw', 'w'])
          .map(h => `<i class="fpb-h" data-h="${h}"></i>`).join('')
        + (this.isRotatable(el) ? '<i class="fpb-rot-h" title="Rotate"></i>' : '');

      this.$.els.innerHTML = this.elements.map(el => {
        const sel = this.isSelected(el.id) ? ' selected' : '';
        if (el.type === 'booth') {
          const wpx = el.w * W, hpx = el.h * H;
          const name = el.label || this.vendorName(el.vendor_id) || '';   // fall back to linked vendor
          const boothNumber = el.number != null && el.number !== '' ? el.number : '';
          const mult = LBL_SIZES[el.labelSize] || 1;
          const inBox = name && (el.labelPos || 'in') === 'in';
          // Number shrinks when a name shares the box; both sit inside, upright.
          const numSize = clamp(Math.min(wpx, hpx) * (inBox ? 0.3 : 0.46), 10, inBox ? 22 : 30);
          const nameSize = clamp(wpx * 0.14 * mult, 7, 44);
          const ink = this.textOn(el.color);
          return `<div class="fpb-el fpb-booth${sel}" data-id="${el.id}" style="left:${(el.x - el.w / 2) * 100}%;top:${(el.y - el.h / 2) * 100}%;width:${el.w * 100}%;height:${el.h * 100}%;--c:${esc(el.color)};${tf(el)}">
            <div class="fpb-booth-in" style="color:${ink};${up(el)}">
              ${boothNumber !== '' ? `<span class="num" style="font-size:${numSize}px">${esc(boothNumber)}</span>` : ''}
              ${inBox ? `<span class="bname" style="font-size:${nameSize}px;transform:rotate(${num(el.labelRot)}deg) scale(${num(el.labelScale, 1)})">${esc(name)}</span>` : ''}
            </div>
            ${name && !inBox ? `<span class="fpb-el-label" style="font-size:${clamp(wpx * 0.2 * mult, 11, 30)}px;transform:translateX(-50%) rotate(${num(el.labelRot) - num(el.rot)}deg) scale(${num(el.labelScale, 1)});">${esc(name)}</span>` : ''}
            ${handles(el)}</div>`;
        }
        if (el.type === 'zone') {
          const wpx = el.w * W;
          const fs = clamp(wpx * 0.06, 12, 22);
          const poly = el.points ? `<svg class="fpb-zone-poly" viewBox="0 0 100 100" preserveAspectRatio="none"><polygon points="${el.points.map(p => `${p[0]*100},${p[1]*100}`).join(' ')}"/></svg>` : '';
          return `<div class="fpb-el fpb-zone${el.points ? ' polygon' : ''}${sel}" data-id="${el.id}" style="left:${(el.x - el.w / 2) * 100}%;top:${(el.y - el.h / 2) * 100}%;width:${el.w * 100}%;height:${el.h * 100}%;--c:${esc(el.color)};${tf(el)}">
            ${poly}
            ${el.label ? `<span class="zlabel" style="font-size:${fs}px;transform:rotate(${num(el.labelRot)}deg) scale(${num(el.labelScale, 1)})">${esc(el.label)}</span>` : ''}
            ${handles(el)}</div>`;
        }
        if (el.type === 'shape') {
          const o = OBJ_BY_KIND[el.kind] || OBJ_BY_KIND[DEFAULT_OBJ];
          const wpx = el.w * W, hpx = el.h * H;
          const round = o.shape === 'round' ? ' round' : '';
          const fs = clamp(Math.min(wpx, hpx) * 0.32, 9, 20);
          const grp = el.groupId && selEl && selEl.groupId === el.groupId ? ' ingroup' : '';
          const deco = o.deco ? ` fpb-deco-${o.deco}` : '';
          const ink = this.textOn(el.color);
          const icSize = clamp(Math.min(wpx, hpx) * 0.5, 12, 40);
          const showIc = o.ic && !el.label && Math.min(wpx, hpx) > 22;
          return `<div class="fpb-el fpb-shape${round}${sel}${grp}${deco}" data-id="${el.id}" data-kind="${esc(el.kind)}" style="left:${(el.x - el.w / 2) * 100}%;top:${(el.y - el.h / 2) * 100}%;width:${el.w * 100}%;height:${el.h * 100}%;--c:${esc(el.color)};--ink:${ink};${tf(el)}">
            ${showIc ? `<svg class="sicon" style="width:${icSize}px;height:${icSize}px;${up(el)}"><use href="#${o.icon}"/></svg>` : ''}
            ${el.label ? `<span class="slabel" style="font-size:${fs}px;color:${ink};${up(el)}">${esc(el.label)}</span>` : ''}
            ${handles(el, o.shape === 'round')}</div>`;
        }
        if (el.type === 'text') {
          const fs = Math.max(11, (el.fontSize || 0.016) * W);
          return `<div class="fpb-el fpb-text${sel}${el.label ? '' : ' empty'}" data-id="${el.id}" style="left:${el.x * 100}%;top:${el.y * 100}%;font-size:${fs}px;--c:${esc(el.color || '#111')};transform:translate(-50%, -50%) rotate(${el.rot || 0}deg)">${esc(el.label || 'Text')}${handles(el, true)}</div>`;
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
      if (this._sel.length > 1) { this.renderMultiPanel(side); return; }
      if (this.tool === 'object') {
        const groups = OBJ_CATS.map(cat => `
          <div class="fpb-obj-cat">${esc(cat)}</div>
          <div class="fpb-obj-grid">${OBJECTS.filter(o => o.cat === cat).map(o => `
            <button type="button" class="fpb-obj-btn${o.kind === this.objKind ? ' active' : ''}" data-obj="${o.kind}" title="${esc(o.label)} · ${o.ftW}×${o.ftH} ft">
              <span class="obj-ic ${o.shape === 'round' ? 'round' : ''}" style="--c:${o.color}"><svg><use href="#${o.icon}"/></svg></span>
              <span class="obj-name">${esc(o.label)}</span><span class="obj-dim">${o.ftW}×${o.ftH}</span>
            </button>`).join('')}</div>`).join('');
        side.innerHTML = `<h3>Objects</h3>
          <div class="fpb-helper">Pick an object, then click or drag on the map to place it. Bars and barriers snap together into runs.</div>
          ${groups}`;
        side.querySelectorAll('[data-obj]').forEach(b => b.addEventListener('click', () => { this.objKind = b.dataset.obj; this.renderSide(); }));
        return;
      }
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
      if (this.tool === 'zone') {
        side.innerHTML = `<h3>Zone shape</h3><div class="fpb-helper">Use a rectangle for clean boundaries, or click points around an irregular area. Double-click the final point to finish.</div><div class="fpb-segmented"><button type="button" class="fpb-btn${this.zoneMode === 'rect' ? ' active' : ''}" data-zone-mode="rect">Rectangle</button><button type="button" class="fpb-btn${this.zoneMode === 'freeform' ? ' active' : ''}" data-zone-mode="freeform">Polygon</button></div>`;
        side.querySelectorAll('[data-zone-mode]').forEach(b => b.addEventListener('click', () => this.setTool(b.dataset.zoneMode === 'freeform' ? 'freezone' : 'zone')));
        return;
      }
      side.innerHTML = `${this.unplacedVendorsHtml()}<h3>Layout</h3>${this.listHtml()}`;
      side.querySelectorAll('li[data-id]').forEach(li => li.addEventListener('click', () => this.select(li.dataset.id)));
      side.querySelectorAll('[data-vendor]').forEach(btn => btn.addEventListener('click', () => {
        const v = this.vendors.find(v => String(v.event_vendor_id || v.vendor_id) === btn.dataset.vendor);
        if (v) this.placeVendorBooth(v);
      }));
    }

    // Bulk panel for a multi-selection (shift-click): recolour, rotate, align, etc.
    renderMultiPanel(side) {
      const palette = ['#1a9e57', '#0891b2', '#262626', '#6d28d9', '#d4a017', '#b45309', '#475569', '#b08850', '#64748b', '#2f7d4f'];
      side.innerHTML = `<h3>${this._sel.length} items selected</h3>
        <div class="fpb-helper">Shift-click to add or remove. Drag any one to move them together.</div>
        <div class="fpb-field"><label>Colour all</label><div class="fpb-color-row">
          ${palette.map(c => `<button type="button" class="fpb-color-dot" data-mc="${c}" style="background:${c}"></button>`).join('')}
          <input type="color" data-mc-pick value="#1a9e57" title="Custom colour"/>
        </div></div>
        <div class="fpb-field"><label>Align</label><div class="fpb-align-row">
          <button type="button" class="fpb-btn" data-al="left">Left</button>
          <button type="button" class="fpb-btn" data-al="hcenter">Center</button>
          <button type="button" class="fpb-btn" data-al="right">Right</button>
          <button type="button" class="fpb-btn" data-al="top">Top</button>
          <button type="button" class="fpb-btn" data-al="vcenter">Middle</button>
          <button type="button" class="fpb-btn" data-al="bottom">Bottom</button>
        </div></div>
        <div class="fpb-field"><label>Distribute</label><div class="fpb-align-row">
          <button type="button" class="fpb-btn" data-dist="h">Horizontally</button>
          <button type="button" class="fpb-btn" data-dist="v">Vertically</button>
        </div></div>
        <div class="fpb-actions">
          <button type="button" class="fpb-btn" data-m="rot">Rotate 90°</button>
          <button type="button" class="fpb-btn" data-m="dup"><svg><use href="#fpb-copy"/></svg>Duplicate</button>
          <button type="button" class="fpb-btn danger" data-m="del"><svg><use href="#fpb-trash"/></svg>Delete</button>
        </div>`;
      const recolour = (c) => { this.pushUndo(); this.selectedEls().forEach(el => { if (el.type !== 'text' && el.type !== 'pin') el.color = c; }); this.setDirty(true); this.renderElements(); };
      side.querySelectorAll('[data-mc]').forEach(b => b.addEventListener('click', () => recolour(b.dataset.mc)));
      const pick = side.querySelector('[data-mc-pick]'); if (pick) pick.addEventListener('input', () => recolour(pick.value));
      side.querySelectorAll('[data-al]').forEach(b => b.addEventListener('click', () => this.alignSelection(b.dataset.al)));
      side.querySelectorAll('[data-dist]').forEach(b => b.addEventListener('click', () => this.distributeSelection(b.dataset.dist)));
      side.querySelector('[data-m="rot"]').addEventListener('click', () => { this.pushUndo(); this.selectedEls().forEach(el => { if (el.rot != null) el.rot = (((el.rot + 90) % 360) + 360) % 360; }); this.setDirty(true); this.renderElements(); });
      side.querySelector('[data-m="dup"]').addEventListener('click', () => this.duplicateSelection());
      side.querySelector('[data-m="del"]').addEventListener('click', () => { this.pushUndo(); const ids = new Set(this._sel); this.elements = this.elements.filter(e => !ids.has(e.id)); this._sel = []; this.setDirty(true); this.renderAll(); });
    }

    alignSelection(how) {
      const els = this.selectedEls(); if (els.length < 2) return;
      this.pushUndo();
      const halfW = el => (el.w || 0) / 2, halfH = el => (el.h || 0) / 2;
      const lefts = els.map(e => e.x - halfW(e)), rights = els.map(e => e.x + halfW(e));
      const tops = els.map(e => e.y - halfH(e)), bots = els.map(e => e.y + halfH(e));
      const minL = Math.min(...lefts), maxR = Math.max(...rights), minT = Math.min(...tops), maxB = Math.max(...bots);
      const cx = (minL + maxR) / 2, cy = (minT + maxB) / 2;
      els.forEach(e => {
        if (how === 'left') e.x = minL + halfW(e);
        else if (how === 'right') e.x = maxR - halfW(e);
        else if (how === 'hcenter') e.x = cx;
        else if (how === 'top') e.y = minT + halfH(e);
        else if (how === 'bottom') e.y = maxB - halfH(e);
        else if (how === 'vcenter') e.y = cy;
      });
      this.setDirty(true); this.renderElements();
    }

    distributeSelection(axis) {
      const els = this.selectedEls(); if (els.length < 3) return;
      this.pushUndo();
      const k = axis === 'h' ? 'x' : 'y';
      els.sort((a, b) => a[k] - b[k]);
      const first = els[0][k], last = els[els.length - 1][k], step = (last - first) / (els.length - 1);
      els.forEach((e, i) => { e[k] = first + step * i; });
      this.setDirty(true); this.renderElements();
    }

    duplicateSelection() {
      const els = this.selectedEls(); if (!els.length) return;
      this.pushUndo();
      const copies = els.map(el => { const c = JSON.parse(JSON.stringify(el)); c.id = uid(); c.x = clamp(c.x + 14 / this.world.w, 0, 1); c.y = clamp(c.y + 14 / this.world.h, 0, 1); if (c.type === 'booth') { c.number = this.nextBoothNumber(); c.vendor_id = null; } return c; });
      this.elements.push(...copies);
      this._sel = copies.map(c => c.id);
      this.setDirty(true); this.renderAll();
    }

    // Checklist of vendors that don't have an element on the map yet.
    unplacedVendorsHtml() {
      if (!this.vendors.length) return '';
      const placed = new Set(this.elements.filter(e => e.vendor_id).map(e => String(e.vendor_id)));
      const unplaced = this.vendors.filter(v => !placed.has(String(v.event_vendor_id || v.vendor_id)));
      if (!unplaced.length) {
        return `<h3>Vendors</h3><div class="fpb-helper fpb-all-placed">✓ All ${this.vendors.length} vendor${this.vendors.length === 1 ? ' is' : 's are'} placed on the map.</div>`;
      }
      return `<h3>Vendors to place · ${unplaced.length}</h3>
        <div class="fpb-helper">Click a vendor to drop their booth in the middle of the view, then drag it into position.</div>
        <ul class="fpb-list fpb-unplaced">${unplaced.map(v => `
          <li class="item" role="button"><button type="button" class="fpb-vendor-add" data-vendor="${esc(v.event_vendor_id || v.vendor_id)}">
            <span class="plus">+</span><span class="vname">${esc(v.vendor_name || v.name || 'Vendor')}</span>
          </button></li>`).join('')}</ul>`;
    }

    // One-click placement: booth in the centre of the current view,
    // pre-linked to the vendor and auto-numbered. Drag to position.
    placeVendorBooth(v) {
      this.pushUndo();
      const vp = this.$.viewport.getBoundingClientRect();
      const pt = this.worldPoint({ clientX: vp.left + vp.width / 2, clientY: vp.top + vp.height / 2 });
      const w = this.lastBoothFt.w * this.ppf, h = this.lastBoothFt.h * this.ppf;
      const cx = this.snap ? this.snapWorld(pt.x - w / 2) + w / 2 : pt.x;
      const cy = this.snap ? this.snapWorld(pt.y - h / 2) + h / 2 : pt.y;
      const cat = CAT_BY_ID[this.boothCategory] || CAT_BY_ID[DEFAULT_CAT];
      const el = {
        id: uid(), type: 'booth', rot: 0,
        x: clamp(cx / this.world.w, 0, 1), y: clamp(cy / this.world.h, 0, 1),
        w: w / this.world.w, h: h / this.world.h,
        number: this.nextBoothNumber(),
        label: v.vendor_name || v.name || '',
        icon: cat.id, color: cat.color,
        vendor_id: v.event_vendor_id || v.vendor_id || null,
        size: `${Math.round(this.lastBoothFt.w)}x${Math.round(this.lastBoothFt.h)}`, description: '',
      };
      this.elements.push(el);
      this.setDirty(true);
      this.select(el.id);
    }

    listHtml() {
      if (!this.elements.length) {
        return `<div class="fpb-helper">Use the tools above the canvas: <strong>Booth</strong> stamps numbered vendor stalls, <strong>Zone</strong> draws stages &amp; bars, <strong>Pin</strong> marks entrances and facilities.</div><ul class="fpb-list"><li class="empty-note">Nothing placed yet.</li></ul>`;
      }
      const groups = [
        ['Booths', this.elements.filter(e => e.type === 'booth').sort((a, b) => num(a.number) - num(b.number))],
        ['Objects', this.elements.filter(e => e.type === 'shape')],
        ['Zones', this.elements.filter(e => e.type === 'zone')],
        ['Pins', this.elements.filter(e => e.type === 'pin')],
        ['Text', this.elements.filter(e => e.type === 'text')],
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
          } else if (el.type === 'shape') {
            const o = OBJ_BY_KIND[el.kind];
            name = esc(el.label || (o ? o.label : 'Object'));
            meta = [el.size ? el.size.replace('x', '×') + ' ft' : '', el.groupId ? 'in a run' : ''].filter(Boolean).join(' · ');
            if (o && o.shape === 'round') dotCls += ' round';
          } else if (el.type === 'zone') { name = esc(el.label || 'Zone'); }
          else if (el.type === 'text') { name = esc(el.label || '(empty text)'); dotCls += ' round'; color = '#ddd'; }
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
      // Live "W × D ft" footprint control — drives the box geometry directly.
      const sizeControl = (labelTxt, presets) => {
        const sv = el.size || '';
        const parts = sv.includes('x') ? sv.split('x') : ['', ''];
        const chips = presets.map(s => `<button type="button" class="fpb-size-chip${sv === s ? ' active' : ''}" data-size="${s}">${s.replace('x', '×')}</button>`).join('');
        return `<div class="fpb-field"><label>${labelTxt} (ft)</label>
          <div class="fpb-field-row fpb-size-row"><input data-f="sizeW" type="number" min="1" max="999" placeholder="W" value="${esc(parts[0])}"/><span class="fpb-x">×</span><input data-f="sizeD" type="number" min="1" max="999" placeholder="D" value="${esc(parts[1])}"/></div>
          <div class="fpb-size-chips">${chips}</div></div>`;
      };
      const sizeFields = sizeControl('Booth size', PRESET_FT);
      // Rotation control — numeric degrees + quick steps.
      const rotControl = () => `<div class="fpb-field"><label>Rotation</label>
        <div class="fpb-field-row fpb-rot-row">
          <button type="button" class="fpb-btn icon-only" data-f="rotCCW" title="Rotate -15°"><svg style="transform:scaleX(-1)"><use href="#fpb-rotate"/></svg></button>
          <input data-f="rot" type="number" min="0" max="359" value="${Math.round(el.rot || 0)}"/><span class="fpb-x">°</span>
          <button type="button" class="fpb-btn icon-only" data-f="rotCW" title="Rotate +15°"><svg><use href="#fpb-rotate"/></svg></button>
          <button type="button" class="fpb-btn" data-f="rot90" title="Turn 90°">90°</button>
        </div></div>`;
      const colorRow = (colors, pickDefault) => `<div class="fpb-field"><label>Colour</label><div class="fpb-color-row">
          ${colors.map(c => `<button type="button" class="fpb-color-dot${(el.color || '').toLowerCase() === c.toLowerCase() ? ' active' : ''}" data-zc="${c}" style="background:${c}"></button>`).join('')}
          <input type="color" data-f="colorPick" value="${esc(/^#[0-9a-f]{6}$/i.test(el.color || '') ? el.color : pickDefault)}" title="Custom colour"/>
        </div></div>`;
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
          <div class="fpb-field-row">
            ${f('Name shows', `<select data-f="labelPos"><option value="in"${(el.labelPos || 'in') === 'in' ? ' selected' : ''}>Inside booth</option><option value="below"${el.labelPos === 'below' ? ' selected' : ''}>Below booth</option></select>`)}
            ${f('Name size', `<select data-f="labelSize">${[['s', 'Small'], ['m', 'Medium'], ['l', 'Large'], ['xl', 'X-Large']].map(([v, l]) => `<option value="${v}"${(el.labelSize || 'm') === v ? ' selected' : ''}>${l}</option>`).join('')}</select>`)}
          </div>
          <div class="fpb-field-row">
            ${f('Label scale (%)', `<input data-f="labelScale" type="number" min="50" max="300" step="5" value="${Math.round(num(el.labelScale, 1) * 100)}"/>`)}
            ${f('Label rotation (°)', `<input data-f="labelRot" type="number" min="-180" max="180" step="1" value="${num(el.labelRot)}"/>`)}
          </div>
          ${sizeFields}
          ${rotControl()}
          ${f('Notes (optional)', `<textarea data-f="desc" rows="2" maxlength="240">${esc(el.description || '')}</textarea>`)}
          ${actions()}`;
      }
      if (el.type === 'zone') {
        return `<h3>Zone</h3>
          ${f('Label', `<input data-f="label" type="text" maxlength="60" placeholder="e.g. Stage area / VIP / Emporium" value="${esc(el.label || '')}"/>`)}
          <div class="fpb-field-row">
            ${f('Label scale (%)', `<input data-f="labelScale" type="number" min="50" max="300" step="5" value="${Math.round(num(el.labelScale, 1) * 100)}"/>`)}
            ${f('Label rotation (°)', `<input data-f="labelRot" type="number" min="-180" max="180" step="1" value="${num(el.labelRot)}"/>`)}
          </div>
          ${colorRow(ZONE_COLORS, '#b03a2e')}
          ${rotControl()}
          ${f('Notes (optional)', `<textarea data-f="desc" rows="2" maxlength="240">${esc(el.description || '')}</textarea>`)}
          ${actions()}`;
      }
      if (el.type === 'shape') {
        const o = OBJ_BY_KIND[el.kind] || OBJ_BY_KIND[DEFAULT_OBJ];
        const presets = o.connect
          ? [`${o.ftW}x${o.ftH}`, `12x${o.ftH}`, `16x${o.ftH}`, `20x${o.ftH}`]
          : [`${o.ftW}x${o.ftH}`, '6x6', '8x8', '10x10'];
        const palette = ['#b08850', '#0891b2', '#262626', '#6d28d9', '#d4a017', '#1a9e57', '#475569', '#64748b'];
        const groupCount = el.groupId ? this.elements.filter(s => s.type === 'shape' && s.groupId === el.groupId).length : 0;
        const kindOptions = OBJECTS.map(k => `<option value="${k.kind}"${k.kind === el.kind ? ' selected' : ''}>${esc(k.label)}</option>`).join('');
        return `<h3>${esc(o.label)}</h3>
          ${f('Type', `<select data-f="kind">${kindOptions}</select>`)}
          ${f('Label (optional)', `<input data-f="label" type="text" maxlength="60" placeholder="${o.connect ? 'e.g. Main Bar' : 'e.g. Stage'}" value="${esc(el.label || '')}"/>`)}
          ${sizeControl(o.connect ? 'Length × depth' : 'Size', presets)}
          ${rotControl()}
          ${colorRow(palette, o.color)}
          ${o.connect ? (groupCount > 1
            ? `<div class="fpb-helper">Joined into a run of ${groupCount} — they move together. Naming any one names them all.</div>`
            : `<div class="fpb-helper">Place another ${esc(o.label.toLowerCase())} flush against an end to build an L- or U-shape.</div>`) : ''}
          ${actions(groupCount > 1 ? `<button type="button" class="fpb-btn" data-f="ungroup" title="Detach from the run">Ungroup</button>` : '')}`;
      }
      if (el.type === 'text') {
        const cur = TEXT_SIZES.reduce((best, s) => Math.abs(s.v - (el.fontSize || 0.016)) < Math.abs(best.v - (el.fontSize || 0.016)) ? s : best, TEXT_SIZES[1]);
        return `<h3>Text label</h3>
          <div class="fpb-helper">Drag a corner handle to resize. Use the round handle above the label—or the controls below—to rotate it.</div>
          ${f('Text', `<input data-f="label" type="text" maxlength="120" placeholder="e.g. SECURITY" value="${esc(el.label || '')}"/>`)}
          <div class="fpb-field-row">
            ${f('Size', `<select data-f="tsize">${TEXT_SIZES.map(s => `<option value="${s.v}"${s.id === cur.id ? ' selected' : ''}>${s.label}</option>`).join('')}</select>`)}
            ${f('Colour', `<input data-f="colorPick" type="color" value="${esc(/^#[0-9a-f]{6}$/i.test(el.color || '') ? el.color : '#111111')}"/>`)}
          </div>
          ${rotControl()}
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
        if (q('labelPos')) el.labelPos = q('labelPos').value;
        if (q('labelSize')) el.labelSize = q('labelSize').value;
        if (q('labelScale')) el.labelScale = clamp(num(q('labelScale').value, 100) / 100, 0.5, 3);
        if (q('labelRot')) el.labelRot = clamp(num(q('labelRot').value), -180, 180);
        if (q('booth')) el.booth = q('booth').value.trim();
        if (q('desc')) el.description = q('desc').value.trim();
        if (q('tsize')) el.fontSize = Number(q('tsize').value) || 0.016;
        if (q('rot')) { const r = parseInt(q('rot').value, 10); if (Number.isFinite(r)) el.rot = ((r % 360) + 360) % 360; }
        if (q('colorPick') && el.type !== 'zone') el.color = q('colorPick').value;
        if (q('sizeW') || q('sizeD')) {
          const w = parseFloat(q('sizeW').value), d = parseFloat(q('sizeD').value);
          el.size = (w > 0 && d > 0) ? `${w}x${d}` : '';
          this.applySizeFt(el);   // the entered size resizes the box on the map
          side.querySelectorAll('.fpb-size-chip').forEach(c => c.classList.toggle('active', c.dataset.size === el.size));
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
      // Size preset chips fill W/D and apply.
      side.querySelectorAll('.fpb-size-chip').forEach(b => b.addEventListener('click', () => {
        const [w, d] = b.dataset.size.split('x');
        if (q('sizeW')) q('sizeW').value = w;
        if (q('sizeD')) q('sizeD').value = d;
        apply();
      }));
      // Rotation quick-steps.
      const bumpRot = (delta) => {
        this.pushUndo(true);
        el.rot = ((Math.round((el.rot || 0) + delta) % 360) + 360) % 360;
        if (q('rot')) q('rot').value = el.rot;
        this.setDirty(true); this.renderElements();
      };
      if (q('rotCW')) q('rotCW').addEventListener('click', () => bumpRot(ROT_SNAP));
      if (q('rotCCW')) q('rotCCW').addEventListener('click', () => bumpRot(-ROT_SNAP));
      if (q('rot90')) q('rot90').addEventListener('click', () => bumpRot(90));
      // Changing an object's type swaps its kind, profile shape and (if untouched) colour.
      if (q('kind')) q('kind').addEventListener('change', () => {
        this.pushUndo();
        const prev = OBJ_BY_KIND[el.kind], next = OBJ_BY_KIND[q('kind').value];
        if (next) {
          if ((el.color || '').toLowerCase() === (prev && prev.color || '').toLowerCase()) el.color = next.color;
          el.kind = next.kind; el.shape = next.shape;
          if (!next.connect) el.groupId = null;
        }
        this.setDirty(true); this.renderAll();
      });
      if (q('ungroup')) q('ungroup').addEventListener('click', () => {
        this.pushUndo();
        el.groupId = null;
        this.setDirty(true); this.renderAll();
      });
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
      if (el) {
        el.textContent = yes ? 'Unsaved changes' : 'No unsaved changes';
        el.classList.toggle('clean', !yes);
      }
      if (this.opts.onDirtyChange) this.opts.onDirtyChange(this.dirty);
      if (yes) this.persistDraft();
    }
    persistDraft() {
      if (!this.draftKey) return;
      try {
        localStorage.setItem(this.draftKey, JSON.stringify({
          updatedAt: Date.now(), backgroundUrl: this.bgUrl, elements: this.serialize(),
        }));
      } catch (e) { /* private mode / quota: server Save still works */ }
    }
    clearDraft() {
      if (!this.draftKey) return;
      try { localStorage.removeItem(this.draftKey); } catch (e) {}
      this.recoveredDraft = false;
    }
    status(msg, kind, node) {
      const el = node || this.$.status;
      if (!el) return;
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
    scaleMeta() {
      return {
        id: 'meta', type: 'meta',
        ppf: this.ppf, worldW: this.world.w, worldH: this.world.h,
        siteFtW: this.siteFt.w, siteFtH: this.siteFt.h, calibrated: !!this.calibrated,
        bg: this.bg || DEFAULT_BG,
      };
    }
    serialize() {
      const els = this.elements.map(el => {
        const base = { id: el.id, type: el.type, x: el.x, y: el.y };
        if (el.type === 'pin') return Object.assign(base, {
          label: el.label || '', icon: el.icon || DEFAULT_CAT, color: el.color || CAT_BY_ID[DEFAULT_CAT].color,
          vendor_id: el.vendor_id || null, booth: el.booth || '', size: el.size || '', description: el.description || '',
        });
        if (el.type === 'booth') return Object.assign(base, {
          w: el.w, h: el.h, rot: el.rot || 0, number: el.number != null ? el.number : '',
          label: el.label || '', icon: el.icon || DEFAULT_CAT, color: el.color || CAT_BY_ID[DEFAULT_CAT].color,
          vendor_id: el.vendor_id || null, size: el.size || '', description: el.description || '',
          labelPos: el.labelPos || 'in', labelSize: el.labelSize || 'm', labelScale: num(el.labelScale, 1), labelRot: num(el.labelRot),
        });
        if (el.type === 'shape') return Object.assign(base, {
          w: el.w, h: el.h, rot: el.rot || 0, kind: el.kind, shape: el.shape,
          label: el.label || '', color: el.color, size: el.size || '',
          groupId: el.groupId || null,
        });
        if (el.type === 'zone') return Object.assign(base, { w: el.w, h: el.h, rot: el.rot || 0, label: el.label || '', labelScale: num(el.labelScale, 1), labelRot: num(el.labelRot), color: el.color || ZONE_COLORS[0], description: el.description || '', ...(el.points ? { points: el.points } : {}) });
        return Object.assign(base, { label: el.label || '', color: el.color || '#111111', fontSize: el.fontSize || 0.016, rot: el.rot || 0 });
      });
      // Persist scale as the first entry so the layout round-trips to-scale.
      return [this.scaleMeta()].concat(els);
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
        this.clearDraft();
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
      ctx.fillStyle = this.bg || '#ffffff';
      ctx.fillRect(0, 0, W, H);

      if (this.bgUrl) {
        try {
          const img = new Image();
          img.crossOrigin = 'anonymous';
          await new Promise((res, rej) => { img.onload = res; img.onerror = rej; img.src = this.bgUrl; });
          ctx.drawImage(img, 0, 0, W, H);
        } catch (e) { /* draw without background */ }
      }

      const order = { zone: 0, shape: 1, booth: 2, text: 3, pin: 4 };
      const els = [...this.elements].sort((a, b) => (order[a.type] || 0) - (order[b.type] || 0));
      els.forEach(el => {
        const cx = el.x * W, cy = el.y * H;
        if (el.type === 'zone' || el.type === 'booth' || el.type === 'shape') {
          const w = el.w * W, h = el.h * H;
          const round = el.type === 'shape' && el.shape === 'round';
          ctx.save();
          ctx.translate(cx, cy);
          if (el.rot) ctx.rotate(el.rot * Math.PI / 180);   // draw in the element's own frame
          ctx.fillStyle = el.color || '#1a7f4e';
          if (el.type === 'zone') ctx.globalAlpha = 0.22;
          ctx.strokeStyle = el.type === 'zone' ? (el.color || '#b03a2e') : 'rgba(0,0,0,0.3)';
          ctx.lineWidth = el.type === 'zone' ? 2 : 1.5;
          if (el.type === 'zone' && el.points) {
            ctx.beginPath(); el.points.forEach((p,i) => { const x=(p[0]-.5)*w, y=(p[1]-.5)*h; i ? ctx.lineTo(x,y) : ctx.moveTo(x,y); });
            ctx.closePath(); ctx.fill(); ctx.globalAlpha=1; ctx.stroke();
          } else if (round) {
            ctx.beginPath(); ctx.ellipse(0, 0, w / 2, h / 2, 0, 0, Math.PI * 2); ctx.fill();
            ctx.globalAlpha = 1; ctx.stroke();
          } else {
            ctx.fillRect(-w / 2, -h / 2, w, h);
            ctx.globalAlpha = 1; ctx.strokeRect(-w / 2, -h / 2, w, h);
          }
          ctx.fillStyle = '#fff';
          ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
          if (el.type === 'booth') {
            const bname = el.label || this.vendorName(el.vendor_id) || '';
            const boothNumber = el.number != null && el.number !== '' ? String(el.number) : '';
            const mult = LBL_SIZES[el.labelSize] || 1, inBox = bname && (el.labelPos || 'in') === 'in';
            ctx.fillStyle = this.textOn(el.color);
            if (boothNumber) {
              ctx.font = `800 ${clamp(Math.min(w, h) * (inBox ? 0.3 : 0.46), 10, inBox ? 22 : 30)}px Poppins, sans-serif`;
              ctx.fillText(boothNumber, 0, inBox ? -h * 0.13 : 0);
            }
            if (inBox) {
              const ly = boothNumber ? h * 0.16 : 0;
              ctx.save(); ctx.translate(0, ly); ctx.rotate(num(el.labelRot) * Math.PI / 180); ctx.scale(num(el.labelScale, 1), num(el.labelScale, 1));
              ctx.font = `600 ${clamp(w * 0.14 * mult, 8, 44)}px Poppins, sans-serif`;
              ctx.fillText(bname, 0, 0, w - 6); ctx.restore();
            } else if (bname) {   // label below the booth
              const fs = clamp(w * 0.2 * mult, 11, 30);
              ctx.font = `600 ${fs}px Poppins, sans-serif`;
              const tw = ctx.measureText(bname).width + 10;
              ctx.save(); ctx.translate(0, h / 2 + 3 + (fs + 6) / 2); ctx.rotate(num(el.labelRot) * Math.PI / 180); ctx.scale(num(el.labelScale, 1), num(el.labelScale, 1));
              ctx.fillStyle = 'rgba(255,255,255,0.95)'; ctx.fillRect(-tw / 2, -(fs + 6) / 2, tw, fs + 6);
              ctx.fillStyle = '#111'; ctx.fillText(bname, 0, 0); ctx.restore();
            }
          }
          if (el.type === 'zone' && el.label) {
            const fs = clamp(w * 0.06, 12, 22), txt = el.label.toUpperCase();
            ctx.font = `700 ${fs}px Poppins, sans-serif`;
            const tw = Math.min(ctx.measureText(txt).width, w - 16), cy2 = -h / 2 + fs * 0.9 + 6;
            ctx.save(); ctx.translate(0, cy2); ctx.rotate(num(el.labelRot) * Math.PI / 180); ctx.scale(num(el.labelScale, 1), num(el.labelScale, 1));
            ctx.fillStyle = el.color || '#b03a2e';
            ctx.fillRect(-tw / 2 - 9, -fs / 2 - 3, tw + 18, fs + 6);   // title chip
            ctx.fillStyle = '#fff'; ctx.fillText(txt, 0, 0, w - 18); ctx.restore();
          }
          if (el.type === 'shape' && el.label) {
            ctx.font = `700 ${clamp(Math.min(w, h) * 0.34, 11, 22)}px Poppins, sans-serif`;
            ctx.fillText(el.label, 0, 0, w - 6);
          }
          ctx.restore();
        } else if (el.type === 'text') {
          ctx.save();
          ctx.translate(cx, cy); if (el.rot) ctx.rotate(el.rot * Math.PI / 180);
          ctx.fillStyle = el.color || '#111';
          ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
          ctx.font = `700 ${Math.max(11, (el.fontSize || 0.016) * W)}px Poppins, sans-serif`;
          ctx.fillText(el.label || '', 0, 0);
          ctx.restore();
        } else {
          ctx.save();
          ctx.beginPath(); ctx.arc(cx, cy, 13, 0, Math.PI * 2);
          ctx.fillStyle = el.color || '#0a7aff'; ctx.fill();
          ctx.lineWidth = 3; ctx.strokeStyle = '#fff'; ctx.stroke();
          if (el.label) {
            ctx.font = '600 12px Poppins, sans-serif';
            ctx.textAlign = 'center'; ctx.textBaseline = 'middle';
            const tw = ctx.measureText(el.label).width + 10;
            ctx.fillStyle = 'rgba(255,255,255,0.95)';
            ctx.fillRect(cx - tw / 2, cy + 17, tw, 18);
            ctx.fillStyle = '#111';
            ctx.fillText(el.label, cx, cy + 26);
          }
          ctx.restore();
        }
      });

      this.drawScaleBar(ctx, W, H);

      try {
        const a = document.createElement('a');
        a.download = 'floor-plan.png';
        a.href = cv.toDataURL('image/png');
        a.click();
      } catch (e) {
        this.status('Export blocked: the background image does not allow cross-origin export.', 'error');
      }
    }

    // A to-scale ruler in the corner so a printed/exported plan reads in feet.
    drawScaleBar(ctx, W, H) {
      const targetPx = W / 7;
      let ft = targetPx / this.ppf;
      const pow = Math.pow(10, Math.floor(Math.log10(ft)));
      ft = [1, 2, 5, 10].reduce((b, m) => Math.abs(m * pow - ft) < Math.abs(b - ft) ? m * pow : b, pow);
      const barPx = ft * this.ppf;
      const pad = Math.max(16, W * 0.012), x = pad, y = H - pad, hgt = Math.max(7, W * 0.006);
      ctx.save();
      ctx.fillStyle = 'rgba(255,255,255,0.85)';
      ctx.fillRect(x - 6, y - hgt - 22, barPx + 12, hgt + 30);
      ctx.fillStyle = '#111'; ctx.strokeStyle = '#111'; ctx.lineWidth = 1.5;
      ctx.fillRect(x, y - hgt, barPx / 2, hgt);          // checker bar
      ctx.strokeRect(x, y - hgt, barPx, hgt);
      ctx.font = `700 ${Math.max(11, W * 0.011)}px Poppins, sans-serif`;
      ctx.textAlign = 'left'; ctx.textBaseline = 'bottom';
      ctx.fillText(`${this.fmtFt(ft)} ft`, x, y - hgt - 4);
      ctx.restore();
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
          this.closeContextMenu();
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
