(() => {
  const guideCards = [...document.querySelectorAll('[data-guide-category]')];
  const filterButtons = [...document.querySelectorAll('[data-guide-filter]')];
  if (guideCards.length) {
    document.querySelector('.mood-options').hidden = false;
    filterButtons.forEach(button => button.addEventListener('click', () => {
      filterButtons.forEach(item => item.setAttribute('aria-pressed', String(item === button)));
      guideCards.forEach(card => { card.hidden = button.dataset.guideFilter !== 'all' && card.dataset.guideCategory !== button.dataset.guideFilter; });
      const count = guideCards.filter(card => !card.hidden).length;
      document.querySelector('#guide-count').textContent = `${count} ${count === 1 ? 'guide' : 'guides'} to explore`;
    }));
    document.querySelectorAll('.guide-cover-link img').forEach(img => {
      const fallback = () => { img.hidden = true; img.parentElement.classList.add('cover-unavailable'); };
      img.addEventListener('error', fallback);
      if (img.complete && !img.naturalWidth) fallback();
    });
  }
  document.querySelectorAll('[data-preview]').forEach(button => button.addEventListener('click', () => {
    const screen = document.querySelector('.phone-screen');
    screen.dispatchEvent(new Event('pointerdown'));
    screen.scrollBy({ top: screen.clientHeight * .65 * (button.dataset.preview === 'up' ? -1 : 1), behavior: matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth' });
  }));
  // Keep keyboard focus inside the existing mobile menu while it is open.
  document.addEventListener('keydown', event => {
    if (event.key !== 'Tab' || !document.body.classList.contains('menu-open')) return;
    const items = [...document.querySelectorAll('#primary-navigation a, #primary-navigation button')].filter(el => el.getClientRects().length);
    const first = items[0], last = items[items.length - 1];
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
  });
  matchMedia('(min-width: 769px)').addEventListener('change', event => {
    if (!event.matches) return;
    document.body.classList.remove('menu-open');
    document.querySelector('.nav-links').classList.remove('mobile-open');
    const button = document.querySelector('.mobile-menu-btn');
    button.classList.remove('active'); button.setAttribute('aria-expanded', 'false');
  });
})();
