'use server';

// WhatsApp Inbox (migration 053). New module -- nothing else imports this.
//   getWhatsAppInbox   : the conversation list, ONE db call (read-only,
//                        runs through /api/rpc, see tools/parallel-reads)
//   openWhatsAppThread : opening a chat, ONE db call (marks replies read
//                        and returns thread + templates sent + patients)
//   sendWhatsAppReply  : free-text reply inside WhatsApp's 24-hour window;
//                        sends, saves, and returns the refreshed thread in
//                        the same response (one request per click)

import { createClient } from '@/lib/supabase-server';
import { createAdminClient } from '@/lib/supabase-admin';
import { getCurrentUserId } from '@/lib/authUser';
import { sendWhatsAppText, REPLY_WINDOW_MS } from '@/lib/whatsappInbox';

const cleanMobile = (m) => String(m || '').replace(/\D/g, '');

export async function getWhatsAppInbox({ search = '', unreadOnly = false } = {}) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('ui_whatsapp_inbox', { p_search: search || '', p_unread_only: !!unreadOnly });
  if (error) return { error: error.message };
  return data;
}

export async function openWhatsAppThread(mobile) {
  const supabase = await createClient();
  const { data, error } = await supabase.rpc('whatsapp_open_thread', { p_mobile: cleanMobile(mobile) });
  if (error) return { error: error.message };
  return data;
}

export async function sendWhatsAppReply({ mobile, text, replyToWaId = null }) {
  const to = cleanMobile(mobile);
  const body = String(text || '').trim();
  if (!to) return { error: 'No number selected.' };
  if (!body) return { error: 'Type a message first.' };
  if (body.length > 4096) return { error: 'Message is too long (WhatsApp allows 4096 characters).' };

  const supabase = await createClient();
  const userId = await getCurrentUserId(supabase);
  if (!userId) return { error: 'Your session has ended. Please log in again.' };

  // WhatsApp only allows free text within 24 hours of the patient's last
  // message (after that, only approved templates). Check before calling Meta
  // so staff get a plain explanation instead of an API error code.
  const { data: last } = await supabase
    .from('whatsapp_messages')
    .select('message_at')
    .eq('mobile', to)
    .eq('direction', 'in')
    .order('message_at', { ascending: false })
    .limit(1)
    .maybeSingle();
  if (!last || Date.now() - new Date(last.message_at).getTime() > REPLY_WINDOW_MS) {
    return { error: "More than 24 hours have passed since this patient's last message. WhatsApp only allows approved template messages now -- the patient needs to message again, or call them." };
  }

  const sent = await sendWhatsAppText({ to, text: body, replyToWaId });

  const admin = createAdminClient();
  const { error: saveError } = await admin.from('whatsapp_messages').insert({
    wa_message_id: sent.waMessageId || null,
    direction: 'out',
    mobile: to,
    msg_type: 'text',
    body,
    reply_to_wa_id: replyToWaId || null,
    status: sent.error ? 'failed' : 'sent',
    error_message: sent.error || null,
    sent_by: userId,
    message_at: new Date().toISOString(),
    raw: sent.data || null,
  });

  const { data: thread } = await supabase.rpc('whatsapp_open_thread', { p_mobile: to });

  if (sent.error) return { error: `WhatsApp did not accept the message: ${sent.error}`, thread };
  if (saveError) return { warning: `Sent, but could not be saved in the inbox: ${saveError.message}`, thread };
  return { ok: true, thread };
}
