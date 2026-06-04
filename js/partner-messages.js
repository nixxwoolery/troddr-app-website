/* ============================================================
 * Partner Messages: shared "Send a message" FAB + modal.
 * Drop this script onto any partner-* page; it self-contains
 * its styles, HTML, and Supabase client. No build step needed.
 * ============================================================ */
(function () {
  if (window.__partnerMessagesLoaded) return;
  window.__partnerMessagesLoaded = true;

  const SUPABASE_URL  = (window.__ENV__ && window.__ENV__.SUPABASE_URL)  || 'https://rprpwudhplodaqmmwqkf.supabase.co';
  const SUPABASE_ANON = (window.__ENV__ && window.__ENV__.SUPABASE_ANON) || 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJwcnB3dWRocGxvZGFxbW13cWtmIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NTAyODcyODksImV4cCI6MjA2NTg2MzI4OX0.lNL6YZQqZgbsQRJyRAXpaWMC4LxncvPPyXNP1qopTFk';

  // ---- 1. Styles ---------------------------------------------------
  const css = `
    .msg-fab {
      position: fixed; bottom: 20px; right: 20px;
      z-index: 100;
      background: var(--brand-primary, #0077CC);
      color: var(--brand-text, #fff);
      border: none;
      padding: 11px 18px;
      border-radius: 100px;
      font-family: 'Poppins', sans-serif;
      font-size: 13px; font-weight: 600;
      box-shadow: 0 4px 14px rgba(0,0,0,0.18);
      cursor: pointer;
      display: inline-flex; align-items: center; gap: 8px;
      transition: transform 0.15s, box-shadow 0.15s;
    }
    .msg-fab:hover {
      transform: translateY(-2px);
      box-shadow: 0 6px 20px rgba(0,0,0,0.22);
    }
    .msg-fab svg { width: 14px; height: 14px; flex-shrink: 0; }

    .msg-overlay {
      position: fixed; inset: 0; z-index: 300;
      background: rgba(0,0,0,0.45);
      display: none; align-items: center; justify-content: center;
      padding: 20px;
    }
    .msg-overlay.open { display: flex; }
    .msg-modal {
      background: #fff;
      border-radius: 16px;
      width: 100%; max-width: 480px;
      padding: 26px 28px 24px;
      box-shadow: 0 20px 60px rgba(0,0,0,0.25);
      font-family: 'Poppins', sans-serif;
      color: #111;
    }
    .msg-modal h3 {
      font-size: 18px; font-weight: 700;
      margin: 0 0 6px 0;
      letter-spacing: -0.3px;
      color: #111;
    }
    .msg-sub {
      font-size: 13px; color: #666;
      margin: 0 0 16px 0;
      line-height: 1.5;
    }
    .msg-field { margin-bottom: 12px; }
    .msg-field label {
      display: block;
      font-size: 11px; font-weight: 700;
      letter-spacing: 0.06em; text-transform: uppercase;
      color: #666;
      margin-bottom: 4px;
    }
    .msg-field input,
    .msg-field textarea {
      width: 100%;
      padding: 10px 12px;
      font-family: inherit;
      font-size: 13px;
      border: 1px solid #e8e8e8;
      border-radius: 8px;
      background: #fff;
      color: #111;
      box-sizing: border-box;
    }
    .msg-field input:focus,
    .msg-field textarea:focus {
      outline: none;
      border-color: var(--brand-primary, #0077CC);
    }
    .msg-field textarea {
      min-height: 120px;
      resize: vertical;
      line-height: 1.5;
    }
    .msg-actions {
      display: flex; gap: 8px; justify-content: flex-end;
      margin-top: 6px;
    }
    .msg-btn {
      padding: 10px 16px;
      border-radius: 8px;
      font-family: inherit;
      font-size: 13px; font-weight: 600;
      cursor: pointer;
      border: 1px solid #e8e8e8;
      background: #fff;
      color: #333;
      transition: background 0.15s;
    }
    .msg-btn:hover { background: #f8f9fa; }
    .msg-btn:disabled { opacity: 0.6; cursor: not-allowed; }
    .msg-btn.primary {
      background: var(--brand-primary, #0077CC);
      border-color: var(--brand-primary, #0077CC);
      color: var(--brand-text, #fff);
    }
    .msg-btn.primary:hover { filter: brightness(1.08); }
    .msg-error {
      font-size: 12px; color: #c0392b;
      margin-top: 8px;
      padding: 8px 10px;
      background: #fdecea;
      border-radius: 6px;
      display: none;
    }
    .msg-error.show { display: block; }
    .msg-success {
      text-align: center;
      padding: 20px 0 4px;
    }
    .msg-success-title {
      font-size: 18px; font-weight: 700;
      color: #1a7f4e;
      margin-bottom: 6px;
    }
    .msg-success-text {
      font-size: 13px; color: #666;
      margin-bottom: 16px;
      line-height: 1.5;
    }
  `;
  const style = document.createElement('style');
  style.textContent = css;
  document.head.appendChild(style);

  // ---- 2. HTML -----------------------------------------------------
  const html = `
    <button class="msg-fab" id="msg-fab" type="button" aria-label="Send a message">
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">
        <path d="M21 11.5a8.4 8.4 0 0 1-1 4 8.5 8.5 0 0 1-7.6 4.5 8.4 8.4 0 0 1-4-1L3 21l1.9-5.4a8.5 8.5 0 0 1-1-4 8.5 8.5 0 0 1 4.5-7.6 8.4 8.4 0 0 1 4-1A8.5 8.5 0 0 1 21 11.5z"/>
      </svg>
      Send a message
    </button>
    <div class="msg-overlay" id="msg-overlay" role="dialog" aria-modal="true" aria-labelledby="msg-title">
      <div class="msg-modal">
        <div id="msg-form-box">
          <h3 id="msg-title">Send us a message</h3>
          <p class="msg-sub">Questions, feedback, or something not working? We'll get back to you on the email associated with your partner profile.</p>
          <div class="msg-field">
            <label for="msg-subject">Subject (optional)</label>
            <input id="msg-subject" type="text" maxlength="120" placeholder="e.g. Loyalty stamps not registering" />
          </div>
          <div class="msg-field">
            <label for="msg-body">Message</label>
            <textarea id="msg-body" maxlength="5000" placeholder="Tell us what's going on..."></textarea>
          </div>
          <div class="msg-error" id="msg-error"></div>
          <div class="msg-actions">
            <button type="button" class="msg-btn" id="msg-cancel">Cancel</button>
            <button type="button" class="msg-btn primary" id="msg-send">Send</button>
          </div>
        </div>
        <div class="msg-success" id="msg-success" style="display:none">
          <div class="msg-success-title">Message sent</div>
          <div class="msg-success-text">Thanks for reaching out. We'll be in touch soon.</div>
          <button type="button" class="msg-btn" id="msg-close">Close</button>
        </div>
      </div>
    </div>
  `;
  const root = document.createElement('div');
  root.innerHTML = html;
  document.body.appendChild(root);

  // ---- 3. Behaviour ------------------------------------------------
  // Wait for Supabase library to be available (loaded by host page).
  function init() {
    if (!window.supabase) { setTimeout(init, 30); return; }
    const db = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON);

    const overlay     = document.getElementById('msg-overlay');
    const formBox     = document.getElementById('msg-form-box');
    const successBox  = document.getElementById('msg-success');
    const subjectIn   = document.getElementById('msg-subject');
    const bodyIn      = document.getElementById('msg-body');
    const errorBox    = document.getElementById('msg-error');
    const sendBtn     = document.getElementById('msg-send');

    function open() {
      overlay.classList.add('open');
      formBox.style.display = '';
      successBox.style.display = 'none';
      subjectIn.value = '';
      bodyIn.value = '';
      errorBox.classList.remove('show');
      setTimeout(() => bodyIn.focus(), 50);
    }
    function close() { overlay.classList.remove('open'); }

    document.getElementById('msg-fab').addEventListener('click', open);
    document.getElementById('msg-cancel').addEventListener('click', close);
    document.getElementById('msg-close').addEventListener('click', close);
    overlay.addEventListener('click', (e) => { if (e.target === overlay) close(); });
    document.addEventListener('keydown', (e) => {
      if (e.key === 'Escape' && overlay.classList.contains('open')) close();
    });

    sendBtn.addEventListener('click', async () => {
      const msg = bodyIn.value.trim();
      if (!msg) {
        errorBox.textContent = 'Please write a message before sending.';
        errorBox.classList.add('show');
        return;
      }
      const token = new URLSearchParams(location.search).get('token');
      if (!token) {
        errorBox.textContent = 'Missing partner token. Reload from your bookmarked link.';
        errorBox.classList.add('show');
        return;
      }

      errorBox.classList.remove('show');
      const original = sendBtn.textContent;
      sendBtn.disabled = true;
      sendBtn.textContent = 'Sending...';

      try {
        const { data, error } = await db.rpc('send_partner_message', {
          p_token:       token,
          p_subject:     subjectIn.value.trim() || null,
          p_message:     msg,
          p_source_page: location.pathname
        });
        if (error || !data || !data.ok) {
          errorBox.textContent = (data && data.error)
            || (error && error.message)
            || 'Could not send right now. Please try again.';
          errorBox.classList.add('show');
        } else {
          formBox.style.display = 'none';
          successBox.style.display = '';
        }
      } catch (err) {
        errorBox.textContent = 'Network error. Please try again.';
        errorBox.classList.add('show');
      } finally {
        sendBtn.disabled = false;
        sendBtn.textContent = original;
      }
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
