/* ============================================================
 * Partner Errors: translates Supabase / network errors into
 * partner-friendly messages. Include this BEFORE any partner
 * script that does RPC or storage calls.
 *
 * Usage:
 *   const msg = friendlyError(err, 'Optional fallback');
 *   showError(msg);
 *
 * Always logs the raw error to the console so you can debug.
 * ============================================================ */
(function () {
  if (window.friendlyError) return;

  // Order matters: more specific patterns first.
  const RULES = [
    // ── Token / auth ──────────────────────────────────────
    {
      test: (s) => /invalid or revoked token/.test(s) || /not authorized/.test(s) || /invalid token/.test(s),
      msg:  "Your dashboard link has expired or was revoked. Open the latest link we emailed you, or send us a message and we'll resend it.",
    },
    {
      test: (s) => /missing.*token/.test(s) || /no token/.test(s),
      msg:  "We couldn't find your account from this link. Open the dashboard from your bookmarked URL.",
    },

    // ── Validation we surface from RPCs ───────────────────
    {
      test: (s) => /title is required/.test(s),
      msg:  "Please add a title before submitting.",
    },
    {
      test: (s) => /message is required/.test(s),
      msg:  "Please write a message before sending.",
    },
    {
      test: (s) => /start and end dates? (are )?required/.test(s) || /pick a start date/.test(s) || /pick an end date/.test(s),
      msg:  "Please pick both a start and an end date.",
    },
    {
      test: (s) => /end date must be on or after start date/.test(s),
      msg:  "The end date needs to be on or after the start date.",
    },
    {
      test: (s) => /pick a valid special type/.test(s) || /pick a special type/.test(s),
      msg:  "Please choose a type for this special.",
    },

    // ── Schema constraint failures ────────────────────────
    {
      test: (s) => /violates check constraint/.test(s) || /check constraint/.test(s),
      msg:  "One of the values isn't supported. Try a different value, or send us a message and we'll sort it out.",
    },
    {
      test: (s) => /violates foreign key/.test(s),
      msg:  "Something this is linked to has changed. Refresh the page and try again.",
    },
    {
      test: (s) => /duplicate key/.test(s) || /already exists/.test(s),
      msg:  "It looks like this already exists. Refresh the page to see the current state.",
    },
    {
      test: (s) => /violates not.null/.test(s) || /null value in column/.test(s),
      msg:  "A required field is missing. Please double-check and try again.",
    },
    {
      test: (s) => /column .* does not exist/.test(s) || /relation .* does not exist/.test(s),
      msg:  "Part of our system needs attention. Our team has been alerted. Please try again shortly, or send us a message.",
    },
    {
      test: (s) => /function .* does not exist/.test(s),
      msg:  "We're updating this feature. Please try again in a minute, or send us a message.",
    },
    {
      test: (s) => /invalid input syntax/.test(s) || /syntax error/.test(s) || /malformed/.test(s),
      msg:  "One of the inputs couldn't be processed. Refresh and try again, or send us a message.",
    },

    // ── Permissions / RLS ─────────────────────────────────
    {
      test: (s) => /row.level security/.test(s) || /permission denied/.test(s) || /policy/.test(s),
      msg:  "You don't have permission for that action. Send us a message if you think that's wrong.",
    },

    // ── Storage / uploads ─────────────────────────────────
    {
      test: (s) => /payload too large/.test(s) || /\b413\b/.test(s) || /file too large/.test(s) || /image too large/.test(s),
      msg:  "That file is too large. Please use an image under 10MB.",
    },
    {
      test: (s) => /image file/.test(s) && /please choose|invalid/.test(s),
      msg:  "Please choose an image file (JPG, PNG, or WEBP).",
    },
    {
      test: (s) => /bucket not found/.test(s) || /no such bucket/.test(s),
      msg:  "Image upload isn't available right now. Paste an image URL instead, or send us a message.",
    },

    // ── Network / connectivity ────────────────────────────
    {
      test: (s) => /network/.test(s) || /failed to fetch/.test(s) || /\btimeout/.test(s) || /timed out/.test(s),
      msg:  "Couldn't reach our servers. Check your connection and try again.",
    },
    {
      test: (s) => /not found/.test(s) || /\b404\b/.test(s),
      msg:  "We couldn't find that. It may have been removed, or hasn't been published yet.",
    },
    {
      test: (s) => /rate.limit/.test(s) || /\b429\b/.test(s) || /too many requests/.test(s),
      msg:  "You're sending requests faster than we can handle. Take a breath and try again in a moment.",
    },
    {
      test: (s) => /\b5\d\d\b/.test(s) || /internal server/.test(s),
      msg:  "Something went wrong on our end. Please try again, or send us a message.",
    },
  ];

  function rawText(err) {
    if (err == null) return '';
    if (typeof err === 'string') return err;
    // Supabase error shapes
    if (err.error && typeof err.error === 'string') return err.error;
    if (err.message) return err.message;
    if (err.error_description) return err.error_description;
    if (err.details) return err.details;
    if (err.hint) return err.hint;
    if (err.code) return err.code;
    try { return JSON.stringify(err); } catch (e) { return String(err); }
  }

  window.friendlyError = function (err, fallback) {
    const raw = rawText(err);
    if (raw) {
      // Always log so devs can debug. Partners only see the friendly text.
      console.error('[friendlyError] raw:', raw, '| original:', err);
    }
    const lower = raw.toLowerCase();
    for (const rule of RULES) {
      try { if (rule.test(lower)) return rule.msg; } catch (e) {}
    }
    return fallback || "Something went wrong on our end. Please try again, or send us a message via the button at the bottom right.";
  };

  // Optional: a tiny helper that returns both the friendly message
  // and the raw text (in case the caller wants to log to the UI for
  // an internal/admin page).
  window.friendlyErrorWithRaw = function (err, fallback) {
    return { friendly: window.friendlyError(err, fallback), raw: rawText(err) };
  };
})();
