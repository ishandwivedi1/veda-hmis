'use client';

// Client helper for background WhatsApp sends (speed-up, 23 Oct 2026).
//
// The "Send on WhatsApp" buttons now get an instant reply ({ queued, track })
// while the PDF + send run in the background. trackWhatsAppSend() follows
// the outcome through whatsapp_logs and resolves to the SAME shape the
// buttons always handled -- { success } | { error } | { warning } -- so each
// screen keeps its existing Sending / Sent / Failed display. Polling uses
// the parallel read route, so the rest of the page stays usable meanwhile.

import { getWhatsAppSendStatus } from '@/lib/rpc-reads/whatsapp__actions'; // parallel reads (tools/parallel-reads)

const wait = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

export async function trackWhatsAppSend(ticket, { timeoutMs = 60000 } = {}) {
  if (!ticket) return { error: 'Could not send -- try again.' };
  if (ticket.error || !ticket.queued) return ticket; // instant checks failed, or an old-style reply
  const deadline = Date.now() + timeoutMs;
  let delay = 3000; // a send takes a few seconds; no point asking sooner
  while (Date.now() < deadline) {
    await wait(delay);
    delay = 2500;
    try {
      const s = await getWhatsAppSendStatus(ticket.track);
      if (s?.status === 'sent') return { success: true };
      if (s?.status === 'failed') return { error: s.error || 'WhatsApp send failed.' };
    } catch {
      // network blip -- keep waiting
    }
  }
  return { warning: 'Still sending in the background. If the patient does not receive it, try again.' };
}
