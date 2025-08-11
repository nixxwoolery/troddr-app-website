// 1) Setup
const SUPABASE_URL = 'https://YOUR_PROJECT.supabase.co';
const SUPABASE_ANON_KEY = 'YOUR_ANON_KEY';
const supabase = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// 2) Get slug from URL: itineraries.html?slug=your-trip-slug
const params = new URLSearchParams(window.location.search);
const slug = params.get('slug');

async function loadItinerary() {
  if (!slug) return;

  // 3) Fetch itinerary
  const { data: trip, error: tripErr } = await supabase
    .from('itineraries')
    .select('id, title, destination, start_date, end_date, place_count, cover_image, base_location, travel_mode')
    .eq('slug', slug)
    .eq('public', true)
    .single();

  if (tripErr || !trip) {
    document.querySelector('.trip-title').textContent = 'Itinerary not found';
    document.querySelector('.trip-sub').textContent = 'This link may be private or no longer available.';
    return;
  }

  // 4) Fetch stops (group by day)
  const { data: stops, error: stopsErr } = await supabase
    .from('itinerary_stops')
    .select('id, day_number, position, name, category, notes, start_time, image_url, external_url, lat, lng')
    .eq('itinerary_id', trip.id)
    .order('day_number', { ascending: true })
    .order('position', { ascending: true });

  // 5) Render header/meta
  const titleEl = document.getElementById('trip-title');
  const subEl = document.getElementById('trip-sub');
  const destEl = document.getElementById('meta-destination');
  const datesEl = document.getElementById('meta-dates');

  titleEl.textContent = trip.title || 'Your Trip';
  subEl.textContent = trip.destination ? `Eat • Stay • Play around ${trip.destination}` : 'Eat • Stay • Play';
  destEl.textContent = trip.destination || '—';
  datesEl.textContent = formatDateRange(trip.start_date, trip.end_date, stops);

  // 6) Build day tabs & sections
  const dayTrack = document.getElementById('day-track');
  const contentRoot = document.querySelector('main.page > section');
  dayTrack.innerHTML = '';
  contentRoot.innerHTML = '';

  const days = groupBy(stops || [], s => s.day_number);
  const dayNumbers = Object.keys(days).map(n => parseInt(n,10)).sort((a,b)=>a-b);

  if (dayNumbers.length === 0) {
    contentRoot.innerHTML = '<p style="color:var(--gray)">No stops yet.</p>';
    return;
  }

  // Tabs
  dayNumbers.forEach((d, i) => {
    const a = document.createElement('a');
    a.className = 'day-pill' + (i===0 ? ' active' : '');
    a.href = `#day-${d}`;
    a.textContent = `Day ${d}`;
    dayTrack.appendChild(a);
  });

  // Sections
  dayNumbers.forEach((d) => {
    const section = document.createElement('section');
    section.id = `day-${d}`;
    section.className = 'day-section';

    const header = document.createElement('div');
    header.className = 'day-header';
    header.innerHTML = `<h2 class="day-title">Day ${d}</h2><span class="day-date"></span>`;
    section.appendChild(header);

    const wrap = document.createElement('div');
    wrap.className = 'stops';

    (days[d] || []).forEach(stop => {
      wrap.appendChild(renderStopCard(stop));
    });

    section.appendChild(wrap);
    contentRoot.appendChild(section);
  });

  // Re-bind active tab on scroll (since we rebuilt DOM)
  rebindActiveTabs();
}

function renderStopCard(stop) {
  const card = document.createElement('article');
  card.className = 'stop-card';
  const cover = document.createElement('div');
  cover.className = 'stop-cover';
  cover.style.backgroundImage = `url('${stop.image_url || 'https://images.unsplash.com/photo-1507525428034-b723cf961d3e?q=80&w=1200'}')`;
  const body = document.createElement('div');
  body.className = 'stop-body';

  const top = document.createElement('div');
  top.className = 'stop-top';
  top.innerHTML = `<h3 class="stop-name">${escapeHtml(stop.name)}</h3><span class="badge ${stop.category?.toLowerCase() || 'play'}">${stop.category || 'PLAY'}</span>`;

  const meta = document.createElement('div');
  meta.className = 'stop-meta';
  const timeLabel = stop.start_time ? new Date(`1970-01-01T${stop.start_time}Z`).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' }) + ' • ' : '';
  meta.innerHTML = `<span>${timeLabel}${escapeHtml(stop.notes || '')}</span>`;

  const actions = document.createElement('div');
  actions.className = 'stop-actions';

  if (stop.lat && stop.lng) {
    const maps = document.createElement('a');
    maps.className = 'btn-mini';
    maps.href = `https://www.google.com/maps/search/?api=1&query=${stop.lat},${stop.lng}`;
    maps.target = '_blank';
    maps.textContent = 'Get Directions';
    actions.appendChild(maps);
  }

  if (stop.external_url) {
    const ext = document.createElement('a');
    ext.className = 'btn-mini';
    ext.href = stop.external_url;
    ext.target = '_blank';
    ext.textContent = 'More Info';
    actions.appendChild(ext);
  }

  body.appendChild(top);
  body.appendChild(meta);
  body.appendChild(actions);

  card.appendChild(cover);
  card.appendChild(body);
  return card;
}

function groupBy(arr, fn) {
  return arr.reduce((acc, item) => {
    const k = fn(item);
    (acc[k] = acc[k] || []).push(item);
    return acc;
  }, {});
}

function formatDateRange(start, end, stops) {
  if (!start && !end) return `${(stops||[]).length} stops`;
  try {
    const s = start ? new Date(start) : null;
    const e = end ? new Date(end) : null;
    if (s && e) {
      const days = Math.max(1, Math.round((e - s) / 86400000) + 1);
      const sFmt = s.toLocaleDateString(undefined, { month:'short', day:'numeric' });
      const eFmt = e.toLocaleDateString(undefined, { month:'short', day:'numeric', year:'numeric' });
      return `${sFmt}–${eFmt} • ${days} day${days>1?'s':''}`;
    }
    return (s || e).toLocaleDateString();
  } catch { return ''; }
}

function escapeHtml(str) {
  if (str == null) return '';
  return String(str).replace(/[&<>\'\"]/g, function (s) {
    return ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', "'": '&#39;', '"': '&quot;' })[s];
  });
}

function rebindActiveTabs() {
  const tabs = Array.from(document.querySelectorAll('.day-pill'));
  const sections = tabs.map(t => document.querySelector(t.getAttribute('href'))).filter(Boolean);
  const onScroll = () => {
    const y = window.scrollY + 140;
    let activeIndex = 0;
    sections.forEach((sec,i)=>{ if(sec.offsetTop <= y) activeIndex = i; });
    tabs.forEach((t,i)=> t.classList.toggle('active', i===activeIndex));
  };
  document.addEventListener('scroll', onScroll, {passive:true});
  onScroll();
}

loadItinerary();