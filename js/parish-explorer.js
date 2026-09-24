(() => {
  const select = document.querySelector('#parish-select');
  const grid = document.querySelector('#parish-places');
  const status = document.querySelector('#parish-status');
  const retry = document.querySelector('#parish-retry');
  let data = null;
  let generation = 0;
  // Jamaica stays on UTC-5 year-round. Advance the window at local midnight.
  function dailyPlaces(places, now = Date.now()) {
    if (!places.length) return [];
    const day = Math.floor((now - 5 * 60 * 60 * 1000) / 86400000);
    const start = ((day % places.length) + places.length) % places.length;
    return Array.from({ length: Math.min(3, places.length) }, (_, i) => places[(start + i) % places.length]);
  }
  function render() {
    const current = ++generation;
    const parish = select.value;
    grid.replaceChildren();
    const brands = new Set();
    const eligible = (data[parish] || []).filter(place => {
      if (!place.name || !place.slug || !/^https:\/\//.test(place.image)) return false;
      const brand = place.name.trim().toLowerCase();
      if (brands.has(brand)) return false;
      brands.add(brand); return true;
    });
    const rows = dailyPlaces(eligible);
    function updateCount() {
      const count = grid.children.length;
      status.textContent = count ? `${count} ${count === 1 ? 'place' : 'places'} to preview in ${parish}${eligible.length > 3 ? ' · Today’s picks' : ''}` : `Photo previews for ${parish} are coming soon. Explore TRODDR in the app in the meantime.`;
    }
    rows.forEach(place => {
      const card = document.createElement('article'); card.className = 'parish-card';
      const link = document.createElement('a');
      link.href = `https://www.troddr.com/listings/${encodeURIComponent(place.slug)}`;
      const img = document.createElement('img'); img.src = place.image; img.alt = ''; img.loading = 'lazy'; img.width = 480; img.height = 360;
      img.addEventListener('error', () => { if (current === generation) { card.remove(); updateCount(); } });
      const body = document.createElement('div'); body.className = 'parish-card-body';
      const title = document.createElement('h3'); title.textContent = place.name;
      const location = document.createElement('p'); location.textContent = [...new Set([place.town, place.parish || parish].filter(Boolean))].join(' · ');
      const action = document.createElement('span'); action.className = 'parish-view'; action.textContent = 'View place ↗';
      body.append(title, location);
      if (place.rewards === true) {
        const badge = document.createElement('span');
        badge.className = 'troddr-rewards-badge';
        badge.setAttribute('role', 'img');
        badge.setAttribute('aria-label', 'TRODDR Rewards partner');
        const icon = document.createElement('span');
        icon.className = 'rewards-ribbon';
        icon.setAttribute('aria-hidden', 'true');
        icon.textContent = String.fromCodePoint(60997);
        badge.append(icon, document.createTextNode('Rewards'));
        body.append(badge);
      }
      body.append(action); link.append(img, body); card.append(link); grid.append(card);
    });
    updateCount();
  }
  async function load() {
    retry.hidden = true; select.disabled = true; status.textContent = 'Loading places…';
    try {
      const response = await fetch('data/location-previews.json?v=1', {signal: AbortSignal.timeout(12000)});
      if (!response.ok) throw new Error('Unavailable');
      data = await response.json(); render();
    } catch { status.textContent = 'We couldn’t load the place previews. Try again or explore in the app.'; retry.hidden = false; }
    finally { select.disabled = false; }
  }
  select.value = 'Kingston';
  select.addEventListener('change', () => { if (data) render(); });
  retry.addEventListener('click', load);
  load();
})();
