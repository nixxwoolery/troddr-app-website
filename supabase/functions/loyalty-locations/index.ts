// ============================================================
// loyalty-locations
// ------------------------------------------------------------
// Drives optional cross-location loyalty linking from the partner
// dashboard. The loyalty_programs / loyalty_program_locations tables
// have RLS and the browser anon key is read-only, so every WRITE here
// runs with the service role after validating the partner access token.
//
// Auth: the same places.partner_access_token used by the loyalty
// dashboard RPCs. Token -> primary place -> active loyalty program.
//
// POST { partner_token, action, ... }
//   action 'get'          -> current link state + brand-sibling candidates
//   action 'set_link'     -> { enabled } sets loyalty_programs.link_locations.
//                            When disabled, deletes every junction row except
//                            the program's primary place (so the program
//                            resolves to its own place_id only).
//   action 'add_place'    -> { place_id } links a brand sibling. Enforces
//                            one-active-program-per-place (no DB constraint).
//   action 'remove_place' -> { place_id } unlinks a place; primary is locked.
//
// All mutating actions return the refreshed state (same shape as 'get').
//
// The brand-sibling definition matches the dashboard entity-picker
// (partner-capabilities.sql): same partner_id OR same hospitality_group
// OR sharing a parent/root place. There is no places.brand_name column.
//
// Untouched on purpose: has_multiple_locations (cosmetic card flag) and
// get_loyalty_program_for_place (the mobile resolver).
//
// Deploy: supabase functions deploy loyalty-locations
// ============================================================
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type PlaceRow = {
  id: string;
  name: string | null;
  partner_id: string | null;
  hospitality_group: string | null;
  parent_place_id: string | null;
};

// Brand siblings = places that share a partner_id, a hospitality_group, or a
// parent/root place with the primary place. Built from separate equality
// queries (never string-interpolated into .or()) so brand names with commas
// or parentheses can't break the filter. The primary place is always included.
async function brandSiblings(supabase: SupabaseClient, place: PlaceRow) {
  const byId = new Map<string, { id: string; name: string | null }>();
  const add = (rows: Array<{ id: string; name: string | null }> | null) =>
    (rows || []).forEach((r) => byId.set(r.id, r));

  const root = place.parent_place_id || place.id;

  if (place.partner_id) {
    const { data } = await supabase.from("places").select("id, name")
      .eq("partner_id", place.partner_id);
    add(data);
  }
  const group = (place.hospitality_group || "").trim();
  if (group) {
    const { data } = await supabase.from("places").select("id, name")
      .eq("hospitality_group", group);
    add(data);
  }
  const { data: rootRow } = await supabase.from("places").select("id, name").eq("id", root);
  add(rootRow);
  const { data: children } = await supabase.from("places").select("id, name")
    .eq("parent_place_id", root);
  add(children);

  if (!byId.has(place.id)) byId.set(place.id, { id: place.id, name: place.name });
  return [...byId.values()];
}

// Returns a human-readable reason if `targetId` is already claimed by another
// active program (its primary place, or one of its linked locations), else null.
async function placeConflict(
  supabase: SupabaseClient,
  targetId: string,
  programId: string,
): Promise<string | null> {
  const { data: asPrimary } = await supabase.from("loyalty_programs")
    .select("id").eq("place_id", targetId).eq("is_active", true)
    .neq("id", programId).limit(1);
  if (asPrimary && asPrimary.length) {
    return "That location already has its own loyalty program.";
  }
  const { data: asLinked } = await supabase.from("loyalty_program_locations")
    .select("place_id, loyalty_programs!inner(is_active)")
    .eq("place_id", targetId)
    .neq("program_id", programId)
    .eq("loyalty_programs.is_active", true)
    .limit(1);
  if (asLinked && asLinked.length) {
    return "That location is already linked to another active loyalty program.";
  }
  return null;
}

// Current link state + annotated candidate list. Re-reads link_locations so it
// is always fresh after a mutation.
async function buildState(
  supabase: SupabaseClient,
  place: PlaceRow,
  programId: string,
) {
  const primaryPlaceId = place.id;

  const { data: prog } = await supabase.from("loyalty_programs")
    .select("link_locations").eq("id", programId).maybeSingle();

  const siblings = await brandSiblings(supabase, place);
  const siblingIds = siblings.map((s) => s.id);

  const { data: mine } = await supabase.from("loyalty_program_locations")
    .select("place_id").eq("program_id", programId);
  const linkedSet = new Set<string>((mine || []).map((r) => r.place_id));
  linkedSet.add(primaryPlaceId); // primary is always linked

  // Conflicts across the candidate set, batched.
  const { data: otherPrimaries } = await supabase.from("loyalty_programs")
    .select("place_id").eq("is_active", true).neq("id", programId).in("place_id", siblingIds);
  const primarySet = new Set<string>((otherPrimaries || []).map((r) => r.place_id));

  const { data: otherLinks } = await supabase.from("loyalty_program_locations")
    .select("place_id, loyalty_programs!inner(is_active)")
    .neq("program_id", programId)
    .eq("loyalty_programs.is_active", true)
    .in("place_id", siblingIds);
  const otherLinkSet = new Set<string>((otherLinks || []).map((r) => r.place_id));

  const candidates = siblings
    .map((s) => {
      const isPrimary = s.id === primaryPlaceId;
      const linked = linkedSet.has(s.id);
      let conflict: string | null = null;
      if (!linked && !isPrimary) {
        if (primarySet.has(s.id)) conflict = "Has its own loyalty program";
        else if (otherLinkSet.has(s.id)) conflict = "Linked to another program";
      }
      return { place_id: s.id, name: s.name, primary: isPrimary, linked, conflict };
    })
    // Primary first, then linked, then the rest — stable for the UI.
    .sort((a, b) =>
      (b.primary ? 1 : 0) - (a.primary ? 1 : 0) ||
      (b.linked ? 1 : 0) - (a.linked ? 1 : 0) ||
      String(a.name || "").localeCompare(String(b.name || "")));

  return {
    ok: true,
    link_locations: !!(prog && prog.link_locations),
    primary_place_id: primaryPlaceId,
    candidates,
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  const json = (body: unknown, status = 200) =>
    new Response(JSON.stringify(body), {
      status,
      headers: { ...cors, "Content-Type": "application/json" },
    });

  try {
    const body = await req.json().catch(() => ({}));
    const partner_token = body.partner_token;
    const action = body.action;
    if (!partner_token || !action) {
      return json({ ok: false, error: "partner_token and action are required" }, 400);
    }

    const supabase = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
    );

    // Resolve token -> primary place (service role bypasses RLS).
    const { data: place, error: placeErr } = await supabase.from("places")
      .select("id, name, partner_id, hospitality_group, parent_place_id")
      .eq("partner_access_token", partner_token)
      .maybeSingle();
    if (placeErr) return json({ ok: false, error: placeErr.message }, 500);
    if (!place) return json({ ok: false, error: "Not authorized" }, 401);

    // Active loyalty program for the primary place.
    const { data: program, error: progErr } = await supabase.from("loyalty_programs")
      .select("id, place_id, link_locations")
      .eq("place_id", place.id)
      .eq("is_active", true)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (progErr) return json({ ok: false, error: progErr.message }, 500);
    if (!program) return json({ ok: false, error: "No active loyalty program for this location." }, 404);

    const programId = program.id as string;
    const primaryPlaceId = place.id as string;

    if (action === "get") {
      return json(await buildState(supabase, place, programId));
    }

    if (action === "set_link") {
      const enabled = !!body.enabled;
      const { error: updErr } = await supabase.from("loyalty_programs")
        .update({ link_locations: enabled }).eq("id", programId);
      if (updErr) return json({ ok: false, error: updErr.message }, 500);

      if (!enabled) {
        // Resolve to the primary place only: drop every other junction row.
        const { error: delErr } = await supabase.from("loyalty_program_locations")
          .delete().eq("program_id", programId).neq("place_id", primaryPlaceId);
        if (delErr) return json({ ok: false, error: delErr.message }, 500);
      }
      return json(await buildState(supabase, place, programId));
    }

    if (action === "add_place") {
      const targetId = body.place_id;
      if (!targetId) return json({ ok: false, error: "place_id is required" }, 400);

      // Target must be a sibling of this brand.
      const siblings = await brandSiblings(supabase, place);
      if (!siblings.some((s) => s.id === targetId)) {
        return json({ ok: false, error: "That location is not part of this brand." }, 400);
      }
      // One active program per place.
      const conflict = await placeConflict(supabase, targetId, programId);
      if (conflict) return json({ ok: false, error: conflict }, 409);

      const { error: insErr } = await supabase.from("loyalty_program_locations")
        .upsert({ program_id: programId, place_id: targetId },
          { onConflict: "program_id,place_id", ignoreDuplicates: true });
      if (insErr) return json({ ok: false, error: insErr.message }, 500);
      return json(await buildState(supabase, place, programId));
    }

    if (action === "remove_place") {
      const targetId = body.place_id;
      if (!targetId) return json({ ok: false, error: "place_id is required" }, 400);
      if (targetId === primaryPlaceId) {
        return json({ ok: false, error: "The primary location can't be removed." }, 400);
      }
      const { error: delErr } = await supabase.from("loyalty_program_locations")
        .delete().eq("program_id", programId).eq("place_id", targetId);
      if (delErr) return json({ ok: false, error: delErr.message }, 500);
      return json(await buildState(supabase, place, programId));
    }

    return json({ ok: false, error: "Unknown action" }, 400);
  } catch (e) {
    return json({ ok: false, error: String((e as Error)?.message || e) }, 500);
  }
});
