// ============================================================
// admin-receipt-url
// ------------------------------------------------------------
// The payment-receipts bucket is PRIVATE: company users read
// their own company's receipts through storage RLS, but Troddr
// admins authenticate with admin_tokens (no Supabase Auth JWT),
// so they can't pass storage policies. This function validates
// the admin token and mints a short-lived signed URL with the
// service role.
//
// POST { admin_token: string, path: string }
// -> { ok: true, url: string } | { ok: false, error: string }
//
// Deploy: supabase functions deploy admin-receipt-url
// ============================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const SIGNED_URL_TTL_SECONDS = 60 * 10; // 10 minutes

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, "Content-Type": "application/json" },
    });

  try {
    const { admin_token, path } = await req.json();
    if (!admin_token || !path) {
      return json({ ok: false, error: "admin_token and path are required" }, 400);
    }
    // Receipts live at <company_account_id>/<invoice_id>/<file>.
    if (typeof path !== "string" || path.includes("..")) {
      return json({ ok: false, error: "Invalid path" }, 400);
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // Validate the admin token against admin_tokens (service role
    // bypasses RLS; _is_admin is not callable by client roles).
    const { data: tokenRow, error: tokenErr } = await supabase
      .from("admin_tokens")
      .select("id")
      .eq("token", admin_token)
      .eq("is_active", true)
      .maybeSingle();
    if (tokenErr) return json({ ok: false, error: tokenErr.message }, 500);
    if (!tokenRow) return json({ ok: false, error: "Not authorized" }, 401);

    const { data, error } = await supabase.storage
      .from("payment-receipts")
      .createSignedUrl(path, SIGNED_URL_TTL_SECONDS);
    if (error) return json({ ok: false, error: error.message }, 404);

    return json({ ok: true, url: data.signedUrl });
  } catch (e) {
    return json({ ok: false, error: String(e?.message || e) }, 500);
  }
});
