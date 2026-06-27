/* ============================================================
 * TRODDR Partner/Auth Shell
 * ------------------------------------------------------------
 * Keeps the existing token-gated RPC model working while making
 * partner pages behave like a unified authenticated portal.
 * ============================================================ */
(function () {
  if (window.PartnerAuth) return;

  const PARTNER_TOKEN_KEY = 'troddr_partner_access_token';
  const ADMIN_TOKEN_KEY = 'troddr_admin_token';
  const loggedAccessKeys = new Set();

  function storage() {
    try { return window.localStorage; } catch (e) { return null; }
  }

  function sessionStorageSafe() {
    try { return window.sessionStorage; } catch (e) { return null; }
  }

  function params() {
    return new URLSearchParams(window.location.search);
  }

  function cleanTokenFromUrl(names) {
    const url = new URL(window.location.href);
    let changed = false;
    names.forEach((name) => {
      if (url.searchParams.has(name)) {
        url.searchParams.delete(name);
        changed = true;
      }
    });
    if (changed && window.history && window.history.replaceState) {
      window.history.replaceState({}, document.title, url.toString());
    }
  }

  function readStored(key) {
    let value = '';
    try { value = (storage() && storage().getItem(key)) || ''; } catch (e) {}
    if (value) return value;
    try { value = (sessionStorageSafe() && sessionStorageSafe().getItem(key)) || ''; } catch (e) {}
    return value || '';
  }

  function writeStored(key, value) {
    if (!value) return false;
    let saved = false;
    try {
      if (storage()) {
        storage().setItem(key, value);
        saved = true;
      }
    } catch (e) {}
    try {
      if (sessionStorageSafe()) {
        sessionStorageSafe().setItem(key, value);
        saved = true;
      }
    } catch (e) {}
    return saved;
  }

  function clearStored(key) {
    try { if (storage()) storage().removeItem(key); } catch (e) {}
    try { if (sessionStorageSafe()) sessionStorageSafe().removeItem(key); } catch (e) {}
  }

  function trackDashboardAccess(token) {
    if (!token || typeof fetch !== 'function') return;
    const key = token.slice(0, 12) + '|' + window.location.pathname;
    if (loggedAccessKeys.has(key)) return;
    loggedAccessKeys.add(key);
    const env = window.__ENV__ || {};
    const url = env.SUPABASE_URL;
    const anon = env.SUPABASE_ANON;
    if (!url || !anon) return;
    fetch(url.replace(/\/$/, '') + '/rest/v1/rpc/track_partner_dashboard_access', {
      method: 'POST',
      headers: {
        apikey: anon,
        Authorization: 'Bearer ' + anon,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        p_token: token,
        p_path: window.location.pathname,
        p_user_agent: navigator.userAgent || null,
      }),
      keepalive: true,
    }).catch(() => {});
  }

  function getToken(options) {
    const opts = options || {};
    const token = params().get('token') || params().get('access_token') || readStored(PARTNER_TOKEN_KEY);
    if (token) {
      writeStored(PARTNER_TOKEN_KEY, token);
      trackDashboardAccess(token);
      if (opts.cleanUrl === true) cleanTokenFromUrl(['token', 'access_token']);
      return token;
    }
    if (opts.require !== false) showAccessGate('partner');
    return '';
  }

  function setToken(token, options) {
    if (!token) return;
    writeStored(PARTNER_TOKEN_KEY, token);
    if (options && options.cleanUrl === true) cleanTokenFromUrl(['token', 'access_token']);
  }

  function getAdminToken(options) {
    const opts = options || {};
    const token = params().get('token') || params().get('admin_token') || readStored(ADMIN_TOKEN_KEY);
    if (token) {
      writeStored(ADMIN_TOKEN_KEY, token);
      if (opts.cleanUrl === true) cleanTokenFromUrl(['token', 'admin_token']);
      return token;
    }
    if (opts.require) showAccessGate('admin');
    return '';
  }

  function setAdminToken(token, options) {
    if (!token) return;
    writeStored(ADMIN_TOKEN_KEY, token);
    if (options && options.cleanUrl === true) cleanTokenFromUrl(['token', 'admin_token']);
  }

  function pageUrl(path, token) {
    const url = new URL(path, window.location.origin);
    if (token) url.searchParams.set('token', token);
    return url.toString();
  }

  function navigate(path, token) {
    const saved = token ? writeStored(PARTNER_TOKEN_KEY, token) : true;
    try { sessionStorage.setItem('__partner_intent', path); } catch (e) {}
    window.location.href = pageUrl(path, saved ? null : token);
  }

  function consumeIntent(path) {
    try {
      const intent = sessionStorage.getItem('__partner_intent');
      sessionStorage.removeItem('__partner_intent');
      return intent === path;
    } catch (e) { return false; }
  }


  function signOut(kind) {
    if (kind === 'admin') clearStored(ADMIN_TOKEN_KEY);
    else clearStored(PARTNER_TOKEN_KEY);
    window.location.href = window.location.pathname;
  }

  function showAccessGate(kind) {
    if (!document.body || document.getElementById('partner-auth-gate')) return;
    const isAdmin = kind === 'admin';
    const gate = document.createElement('div');
    gate.id = 'partner-auth-gate';
    gate.className = 'partner-auth-gate';
    gate.innerHTML = `
      <div class="partner-auth-card">
        <a class="partner-auth-logo" href="/">troddr</a>
        <div class="partner-auth-kicker">${isAdmin ? 'Admin Review' : 'Partner Dashboard'}</div>
        <h1>${isAdmin ? 'Enter your admin access token' : 'Sign in to your partner dashboard'}</h1>
        <p>${isAdmin
          ? 'Use the current admin token issued by TRODDR.'
          : 'Open your dashboard link from TRODDR, or paste your access token below to continue.'}</p>
        <label for="partner-auth-token">${isAdmin ? 'Admin token' : 'Access token'}</label>
        <input id="partner-auth-token" type="password" autocomplete="one-time-code" />
        <button type="button" id="partner-auth-submit">Continue</button>
        <div class="partner-auth-help">Need a fresh link? Send us a message from your latest TRODDR email.</div>
      </div>
    `;
    document.body.appendChild(gate);
    document.documentElement.classList.add('partner-auth-locked');

    const input = document.getElementById('partner-auth-token');
    const submit = document.getElementById('partner-auth-submit');
    function saveAndReload() {
      const value = input.value.trim();
      if (!value) return;
      if (isAdmin) setAdminToken(value);
      else setToken(value);
      window.location.reload();
    }
    submit.addEventListener('click', saveAndReload);
    input.addEventListener('keydown', (e) => { if (e.key === 'Enter') saveAndReload(); });
    setTimeout(() => input.focus(), 50);
  }

  function ensureStyles() {
    if (document.getElementById('partner-auth-styles')) return;
    const style = document.createElement('style');
    style.id = 'partner-auth-styles';
    style.textContent = `
      html.partner-auth-locked body > *:not(#partner-auth-gate) { display: none !important; }
      .partner-auth-gate {
        min-height: 100vh;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 24px;
        background: #f8f9fa;
        font-family: 'Poppins', Inter, system-ui, sans-serif;
        color: #111;
      }
      .partner-auth-card {
        width: 100%;
        max-width: 420px;
        background: #fff;
        border: 1px solid #e8e8e8;
        border-radius: 16px;
        box-shadow: 0 16px 45px rgba(0,0,0,0.08);
        padding: 30px;
      }
      .partner-auth-logo {
        color: #0077CC;
        font-size: 28px;
        font-weight: 800;
        letter-spacing: -1px;
        text-decoration: none;
      }
      .partner-auth-kicker {
        margin-top: 18px;
        color: #666;
        font-size: 11px;
        font-weight: 700;
        letter-spacing: 0.12em;
        text-transform: uppercase;
      }
      .partner-auth-card h1 {
        margin: 8px 0 8px;
        font-size: 24px;
        line-height: 1.15;
        letter-spacing: -0.5px;
      }
      .partner-auth-card p,
      .partner-auth-help {
        color: #666;
        font-size: 13px;
        line-height: 1.55;
      }
      .partner-auth-card label {
        display: block;
        margin-top: 18px;
        margin-bottom: 6px;
        color: #333;
        font-size: 12px;
        font-weight: 700;
      }
      .partner-auth-card input {
        width: 100%;
        border: 1px solid #dcdcdc;
        border-radius: 8px;
        padding: 11px 12px;
        font: inherit;
      }
      .partner-auth-card button {
        width: 100%;
        margin-top: 12px;
        border: 0;
        border-radius: 8px;
        padding: 12px 16px;
        background: #0077CC;
        color: #fff;
        font: inherit;
        font-size: 14px;
        font-weight: 700;
        cursor: pointer;
      }
      .partner-auth-help { margin-top: 14px; }
      .partner-session-control {
        display: inline-flex;
        align-items: center;
        gap: 8px;
        margin-left: 0;
      }
      .partner-session-btn {
        border: 1px solid var(--border, #e8e8e8);
        background: #fff;
        color: var(--grey-dark, #333);
        border-radius: 6px;
        padding: 6px 10px;
        font-family: inherit;
        font-size: 11px;
        font-weight: 700;
        letter-spacing: 0.06em;
        text-transform: uppercase;
        cursor: pointer;
      }
      .partner-session-btn:hover { background: var(--bg-soft, #f8f9fa); }
    `;
    document.head.appendChild(style);
  }

  function mountSessionControl(kind) {
    if (!document.body || document.getElementById('partner-session-control')) return;
    const nav = document.querySelector('.navbar');
    if (!nav) return;
    const control = document.createElement('div');
    control.id = 'partner-session-control';
    control.className = 'partner-session-control';
    control.innerHTML = `<button type="button" class="partner-session-btn">Sign out</button>`;
    control.querySelector('button').addEventListener('click', () => signOut(kind));
    nav.appendChild(control);
  }

  function setupPageLinks(capabilities) {
    const token = getToken({ require: false });
    const caps = capabilities || { listing: true, bookings: true, loyalty: true, feedback: true, specials: true, billing: true };
    document.querySelectorAll('.page-link').forEach((a) => {
      const target = a.dataset.href || a.getAttribute('href') || '#';
      const key = target.split('/').pop();
      if (key && caps[key] === false) {
        a.style.display = 'none';
        return;
      }
      a.href = pageUrl(target);
      a.addEventListener('click', () => {
        if (token) setToken(token);
        // Mark this as an intentional cross-page navigation so the destination
        // page doesn't bounce a group member back to /partner/group.
        try { sessionStorage.setItem('__partner_intent', target); } catch (e) {}
      });
    });
  }

  ensureStyles();

  window.PartnerAuth = {
    getToken,
    setToken,
    getAdminToken,
    setAdminToken,
    clearToken: () => clearStored(PARTNER_TOKEN_KEY),
    clearAdminToken: () => clearStored(ADMIN_TOKEN_KEY),
    pageUrl,
    navigate,
    consumeIntent,
    signOut,
    mountSessionControl,
    setupPageLinks,
    cleanPartnerTokenFromUrl: () => cleanTokenFromUrl(['token', 'access_token']),
    cleanAdminTokenFromUrl: () => cleanTokenFromUrl(['token', 'admin_token']),
  };
})();
