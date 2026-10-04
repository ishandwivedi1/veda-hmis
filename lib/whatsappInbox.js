// lib/whatsappInbox.js
// WhatsApp Inbox (migration 053): turning Meta webhook payloads into
// whatsapp_messages rows, sending free-text replies, and fetching media.
// SERVER ONLY -- uses WHATSAPP_ACCESS_TOKEN and the service key.
// lib/whatsapp.js (template sends + whatsapp_logs) is deliberately untouched.

import crypto from 'crypto';

const API_VERSION = process.env.WHATSAPP_API_VERSION || 'v21.0';
export const REPLY_WINDOW_MS = 24 * 60 * 60 * 1000;

// ── Webhook signature (X-Hub-Signature-256 = sha256 HMAC of the raw body
// with the Meta App Secret). Returns true when it matches. ─────────────
export function verifyMetaSignature(rawBody, header, appSecret) {
  if (!header || !appSecret) return false;
  const expected = 'sha256=' + crypto.createHmac('sha256', appSecret).update(rawBody, 'utf8').digest('hex');
  const a = Buffer.from(expected);
  const b = Buffer.from(String(header));
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

// A readable one-line body for any message type, so the list and thread
// always have something to show.
function describeMessage(m) {
  switch (m.type) {
    case 'text': return m.text?.body || '';
    case 'image': return m.image?.caption || '';
    case 'video': return m.video?.caption || '';
    case 'document': return m.document?.caption || m.document?.filename || '';
    case 'audio': return m.audio?.voice ? 'Voice note' : 'Audio';
    case 'sticker': return 'Sticker';
    case 'location': {
      const l = m.location || {};
      const where = [l.name, l.address].filter(Boolean).join(', ');
      return `Location: ${where || `${l.latitude}, ${l.longitude}`}`;
    }
    case 'contacts': return `Contact card: ${(m.contacts || []).map((c) => c.name?.formatted_name).filter(Boolean).join(', ')}`;
    case 'button': return m.button?.text || '';
    case 'interactive': return m.interactive?.button_reply?.title || m.interactive?.list_reply?.title || '';
    case 'reaction': return m.reaction?.emoji ? `Reacted ${m.reaction.emoji}` : 'Removed a reaction';
    default: return `(${m.type || 'unknown'} message — not supported by WhatsApp Cloud API)`;
  }
}

function mediaOf(m) {
  const media = m[m.type];
  // Every row carries the same keys, so a batch insert never mixes shapes.
  if (!media || !['image', 'video', 'document', 'audio', 'sticker'].includes(m.type)) return { media_id: null, media_mime: null, media_filename: null };
  return { media_id: media.id || null, media_mime: media.mime_type || null, media_filename: media.filename || null };
}

// Meta payload -> { inbound: [rows to insert], statuses: [{ id, status, error }] }.
// Only events for OUR phone number id are kept (a WhatsApp Business Account
// can hold more than one number).
export function parseWebhookPayload(payload, phoneNumberId) {
  const inbound = [];
  const statuses = [];
  for (const entry of payload?.entry || []) {
    for (const change of entry.changes || []) {
      if (change.field !== 'messages') continue;
      const v = change.value || {};
      if (phoneNumberId && v.metadata?.phone_number_id && String(v.metadata.phone_number_id) !== String(phoneNumberId)) continue;
      const names = Object.fromEntries((v.contacts || []).map((c) => [c.wa_id, c.profile?.name || null]));
      for (const m of v.messages || []) {
        inbound.push({
          wa_message_id: m.id,
          direction: 'in',
          mobile: String(m.from || '').replace(/\D/g, ''),
          contact_name: names[m.from] || null,
          msg_type: m.type || 'unknown',
          body: describeMessage(m),
          ...mediaOf(m),
          reply_to_wa_id: m.context?.id || (m.type === 'reaction' ? m.reaction?.message_id : null) || null,
          status: 'received',
          message_at: m.timestamp ? new Date(Number(m.timestamp) * 1000).toISOString() : new Date().toISOString(),
          raw: m,
        });
      }
      for (const s of v.statuses || []) {
        statuses.push({
          id: s.id,
          status: s.status,
          error: (s.errors || []).map((e) => e.title || e.message).filter(Boolean).join('; ') || null,
        });
      }
    }
  }
  return { inbound, statuses };
}

// Free-text reply. Only allowed by WhatsApp within 24h of the patient's
// last message -- the caller checks that first; Meta enforces it anyway.
export async function sendWhatsAppText({ to, text, replyToWaId = null }) {
  const token = process.env.WHATSAPP_ACCESS_TOKEN;
  const phoneNumberId = process.env.WHATSAPP_PHONE_NUMBER_ID;
  if (!token || !phoneNumberId) return { error: 'WhatsApp credentials missing (WHATSAPP_ACCESS_TOKEN / WHATSAPP_PHONE_NUMBER_ID)' };
  const payload = {
    messaging_product: 'whatsapp',
    recipient_type: 'individual',
    to,
    type: 'text',
    text: { preview_url: true, body: text },
  };
  if (replyToWaId) payload.context = { message_id: replyToWaId };
  try {
    const res = await fetch(`https://graph.facebook.com/${API_VERSION}/${phoneNumberId}/messages`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(payload),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) return { error: data?.error?.message || `WhatsApp API error (status ${res.status})`, data };
    return { waMessageId: data?.messages?.[0]?.id || null, data };
  } catch (err) {
    return { error: err.message || 'Could not reach WhatsApp' };
  }
}

// Downloads a media file a patient sent (Meta keeps it ~30 days).
export async function fetchWhatsAppMedia(mediaId) {
  const token = process.env.WHATSAPP_ACCESS_TOKEN;
  if (!token) return { error: 'WhatsApp credentials missing' };
  const meta = await fetch(`https://graph.facebook.com/${API_VERSION}/${encodeURIComponent(mediaId)}`, {
    headers: { Authorization: `Bearer ${token}` },
  });
  const info = await meta.json().catch(() => ({}));
  if (!meta.ok || !info.url) return { error: info?.error?.message || 'Media not found (WhatsApp keeps files about 30 days)' };
  const file = await fetch(info.url, { headers: { Authorization: `Bearer ${token}` } });
  if (!file.ok) return { error: `Could not download media (status ${file.status})` };
  return { buffer: Buffer.from(await file.arrayBuffer()), mime: info.mime_type || file.headers.get('content-type') || 'application/octet-stream' };
}
