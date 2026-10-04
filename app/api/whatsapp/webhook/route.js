// Meta WhatsApp Cloud API webhook (WhatsApp Inbox, migration 053).
//
// Configure in Meta: App -> WhatsApp -> Configuration -> Webhook
//   Callback URL : https://portal.vedaeyehospital.com/api/whatsapp/webhook
//   Verify token : the value of WHATSAPP_VERIFY_TOKEN (Vercel env)
//   Subscribe to : messages
//
// GET  -- Meta's one-time verification handshake.
// POST -- every patient message (saved to whatsapp_messages) and delivery
//         status updates for replies sent from the inbox. Always answers
//         200 quickly once the signature checks out, so Meta never retries
//         a message we already saved (duplicates are ignored anyway).
//
// No login here (Meta calls it) -- middleware.js lets this one path through.
// Authenticity comes from the X-Hub-Signature-256 check against
// WHATSAPP_APP_SECRET.

import { NextResponse } from 'next/server';
import { createAdminClient } from '@/lib/supabase-admin';
import { parseWebhookPayload, verifyMetaSignature } from '@/lib/whatsappInbox';

export const dynamic = 'force-dynamic';

export async function GET(request) {
  const p = request.nextUrl.searchParams;
  const expected = process.env.WHATSAPP_VERIFY_TOKEN;
  if (p.get('hub.mode') === 'subscribe' && expected && p.get('hub.verify_token') === expected) {
    return new NextResponse(p.get('hub.challenge') || '', { status: 200, headers: { 'content-type': 'text/plain' } });
  }
  return new NextResponse('Forbidden', { status: 403 });
}

const RANK = { sent: 1, delivered: 2, read: 3 };

export async function POST(request) {
  const raw = await request.text();

  const appSecret = process.env.WHATSAPP_APP_SECRET;
  if (appSecret) {
    if (!verifyMetaSignature(raw, request.headers.get('x-hub-signature-256'), appSecret)) {
      return new NextResponse('Bad signature', { status: 401 });
    }
  } else {
    console.warn('[whatsapp webhook] WHATSAPP_APP_SECRET not set -- signature not checked');
  }

  let payload;
  try { payload = JSON.parse(raw); } catch { return new NextResponse('Bad JSON', { status: 400 }); }

  const { inbound, statuses } = parseWebhookPayload(payload, process.env.WHATSAPP_PHONE_NUMBER_ID);
  if (!inbound.length && !statuses.length) return NextResponse.json({ ok: true });

  const supabase = createAdminClient();

  try {
    if (inbound.length) {
      const { error } = await supabase
        .from('whatsapp_messages')
        .upsert(inbound, { onConflict: 'wa_message_id', ignoreDuplicates: true });
      if (error) console.error('[whatsapp webhook] insert failed:', error.message);
    }

    if (statuses.length) {
      // Meta sends statuses for every template send too; only replies sent
      // from the inbox live in whatsapp_messages, so look those up first.
      const ids = [...new Set(statuses.map((s) => s.id).filter(Boolean))];
      const { data: existing } = await supabase
        .from('whatsapp_messages')
        .select('wa_message_id, status')
        .in('wa_message_id', ids);
      for (const row of existing || []) {
        // Statuses can arrive out of order -- never step back (read -> delivered).
        const updates = statuses.filter((s) => s.id === row.wa_message_id);
        let best = row.status;
        let error = null;
        for (const s of updates) {
          if (s.status === 'failed') { best = 'failed'; error = s.error; }
          else if (best !== 'failed' && (RANK[s.status] || 0) > (RANK[best] || 0)) best = s.status;
        }
        if (best !== row.status) {
          await supabase.from('whatsapp_messages')
            .update({ status: best, ...(error ? { error_message: error } : {}) })
            .eq('wa_message_id', row.wa_message_id);
        }
      }
    }
  } catch (err) {
    // Still 200: Meta retrying won't fix a database problem, and the
    // payload is in the function logs for diagnosis.
    console.error('[whatsapp webhook] failed:', err?.message, raw.slice(0, 2000));
  }

  return NextResponse.json({ ok: true });
}
