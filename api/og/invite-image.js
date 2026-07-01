// api/og/invite-image.js
//
// Generated portrait image used as the og:image for a collaborator invite
// (/invites/{token}). It mirrors the shared-itinerary card so an invite unfurls
// with the same premium look as a trip share — just re-badged as an invite.
//
//   /api/og/invite-image?token={inviteToken}
//
// The invite token is the capability: get_trip_invite_preview (SECURITY DEFINER)
// validates it and returns the trip meta, then get_shared_itinerary_by_id fills
// in the place photos for the hero + thumbnails. If the photo RPC is
// unavailable we still render a clean, photo-less card from the invite meta.

import { ImageResponse } from '@vercel/og';
import { sbRpc } from './_lib/og.js';
import {
  buildCard, fieldsFrom, loadInterFonts, shortRange, CANVAS_W, CANVAS_H,
} from './itinerary-image.js';

export const config = { runtime: 'edge' };

const BADGE = 'Trip invite';
const FOOTER = 'Join this trip on troddr';

// get_trip_invite_preview returns a TABLE (one row). PostgREST gives an array.
function firstRow(data) {
  if (Array.isArray(data)) return data[0] || null;
  return data || null;
}

// Photo-less fallback fields, built from the invite preview meta alone.
function metaFields(preview) {
  const destination =
    preview?.trip_destination || preview?.trip_title || 'My Trip';
  const inviter = preview?.inviter_name;
  return {
    destination,
    dateRange: shortRange(preview?.trip_start_date, preview?.trip_end_date),
    stopsLabel: '',
    names: inviter ? `Invited by ${inviter}` : '',
    hero: undefined,
    thumbs: [],
  };
}

export default async function handler(request) {
  const url = new URL(request.url);
  const token = url.searchParams.get('token') || '';

  const [preview, fonts] = await Promise.all([
    token ? sbRpc('get_trip_invite_preview', { _token: token }) : null,
    loadInterFonts(),
  ]);
  const invite = firstRow(preview);

  let fields;
  if (invite?.trip_id) {
    // Try to enrich with place photos; degrade gracefully if it fails.
    const byId = await sbRpc('get_shared_itinerary_by_id', {
      _itinerary_id: invite.trip_id,
    });
    const photo = byId && (byId.items || byId.places) ? fieldsFrom(byId) : null;
    fields = photo && photo.hero ? photo : metaFields(invite);
    // Keep the invite's destination/dates even when photos resolve, so the card
    // always reflects the invited trip.
    fields.destination = invite.trip_destination || fields.destination;
    fields.dateRange =
      shortRange(invite.trip_start_date, invite.trip_end_date) || fields.dateRange;
  } else {
    // Invalid/expired token → generic branded invite card, never leaks a trip.
    fields = {
      destination: 'Plan together',
      dateRange: '',
      stopsLabel: 'Join the trip on TRODDR',
      names: '',
      hero: undefined,
      thumbs: [],
    };
  }

  const responseOptions = {
    width: CANVAS_W,
    height: CANVAS_H,
    headers: { 'Cache-Control': 'public, s-maxage=3600, stale-while-revalidate=86400' },
  };
  if (fonts.length) responseOptions.fonts = fonts;

  return new ImageResponse(
    buildCard({ ...fields, badge: BADGE, footer: FOOTER }),
    responseOptions
  );
}
